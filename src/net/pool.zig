/// pool.zig — Per-origin connection pool.
///
/// Enforces Chrome's connection limits:
///   - max 6 connections per origin (scheme://host:port)
///   - idle timeout: 30 seconds (evict connections unused for > 30s)
///   - max requests per connection: 100
///   - max total connections: 256 across all origins
///
/// NOTE: pool.zig is generic over connection type — no TLS import needed.
/// without curl-impersonate. The pool stores opaque PooledConn entries;
/// the caller provides/receives connection handles as *anyopaque pointers
/// during the real integration. Tests use a lightweight mock.
const std = @import("std");

pub const MAX_PER_ORIGIN: usize = 6;
pub const MAX_TOTAL: usize = 256;
pub const IDLE_TIMEOUT_MS: i64 = 30_000;
pub const MAX_REQUESTS: u32 = 100;

// ── PooledConn ─────────────────────────────────────────────────────────────

pub const PooledConn = struct {
    /// Opaque handle to the underlying connection.
    handle: *anyopaque,
    in_use: bool,
    last_used_ms: i64,
    request_count: u32,
    /// Optional teardown callback. When non-null, called during eviction to close
    /// the underlying connection. The handle is passed as the sole argument.
    close_fn: ?*const fn (*anyopaque) void = null,

    pub fn isHealthy(self: *const PooledConn) bool {
        const now = std.time.milliTimestamp();
        return !self.in_use and
            (now - self.last_used_ms) < IDLE_TIMEOUT_MS and
            self.request_count < MAX_REQUESTS;
    }
};

// ── OriginPool ─────────────────────────────────────────────────────────────

