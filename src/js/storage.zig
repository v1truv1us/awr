/// storage.zig — Web Storage backend for AWR (Tier 3 — T3.A).
///
/// Implements the `Storage` interface (getItem/setItem/removeItem/clear/
/// key/length) used by `localStorage` and `sessionStorage`.
///
/// Two structs:
///   - `LocalStorage`  — origin-scoped, disk-persisted to
///     `<storage_dir>/<encoded-origin>.json`. Survives process restart.
///   - `SessionStorage` — in-memory only, per-Page lifetime.
///
/// Both enforce a 5 MB per-instance quota and throw `QuotaExceeded` when
/// `setItem` would push the total beyond it (atomic: original entry is
/// preserved on failure).
///
/// The owning `BridgeCtx` (src/dom/bridge.zig) constructs both storages
/// with `init`, sets the origin via `LocalStorage.setOrigin` once
/// `window.location` is known, and calls `deinit` on teardown.
///
/// Native callbacks in `src/dom/bridge.zig` reach these via the bridge
/// pointer; the `BRIDGE_POLYFILL` JS shim calls those natives instead
/// of maintaining its own in-memory map.
const std = @import("std");

/// Per-spec quota. Browsers vary (Chrome: ~10 MB, Firefox: ~10 MB,
/// Safari: ~5 MB) — AWR picks the conservative end so apps that
/// branch on `QuotaExceededError` see realistic behavior.
pub const QUOTA_BYTES: usize = 5 * 1024 * 1024;

pub const StorageError = error{
    QuotaExceeded,
    InvalidOrigin,
    OutOfMemory,
};

