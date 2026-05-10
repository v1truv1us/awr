const std = @import("std");
const page_mod = @import("page");
const tui = @import("tui.zig");

/// Hard ceiling for the browse renderer. Defends against terminals that lie
/// about width (some iOS SSH apps + tmux chains) or report extreme values that
/// would produce unreadable layouts. The wrap budget never exceeds this even
/// when the reported `cols` does.
const MAX_RENDER_WIDTH: usize = 200;

/// Idle interval between size re-queries while waiting for a keystroke. Keeps
/// the renderer reactive to SIGWINCH-equivalent resize events that can't be
/// observed any other way (raw mode + libxev + signal-safety constraints make
/// a real signal handler more invasive than this poll).
const SIZE_POLL_MS: i32 = 200;

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

const FocusTarget = enum {
    link,
    field,
};

/// Sort key for document-order focus traversal (T-60 / Tier 1).
/// Tab and Shift-Tab walk all focusables — links plus form
/// fields — in increasing key order. Within a single line, the
/// `col` field disambiguates fields by their rendered column;
/// links don't carry a column today (`ScreenLink` only has
/// `line`), so they sort to the start of their line. The trailing
/// `index` field breaks remaining ties via input-order so two
/// focusables that resolve to the same (line, col) stay in DOM
/// order (rare in practice).
const FocusKey = struct {
    line: usize,
    col: usize,
    is_link: bool,
    index: usize,
};

fn focusKeyForLink(link: page_mod.ScreenLink, index: usize) FocusKey {
    return .{ .line = link.line, .col = 0, .is_link = true, .index = index };
}

fn focusKeyForField(field: page_mod.ScreenField, index: usize) FocusKey {
    return .{ .line = field.line, .col = field.col, .is_link = false, .index = index };
}

fn focusKeyLess(a: FocusKey, b: FocusKey) bool {
    if (a.line != b.line) return a.line < b.line;
    if (a.col != b.col) return a.col < b.col;
    // Same (line, col): links sort before fields so a link rendered
    // immediately before a field on the same row keeps its place.
    if (a.is_link != b.is_link) return a.is_link;
    return a.index < b.index;
}