pub const OriginPool = struct {
    conns: std.ArrayList(PooledConn) = .{},

    pub fn deinit(self: *OriginPool, allocator: std.mem.Allocator) void {
        for (self.conns.items) |*c| {
            if (c.close_fn) |close| close(c.handle);
        }
        self.conns.deinit(allocator);
    }

    /// Total connection count (idle + in-use).
    pub fn totalCount(self: *const OriginPool) usize {
        return self.conns.items.len;
    }

    /// Count of idle (available) connections.
    pub fn idleCount(self: *const OriginPool) usize {
        var n: usize = 0;
        for (self.conns.items) |*c| {
            if (!c.in_use) n += 1;
        }
        return n;
    }

    /// Acquire a healthy idle connection, marking it in_use. Returns null if none.
    pub fn acquireIdle(self: *OriginPool) ?*anyopaque {
        for (self.conns.items) |*c| {
            if (c.isHealthy()) {
                c.in_use = true;
                return c.handle;
            }
        }
        return null;
    }

    /// Register a new connection handle in the pool (in_use = true).
    /// Returns error.PoolFull if already at MAX_PER_ORIGIN.
    pub fn addNew(self: *OriginPool, allocator: std.mem.Allocator, handle: *anyopaque, close_fn: ?*const fn (*anyopaque) void) !void {
        if (self.conns.items.len >= MAX_PER_ORIGIN) return error.PoolFull;
        try self.conns.append(allocator, PooledConn{
            .handle = handle,
            .in_use = true,
            .last_used_ms = std.time.milliTimestamp(),
            .request_count = 0,
            .close_fn = close_fn,
        });
    }

    /// Release a connection back to the pool.
    pub fn release(self: *OriginPool, handle: *anyopaque) void {
        for (self.conns.items) |*c| {
            if (c.handle == handle) {
                c.in_use = false;
                c.last_used_ms = std.time.milliTimestamp();
                c.request_count += 1;
                return;
            }
        }
    }

    /// Remove a connection from the pool and close it if needed.
    pub fn remove(self: *OriginPool, handle: *anyopaque) bool {
        var i: usize = 0;
        while (i < self.conns.items.len) : (i += 1) {
            const conn = &self.conns.items[i];
            if (conn.handle == handle) {
                if (conn.close_fn) |close| close(conn.handle);
                _ = self.conns.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Remove connections idle for longer than `older_than_ms` milliseconds.
    pub fn evictIdle(self: *OriginPool, allocator: std.mem.Allocator, older_than_ms: i64) usize {
        _ = allocator;
        const now = std.time.milliTimestamp();
        var i: usize = 0;
        var evicted: usize = 0;
        while (i < self.conns.items.len) {
            const c = &self.conns.items[i];
            if (!c.in_use and (now - c.last_used_ms) >= older_than_ms) {
                if (c.close_fn) |close| close(c.handle);
                _ = self.conns.swapRemove(i);
                evicted += 1;
                continue;
            }
            i += 1;
        }
        return evicted;
    }
};

// ── ConnectionPool ─────────────────────────────────────────────────────────

pub const ConnectionPool = struct {
    pools: std.StringHashMap(OriginPool),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    total_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ConnectionPool {
        return .{
            .pools = std.StringHashMap(OriginPool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        var it = self.pools.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.pools.deinit();
    }

    /// Get-or-create the OriginPool for `origin`.
    fn getOrCreatePool(self: *ConnectionPool, origin: []const u8) !*OriginPool {
        if (self.pools.getPtr(origin)) |pool| return pool;

        const owned_origin = try self.allocator.dupe(u8, origin);
        errdefer self.allocator.free(owned_origin);

        const result = try self.pools.getOrPut(owned_origin);
        if (!result.found_existing) {
            result.value_ptr.* = OriginPool{};
        } else {
            self.allocator.free(owned_origin);
        }
        return result.value_ptr;
    }

    /// Acquire an idle connection for `origin`, or return error.PoolFull / error.NoIdle.
    /// Caller must call `release()` when done.
    pub fn acquireIdle(self: *ConnectionPool, origin: []const u8) !?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pools.getPtr(origin)) |pool| {
            return pool.acquireIdle();
        }
        return null;
    }

    /// Register a new connection in the pool for `origin`.
    pub fn addNew(self: *ConnectionPool, origin: []const u8, handle: *anyopaque, close_fn: ?*const fn (*anyopaque) void) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.total_count >= MAX_TOTAL) return error.PoolFull;
        const pool = try self.getOrCreatePool(origin);
        try pool.addNew(self.allocator, handle, close_fn);
        self.total_count += 1;
    }

    /// Return `handle` to the idle pool for `origin`.
    pub fn release(self: *ConnectionPool, origin: []const u8, handle: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pools.getPtr(origin)) |pool| {
            pool.release(handle);
        }
    }

    /// Remove a broken or no-longer-reusable connection from the pool.
    pub fn remove(self: *ConnectionPool, origin: []const u8, handle: *anyopaque) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pools.getPtr(origin)) |pool| {
            if (pool.remove(handle)) {
                if (self.total_count > 0) self.total_count -= 1;
                if (pool.totalCount() == 0) {
                    if (self.pools.fetchRemove(origin)) |entry| {
                        var removed_pool = entry.value;
                        removed_pool.deinit(self.allocator);
                        self.allocator.free(entry.key);
                    }
                }
                return true;
            }
        }
        return false;
    }

    /// Count of connections for a specific origin.
    pub fn countForOrigin(self: *ConnectionPool, origin: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pools.getPtr(origin)) |pool| return pool.totalCount();
        return 0;
    }

    /// Total pooled connection count across all origins.
    pub fn totalCount(self: *ConnectionPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.total_count;
    }

    /// Check if the global connection limit has been reached.
    pub fn isFull(self: *ConnectionPool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.total_count >= MAX_TOTAL;
    }

    /// Evict idle connections older than `older_than_ms` milliseconds across all origins.
    pub fn evictIdle(self: *ConnectionPool, older_than_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var empty_origins = std.ArrayListUnmanaged([]const u8){};
        defer empty_origins.deinit(self.allocator);

        var it = self.pools.valueIterator();
        while (it.next()) |pool| {
            const evicted = pool.evictIdle(self.allocator, older_than_ms);
            if (evicted <= self.total_count) {
                self.total_count -= evicted;
            } else {
                self.total_count = 0;
            }
        }

        var key_it = self.pools.iterator();
        while (key_it.next()) |entry| {
            if (entry.value_ptr.totalCount() == 0) {
                empty_origins.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }

        for (empty_origins.items) |origin| {
            if (self.pools.fetchRemove(origin)) |entry| {
                var removed_pool = entry.value;
                removed_pool.deinit(self.allocator);
                self.allocator.free(entry.key);
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

// Lightweight mock handle — just a u8 value we can take a pointer to.
var mock_handles: [16]u8 = [_]u8{0} ** 16;

fn mockHandle(i: usize) *anyopaque {
    return @ptrCast(&mock_handles[i]);
}

test "OriginPool starts empty" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), pool.totalCount());
}

test "OriginPool.addNew adds a connection" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    try pool.addNew(std.testing.allocator, mockHandle(0), null);
    try std.testing.expectEqual(@as(usize, 1), pool.totalCount());
}

