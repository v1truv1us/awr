/// history.zig — History API stack for AWR (Tier 3 — T3.B).
///
/// Backs `window.history` for the page. Owns the entries array and
/// the cursor; native callbacks in `bridge.zig` are thin wrappers.
///
/// State objects are stored as JSON strings — what browsers call
/// "structured cloning" of plain objects degrades to JSON round-trip
/// on the AWR side, which matches the ergonomics every script that
/// uses `history.state` expects (read it once, get a fresh copy).
///
/// Pure-Zig, no QuickJS dependency. Unit-testable on its own.
const std = @import("std");

pub const HistoryError = error{
    OutOfMemory,
    InvalidUrl,
};

pub const Entry = struct {
    url: []u8,
    /// JSON-encoded state. `null` slice means the entry's state IS
    /// JS `null` (not "no entry"). The textual JSON would be `"null"`.
    state_json: ?[]u8,
};

pub const HistoryStack = struct {
    allocator: std.mem.Allocator,
    /// Insertion-ordered list of entries. `entries[cursor]` is the
    /// "current" entry (matches `location.href`). Entries to the
    /// right of the cursor are forward history; back() decrements
    /// the cursor; pushState truncates forward history then appends.
    entries: std.ArrayList(Entry),
    cursor: usize,

    pub fn init(allocator: std.mem.Allocator) HistoryStack {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .cursor = 0,
        };
    }

    pub fn deinit(self: *HistoryStack) void {
        for (self.entries.items) |*e| self.freeEntry(e);
        self.entries.deinit(self.allocator);
        self.cursor = 0;
    }

    fn freeEntry(self: *HistoryStack, e: *Entry) void {
        self.allocator.free(e.url);
        if (e.state_json) |s| self.allocator.free(s);
    }

    /// Seed the stack with the first entry (the page that was loaded).
    /// Idempotent for the same URL — calling twice with the same URL
    /// while the stack already has an initial entry is a no-op so
    /// `setLocationFromUrl` can call this every navigation without
    /// growing the stack.
    pub fn setInitialEntry(self: *HistoryStack, url: []const u8) HistoryError!void {
        if (self.entries.items.len == 0) {
            const dup = self.allocator.dupe(u8, url) catch return HistoryError.OutOfMemory;
            self.entries.append(self.allocator, .{
                .url = dup,
                .state_json = null,
            }) catch {
                self.allocator.free(dup);
                return HistoryError.OutOfMemory;
            };
            self.cursor = 0;
            return;
        }
        // Stack already exists — only update URL of the current entry
        // when it's a true navigation (different URL). Same URL = idempotent.
        const cur = &self.entries.items[self.cursor];
        if (std.mem.eql(u8, cur.url, url)) return;
        // Different URL after page load (full navigation, not pushState):
        // truncate forward history and replace current entry's URL.
        self.truncateForward();
        const dup = self.allocator.dupe(u8, url) catch return HistoryError.OutOfMemory;
        self.allocator.free(cur.url);
        cur.url = dup;
        if (cur.state_json) |s| {
            self.allocator.free(s);
            cur.state_json = null;
        }
    }

    /// Drop everything strictly after the cursor.
    fn truncateForward(self: *HistoryStack) void {
        while (self.entries.items.len > self.cursor + 1) {
            var last = self.entries.pop().?;
            self.freeEntry(&last);
        }
    }

    /// pushState: append a new entry, truncating any forward history.
    /// state_json may be null (JS `null`); empty string is treated the
    /// same as null.
    pub fn pushState(self: *HistoryStack, url: []const u8, state_json: ?[]const u8) HistoryError!void {
        // Make sure there's at least an initial entry to push past.
        if (self.entries.items.len == 0) {
            try self.setInitialEntry(url);
            return;
        }
        self.truncateForward();
        const url_dup = self.allocator.dupe(u8, url) catch return HistoryError.OutOfMemory;
        errdefer self.allocator.free(url_dup);
        const state_dup = if (state_json) |s|
            (self.allocator.dupe(u8, s) catch return HistoryError.OutOfMemory)
        else
            null;
        errdefer if (state_dup) |s| self.allocator.free(s);
        self.entries.append(self.allocator, .{
            .url = url_dup,
            .state_json = state_dup,
        }) catch return HistoryError.OutOfMemory;
        self.cursor = self.entries.items.len - 1;
    }

    /// replaceState: overwrite the current entry's url + state.
    /// Forward history is preserved (per spec).
    pub fn replaceState(self: *HistoryStack, url: []const u8, state_json: ?[]const u8) HistoryError!void {
        if (self.entries.items.len == 0) {
            try self.setInitialEntry(url);
            // Then layer state on top.
            const cur = &self.entries.items[self.cursor];
            if (state_json) |s| {
                cur.state_json = self.allocator.dupe(u8, s) catch return HistoryError.OutOfMemory;
            }
            return;
        }
        const cur = &self.entries.items[self.cursor];
        const url_dup = self.allocator.dupe(u8, url) catch return HistoryError.OutOfMemory;
        const state_dup = if (state_json) |s|
            (self.allocator.dupe(u8, s) catch {
                self.allocator.free(url_dup);
                return HistoryError.OutOfMemory;
            })
        else
            null;
        self.allocator.free(cur.url);
        if (cur.state_json) |old| self.allocator.free(old);
        cur.url = url_dup;
        cur.state_json = state_dup;
    }

    /// Move the cursor by `delta`. Returns true when the cursor
    /// moved (i.e. a popstate event should fire). `delta == 0` is a
    /// no-op (browsers would reload; AWR doesn't have a reload concept
    /// here so we treat it as no-op per the spec's permission).
    pub fn go(self: *HistoryStack, delta: i32) bool {
        if (delta == 0) return false;
        if (self.entries.items.len == 0) return false;
        const cur_i: i64 = @intCast(self.cursor);
        const target = cur_i + delta;
        if (target < 0) return false;
        const target_u: usize = @intCast(target);
        if (target_u >= self.entries.items.len) return false;
        if (target_u == self.cursor) return false;
        self.cursor = target_u;
        return true;
    }

    pub fn back(self: *HistoryStack) bool {
        return self.go(-1);
    }

    pub fn forward(self: *HistoryStack) bool {
        return self.go(1);
    }

    pub fn currentUrl(self: *const HistoryStack) []const u8 {
        if (self.entries.items.len == 0) return "";
        return self.entries.items[self.cursor].url;
    }

    /// Returns the JSON for the current entry's state, or null when
    /// the state is JS `null`. Caller must NOT free; the slice is
    /// borrowed from the stack.
    pub fn currentStateJson(self: *const HistoryStack) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.cursor].state_json;
    }

    pub fn length(self: *const HistoryStack) u32 {
        return @intCast(self.entries.items.len);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "HistoryStack — initial seed" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try std.testing.expectEqual(@as(u32, 1), h.length());
    try std.testing.expectEqualStrings("https://example.com/", h.currentUrl());
    try std.testing.expect(h.currentStateJson() == null);
}