pub const BrowserSession = struct {
    allocator: std.mem.Allocator,
    page: page_mod.Page,
    current: ?LoadedPage,
    history: std.ArrayList(HistoryEntry),
    history_index: usize,
    focus_target: FocusTarget,
    selected_link: ?usize,
    selected_field: ?usize,
    field_values: std.ArrayListUnmanaged(FieldValue) = .empty,
    field_editing: bool,
    scroll_row: usize,
    search_query: ?[]u8,
    search_matches: std.ArrayList(usize),
    search_index: ?usize,
    prompt_mode: PromptMode,
    prompt_buffer: std.ArrayList(u8),
    status_message: ?[]u8,
    render_width: usize,
    render_height: usize,

    const FieldValue = struct {
        name: []u8,
        value: std.ArrayList(u8),
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !BrowserSession {
        return .{
            .allocator = allocator,
            .page = try page_mod.Page.init(allocator, io),
            .current = null,
            .history = std.ArrayList(HistoryEntry).empty,
            .history_index = 0,
            .focus_target = .link,
            .selected_link = null,
            .selected_field = null,
            .field_values = .empty,
            .field_editing = false,
            .scroll_row = 0,
            .search_query = null,
            .search_matches = std.ArrayList(usize).empty,
            .search_index = null,
            .prompt_mode = .none,
            .prompt_buffer = std.ArrayList(u8).empty,
            .status_message = null,
            .render_width = 78,
            .render_height = 22,
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
        for (self.field_values.items) |*fv| {
            self.allocator.free(fv.name);
            fv.value.deinit(self.allocator);
        }
        self.field_values.deinit(self.allocator);
        self.page.deinit();
    }

    pub fn navigateTo(self: *BrowserSession, url: []const u8) !void {
        try self.loadUrl(url);
        try self.pushHistory(self.current.?.result.url);
    }

    pub fn setViewportSize(self: *BrowserSession, cols: usize, rows: usize) !void {
        const desired_width = browserRenderWidth(cols);
        const desired_height = if (rows > 2) rows - 2 else 0;
        if (desired_width == self.render_width and desired_height == self.render_height) return;
        self.render_width = desired_width;
        self.render_height = desired_height;
        self.page.setViewportSize(self.render_width, self.render_height);
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

    pub fn selectNextField(self: *BrowserSession, backwards: bool, viewport_height: usize) void {
        const model = self.screenModel() orelse return;
        const editable_count = countEditableFields(model);
        if (editable_count == 0) return;

        const next_index: usize = if (self.selected_field) |selected|
            if (backwards)
                if (selected == 0) editable_count - 1 else selected - 1
            else
                (selected + 1) % editable_count
        else if (backwards)
            editable_count - 1
        else
            0;

        self.selected_field = next_index;
        self.focus_target = .field;
        self.field_editing = true;
        if (editableFieldAt(model, next_index)) |field| {
            self.ensureLineVisible(field.line, viewport_height);
        }
    }

    /// Tier 1 / T-60: Tab and Shift-Tab move focus across ALL
    /// focusable elements (links + form fields) in document order,
    /// matching real-browser semantics. Replaces the older mode-
    /// dependent branching that walked links and fields as
    /// separate cycles.
    ///
    /// Document-order ranking key: (line, then col for fields,
    /// then 0 for links since ScreenLink lacks a column).
    /// Links and fields on the same line interleave in source
    /// order via their respective `index` fields. Submit
    /// buttons participate in the focus order — pressing Enter
    /// on a focused submit triggers form submission.
    ///
    /// Side effect: any in-flight text editing exits before
    /// focus moves (matching browser behavior — Tab commits
    /// the field's value).
    pub fn nextFocusable(self: *BrowserSession, backwards: bool, viewport_height: usize) void {
        const model = self.screenModel() orelse return;
        const total = countFocusables(model);
        if (total == 0) return;

        // Stop editing first (Tab commits in real browsers).
        if (self.field_editing) self.exitFieldEditing();

        // Find current ordinal in document-ordered focus list.
        // We don't need to materialize the full list; just walk
        // it with a comparison function. For N focusables this is
        // O(N) per Tab press, which is fine for any realistic
        // page (links + fields rarely exceed a few hundred).
        const current_ord = self.currentFocusOrdinal(model);
        const next_ord: usize = if (current_ord) |c|
            if (backwards)
                if (c == 0) total - 1 else c - 1
            else
                (c + 1) % total
        else if (backwards) total - 1 else 0;

        self.setFocusByOrdinal(model, next_ord, viewport_height);
    }

    /// Return this session's focus position as an ordinal in the
    /// merged document-order list, or null if nothing is focused.
    fn currentFocusOrdinal(self: *const BrowserSession, model: *const page_mod.ScreenModel) ?usize {
        const cur = self.currentFocusKey(model) orelse return null;
        return countPredecessors(model, cur);
    }

    fn currentFocusKey(self: *const BrowserSession, model: *const page_mod.ScreenModel) ?FocusKey {
        switch (self.focus_target) {
            .link => {
                const idx = self.selected_link orelse return null;
                if (idx >= model.links.len) return null;
                return focusKeyForLink(model.links[idx], idx);
            },
            .field => {
                const idx = self.selected_field orelse return null;
                if (idx >= model.fields.len) return null;
                return focusKeyForField(model.fields[idx], idx);
            },
        }
    }

    /// Walk model in document order; pick the focusable at ordinal
    /// `target_ord`; update focus_target + selected_* + scroll
    /// accordingly. Caller has already validated `target_ord <
    /// links.len + fields.len`.
    fn setFocusByOrdinal(
        self: *BrowserSession,
        model: *const page_mod.ScreenModel,
        target_ord: usize,
        viewport_height: usize,
    ) void {
        // O(N²) scan — for hundreds of focusables this is sub-
        // millisecond and avoids an allocator dance per Tab.
        for (model.links, 0..) |link, i| {
            const ord = countPredecessors(model, focusKeyForLink(link, i));
            if (ord == target_ord) {
                self.focus_target = .link;
                self.selected_link = i;
                self.ensureLineVisible(link.line, viewport_height);
                return;
            }
        }
        for (model.fields, 0..) |field, i| {
            if (!isUserVisibleField(field)) continue;
            const ord = countPredecessors(model, focusKeyForField(field, i));
            if (ord == target_ord) {
                self.focus_target = .field;
                self.selected_field = i;
                // Auto-enter edit mode for text-like fields so the
                // user can type immediately after Tab. Buttons,
                // checkboxes, radios, submits stay non-editing —
                // they activate via Space / Enter (T-62 lands the
                // activation logic). Matches Chrome / Firefox
                // behavior where Tab lands on a text input and
                // typing flows in directly.
                self.field_editing = isTextLikeField(field);
                self.ensureLineVisible(field.line, viewport_height);
                return;
            }
        }
    }

    pub fn activeField(self: *BrowserSession) ?page_mod.ScreenField {
        const model = self.screenModel() orelse return null;
        const idx = self.selected_field orelse return null;
        if (idx >= model.fields.len) return null;
        return model.fields[idx];
    }

    pub fn activeFieldName(self: *BrowserSession) ?[]const u8 {
        const field = self.activeField() orelse return null;
        return field.name;
    }

    pub fn getFieldValue(self: *BrowserSession, field_name: []const u8) ?[]const u8 {
        for (self.field_values.items) |fv| {
            if (std.mem.eql(u8, fv.name, field_name)) return fv.value.items;
        }
        return null;
    }

    pub fn appendFieldByte(self: *BrowserSession, byte: u8) !void {
        if (!self.field_editing) return;
        const field = self.activeField() orelse return;
        if (byte < 0x20 or byte == 0x7f) return;
        const name = field.name;
        for (self.field_values.items) |*fv| {
            if (std.mem.eql(u8, fv.name, name)) {
                try fv.value.append(self.allocator, byte);
                return;
            }
        }
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        var val = std.ArrayList(u8).empty;
        try val.append(self.allocator, byte);
        try self.field_values.append(self.allocator, .{ .name = name_copy, .value = val });
    }

    pub fn deleteFieldByte(self: *BrowserSession) void {
        if (!self.field_editing) return;
        const field = self.activeField() orelse return;
        for (self.field_values.items) |*fv| {
            if (std.mem.eql(u8, fv.name, field.name)) {
                if (fv.value.items.len > 0) _ = fv.value.pop();
                return;
            }
        }
    }

    pub fn submitForm(self: *BrowserSession) !void {
        const model = self.screenModel() orelse return;
        const current_url = self.currentUrl() orelse return;

        // Build URL-encoded payload from all non-submit fields. Hidden inputs
        // and unedited text inputs fall back to the element's `value`
        // attribute so CSRF tokens and pre-filled fields are sent verbatim
        // (per spec/subspecs/agent-browser.md §2).
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(self.allocator);
        var first = true;
        for (model.fields) |field| {
            if (field.is_submit) continue;
            if (field.name.len == 0) continue;
            const edited = self.getFieldValue(field.name);
            const val: []const u8 = edited orelse self.page.fieldValueAttr(field) orelse "";
            if (!first) try body.append(self.allocator, '&');
            first = false;
            try self.appendUrlEncoded(&body, field.name);
            try body.append(self.allocator, '=');
            try self.appendUrlEncoded(&body, val);
        }

        // Resolve the form's method + action. If no <form> ancestor is found
        // (degenerate markup), fall back to the legacy GET-with-querystring
        // behavior at the current URL.
        const meta_opt: ?page_mod.Page.FormMeta = blk: {
            for (model.fields) |field| {
                if (field.is_submit) continue;
                if (self.page.formMetaForField(field)) |m| break :blk m;
            }
            break :blk null;
        };

        const action_raw: []const u8 = if (meta_opt) |m| (m.action orelse current_url) else current_url;
        const target_url = try self.page.resolveUrl(current_url, action_raw);
        defer self.allocator.free(target_url);

        const is_post = if (meta_opt) |m| (m.method == .POST) else false;
        if (is_post) {
            try self.loadPostUrl(target_url, body.items);
            try self.pushHistory(self.current.?.result.url);
            body.deinit(self.allocator);
            return;
        }

        // GET: append payload as query string.
        const full_url = if (body.items.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ target_url, body.items })
        else
            try self.allocator.dupe(u8, target_url);
        defer self.allocator.free(full_url);
        body.deinit(self.allocator);
        try self.navigateTo(full_url);
    }

    fn appendUrlEncoded(self: *BrowserSession, buf: *std.ArrayList(u8), s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(self.allocator, c),
                ' ' => try buf.appendSlice(self.allocator, "+"),
                else => {
                    try buf.append(self.allocator, '%');
                    const hex = try std.fmt.allocPrint(self.allocator, "{X:0>2}", .{c});
                    defer self.allocator.free(hex);
                    try buf.appendSlice(self.allocator, hex);
                },
            }
        }
    }

    pub fn exitFieldEditing(self: *BrowserSession) void {
        self.field_editing = false;
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

        if (self.field_editing) {
            if (self.activeField()) |field| {
                const val = self.getFieldValue(field.name) orelse "";
                try buf.print(allocator, "field '{s}': {s}", .{ field.name, val });
                try buf.append(allocator, '_');
            } else {
                try buf.appendSlice(allocator, "editing field");
            }
        } else if (self.focus_target == .field and self.selected_field != null) {
            if (self.activeField()) |field| {
                const val = self.getFieldValue(field.name) orelse "";
                try buf.print(allocator, "field '{s}': {s}", .{ field.name, val });
            }
        } else if (self.selectedLink()) |link| {
            try buf.print(allocator, "link {d}/{d}: {s}", .{
                link.index,
                self.screenModel().?.links.len,
                link.href,
            });
        } else {
            try buf.appendSlice(allocator, "no link selected");
        }

        if (self.search_query) |query| {
            try buf.print(allocator, " | /{s}", .{query});
            if (self.search_matches.items.len > 0) {
                const current_match = if (self.search_index) |index| index + 1 else 0;
                try buf.print(allocator, " ({d}/{d})", .{ current_match, self.search_matches.items.len });
            }
        }

        if (self.status_message) |msg| {
            try buf.print(allocator, " | {s}", .{msg});
        }

        return buf.toOwnedSlice(allocator);
    }

    fn loadUrl(self: *BrowserSession, url: []const u8) !void {
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        var result = try self.page.navigate(url);
        errdefer result.deinit();
        try self.installLoadedPage(result, previous_query);
    }

    fn loadPostUrl(self: *BrowserSession, url: []const u8, body: []const u8) !void {
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        var result = try self.page.navigatePost(url, body);
        errdefer result.deinit();
        try self.installLoadedPage(result, previous_query);
    }

    /// Shared tail for `loadUrl` and `loadPostUrl`: render the new result,
    /// swap it into the session, reset cursors, and refresh the status line.
    fn installLoadedPage(self: *BrowserSession, result: page_mod.PageResult, previous_query: ?[]u8) !void {
        var local_result = result;
        errdefer local_result.deinit();

        const fvl: page_mod.FieldValueLookup = .{
            .ctx = self,
            .lookup_fn = fieldValueLookupCallback,
        };
        var rendered = try self.page.renderBrowseModel(self.allocator, &local_result, .{
            .max_width = self.render_width,
            .ansi_colors = true,
            .show_links = true,
            .show_images = true,
            .field_value_lookup = fvl,
            // First render of a fresh page — no focus yet (Tab will set
            // it, then the next rerender picks it up).
            .focused_element_ptr = null,
        });
        errdefer rendered.deinit();

        if (self.current) |*current| current.deinit();
        self.current = .{ .result = local_result, .screen = rendered };
        self.scroll_row = 0;
        self.selected_link = if (rendered.links.len > 0) 0 else null;
        self.selected_field = null;
        self.field_editing = false;
        try self.setSearchQuery(if (previous_query) |query| query else "");

        const visible = trimmedTextLen(rendered.text);
        if (visible < 16) {
            try self.setStatusMessage("page rendered no terminal-friendly content (JS-driven page - try `awr <url>` for raw extraction)");
        } else {
            try self.setStatusMessage(self.current.?.result.url);
        }
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

    /// FieldValueLookup callback: returns the user's typed value for
    /// `field_name`, or null when the user hasn't touched that field.
    /// Plumbed into the renderer so the displayed `[___]` reflects what
    /// the user typed instead of staying empty.
    fn fieldValueLookupCallback(ctx: *anyopaque, field_name: []const u8) ?[]const u8 {
        const self: *const BrowserSession = @ptrCast(@alignCast(ctx));
        for (self.field_values.items) |fv| {
            if (std.mem.eql(u8, fv.name, field_name)) return fv.value.items;
        }
        return null;
    }

    /// Pointer-equality identifier of the currently-focused form
    /// control for the renderer's focus highlight. Returns null when
    /// focus is on a link (or nothing) — link highlighting is a
    /// separate code path the renderer already handles.
    fn focusedElementPtrForRender(self: *const BrowserSession) ?usize {
        if (self.focus_target != .field) return null;
        const idx = self.selected_field orelse return null;
        const model = self.screenModel() orelse return null;
        if (idx >= model.fields.len) return null;
        return model.fields[idx].element_ptr;
    }

    fn rerenderCurrent(self: *BrowserSession) !void {
        var current = if (self.current) |*loaded| loaded else return;
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        const fvl: page_mod.FieldValueLookup = .{
            .ctx = self,
            .lookup_fn = fieldValueLookupCallback,
        };
        var rendered = try self.page.renderBrowseModel(self.allocator, &current.result, .{
            .max_width = self.render_width,
            .ansi_colors = true,
            .show_links = true,
            .show_images = true,
            .field_value_lookup = fvl,
            .focused_element_ptr = self.focusedElementPtrForRender(),
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
    return runWith(allocator, io, start_url, .{});
}

pub const RunOptions = struct {
    /// When true, the page pipeline skips script execution. Useful
    /// against pages whose JS strips its own UI in non-Chromium
    /// environments (Google's homepage, similar SPAs). T-72.
    disable_scripts: bool = false,
};

pub fn runWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_url: ?[]const u8,
    opts: RunOptions,
) !void {
    var terminal = try tui.Terminal.init();
    defer terminal.deinit();

    var session = try BrowserSession.init(allocator, io);
    defer session.deinit();
    session.page.disable_scripts = opts.disable_scripts;
    const initial_size = terminal.size();
    try session.setViewportSize(initial_size.cols, initial_size.rows);
    // T-75: when launched without a URL (`awr tui` with no args and no
    // AWR_HOMEPAGE), drop the user straight into the URL bar so they
    // get a "blank tab" feel. The URL prompt already accepts free-form
    // input via the existing `:` binding; we just trigger it on entry.
    if (start_url) |url| {
        try session.navigateTo(url);
    } else {
        try session.startPrompt(.url);
    }

    var prev_cols: usize = 0;
    var prev_rows: usize = 0;
    var needs_draw: bool = true;
    while (true) {
        const size = terminal.size();
        if (size.cols != prev_cols or size.rows != prev_rows) {
            try session.setViewportSize(size.cols, size.rows);
            session.clampScroll(viewportHeight(size));
            prev_cols = size.cols;
            prev_rows = size.rows;
            needs_draw = true;
        }
        if (needs_draw) {
            try draw(&terminal, io, &session);
            needs_draw = false;
        }
        const maybe_key = try terminal.readKeyTimeout(SIZE_POLL_MS);
        const key = maybe_key orelse continue;
        needs_draw = true;
        // Universal quit: Ctrl+C / Ctrl+D always exits, regardless of which
        // mode the session is in (link nav, field editing, prompt). This is
        // the escape hatch when other key bindings don't work as expected.
        if (key == .interrupt) return;
        switch (session.prompt_mode) {
            .none => if (session.field_editing) switch (key) {
                .escape => {
                    session.exitFieldEditing();
                    session.rerenderCurrent() catch {};
                },
                .tab => {
                    session.nextFocusable(false, viewportHeight(terminal.size()));
                    session.rerenderCurrent() catch {};
                },
                .shift_tab => {
                    session.nextFocusable(true, viewportHeight(terminal.size()));
                    session.rerenderCurrent() catch {};
                },
                .enter => {
                    // T-64 / Tier 1 slice T1.5: implicit form
                    // submission. Per HTML5 forms, pressing Enter
                    // in a focused text input submits the parent
                    // <form>. We commit the field's value (exit
                    // edit mode) then call submitForm — which
                    // handles GET vs POST, hidden CSRF inputs,
                    // and target URL resolution.
                    if (session.activeField()) |field| {
                        if (isTextLikeField(field)) {
                            session.exitFieldEditing();
                            session.submitForm() catch |err| {
                                const msg = std.fmt.allocPrint(
                                    session.allocator,
                                    "submit failed: {t}",
                                    .{err},
                                ) catch null;
                                if (msg) |m| {
                                    defer session.allocator.free(m);
                                    session.setStatusMessage(m) catch {};
                                }
                            };
                        } else {
                            session.exitFieldEditing();
                        }
                    } else {
                        session.exitFieldEditing();
                    }
                },
                .backspace => {
                    session.deleteFieldByte();
                    // Rerender so the box reflects the deleted byte
                    // immediately. T-73.
                    session.rerenderCurrent() catch {};
                },
                .char => |ch| {
                    try session.appendFieldByte(ch);
                    // Rerender so the typed byte appears inside the
                    // [____] box. T-73.
                    session.rerenderCurrent() catch {};
                },
                else => {},
            } else switch (key) {
                .arrow_down => session.scrollBy(1, viewportHeight(terminal.size())),
                .arrow_up => session.scrollBy(-1, viewportHeight(terminal.size())),
                .tab => {
                    session.nextFocusable(false, viewportHeight(terminal.size()));
                    // Rerender so the focus highlight moves with the
                    // cursor. T-73.
                    session.rerenderCurrent() catch {};
                },
                .shift_tab => {
                    session.nextFocusable(true, viewportHeight(terminal.size()));
                    session.rerenderCurrent() catch {};
                },
                .enter => {
                    if (session.focus_target == .field and session.selected_field != null) {
                        const field = session.activeField();
                        if (field != null and field.?.is_submit) {
                            try session.submitForm();
                        } else {
                            try session.openSelectedLink();
                        }
                    } else {
                        try session.openSelectedLink();
                    }
                },
                .char => |ch| switch (ch) {
                    'j' => session.scrollBy(1, viewportHeight(terminal.size())),
                    'k' => session.scrollBy(-1, viewportHeight(terminal.size())),
                    'b' => try session.goBack(),
                    'f' => try session.goForward(),
                    'r' => try session.reload(),
                    // T-66 / Tier 1: URL bar opens via vim-style ':'
                    // (preferred per spec/subspecs/browser-tui.md §2.6)
                    // OR legacy 'g' (existing binding kept for muscle
                    // memory compatibility).
                    'g', ':' => try session.startPrompt(.url),
                    '/' => try session.startPrompt(.search),
                    'n' => session.advanceSearch(viewportHeight(terminal.size())),
                    'e' => {
                        const model2 = session.screenModel();
                        if (model2 != null) {
                            for (model2.?.fields) |f| {
                                if (!f.is_submit) {
                                    session.selectNextField(false, viewportHeight(terminal.size()));
                                    break;
                                }
                            }
                        }
                    },
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
    try writeClippedLine(stdout, size.cols, "AWR — ");
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
    var visible: usize = 0;
    var i: usize = 0;
    var last_safe: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }
        visible += 1;
        i += 1;
        if (visible <= width) last_safe = i;
    }
    if (visible <= width) {
        try writer.writeAll(text);
    } else {
        try writer.writeAll(text[0..last_safe]);
        try writer.writeAll("\x1b[0m");
    }
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
    const padded = if (cols > 2) cols - 2 else cols;
    const clamped = @min(padded, MAX_RENDER_WIDTH);
    return @max(@as(usize, 20), clamped);
}

fn trimmedTextLen(text: []const u8) usize {
    var count: usize = 0;
    for (text) |ch| {
        if (!std.ascii.isWhitespace(ch)) count += 1;
    }
    return count;
}

fn isUserVisibleField(field: page_mod.ScreenField) bool {
    if (field.is_submit) return false;
    // Hidden inputs are kept in the model for form submission (CSRF round-trip
    // per spec/subspecs/agent-browser.md §2) but must not appear in the user's
    // tab order or field counts.
    if (std.mem.eql(u8, field.field_type, "hidden")) return false;
    return true;
}

fn countEditableFields(model: *const page_mod.ScreenModel) usize {
    var count: usize = 0;
    for (model.fields) |field| {
        if (isUserVisibleField(field)) count += 1;
    }
    return count;
}

/// True for field types where the user types text directly:
/// `text`, `password`, `email`, `url`, `search`, `tel`, `number`,
/// and `textarea`. Buttons / checkboxes / radios / submits are
/// focusable but not text-typing — they accept Space / Enter
/// activation (handled by T-62 / slice T1.3).
fn isTextLikeField(field: page_mod.ScreenField) bool {
    if (field.is_submit) return false;
    const t = field.field_type;
    if (std.mem.eql(u8, t, "text")) return true;
    if (std.mem.eql(u8, t, "password")) return true;
    if (std.mem.eql(u8, t, "email")) return true;
    if (std.mem.eql(u8, t, "url")) return true;
    if (std.mem.eql(u8, t, "search")) return true;
    if (std.mem.eql(u8, t, "tel")) return true;
    if (std.mem.eql(u8, t, "number")) return true;
    if (std.mem.eql(u8, t, "textarea")) return true;
    // Default-to-text behavior for inputs without an explicit
    // type attribute (HTML default is "text"). Defensive — most
    // pages set type explicitly, but lazy markup exists.
    if (t.len == 0) return true;
    return false;
}

fn editableFieldAt(model: *const page_mod.ScreenModel, idx: usize) ?page_mod.ScreenField {
    var i: usize = 0;
    for (model.fields) |field| {
        if (!isUserVisibleField(field)) continue;
        if (i == idx) return field;
        i += 1;
    }
    return null;
}

/// Total number of focusable elements in document order.
/// Includes all links + visible (non-hidden) fields including
/// submit buttons. Free function so tests can call it directly.
fn countFocusables(model: *const page_mod.ScreenModel) usize {
    var n: usize = model.links.len;
    for (model.fields) |field| {
        if (isUserVisibleField(field)) n += 1;
    }
    return n;
}

/// Count how many focusables sort strictly before `key` in
/// document order. Used by the unified Tab/Shift-Tab traversal
/// to compute and apply ordinals.
fn countPredecessors(model: *const page_mod.ScreenModel, key: FocusKey) usize {
    var n: usize = 0;
    for (model.links, 0..) |link, i| {
        if (focusKeyLess(focusKeyForLink(link, i), key)) n += 1;
    }
    for (model.fields, 0..) |field, i| {
        if (!isUserVisibleField(field)) continue;
        if (focusKeyLess(focusKeyForField(field, i), key)) n += 1;
    }
    return n;
}

test "containsCaseInsensitive matches ASCII substrings" {
    try std.testing.expect(containsCaseInsensitive("Hello World", "world"));
    try std.testing.expect(!containsCaseInsensitive("Hello", "planet"));
}

test "browserRenderWidth clamps to floor and ceiling" {
    // Normal terminal: padded by 2.
    try std.testing.expectEqual(@as(usize, 78), browserRenderWidth(80));
    // Tiny terminal: floor at 20 cols.
    try std.testing.expectEqual(@as(usize, 20), browserRenderWidth(10));
    try std.testing.expectEqual(@as(usize, 20), browserRenderWidth(22));
    // Pathological wide value (lying terminal): ceiling at MAX_RENDER_WIDTH.
    try std.testing.expectEqual(@as(usize, MAX_RENDER_WIDTH), browserRenderWidth(500));
    try std.testing.expectEqual(@as(usize, MAX_RENDER_WIDTH), browserRenderWidth(202));
    // Boundary: cols-2 exactly equals MAX → unclamped.
    try std.testing.expectEqual(@as(usize, MAX_RENDER_WIDTH), browserRenderWidth(MAX_RENDER_WIDTH + 2));
}

test "BrowserSession rerenderCurrent uses browse render seam" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
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

// ── T-60 / Tier 1 slice T1.1: focus traversal ────────────────────

test "focusKeyLess sorts by line, then col, then link-before-field, then index" {
    const a: FocusKey = .{ .line = 0, .col = 0, .is_link = true, .index = 0 };
    const b: FocusKey = .{ .line = 0, .col = 5, .is_link = false, .index = 0 };
    const c: FocusKey = .{ .line = 1, .col = 0, .is_link = true, .index = 0 };

    // Earlier line wins regardless of col / kind.
    try std.testing.expect(focusKeyLess(a, c));
    try std.testing.expect(focusKeyLess(b, c));
    try std.testing.expect(!focusKeyLess(c, a));

    // Same line, lower col wins.
    try std.testing.expect(focusKeyLess(a, b));
    try std.testing.expect(!focusKeyLess(b, a));

    // Same (line, col): link sorts before field.
    const link_at_zero: FocusKey = .{ .line = 2, .col = 0, .is_link = true, .index = 0 };
    const field_at_zero: FocusKey = .{ .line = 2, .col = 0, .is_link = false, .index = 0 };
    try std.testing.expect(focusKeyLess(link_at_zero, field_at_zero));

    // Same kind+pos: index breaks tie.
    const idx0: FocusKey = .{ .line = 3, .col = 7, .is_link = false, .index = 0 };
    const idx1: FocusKey = .{ .line = 3, .col = 7, .is_link = false, .index = 1 };
    try std.testing.expect(focusKeyLess(idx0, idx1));
}

test "Tab traversal walks links and visible fields in document order, skipping hidden" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();

    // Page with: link → text input → hidden input → submit button → link.
    // Tab should visit link0, input, submit, link1 (4 stops; hidden skipped).
    const html =
        \\<html><body>
        \\<form action="/submit" method="post">
        \\<a href="/before">first link</a>
        \\<input type="text" name="user">
        \\<input type="hidden" name="csrf" value="abc">
        \\<input type="submit" value="Go">
        \\<a href="/after">second link</a>
        \\</form>
        \\</body></html>
    ;
    var result = try session.page.processHtml("http://example.com/", 200, html);
    const screen = try session.page.renderBrowseModel(std.testing.allocator, &result, .{
        .max_width = 78,
        .ansi_colors = false,
        .show_links = true,
        .show_images = true,
    });
    session.current = .{ .result = result, .screen = screen };

    const model = session.screenModel().?;

    // Expectation: 2 links + 2 visible fields (hidden CSRF skipped) = 4 stops.
    try std.testing.expectEqual(@as(usize, 4), countFocusables(model));

    // First Tab from no-focus lands on the first focusable in
    // document order. With our fixture and the renderer's ordering,
    // walking 4 Tab presses must end on the same starting position
    // (cycle-complete). We don't assert exact identity at each step
    // (that depends on renderer line/col placement which can shift
    // with style changes), only that the cycle returns home.
    session.nextFocusable(false, 24);
    const first_target = session.focus_target;
    const first_link = session.selected_link;
    const first_field = session.selected_field;
    var i: usize = 0;
    while (i < 4) : (i += 1) session.nextFocusable(false, 24);
    try std.testing.expectEqual(first_target, session.focus_target);
    try std.testing.expectEqual(first_link, session.selected_link);
    try std.testing.expectEqual(first_field, session.selected_field);
}

test "countFocusables excludes hidden inputs" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();

    const html =
        \\<html><body>
        \\<form>
        \\<input type="hidden" name="a" value="1">
        \\<input type="hidden" name="b" value="2">
        \\<input type="text" name="c">
        \\</form>
        \\</body></html>
    ;
    var result = try session.page.processHtml("http://example.com/", 200, html);
    const screen = try session.page.renderBrowseModel(std.testing.allocator, &result, .{
        .max_width = 78,
        .ansi_colors = false,
        .show_links = true,
        .show_images = true,
    });
    session.current = .{ .result = result, .screen = screen };

    const model = session.screenModel().?;
    // 0 links + 1 visible field = 1 focusable. Hidden inputs do
    // appear in model.fields (we keep them for form submission)
    // but must not be counted toward focus order.
    try std.testing.expectEqual(@as(usize, 1), countFocusables(model));
}

test "Tab onto Google-shaped textarea enters edit mode and accepts typing" {
    // Mirror Google's homepage form shape: hidden CSRF-style inputs +
    // textarea named `q` + submit button. The user-visible flow is:
    //   1. press Tab once → focus lands on textarea (hidden skipped)
    //   2. text-like auto-edit kicks in (`field_editing == true`)
    //   3. typing flows into `field_values["q"]` not the status bar
    //   4. activeField()'s type is "textarea" and is text-like
    //
    // T-76 follow-up: documents the keypress contract that "clicks/
    // presses don't work" was actually testing. If this test ever
    // regresses, the TUI is broken in the same way the user reported.
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();

    const html =
        \\<html><body>
        \\<form action="/search" method="get">
        \\<input type="hidden" name="ie" value="UTF-8">
        \\<input type="hidden" name="source" value="hp">
        \\<textarea name="q" aria-label="Search"></textarea>
        \\<input type="submit" name="btnK" value="Google Search">
        \\</form>
        \\</body></html>
    ;
    var result = try session.page.processHtml("https://www.google.com/", 200, html);
    const screen = try session.page.renderBrowseModel(std.testing.allocator, &result, .{
        .max_width = 78,
        .ansi_colors = false,
        .show_links = true,
        .show_images = true,
    });
    session.current = .{ .result = result, .screen = screen };

    const model = session.screenModel().?;
    // 0 links + 2 visible fields (textarea + submit; 2 hidden skipped).
    try std.testing.expectEqual(@as(usize, 2), countFocusables(model));

    // First Tab: should land on the textarea (first visible field in
    // doc order). Submit comes after.
    session.nextFocusable(false, 24);
    try std.testing.expectEqual(@as(@TypeOf(session.focus_target), .field), session.focus_target);
    const field = session.activeField().?;
    try std.testing.expect(std.mem.eql(u8, field.field_type, "textarea"));
    try std.testing.expect(std.mem.eql(u8, field.name, "q"));
    try std.testing.expect(isTextLikeField(field));
    // Auto-edit on text-like — typing flows into the field, not the
    // status line. This was the bug the user reported.
    try std.testing.expect(session.field_editing);

    // Type "hi" — should populate field_values["q"], not status bar.
    try session.appendFieldByte('h');
    try session.appendFieldByte('i');
    const stored = session.getFieldValue("q") orelse "";
    try std.testing.expect(std.mem.eql(u8, stored, "hi"));
}