test "OriginPool.addNew rejects when at MAX_PER_ORIGIN (6)" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    for (0..MAX_PER_ORIGIN) |i| try pool.addNew(std.testing.allocator, mockHandle(i), null);
    const err = pool.addNew(std.testing.allocator, mockHandle(MAX_PER_ORIGIN), null);
    try std.testing.expectError(error.PoolFull, err);
}

test "OriginPool.acquireIdle returns null when empty" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?*anyopaque, null), pool.acquireIdle());
}

test "OriginPool.acquireIdle returns null when all in_use" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    try pool.addNew(std.testing.allocator, mockHandle(0), null); // in_use = true
    try std.testing.expectEqual(@as(?*anyopaque, null), pool.acquireIdle());
}

test "OriginPool.release makes connection available again" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    const h = mockHandle(0);
    try pool.addNew(std.testing.allocator, h, null);
    pool.release(h);
    const acquired = pool.acquireIdle();
    try std.testing.expect(acquired != null);
    try std.testing.expectEqual(h, acquired.?);
}

test "OriginPool.release increments request_count" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    const h = mockHandle(0);
    try pool.addNew(std.testing.allocator, h, null);
    pool.release(h);
    try std.testing.expectEqual(@as(u32, 1), pool.conns.items[0].request_count);
}

test "OriginPool evicts idle connections older than threshold" {
    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    const h = mockHandle(0);
    try pool.addNew(std.testing.allocator, h, null);
    pool.release(h);
    // Backdate last_used_ms to simulate 31s of idle time
    pool.conns.items[0].last_used_ms -= 31_000;
    _ = pool.evictIdle(std.testing.allocator, IDLE_TIMEOUT_MS);
    try std.testing.expectEqual(@as(usize, 0), pool.totalCount());
}