/// Common Storage interface state. Used by both Local and Session
/// storage; the persistence + origin layer is added by `LocalStorage`.
///
/// Backing: `StringArrayHashMapUnmanaged` preserves insertion order so
/// that `key(n)` returns entries in the order they were added — Web
/// Storage spec calls this the "ordered key list" and WPT enforces it.
const StorageMap = struct {
    allocator: std.mem.Allocator,
    /// All keys + values are heap-owned ([]u8). Entry keys live in the
    /// map's internal storage; values are independently allocated.
    data: std.StringArrayHashMapUnmanaged([]u8),
    /// Sum of `key.len + value.len` across all entries. Used for quota.
    byte_count: usize,

    fn init(allocator: std.mem.Allocator) StorageMap {
        return .{
            .allocator = allocator,
            .data = .empty,
            .byte_count = 0,
        };
    }

    fn deinit(self: *StorageMap) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit(self.allocator);
        self.byte_count = 0;
    }

    fn getItem(self: *const StorageMap, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }

    /// setItem with atomic semantics: if quota would be exceeded the
    /// original entry (if any) is preserved unchanged.
    fn setItem(self: *StorageMap, key: []const u8, value: []const u8) StorageError!bool {
        const old_value = self.data.get(key);
        const old_size = if (old_value) |v| key.len + v.len else 0;
        const new_size = key.len + value.len;

        if (self.byte_count - old_size + new_size > QUOTA_BYTES) {
            return StorageError.QuotaExceeded;
        }

        // Clone first so a failed alloc doesn't corrupt the map.
        const value_copy = self.allocator.dupe(u8, value) catch return StorageError.OutOfMemory;
        errdefer self.allocator.free(value_copy);

        if (old_value) |old| {
            // Replace value in place; key stays the same allocation and
            // its insertion-order index is preserved (ArrayHashMap put
            // for an existing key updates the value without reordering).
            self.allocator.free(old);
            self.data.put(self.allocator, key, value_copy) catch unreachable; // key already present
            self.byte_count = self.byte_count - old_size + new_size;
            return false; // not a new key
        }

        const key_copy = self.allocator.dupe(u8, key) catch return StorageError.OutOfMemory;
        errdefer self.allocator.free(key_copy);

        self.data.put(self.allocator, key_copy, value_copy) catch return StorageError.OutOfMemory;
        self.byte_count += new_size;
        return true; // new key
    }

    /// Returns true when an entry was removed. Uses `orderedRemove` so
    /// later keys keep their original relative order — matches what
    /// Chrome/Firefox do, and Web Storage WPT assumes.
    fn removeItem(self: *StorageMap, key: []const u8) bool {
        if (self.data.fetchOrderedRemove(key)) |kv| {
            self.byte_count -= kv.key.len + kv.value.len;
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    fn clear(self: *StorageMap) bool {
        if (self.data.count() == 0) return false;
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.clearRetainingCapacity();
        self.byte_count = 0;
        return true;
    }

    /// Returns the key at `index` in insertion order, or null when out
    /// of range. ArrayHashMap exposes `keys()` as a stable slice.
    fn keyAt(self: *const StorageMap, index: u32) ?[]const u8 {
        const keys = self.data.keys();
        if (index >= keys.len) return null;
        return keys[index];
    }

    fn length(self: *const StorageMap) u32 {
        return @intCast(self.data.count());
    }
};

pub const SessionStorage = struct {
    map: StorageMap,

    pub fn init(allocator: std.mem.Allocator) SessionStorage {
        return .{ .map = StorageMap.init(allocator) };
    }

    pub fn deinit(self: *SessionStorage) void {
        self.map.deinit();
    }

    pub fn getItem(self: *const SessionStorage, key: []const u8) ?[]const u8 {
        return self.map.getItem(key);
    }

    pub fn setItem(self: *SessionStorage, key: []const u8, value: []const u8) StorageError!void {
        _ = try self.map.setItem(key, value);
    }

    pub fn removeItem(self: *SessionStorage, key: []const u8) void {
        _ = self.map.removeItem(key);
    }

    pub fn clear(self: *SessionStorage) void {
        _ = self.map.clear();
    }

    pub fn keyAt(self: *const SessionStorage, index: u32) ?[]const u8 {
        return self.map.keyAt(index);
    }

    pub fn length(self: *const SessionStorage) u32 {
        return self.map.length();
    }
};

pub const LocalStorage = struct {
    map: StorageMap,
    /// `scheme://host[:port]` — null when no origin has been set
    /// (unit-test contexts, no `window.location` yet). When null, all
    /// operations succeed in-memory; nothing persists.
    origin: ?[]u8,
    /// Base directory for per-origin JSON files. Null = no persistence
    /// even with origin (rare; e.g. `$HOME` unset).
    storage_dir: ?[]u8,
    /// I/O capability. Null = no persistence even with origin+dir set
    /// (the common case for bridge unit tests that don't thread io).
    io: ?std.Io,
    /// Cached `<storage_dir>/<encoded-origin>.json`. Computed lazily
    /// when both `origin` and `storage_dir` are set.
    file_path: ?[]u8,
    /// True after the first disk-load attempt. Prevents re-loading
    /// after the user clears storage in the same session.
    loaded: bool,
    /// Set true on any mutation; reset on flush. Avoids gratuitous
    /// disk writes when nothing changed (e.g. quota-exceeded throws).
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator) LocalStorage {
        return .{
            .map = StorageMap.init(allocator),
            .origin = null,
            .storage_dir = null,
            .io = null,
            .file_path = null,
            .loaded = false,
            .dirty = false,
        };
    }

    pub fn deinit(self: *LocalStorage) void {
        const a = self.map.allocator;
        self.map.deinit();
        if (self.origin) |o| a.free(o);
        if (self.storage_dir) |d| a.free(d);
        if (self.file_path) |p| a.free(p);
        self.origin = null;
        self.storage_dir = null;
        self.file_path = null;
    }

    /// Configure the storage's origin, persistence directory, and I/O
    /// capability, then load the on-disk JSON file (if it exists).
    /// Idempotent: calling twice with the same origin is a no-op;
    /// calling with a different origin clears in-memory state and reloads.
    ///
    /// `storage_dir` or `io` may be null — in either case the storage
    /// operates in-memory only. `origin` must be non-empty.
    pub fn setOrigin(
        self: *LocalStorage,
        origin: []const u8,
        storage_dir: ?[]const u8,
        io: ?std.Io,
    ) !void {
        const a = self.map.allocator;
        if (origin.len == 0) return StorageError.InvalidOrigin;

        self.io = io;

        // Same origin = no-op (don't reload from disk; in-memory is truth).
        if (self.origin) |existing| {
            if (std.mem.eql(u8, existing, origin)) {
                if (storage_dir) |new_dir| {
                    const same_dir = if (self.storage_dir) |old_dir|
                        std.mem.eql(u8, old_dir, new_dir)
                    else
                        false;
                    if (!same_dir) {
                        if (self.storage_dir) |old| a.free(old);
                        self.storage_dir = try a.dupe(u8, new_dir);
                        if (self.file_path) |p| {
                            a.free(p);
                            self.file_path = null;
                        }
                    }
                }
                return;
            }
        }

        // Different origin: drop in-memory state, swap origin/dir, reload.
        _ = self.map.clear();
        if (self.origin) |o| a.free(o);
        if (self.file_path) |p| a.free(p);
        self.file_path = null;
        self.loaded = false;
        self.dirty = false;

        self.origin = try a.dupe(u8, origin);
        if (storage_dir) |new_dir| {
            const same = if (self.storage_dir) |old| std.mem.eql(u8, old, new_dir) else false;
            if (!same) {
                if (self.storage_dir) |old| a.free(old);
                self.storage_dir = try a.dupe(u8, new_dir);
            }
        }

        self.load();
    }

    /// Compute and cache file_path; returns null when persistence is
    /// disabled (no origin or no storage_dir).
    fn ensureFilePath(self: *LocalStorage) ?[]const u8 {
        if (self.file_path) |p| return p;
        const a = self.map.allocator;
        const origin = self.origin orelse return null;
        const dir = self.storage_dir orelse return null;
        const encoded = encodeOrigin(a, origin) catch return null;
        defer a.free(encoded);
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}.json", .{encoded}) catch return null;
        const full = std.fs.path.join(a, &.{ dir, name }) catch return null;
        self.file_path = full;
        return full;
    }

    /// Best-effort: read the on-disk JSON file into the in-memory map.
    /// Missing file = empty (fine). Malformed JSON = log + discard.
    fn load(self: *LocalStorage) void {
        if (self.loaded) return;
        self.loaded = true;
        const a = self.map.allocator;
        const io = self.io orelse return;
        const path = self.ensureFilePath() orelse return;

        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            a,
            .limited(QUOTA_BYTES * 2),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return,
        };
        defer a.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        var it = obj.iterator();
        while (it.next()) |entry| {
            const value = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => continue, // ignore non-string values
            };
            // Use map.setItem to handle byte-counting consistently.
            // Quota errors here are unexpected (file was within quota
            // when written) but tolerated.
            _ = self.map.setItem(entry.key_ptr.*, value) catch continue;
        }
    }

    /// Best-effort: serialize the in-memory map and write to disk
    /// atomically (write-tmp + rename). Returns silently on any error
    /// — Web Storage spec doesn't surface persistence failures to JS.
    fn flush(self: *LocalStorage) void {
        if (!self.dirty) return;
        const a = self.map.allocator;
        const io = self.io orelse {
            self.dirty = false; // no io configured; nothing to persist
            return;
        };
        const path = self.ensureFilePath() orelse {
            self.dirty = false; // no persistence configured; mark clean
            return;
        };

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.append(a, '{') catch return;
        var first = true;
        var it = self.map.data.iterator();
        while (it.next()) |entry| {
            if (!first) buf.append(a, ',') catch return;
            first = false;
            writeJsonString(a, &buf, entry.key_ptr.*) catch return;
            buf.append(a, ':') catch return;
            writeJsonString(a, &buf, entry.value_ptr.*) catch return;
        }
        buf.append(a, '}') catch return;

        // Atomic write: tmp file then rename. The tmp name embeds the
        // pid to avoid two awr processes for the same origin colliding.
        var tmp_buf: [4096]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}", .{ path, std.c.getpid() }) catch return;

        var tmp_file = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return;
        // Force 0600 on the tmp file before writing tokens to it.
        // CreateFileOptions has no mode field in Zig 0.16; we fchmod the
        // fd directly via libc. Failure is non-fatal: file may end up at
        // the process umask default (typically 0644).
        _ = std.c.fchmod(tmp_file.handle, 0o600);
        var write_buf: [4096]u8 = undefined;
        var w = tmp_file.writer(io, &write_buf);
        const ok = blk: {
            w.interface.writeAll(buf.items) catch break :blk false;
            w.interface.flush() catch break :blk false;
            break :blk true;
        };
        tmp_file.close(io);
        if (!ok) {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return;
        }
        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return;
        };
        self.dirty = false;
    }

    pub fn getItem(self: *LocalStorage, key: []const u8) ?[]const u8 {
        self.load();
        return self.map.getItem(key);
    }

    pub fn setItem(self: *LocalStorage, key: []const u8, value: []const u8) StorageError!void {
        self.load();
        _ = try self.map.setItem(key, value);
        self.dirty = true;
        self.flush();
    }

    pub fn removeItem(self: *LocalStorage, key: []const u8) void {
        self.load();
        if (self.map.removeItem(key)) {
            self.dirty = true;
            self.flush();
        }
    }

    pub fn clear(self: *LocalStorage) void {
        self.load();
        if (self.map.clear()) {
            self.dirty = true;
            self.flush();
        }
    }

    pub fn keyAt(self: *LocalStorage, index: u32) ?[]const u8 {
        self.load();
        return self.map.keyAt(index);
    }

    pub fn length(self: *LocalStorage) u32 {
        self.load();
        return self.map.length();
    }
};