test "HistoryStack — setInitialEntry idempotent for same URL" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.setInitialEntry("https://example.com/");
    try std.testing.expectEqual(@as(u32, 1), h.length());
}

test "HistoryStack — pushState grows length and updates URL" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.pushState("https://example.com/a", null);
    try h.pushState("https://example.com/b", "{\"page\":2}");
    try std.testing.expectEqual(@as(u32, 3), h.length());
    try std.testing.expectEqualStrings("https://example.com/b", h.currentUrl());
    try std.testing.expectEqualStrings("{\"page\":2}", h.currentStateJson().?);
}

test "HistoryStack — replaceState overwrites without growing" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.pushState("https://example.com/a", "{\"v\":1}");
    try h.replaceState("https://example.com/a/edit", "{\"v\":2}");
    try std.testing.expectEqual(@as(u32, 2), h.length());
    try std.testing.expectEqualStrings("https://example.com/a/edit", h.currentUrl());
    try std.testing.expectEqualStrings("{\"v\":2}", h.currentStateJson().?);
}

test "HistoryStack — back / forward traversal" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.pushState("https://example.com/a", "\"A\"");
    try h.pushState("https://example.com/b", "\"B\"");

    try std.testing.expect(h.back());
    try std.testing.expectEqualStrings("https://example.com/a", h.currentUrl());
    try std.testing.expectEqualStrings("\"A\"", h.currentStateJson().?);

    try std.testing.expect(h.back());
    try std.testing.expectEqualStrings("https://example.com/", h.currentUrl());
    try std.testing.expect(h.currentStateJson() == null);

    // Past the start = no movement.
    try std.testing.expect(!h.back());
    try std.testing.expectEqualStrings("https://example.com/", h.currentUrl());

    try std.testing.expect(h.forward());
    try std.testing.expectEqualStrings("https://example.com/a", h.currentUrl());
    try std.testing.expect(h.forward());
    try std.testing.expectEqualStrings("https://example.com/b", h.currentUrl());

    // Past the end = no movement.
    try std.testing.expect(!h.forward());
}

test "HistoryStack — go(0) is a no-op" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.pushState("https://example.com/a", null);
    try std.testing.expect(!h.go(0));
}

test "HistoryStack — pushState after back() truncates forward history" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.pushState("https://example.com/a", null);
    try h.pushState("https://example.com/b", null);
    try h.pushState("https://example.com/c", null);
    try std.testing.expectEqual(@as(u32, 4), h.length());

    _ = h.back();
    _ = h.back();
    // Now at /a with /b and /c as forward history.
    try std.testing.expectEqualStrings("https://example.com/a", h.currentUrl());

    try h.pushState("https://example.com/d", null);
    // /b and /c discarded; new entry appended.
    try std.testing.expectEqual(@as(u32, 3), h.length());
    try std.testing.expectEqualStrings("https://example.com/d", h.currentUrl());
    try std.testing.expect(!h.forward()); // no forward history
}

test "HistoryStack — full navigation truncates forward history" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.pushState("https://example.com/a", null);
    _ = h.back();
    // setInitialEntry called by Page.setLocationFromUrl on a new fetch
    // should truncate forward history and replace the current URL.
    try h.setInitialEntry("https://other.com/");
    try std.testing.expectEqual(@as(u32, 1), h.length());
    try std.testing.expectEqualStrings("https://other.com/", h.currentUrl());
}

test "HistoryStack — go(delta) bounds-checked" {
    var h = HistoryStack.init(std.testing.allocator);
    defer h.deinit();
    try h.setInitialEntry("https://example.com/");
    try h.pushState("https://example.com/a", null);
    try h.pushState("https://example.com/b", null);
    // From /b: go(-2) → "/"; go(2) past end = no-op.
    try std.testing.expect(h.go(-2));
    try std.testing.expectEqualStrings("https://example.com/", h.currentUrl());
    try std.testing.expect(!h.go(99));
    try std.testing.expect(!h.go(-99));
}