test "ConnectionPool.acquireIdle returns null for unknown origin" {
    var cp = ConnectionPool.init(std.testing.allocator);
    defer cp.deinit();
    const result = try cp.acquireIdle("https://example.com:443");
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "ConnectionPool.addNew and release lifecycle" {
    var cp = ConnectionPool.init(std.testing.allocator);
    defer cp.deinit();
    const origin = "https://example.com:443";
    const h = mockHandle(0);
    try cp.addNew(origin, h, null);
    try std.testing.expectEqual(@as(usize, 1), cp.countForOrigin(origin));

    cp.release(origin, h);
    const acquired = try cp.acquireIdle(origin);
    try std.testing.expect(acquired != null);
}

test "ConnectionPool.remove decrements total_count" {
    var cp = ConnectionPool.init(std.testing.allocator);
    defer cp.deinit();
    const origin = "https://example.com:443";
    const h = mockHandle(0);

    try cp.addNew(origin, h, null);
    try std.testing.expectEqual(@as(usize, 1), cp.totalCount());
    try std.testing.expect(cp.remove(origin, h));
    try std.testing.expectEqual(@as(usize, 0), cp.totalCount());
    try std.testing.expectEqual(@as(usize, 0), cp.countForOrigin(origin));
}

test "ConnectionPool copies origin keys instead of borrowing caller buffer" {
    var cp = ConnectionPool.init(std.testing.allocator);
    defer cp.deinit();

    var origin_buf = [_]u8{ 'h', 't', 't', 'p', ':', '/', '/', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm', ':', '8', '0' };
    try cp.addNew(origin_buf[0..], mockHandle(0), null);

    @memset(origin_buf[0..], 'x');

    try std.testing.expectEqual(@as(usize, 1), cp.countForOrigin("http://example.com:80"));
}

test "ConnectionPool per-host limit enforced at 6" {
    var cp = ConnectionPool.init(std.testing.allocator);
    defer cp.deinit();
    const origin = "https://example.com:443";
    for (0..MAX_PER_ORIGIN) |i| {
        try cp.addNew(origin, mockHandle(i), null);
    }
    const err = cp.addNew(origin, mockHandle(MAX_PER_ORIGIN), null);
    try std.testing.expectError(error.PoolFull, err);
}

test "ConnectionPool concurrent addNew caps successes at 6" {
    const origin = "https://example.com:443";
    var cp = ConnectionPool.init(std.heap.page_allocator);
    defer cp.deinit();

    const Worker = struct {
        fn run(pool: *ConnectionPool, idx: usize, results: *[10]bool) void {
            pool.addNew(origin, mockHandle(idx), null) catch {
                results[idx] = false;
                return;
            };
            results[idx] = true;
        }
    };

    var results = [_]bool{false} ** 10;
    var threads: [10]std.Thread = undefined;
    for (0..10) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ &cp, i, &results });
    }
    for (threads) |thread| thread.join();

    var successes: usize = 0;
    for (results) |ok| {
        if (ok) successes += 1;
    }

    try std.testing.expectEqual(@as(usize, MAX_PER_ORIGIN), successes);
    try std.testing.expectEqual(@as(usize, MAX_PER_ORIGIN), cp.countForOrigin(origin));
}

test "ConnectionPool.countForOrigin returns 0 for unknown origin" {
    var cp = ConnectionPool.init(std.testing.allocator);
    defer cp.deinit();
    try std.testing.expectEqual(@as(usize, 0), cp.countForOrigin("https://unknown.com:443"));
}

test "MAX_PER_ORIGIN constant is 6 (Chrome limit)" {
    try std.testing.expectEqual(@as(usize, 6), MAX_PER_ORIGIN);
}

test "IDLE_TIMEOUT_MS constant is 30000 (30 seconds)" {
    try std.testing.expectEqual(@as(i64, 30_000), IDLE_TIMEOUT_MS);
}

test "ConnectionPool.addNew rejects when at MAX_TOTAL (256)" {
    var cp = ConnectionPool.init(std.testing.allocator);
    defer cp.deinit();
    // Pre-allocate origin strings so each has a stable address in the StringHashMap.
    var origins: [MAX_TOTAL][]u8 = undefined;
    for (0..MAX_TOTAL) |i| {
        origins[i] = try std.fmt.allocPrint(std.testing.allocator, "https://host{d}:443", .{i});
    }
    defer for (0..MAX_TOTAL) |i| std.testing.allocator.free(origins[i]);

    for (0..MAX_TOTAL) |i| {
        try cp.addNew(origins[i], mockHandle(i % mock_handles.len), null);
    }
    // Next one should fail
    const err = cp.addNew("https://overflow:443", mockHandle(0), null);
    try std.testing.expectError(error.PoolFull, err);
}

test "close_fn is called during eviction" {
    const S = struct {
        var called: bool = false;
        fn close(_: *anyopaque) void {
            called = true;
        }
    };
    S.called = false;

    var pool = OriginPool{};
    defer pool.deinit(std.testing.allocator);
    const h = mockHandle(0);
    try pool.addNew(std.testing.allocator, h, S.close);
    pool.release(h);
    // Backdate to trigger eviction
    pool.conns.items[0].last_used_ms -= 31_000;
    _ = pool.evictIdle(std.testing.allocator, IDLE_TIMEOUT_MS);
    try std.testing.expect(S.called);
}