/// Encode an origin (e.g. `https://example.com:8080`) into a filesystem-safe
/// filename stem. Inlined here so storage.zig has no named-module imports
/// (cheaper to wire into bridge.zig + page.zig + 5 page-mod variants).
///
///   `https://example.com`        → `https__example.com`
///   `http://localhost:3000`      → `http__localhost_3000`
fn encodeOrigin(allocator: std.mem.Allocator, origin: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, origin.len + 8);

    var i: usize = 0;
    while (i < origin.len) {
        if (i + 3 <= origin.len and std.mem.eql(u8, origin[i .. i + 3], "://")) {
            try out.appendSlice(allocator, "__");
            i += 3;
            continue;
        }
        const c = origin[i];
        switch (c) {
            ':', '/', '\\' => try out.append(allocator, '_'),
            0...0x1f, 0x7f => return error.InvalidOrigin,
            else => try out.append(allocator, c),
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                var esc: [6]u8 = undefined;
                const written = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(allocator, written);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "SessionStorage — basic round-trip" {
    var ss = SessionStorage.init(std.testing.allocator);
    defer ss.deinit();

    try std.testing.expectEqual(@as(u32, 0), ss.length());
    try std.testing.expect(ss.getItem("k") == null);

    try ss.setItem("k", "v");
    try std.testing.expectEqual(@as(u32, 1), ss.length());
    try std.testing.expectEqualStrings("v", ss.getItem("k").?);

    try ss.setItem("k", "v2"); // replace
    try std.testing.expectEqual(@as(u32, 1), ss.length());
    try std.testing.expectEqualStrings("v2", ss.getItem("k").?);

    ss.removeItem("k");
    try std.testing.expectEqual(@as(u32, 0), ss.length());
    try std.testing.expect(ss.getItem("k") == null);
}

test "SessionStorage — clear empties the store" {
    var ss = SessionStorage.init(std.testing.allocator);
    defer ss.deinit();
    try ss.setItem("a", "1");
    try ss.setItem("b", "2");
    ss.clear();
    try std.testing.expectEqual(@as(u32, 0), ss.length());
}

test "SessionStorage — quota exceeded leaves prior value intact" {
    var ss = SessionStorage.init(std.testing.allocator);
    defer ss.deinit();
    try ss.setItem("k", "small");
    const big = try std.testing.allocator.alloc(u8, QUOTA_BYTES);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try std.testing.expectError(StorageError.QuotaExceeded, ss.setItem("k", big));
    // Original value preserved.
    try std.testing.expectEqualStrings("small", ss.getItem("k").?);
}

test "LocalStorage — in-memory mode (no origin) works" {
    var ls = LocalStorage.init(std.testing.allocator);
    defer ls.deinit();

    try ls.setItem("token", "abc123");
    try std.testing.expectEqualStrings("abc123", ls.getItem("token").?);
    try std.testing.expectEqual(@as(u32, 1), ls.length());
}

// std.testing.tmpDir gives a sub-path under .zig-cache/tmp; LocalStorage's
// disk path is consumed by std.Io.Dir.cwd() so we build a relative path
// using the sub_path field. Same trick `src/client.zig` uses for the
// tls-fail cache tests.
fn tmpDirPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "LocalStorage — round-trip through disk" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirPath(a, tmp);
    defer a.free(dir_path);

    {
        var ls = LocalStorage.init(a);
        defer ls.deinit();
        try ls.setOrigin("https://example.com", dir_path, io);
        try ls.setItem("session", "tok-abc");
        try ls.setItem("user", "alice");
        // flush is sync; file is on disk now.
    }

    // Second instance, same origin: data must persist.
    {
        var ls = LocalStorage.init(a);
        defer ls.deinit();
        try ls.setOrigin("https://example.com", dir_path, io);
        try std.testing.expectEqualStrings("tok-abc", ls.getItem("session").?);
        try std.testing.expectEqualStrings("alice", ls.getItem("user").?);
        try std.testing.expectEqual(@as(u32, 2), ls.length());
    }
}

test "LocalStorage — cross-origin isolation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirPath(a, tmp);
    defer a.free(dir_path);

    {
        var ls = LocalStorage.init(a);
        defer ls.deinit();
        try ls.setOrigin("https://foo.com", dir_path, io);
        try ls.setItem("token", "foo-secret");
    }

    // Different origin: must NOT see foo.com's data.
    {
        var ls = LocalStorage.init(a);
        defer ls.deinit();
        try ls.setOrigin("https://bar.com", dir_path, io);
        try std.testing.expect(ls.getItem("token") == null);
    }

    // Back to foo.com: still there.
    {
        var ls = LocalStorage.init(a);
        defer ls.deinit();
        try ls.setOrigin("https://foo.com", dir_path, io);
        try std.testing.expectEqualStrings("foo-secret", ls.getItem("token").?);
    }
}

