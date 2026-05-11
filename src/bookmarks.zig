/// bookmarks.zig — Tier 2 / T-89: tab-delimited bookmark store
/// used by `awr bookmark add/list/rm` and the `B` TUI binding.
///
/// File format (per row, `\n` terminated, fields tab-separated):
///   id<TAB>created_unix_seconds<TAB>title<TAB>url
///
/// Why TSV: human-readable, git-friendly, no parser ambiguity since
/// titles and URLs cannot contain literal tabs or newlines without
/// escaping. We sanitize both fields on write (collapse whitespace,
/// drop control bytes) so the round-trip is robust without an escape
/// layer.
///
/// Why ids are stable per-file: `rm <id>` is easier than `rm <url>`
/// when the user is staring at the `list` output and the URL is long.
/// Adding a new bookmark assigns the next free id (max(existing) + 1).
const std = @import("std");
const path_util = @import("util/bookmark_path.zig");

pub const Bookmark = struct {
    id: u64,
    created_ts: i64,
    title: []u8,
    url: []u8,

    pub fn deinit(self: *Bookmark, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.url);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    bookmarks: std.ArrayListUnmanaged(Bookmark) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.bookmarks.items) |*b| b.deinit(self.allocator);
        self.bookmarks.deinit(self.allocator);
    }

    /// Load bookmarks from `path`. Returns an empty store if the
    /// file doesn't exist yet (first-run case). Malformed rows are
    /// skipped silently — we'd rather lose a bad row than refuse
    /// to load the file. Caller owns the returned Store.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        var store = Store.init(allocator);
        errdefer store.deinit();

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer allocator.free(bytes);

        var line_it = std.mem.splitScalar(u8, bytes, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (line.len == 0 or line[0] == '#') continue;

            var fields: [4][]const u8 = undefined;
            var fi: usize = 0;
            var tok_it = std.mem.splitScalar(u8, line, '\t');
            while (tok_it.next()) |tok| {
                if (fi >= 4) break;
                fields[fi] = tok;
                fi += 1;
            }
            if (fi != 4) continue;

            const id = std.fmt.parseInt(u64, fields[0], 10) catch continue;
            const ts = std.fmt.parseInt(i64, fields[1], 10) catch continue;
            const title = try allocator.dupe(u8, fields[2]);
            errdefer allocator.free(title);
            const url = try allocator.dupe(u8, fields[3]);
            try store.bookmarks.append(allocator, .{
                .id = id,
                .created_ts = ts,
                .title = title,
                .url = url,
            });
        }
        return store;
    }

    /// Add a new bookmark. `title` may be empty — in which case the
    /// URL doubles as the display title. Returns the assigned id.
    pub fn add(self: *Store, title: []const u8, url: []const u8) !u64 {
        if (url.len == 0) return error.EmptyUrl;
        const next_id = self.nextId();
        const title_clean = try sanitize(self.allocator, title);
        errdefer self.allocator.free(title_clean);
        const url_clean = try sanitize(self.allocator, url);
        errdefer self.allocator.free(url_clean);

        try self.bookmarks.append(self.allocator, .{
            .id = next_id,
            .created_ts = nowSeconds(),
            .title = title_clean,
            .url = url_clean,
        });
        return next_id;
    }

    /// Remove the bookmark with this id. Returns true on success,
    /// false if no such id existed.
    pub fn remove(self: *Store, id: u64) bool {
        for (self.bookmarks.items, 0..) |*b, i| {
            if (b.id == id) {
                var owned = self.bookmarks.orderedRemove(i);
                owned.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    /// Serialize to `path` atomically: write to `path.tmp`, then
    /// rename. Avoids corruption on a kill mid-write. T-89.
    pub fn save(self: *Store, io: std.Io, path: []const u8) !void {
        var tmp_path_buf: [4096]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});

        var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        var write_buf: [4096]u8 = undefined;
        var w = f.writer(io, &write_buf);
        try w.interface.writeAll("# AWR bookmarks — one row per bookmark\n");
        try w.interface.writeAll("# format: id\\tcreated_unix_seconds\\ttitle\\turl\n");
        for (self.bookmarks.items) |b| {
            var row_buf: [8192]u8 = undefined;
            const row = try std.fmt.bufPrint(&row_buf, "{d}\t{d}\t{s}\t{s}\n", .{ b.id, b.created_ts, b.title, b.url });
            try w.interface.writeAll(row);
        }
        try w.interface.flush();
        f.close(io);

        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
    }

    fn nextId(self: *const Store) u64 {
        var max_id: u64 = 0;
        for (self.bookmarks.items) |b| {
            if (b.id > max_id) max_id = b.id;
        }
        return max_id + 1;
    }
};

