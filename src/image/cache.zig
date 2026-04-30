/// In-process image cache with byte-bounded LRU eviction.
///
/// Per `spec/subspecs/rendering.md §3.1`: keyed by absolute URL string,
/// capped at 32 MiB resident decoded bytes by default. Hit / miss
/// counters surface cache effectiveness. Each call to `put` may evict
/// least-recently-used entries to make room.
///
/// Ownership contract:
///
///   • `put` takes ownership of the supplied `Image` unconditionally.
///     If the image alone exceeds `cap_bytes`, it is freed and `put`
///     returns without storing — callers see this as a subsequent
///     miss; the contract is "best-effort caching."
///   • `get` returns a non-owning `*const Image`. The caller must NOT
///     `deinit()` it. The pointer remains valid until the next
///     mutating call (`put` / `clear` / `deinit`) that may evict.
///   • `deinit` frees every cached image's pixels via the image's own
///     `allocator` field, then frees node + key memory.
///
/// Evict / replace ordering:
///
///   1. If `url` already exists, the existing entry is dropped first.
///   2. While `resident + new > cap`, evict from the LRU tail.
///   3. Insert at the LRU head.
///
/// The intrusive doubly-linked list lives inside `Node` so that LRU
/// promotion on `get` is O(1) (a hashmap lookup followed by
/// detach/attach).
const std = @import("std");

const decode = @import("decode.zig");
const Image = decode.Image;

pub const default_cap_bytes: usize = 32 * 1024 * 1024;

const Node = struct {
    key: []u8, // owned by cache.allocator
    image: Image, // pixels owned by image.allocator (typically cache.allocator)
    byte_count: usize, // pixels.len at time of insert
    prev: ?*Node,
    next: ?*Node,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(*Node),
    head: ?*Node = null, // most recently used
    tail: ?*Node = null, // least recently used (next to evict)
    bytes_resident: usize = 0,
    cap_bytes: usize,
    hits: usize = 0,
    misses: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cap_bytes: usize) Cache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(*Node).init(allocator),
            .cap_bytes = cap_bytes,
        };
    }

    pub fn deinit(self: *Cache) void {
        var cur = self.head;
        while (cur) |n| {
            const next = n.next;
            n.image.deinit();
            self.allocator.free(n.key);
            self.allocator.destroy(n);
            cur = next;
        }
        self.map.deinit();
        self.* = undefined;
    }

    /// Look up `url`. On hit, promote to the LRU head and bump the hit
    /// counter; on miss, bump the miss counter. The returned pointer is
    /// non-owning; do not `deinit` it.
    pub fn get(self: *Cache, url: []const u8) ?*const Image {
        const node = self.map.get(url) orelse {
            self.misses += 1;
            return null;
        };
        self.hits += 1;
        self.detach(node);
        self.attachAtHead(node);
        return &node.image;
    }

    /// Store `image` under `url`, taking ownership. Evicts LRU entries
    /// to fit. If the image alone exceeds `cap_bytes`, it is freed and
    /// not stored (best-effort caching, no error path).
    pub fn put(self: *Cache, url: []const u8, image: Image) std.mem.Allocator.Error!void {
        var img = image;
        const want = img.pixels.len;

        // Single image bigger than the entire cap → reject silently.
        // Callers see this as a subsequent get() miss and must keep their
        // own copy if they need re-encode.
        if (want > self.cap_bytes) {
            img.deinit();
            return;
        }

        // Replace existing entry for the same URL (drop old, accept new).
        if (self.map.get(url)) |existing| {
            self.dropNode(existing);
        }

        // Evict from LRU tail until the new entry fits.
        while (self.bytes_resident + want > self.cap_bytes) {
            if (!self.evictTail()) break;
        }

        const key = self.allocator.dupe(u8, url) catch |e| {
            img.deinit();
            return e;
        };
        errdefer self.allocator.free(key);

        const node = self.allocator.create(Node) catch |e| {
            img.deinit();
            return e;
        };
        errdefer self.allocator.destroy(node);

        node.* = .{
            .key = key,
            .image = img, // ownership transfers; node now owns pixels
            .byte_count = want,
            .prev = null,
            .next = null,
        };
        errdefer node.image.deinit();

        try self.map.put(key, node);
        self.attachAtHead(node);
        self.bytes_resident += want;
    }

    /// Remove every cached image. Counters are NOT reset (they describe
    /// session-wide behavior).
    pub fn clear(self: *Cache) void {
        var cur = self.head;
        while (cur) |n| {
            const next = n.next;
            n.image.deinit();
            _ = self.map.remove(n.key); // remove BEFORE free; map hashes key bytes
            self.allocator.free(n.key);
            self.allocator.destroy(n);
            cur = next;
        }
        self.head = null;
        self.tail = null;
        self.bytes_resident = 0;
    }

    pub fn len(self: *const Cache) usize {
        return self.map.count();
    }

    // ── Internal LRU surgery ────────────────────────────────────────────

    fn attachAtHead(self: *Cache, node: *Node) void {
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| h.prev = node;
        self.head = node;
        if (self.tail == null) self.tail = node;
    }

    fn detach(self: *Cache, node: *Node) void {
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        node.prev = null;
        node.next = null;
    }

    fn dropNode(self: *Cache, node: *Node) void {
        self.detach(node);
        _ = self.map.remove(node.key);
        self.bytes_resident -= node.byte_count;
        node.image.deinit();
        self.allocator.free(node.key);
        self.allocator.destroy(node);
    }

    fn evictTail(self: *Cache) bool {
        const t = self.tail orelse return false;
        self.dropNode(t);
        return true;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a synthetic Image with N bytes of zeroed RGBA pixels (width*height
/// chosen so 4*w*h = N). Caller transfers ownership to the cache via put().
fn makeImage(allocator: std.mem.Allocator, byte_count: usize) !Image {
    std.debug.assert(byte_count % 4 == 0);
    const pixels = try allocator.alloc(u8, byte_count);
    @memset(pixels, 0);
    return .{
        .width = @intCast(byte_count / 4),
        .height = 1,
        .pixels = pixels,
        .allocator = allocator,
    };
}

test "Cache: put + get hits, miss returns null" {
    var c = Cache.init(testing.allocator, 1024);
    defer c.deinit();

    try testing.expect(c.get("missing") == null);
    try testing.expectEqual(@as(usize, 0), c.hits);
    try testing.expectEqual(@as(usize, 1), c.misses);

    try c.put("https://example.com/a.png", try makeImage(testing.allocator, 64));

    const got = c.get("https://example.com/a.png") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 16), got.width);
    try testing.expectEqual(@as(usize, 1), c.hits);
    try testing.expectEqual(@as(usize, 1), c.misses);
}

