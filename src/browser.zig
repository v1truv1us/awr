const std = @import("std");
const page_mod = @import("page");
const tui = @import("tui.zig");

const PromptMode = enum {
    none,
    url,
    search,
};

const HistoryEntry = struct {
    url: []const u8,
};

const LoadedPage = struct {
    result: page_mod.PageResult,
    screen: page_mod.ScreenModel,

    fn deinit(self: *LoadedPage) void {
        self.screen.deinit();
        self.result.deinit();
    }
};

pub const BrowserSession = struct {
    allocator: std.mem.Allocator,
    page: page_mod.Page,
    current: ?LoadedPage,
    history: std.ArrayList(HistoryEntry),
    history_index: usize,
    selected_link: ?usize,
    scroll_row: usize,
    search_query: ?[]u8,
    search_matches: std.ArrayList(usize),
    search_index: ?usize,
    prompt_mode: PromptMode,
    prompt_buffer: std.ArrayList(u8),
    status_message: ?[]u8,
    render_width: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !BrowserSession {
        return .{
            .allocator = allocator,
            .page = try page_mod.Page.init(allocator, io),
            .current = null,
            .history = std.ArrayList(HistoryEntry).empty,
            .history_index = 0,
            .selected_link = null,
            .scroll_row = 0,
            .search_query = null,
            .search_matches = std.ArrayList(usize).empty,
            .search_index = null,
            .prompt_mode = .none,
            .prompt_buffer = std.ArrayList(u8).empty,
            .status_message = null,
            .render_width = 78,
        };
    }

    pub fn deinit(self: *BrowserSession) void {
        if (self.current) |*current| current.deinit();
        for (self.history.items) |entry| self.allocator.free(entry.url);
        self.history.deinit(self.allocator);
        if (self.search_query) |query| self.allocator.free(query);
        self.search_matches.deinit(self.allocator);
        self.prompt_buffer.deinit(self.allocator);
        if (self.status_message) |msg| self.allocator.free(msg);
        self.page.deinit();
    }

    pub fn navigateTo(self: *BrowserSession, url: []const u8) !void {
        try self.loadUrl(url);
        try self.pushHistory(self.current.?.result.url);
    }

    pub fn setViewportWidth(self: *BrowserSession, cols: usize) !void {
        const desired = browserRenderWidth(cols);
        if (desired == self.render_width) return;
        self.render_width = desired;
        if (self.current != null) try self.rerenderCurrent();
    }

    pub fn reload(self: *BrowserSession) !void {
        const url = self.currentUrl() orelse return;
        try self.loadUrl(url);
    }

    pub fn goBack(self: *BrowserSession) !void {
        if (self.history.items.len == 0 or self.history_index == 0) return;
        self.history_index -= 1;
        try self.loadUrl(self.history.items[self.history_index].url);
    }

    pub fn goForward(self: *BrowserSession) !void {
        if (self.history.items.len == 0) return;
        if (self.history_index + 1 >= self.history.items.len) return;
        self.history_index += 1;
        try self.loadUrl(self.history.items[self.history_index].url);
    }

    pub fn scrollBy(self: *BrowserSession, delta: isize, viewport_height: usize) void {
        const max_scroll = self.maxScroll(viewport_height);
        if (delta < 0) {
            const amount: usize = @intCast(-delta);
            self.scroll_row = if (amount > self.scroll_row) 0 else self.scroll_row - amount;
        } else {
            const amount: usize = @intCast(delta);
            self.scroll_row = @min(max_scroll, self.scroll_row + amount);
        }
    }

    pub fn clampScroll(self: *BrowserSession, viewport_height: usize) void {
        self.scroll_row = @min(self.scroll_row, self.maxScroll(viewport_height));
    }

    pub fn selectNextLink(self: *BrowserSession, backwards: bool, viewport_height: usize) void {
        const model = self.screenModel() orelse return;
        if (model.links.len == 0) return;

        const next_index: usize = if (self.selected_link) |selected|
            if (backwards)
                if (selected == 0) model.links.len - 1 else selected - 1
            else
                (selected + 1) % model.links.len
        else if (backwards)
            model.links.len - 1
        else
            0;

        self.selected_link = next_index;
        self.ensureLineVisible(model.links[next_index].line, viewport_height);
    }

    pub fn openSelectedLink(self: *BrowserSession) !void {
        const model = self.screenModel() orelse return;
        const selected = self.selected_link orelse return;
        if (selected >= model.links.len) return;
        const current_url = self.currentUrl() orelse return;
        const resolved = try self.page.resolveUrl(current_url, model.links[selected].href);
        defer self.allocator.free(resolved);
        try self.navigateTo(resolved);
    }

    pub fn startPrompt(self: *BrowserSession, mode: PromptMode) !void {
        self.prompt_mode = mode;
        try self.prompt_buffer.resize(self.allocator, 0);
        switch (mode) {
            .url => if (self.currentUrl()) |url| try self.prompt_buffer.appendSlice(self.allocator, url),
            .search => if (self.search_query) |query| try self.prompt_buffer.appendSlice(self.allocator, query),
            .none => {},
        }
    }

    pub fn cancelPrompt(self: *BrowserSession) void {
        self.prompt_mode = .none;
        self.prompt_buffer.clearRetainingCapacity();
    }

    pub fn promptText(self: *const BrowserSession) ?[]const u8 {
        return switch (self.prompt_mode) {
            .none => null,
            .url => self.prompt_buffer.items,
            .search => self.prompt_buffer.items,
        };
    }

    pub fn promptLabel(self: *const BrowserSession) ?[]const u8 {
        return switch (self.prompt_mode) {
            .none => null,
            .url => "URL: ",
            .search => "Search: ",
        };
    }

    pub fn appendPromptByte(self: *BrowserSession, byte: u8) !void {
        if (self.prompt_mode == .none) return;
        if (byte < 0x20 or byte == 0x7f) return;
        try self.prompt_buffer.append(self.allocator, byte);
    }

    pub fn popPromptByte(self: *BrowserSession) void {
        if (self.prompt_mode == .none or self.prompt_buffer.items.len == 0) return;
        _ = self.prompt_buffer.pop();
    }

    pub fn submitPrompt(self: *BrowserSession) !void {
        const value = std.mem.trim(u8, self.prompt_buffer.items, " \t\r\n");
        switch (self.prompt_mode) {
            .none => return,
            .url => {
                self.cancelPrompt();
                if (value.len == 0) return;
                try self.navigateTo(value);
            },
            .search => {
                self.cancelPrompt();
                try self.setSearchQuery(value);
            },
        }
    }

    pub fn advanceSearch(self: *BrowserSession, viewport_height: usize) void {
        if (self.search_matches.items.len == 0) return;
        const next = if (self.search_index) |index| (index + 1) % self.search_matches.items.len else 0;
        self.search_index = next;
        self.ensureLineVisible(self.search_matches.items[next], viewport_height);
    }

    pub fn title(self: *const BrowserSession) []const u8 {
        if (self.current) |current| {
            if (current.result.title) |page_title| return page_title;
        }
        return "(untitled)";
    }

    pub fn currentUrl(self: *const BrowserSession) ?[]const u8 {
        if (self.current) |current| return current.result.url;
        return null;
    }

    pub fn screenModel(self: *const BrowserSession) ?*const page_mod.ScreenModel {
        if (self.current) |*current| return &current.screen;
        return null;
    }

    pub fn selectedLink(self: *const BrowserSession) ?page_mod.ScreenLink {
        const model = self.screenModel() orelse return null;
        const selected = self.selected_link orelse return null;
        if (selected >= model.links.len) return null;
        return model.links[selected];
    }

    pub fn footerText(self: *BrowserSession, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        if (self.prompt_mode != .none) {
            try buf.appendSlice(allocator, self.promptLabel().?);
            try buf.appendSlice(allocator, self.prompt_buffer.items);
            return buf.toOwnedSlice(allocator);
        }

        if (self.selectedLink()) |link| {
            try buf.writer(allocator).print("link {d}/{d}: {s}", .{
                link.index,
                self.screenModel().?.links.len,
                link.href,
            });
        } else {
            try buf.appendSlice(allocator, "no link selected");
        }

        if (self.search_query) |query| {
            try buf.writer(allocator).print(" | /{s}", .{query});
            if (self.search_matches.items.len > 0) {
                const current_match = if (self.search_index) |index| index + 1 else 0;
                try buf.writer(allocator).print(" ({d}/{d})", .{ current_match, self.search_matches.items.len });
            }
        }

        if (self.status_message) |msg| {
            try buf.writer(allocator).print(" | {s}", .{msg});
        }

        return buf.toOwnedSlice(allocator);
    }

    fn loadUrl(self: *BrowserSession, url: []const u8) !void {
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        var result = try self.page.navigate(url);
        errdefer result.deinit();

        var rendered = try self.page.renderBrowseModel(self.allocator, &result, .{
            .max_width = self.render_width,
            .ansi_colors = false,
            .show_links = true,
            .show_images = true,
        });
        errdefer rendered.deinit();

        if (self.current) |*current| current.deinit();
        self.current = .{ .result = result, .screen = rendered };
        self.scroll_row = 0;
        self.selected_link = if (rendered.links.len > 0) 0 else null;
        try self.setSearchQuery(if (previous_query) |query| query else "");
        try self.setStatusMessage(self.current.?.result.url);
    }

    fn pushHistory(self: *BrowserSession, url: []const u8) !void {
        if (self.history.items.len > 0 and self.history_index + 1 < self.history.items.len) {
            var i = self.history.items.len;
            while (i > self.history_index + 1) {
                i -= 1;
                self.allocator.free(self.history.items[i].url);
            }
            try self.history.resize(self.allocator, self.history_index + 1);
        }

        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1].url, url)) {
            self.history_index = self.history.items.len - 1;
            return;
        }

        try self.history.append(self.allocator, .{ .url = try self.allocator.dupe(u8, url) });
        self.history_index = self.history.items.len - 1;
    }

    fn ensureLineVisible(self: *BrowserSession, line: usize, viewport_height: usize) void {
        if (viewport_height == 0) return;
        if (line < self.scroll_row) {
            self.scroll_row = line;
            return;
        }
        const bottom = self.scroll_row + viewport_height;
        if (line >= bottom) {
            self.scroll_row = line - viewport_height + 1;
        }
    }

    fn maxScroll(self: *const BrowserSession, viewport_height: usize) usize {
        const model = self.screenModel() orelse return 0;
        if (viewport_height == 0 or model.lines.len <= viewport_height) return 0;
        return model.lines.len - viewport_height;
    }

    fn setSearchQuery(self: *BrowserSession, query: []const u8) !void {
        if (self.search_query) |existing| self.allocator.free(existing);
        self.search_query = if (query.len == 0) null else try self.allocator.dupe(u8, query);
        self.search_matches.clearRetainingCapacity();
        self.search_index = null;

        const model = self.screenModel() orelse return;
        const needle = self.search_query orelse return;
        for (model.lines, 0..) |_, line_index| {
            const line = model.lineText(line_index);
            if (containsCaseInsensitive(line, needle)) {
                try self.search_matches.append(self.allocator, line_index);
            }
        }

        if (self.search_matches.items.len > 0) {
            self.search_index = 0;
            self.scroll_row = self.search_matches.items[0];
        }
    }

    fn setStatusMessage(self: *BrowserSession, msg: []const u8) !void {
        if (self.status_message) |old| self.allocator.free(old);
        self.status_message = try self.allocator.dupe(u8, msg);
    }

    fn rerenderCurrent(self: *BrowserSession) !void {
        var current = if (self.current) |*loaded| loaded else return;
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        var rendered = try self.page.renderBrowseModel(self.allocator, &current.result, .{
            .max_width = self.render_width,
            .ansi_colors = false,
            .show_links = true,
            .show_images = true,
        });
        errdefer rendered.deinit();

        current.screen.deinit();
        current.screen = rendered;
        if (rendered.links.len == 0) {
            self.selected_link = null;
        } else if (self.selected_link) |selected| {
            self.selected_link = @min(selected, rendered.links.len - 1);
        } else {
            self.selected_link = 0;
        }
        try self.setSearchQuery(if (previous_query) |query| query else "");
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, start_url: []const u8) !void {
    var terminal = try tui.Terminal.init();
    defer terminal.deinit();

    var session = try BrowserSession.init(allocator, io);
    defer session.deinit();
    try session.setViewportWidth(terminal.size().cols);
    try session.navigateTo(start_url);

    while (true) {
        const size = terminal.size();
        try session.setViewportWidth(size.cols);
        session.clampScroll(viewportHeight(size));
        try draw(&terminal, io, &session);
        const key = try terminal.readKey();
        switch (session.prompt_mode) {
            .none => switch (key) {
                .arrow_down => session.scrollBy(1, viewportHeight(terminal.size())),
                .arrow_up => session.scrollBy(-1, viewportHeight(terminal.size())),
                .tab => session.selectNextLink(false, viewportHeight(terminal.size())),
                .shift_tab => session.selectNextLink(true, viewportHeight(terminal.size())),
                .enter => try session.openSelectedLink(),
                .char => |ch| switch (ch) {
                    'j' => session.scrollBy(1, viewportHeight(terminal.size())),
                    'k' => session.scrollBy(-1, viewportHeight(terminal.size())),
                    'b' => try session.goBack(),
                    'f' => try session.goForward(),
                    'r' => try session.reload(),
                    'g' => try session.startPrompt(.url),
                    '/' => try session.startPrompt(.search),
                    'n' => session.advanceSearch(viewportHeight(terminal.size())),
                    'q' => return,
                    else => {},
                },
                else => {},
            },
            .url, .search => switch (key) {
                .enter => try session.submitPrompt(),
                .backspace => session.popPromptByte(),
                .escape => session.cancelPrompt(),
                .char => |ch| try session.appendPromptByte(ch),
                else => {},
            },
        }
    }
}