/// Strip tabs, newlines, and control bytes from a string so the TSV
/// format stays unambiguous. Trims surrounding whitespace as a
/// readability win. Caller owns the returned slice.
fn sanitize(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var prev_space = true; // strip leading whitespace
    for (s) |c| {
        if (c == '\t' or c == '\n' or c == '\r' or c < 0x20) {
            if (!prev_space) {
                try out.append(alloc, ' ');
                prev_space = true;
            }
        } else if (c == ' ') {
            if (!prev_space) {
                try out.append(alloc, ' ');
                prev_space = true;
            }
        } else {
            try out.append(alloc, c);
            prev_space = false;
        }
    }
    // Trim trailing space.
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.toOwnedSlice(alloc);
}

/// Resolve the bookmark store path via the resolver in util/.
pub fn defaultPath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    return path_util.resolveBookmarksPath(allocator, io);
}

/// Wall-clock seconds, inline (avoids the cross-module util/time
/// import collision that the session_import module also dodges).
fn nowSeconds() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

// ── Tests ──────────────────────────────────────────────────────────

test "Store: empty load returns empty store" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.bookmarks.items.len);
}

test "Store.add assigns sequential ids" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const id1 = try store.add("Example", "https://example.com/");
    const id2 = try store.add("Sample", "https://sample.org/");
    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
}

test "Store.add rejects empty URL" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.EmptyUrl, store.add("title", ""));
}

test "Store.remove deletes the matching row" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.add("a", "https://a.com/");
    const id = try store.add("b", "https://b.com/");
    _ = try store.add("c", "https://c.com/");
    try std.testing.expect(store.remove(id));
    try std.testing.expectEqual(@as(usize, 2), store.bookmarks.items.len);
    try std.testing.expectEqualStrings("https://a.com/", store.bookmarks.items[0].url);
    try std.testing.expectEqualStrings("https://c.com/", store.bookmarks.items[1].url);
}

test "Store.remove returns false for missing id" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.add("a", "https://a.com/");
    try std.testing.expect(!store.remove(999));
}

test "sanitize strips tabs/newlines and collapses whitespace" {
    const out = try sanitize(std.testing.allocator, "  hello\tworld\nfoo  ");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world foo", out);
}

test "sanitize trims trailing whitespace" {
    const out = try sanitize(std.testing.allocator, "hello   ");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "Store.add survives malicious tabs/newlines in input" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.add("evil\ttitle\nrow", "https://x.com/path\twith\ttabs");
    try std.testing.expectEqual(@as(usize, 1), store.bookmarks.items.len);
    // No tab or newline survives into the stored fields.
    try std.testing.expect(std.mem.indexOfScalar(u8, store.bookmarks.items[0].title, '\t') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, store.bookmarks.items[0].title, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, store.bookmarks.items[0].url, '\t') == null);
}

test "nextId reuses gaps when high-id rows are removed" {
    // Implementation detail: ids monotonically increase from max+1, so
    // removing the highest does NOT reset. This is the contract — id
    // stability matters for `rm` output references.
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.add("a", "https://a.com/");
    _ = try store.add("b", "https://b.com/");
    try std.testing.expect(store.remove(2));
    const id3 = try store.add("c", "https://c.com/");
    try std.testing.expectEqual(@as(u64, 2), id3); // gap reused (max remaining = 1, next = 2)
}