test "Cache: LRU eviction respects access order" {
    // 3 entries × 64 bytes = 192 bytes; cap at 192 forces eviction on 4th.
    var c = Cache.init(testing.allocator, 192);
    defer c.deinit();

    try c.put("a", try makeImage(testing.allocator, 64));
    try c.put("b", try makeImage(testing.allocator, 64));
    try c.put("c", try makeImage(testing.allocator, 64));
    try testing.expectEqual(@as(usize, 3), c.len());
    try testing.expectEqual(@as(usize, 192), c.bytes_resident);

    // Touch "a" so it becomes MRU; "b" is now LRU and should evict next.
    _ = c.get("a") orelse return error.TestUnexpectedNull;

    try c.put("d", try makeImage(testing.allocator, 64));

    try testing.expect(c.get("b") == null);
    try testing.expect(c.get("a") != null);
    try testing.expect(c.get("c") != null);
    try testing.expect(c.get("d") != null);
    try testing.expectEqual(@as(usize, 192), c.bytes_resident);
}

test "Cache: replace existing URL drops old image" {
    var c = Cache.init(testing.allocator, 1024);
    defer c.deinit();

    try c.put("u", try makeImage(testing.allocator, 64));
    try c.put("u", try makeImage(testing.allocator, 128)); // replace, larger
    try testing.expectEqual(@as(usize, 1), c.len());
    try testing.expectEqual(@as(usize, 128), c.bytes_resident);

    const got = c.get("u") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 32), got.width);
}

test "Cache: oversize image silently rejected, pixels freed" {
    var c = Cache.init(testing.allocator, 64);
    defer c.deinit();

    // 256-byte image into a 64-byte cap — testing.allocator catches leaks.
    try c.put("big", try makeImage(testing.allocator, 256));
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(@as(usize, 0), c.bytes_resident);
    try testing.expect(c.get("big") == null);
}

test "Cache: clear empties without resetting counters" {
    var c = Cache.init(testing.allocator, 1024);
    defer c.deinit();

    try c.put("a", try makeImage(testing.allocator, 64));
    _ = c.get("a");
    _ = c.get("missing");

    c.clear();
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(@as(usize, 0), c.bytes_resident);
    try testing.expectEqual(@as(usize, 1), c.hits); // counters preserved
    try testing.expectEqual(@as(usize, 1), c.misses);
}

test "Cache: get promotes to head, repeated access keeps in cache" {
    var c = Cache.init(testing.allocator, 128); // 2 entries fit
    defer c.deinit();

    try c.put("a", try makeImage(testing.allocator, 64));
    try c.put("b", try makeImage(testing.allocator, 64));

    // Hammer "a" so it's never the LRU candidate.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = c.get("a");
        try c.put("c", try makeImage(testing.allocator, 64));
        // each put evicts something; "a" was just touched so "b" or "c"
        // (the previous c) is the eviction target.
        try testing.expect(c.get("a") != null);
    }
}