test "LocalStorage — quota exceeded does not corrupt disk" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirPath(a, tmp);
    defer a.free(dir_path);

    var ls = LocalStorage.init(a);
    defer ls.deinit();
    try ls.setOrigin("https://example.com", dir_path, io);
    try ls.setItem("safe", "ok");

    const big = try a.alloc(u8, QUOTA_BYTES);
    defer a.free(big);
    @memset(big, 'x');
    try std.testing.expectError(StorageError.QuotaExceeded, ls.setItem("huge", big));

    // Reload from disk — only "safe" should be present.
    var ls2 = LocalStorage.init(a);
    defer ls2.deinit();
    try ls2.setOrigin("https://example.com", dir_path, io);
    try std.testing.expectEqualStrings("ok", ls2.getItem("safe").?);
    try std.testing.expect(ls2.getItem("huge") == null);
}

test "LocalStorage — clear persists" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirPath(a, tmp);
    defer a.free(dir_path);

    {
        var ls = LocalStorage.init(a);
        defer ls.deinit();
        try ls.setOrigin("https://example.com", dir_path, io);
        try ls.setItem("k", "v");
        ls.clear();
    }

    var ls2 = LocalStorage.init(a);
    defer ls2.deinit();
    try ls2.setOrigin("https://example.com", dir_path, io);
    try std.testing.expectEqual(@as(u32, 0), ls2.length());
}

test "LocalStorage — JSON escaping survives round-trip" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirPath(a, tmp);
    defer a.free(dir_path);

    const tricky = "line1\nline2\t\"quoted\"\\back";
    {
        var ls = LocalStorage.init(a);
        defer ls.deinit();
        try ls.setOrigin("https://example.com", dir_path, io);
        try ls.setItem("multiline", tricky);
    }

    var ls2 = LocalStorage.init(a);
    defer ls2.deinit();
    try ls2.setOrigin("https://example.com", dir_path, io);
    try std.testing.expectEqualStrings(tricky, ls2.getItem("multiline").?);
}