fn draw(terminal: *tui.Terminal, io: std.Io, session: *BrowserSession) !void {
    const size = terminal.size();
    const viewport_height = viewportHeight(size);
    try terminal.clearScreen();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = terminal.stdout_file.writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const model = session.screenModel();
    const url = session.currentUrl() orelse "";
    try writeClippedLine(stdout, size.cols, "AWR browse — ");
    try writeClippedLine(stdout, size.cols, url);
    try stdout.writeAll("\n");

    if (model) |screen_model| {
        var row: usize = 0;
        while (row < viewport_height) : (row += 1) {
            const line_index = session.scroll_row + row;
            if (line_index < screen_model.lines.len) {
                try writeClippedLine(stdout, size.cols, screen_model.lineText(line_index));
            }
            try stdout.writeAll("\x1b[K\n");
        }
    }

    const footer = try session.footerText(session.allocator);
    defer session.allocator.free(footer);
    try writeClippedLine(stdout, size.cols, footer);
    try stdout.writeAll("\x1b[K");
    try stdout.flush();
}

fn viewportHeight(size: tui.Size) usize {
    return if (size.rows > 2) size.rows - 2 else 0;
}

fn writeClippedLine(writer: anytype, width: usize, text: []const u8) !void {
    const clipped = if (text.len > width) text[0..width] else text;
    try writer.writeAll(clipped);
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn browserRenderWidth(cols: usize) usize {
    return @max(@as(usize, 20), if (cols > 2) cols - 2 else cols);
}

test "containsCaseInsensitive matches ASCII substrings" {
    try std.testing.expect(containsCaseInsensitive("Hello World", "world"));
    try std.testing.expect(!containsCaseInsensitive("Hello", "planet"));
}

test "BrowserSession rerenderCurrent uses browse render seam" {
    var session = try BrowserSession.init(std.testing.allocator);
    defer session.deinit();

    var result = try session.page.processHtml(
        "http://example.com/",
        200,
        "<html><body><main><p>Original.</p></main></body></html>",
    );
    const screen = try session.page.renderBrowseModel(std.testing.allocator, &result, .{
        .max_width = 78,
        .ansi_colors = false,
        .show_links = true,
        .show_images = true,
    });

    session.current = .{ .result = result, .screen = screen };
    session.render_width = 78;

    const html_buf = @constCast(session.current.?.result.html);
    const at = std.mem.indexOf(u8, html_buf, "Original.") orelse return error.SkipZigTest;
    @memcpy(html_buf[at .. at + "Changed.!".len], "Changed.!");

    try session.rerenderCurrent();

    const model = session.screenModel() orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Original.") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Changed.!") == null);
}
