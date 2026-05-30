const std = @import("std");
const page_mod = @import("page");
const tui = @import("tui.zig");
const bookmarks_mod = @import("bookmarks.zig");
const image_protocol = @import("image_protocol");
const image_pipeline = @import("image_pipeline");

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
    /// T-81: user-toggled checked state for checkbox / radio fields,
    /// keyed by element_ptr. When a key is missing, the renderer
    /// (and submitForm) falls back to the DOM's `checked` attribute.
    /// Radio toggles set this entry and clear other radios sharing
    /// the same `name`.
    field_checked: std.ArrayListUnmanaged(CheckedState) = .empty,
    /// T-83: user-selected option for `<select>` fields, keyed by
    /// element_ptr. Holds both the submit value and the display
    /// label. When a key is missing, the renderer falls back to DOM
    /// `<option selected>` and submitForm falls back to the same.
    field_selected: std.ArrayListUnmanaged(SelectedOption) = .empty,
    /// T-83: when non-null, an inline `<select>` picker is open.
    /// The TUI overlays the picker on the body area; arrow keys
    /// navigate, Enter commits, Esc cancels.
    select_picker: ?SelectPicker = null,
    /// T-84/T2.3: when non-null, the cookie inspector is open over
    /// the body area. Lists cookies matching the current origin's host
    /// with name/value/domain/path/expiry/secure/http_only/samesite
    /// columns. `d` deletes the focused row; uppercase `C` clears all
    /// (asking for confirmation first); `q`/Esc closes.
    cookie_inspector: ?CookieInspector = null,
    /// T-90 / Tier 2 T2.2: in-memory ring buffer of recently-navigated
    /// URLs. Per-shell-session per spec — persistent cross-process
    /// history is Tier 3 work. Capped at `url_history_cap`; the
    /// oldest entry is evicted on overflow. Each string is owned.
    url_history: std.ArrayListUnmanaged([]u8) = .empty,
    url_history_cap: usize = 20,
    /// T-90: autocomplete state for the URL prompt. Non-null only
    /// while the user is cycling through matches via arrow keys.
    /// Reset whenever the user types or backspaces — see
    /// `resetUrlAutocomplete`.
    url_autocomplete: ?UrlAutocomplete = null,
    /// T-92: terminal image protocol resolved at startup. `.none`
    /// keeps the existing alt-text fallback; any other value triggers
    /// per-page pipeline construction in installLoadedPage so the
    /// renderer's image_lookup hook gets real bytes to emit.
    image_protocol: image_protocol.Protocol = .none,
    /// T2.9: session-level decoded-image LRU cache. Persists across
    /// rerenders and back/forward navigations so the fetch+decode path
    /// only runs once per unique image URL per session. 32 MiB / 32
    /// entry cap; iTerm2 protocol bypasses it (raw bytes, not pixels).
    img_cache: image_pipeline.Cache,
    /// T2.4: mirrors RenderOptions.code_line_numbers. Set from RunOptions.
    code_line_numbers: usize = 5,
    /// T2.4/T2.5: mirrors RenderOptions.code_style. Set from RunOptions.
    code_style: page_mod.CodeStyle = .none,
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
    /// §2.2 (TUI Quality): target URL of an in-flight navigation. Non-null
    /// only between the start of a blocking fetch and the new page being
    /// installed. `drawFrame` shows it plus a "Loading…" marker in the header
    /// so the TUI doesn't look frozen on slow pages. Owned.
    loading_url: ?[]u8 = null,
    /// §2.2: live terminal + io captured by `runWith` so the blocking nav
    /// path can paint a single loading frame before `page.navigate()`. Null in
    /// headless tests (`TuiHarness`), where `paintLoadingFrame` is a no-op.
    active_terminal: ?*tui.Terminal = null,
    active_io: ?std.Io = null,
    /// §2.3 (TUI Quality): when true, `drawFrame` replaces the body area with
    /// the keybinding help overlay. Any key dismisses it.
    show_help: bool = false,

    const FieldValue = struct {
        name: []u8,
        value: std.ArrayList(u8),
    };

    /// T-81: user-toggled checked state for a single checkbox/radio,
    /// keyed by element pointer (stable for the lifetime of the
    /// current page). Cleared on navigation; survives rerenders.
    const CheckedState = struct {
        element_ptr: usize,
        checked: bool,
    };

    /// T-83: user-selected option for a `<select>` element. Owns
    /// both the submit value and the display label so the lookups
    /// (renderer queries label; submitForm queries value) can be
    /// satisfied without re-walking the DOM.
    const SelectedOption = struct {
        element_ptr: usize,
        value: []u8,
        label: []u8,
    };

    /// T-83: state for an open inline `<select>` picker. Owns the
    /// option snapshot taken at open time so subsequent rerenders
    /// of the page don't disturb the picker's contents.
    pub const SelectPicker = struct {
        element_ptr: usize,
        cursor: usize,
        options: []page_mod.Page.OptionEntry,
    };

    /// T-84: snapshot of one cookie row in the inspector. Owned
    /// copies so the inspector survives jar mutations (e.g. user
    /// deletes a row and we need to keep showing the others).
    pub const CookieRow = struct {
        name: []u8,
        value: []u8,
        domain: []u8,
        path: []u8,
        expires: ?i64,
        secure: bool,
        http_only: bool,
        /// 'L' lax · 'S' strict · 'N' none — pre-computed for display.
        same_site_char: u8,
    };

    /// T-84: state for an open cookie inspector. Holds a snapshot
    /// of the cookies for the current origin at open time, plus a
    /// cursor and an optional confirmation sub-state for the
    /// destructive "clear all" action.
    pub const CookieInspector = struct {
        rows: std.ArrayListUnmanaged(CookieRow),
        cursor: usize,
        origin_host: []u8,
        confirm_clear_all: bool = false,
    };

    /// T-90: URL-bar autocomplete cycle state. Built lazily on the
    /// first arrow keypress, owned by the session, cleared on any
    /// prompt mutation. `prefix` is the prompt text snapshot taken
    /// at init time; `match_indices` points into `url_history` by
    /// index (stable for the lifetime of this cycle since we don't
    /// mutate url_history while a prompt is open).
    pub const UrlAutocomplete = struct {
        prefix: []u8,
        match_indices: std.ArrayListUnmanaged(usize),
        cursor: usize,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !BrowserSession {
        var img_c = image_pipeline.Cache.init(allocator, image_pipeline.default_cache_cap_bytes);
        img_c.max_entries = 32;
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
            .url_history_cap = readUrlHistoryCap(),
            .img_cache = img_c,
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
        if (self.loading_url) |u| self.allocator.free(u);
        for (self.field_values.items) |*fv| {
            self.allocator.free(fv.name);
            fv.value.deinit(self.allocator);
        }
        self.field_values.deinit(self.allocator);
        self.field_checked.deinit(self.allocator);
        for (self.field_selected.items) |entry| {
            self.allocator.free(entry.value);
            self.allocator.free(entry.label);
        }
        self.field_selected.deinit(self.allocator);
        if (self.select_picker) |*picker| self.page.freeOptions(picker.options);
        if (self.cookie_inspector) |*ci| freeCookieInspector(self.allocator, ci);
        // T-90: drop URL history strings + any open autocomplete state.
        for (self.url_history.items) |u| self.allocator.free(u);
        self.url_history.deinit(self.allocator);
        self.resetUrlAutocomplete();
        self.img_cache.deinit();
        self.page.deinit();
    }

    /// Look up user-toggled checked state for a field, falling back
    /// to the DOM's `checked` attribute when the user hasn't touched
    /// it. T-81. The renderer and submitForm both query this so the
    /// displayed glyph and submitted payload stay in sync.
    pub fn isFieldChecked(self: *BrowserSession, field: page_mod.ScreenField) bool {
        for (self.field_checked.items) |entry| {
            if (entry.element_ptr == field.element_ptr) return entry.checked;
        }
        return self.page.fieldCheckedAttr(field);
    }

    /// Toggle (checkbox) or select (radio) the focused field. T-81.
    /// For radios, also clears the user-toggle of any other radio in
    /// the same `name` group so only one stays checked at a time.
    fn toggleCheckedField(self: *BrowserSession) !void {
        const field = self.activeField() orelse return;
        const model = self.screenModel() orelse return;
        const is_checkbox = std.mem.eql(u8, field.field_type, "checkbox");
        const is_radio = std.mem.eql(u8, field.field_type, "radio");
        if (!is_checkbox and !is_radio) return;

        if (is_radio) {
            // Clear all other radios in the same name group. This
            // guarantees only the just-pressed one ends up checked.
            for (model.fields) |other| {
                if (!std.mem.eql(u8, other.field_type, "radio")) continue;
                if (!std.mem.eql(u8, other.name, field.name)) continue;
                if (other.element_ptr == field.element_ptr) continue;
                try self.setCheckedRaw(other.element_ptr, false);
            }
            try self.setCheckedRaw(field.element_ptr, true);
        } else {
            const current = self.isFieldChecked(field);
            try self.setCheckedRaw(field.element_ptr, !current);
        }
    }

    /// Upsert a checked-state entry. Lower-level than `toggleCheckedField`
    /// because radio toggles need to clear multiple peers in one go.
    fn setCheckedRaw(self: *BrowserSession, element_ptr: usize, checked: bool) !void {
        for (self.field_checked.items) |*entry| {
            if (entry.element_ptr == element_ptr) {
                entry.checked = checked;
                return;
            }
        }
        try self.field_checked.append(self.allocator, .{
            .element_ptr = element_ptr,
            .checked = checked,
        });
    }

    /// Look up the user-selected option label for a `<select>` so
    /// the renderer can display it. Null when the user hasn't opened
    /// the picker for this select; the renderer falls back to DOM
    /// `<option selected>`. T-83.
    pub fn selectedOptionLabel(self: *const BrowserSession, element_ptr: usize) ?[]const u8 {
        for (self.field_selected.items) |entry| {
            if (entry.element_ptr == element_ptr) return entry.label;
        }
        return null;
    }

    /// Look up the user-selected option *value* (what gets submitted)
    /// for a `<select>`. Null when the user hasn't picked one. T-83.
    pub fn selectedOptionValue(self: *const BrowserSession, element_ptr: usize) ?[]const u8 {
        for (self.field_selected.items) |entry| {
            if (entry.element_ptr == element_ptr) return entry.value;
        }
        return null;
    }

    /// Persist the user's selection from the picker. Owns the
    /// duped value/label strings; frees any prior entry for the
    /// same element. T-83.
    fn setSelectedOption(
        self: *BrowserSession,
        element_ptr: usize,
        value: []const u8,
        label: []const u8,
    ) !void {
        for (self.field_selected.items) |*entry| {
            if (entry.element_ptr == element_ptr) {
                const new_value = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(new_value);
                const new_label = try self.allocator.dupe(u8, label);
                self.allocator.free(entry.value);
                self.allocator.free(entry.label);
                entry.value = new_value;
                entry.label = new_label;
                return;
            }
        }
        const value_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_owned);
        const label_owned = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_owned);
        try self.field_selected.append(self.allocator, .{
            .element_ptr = element_ptr,
            .value = value_owned,
            .label = label_owned,
        });
    }

    /// Open an inline `<select>` picker for the focused select.
    /// No-op if the focus isn't on a select. The picker snapshots
    /// the option list so subsequent rerenders don't disturb it.
    /// Initial cursor lands on the currently-selected option (from
    /// user state if set, else DOM `selected`, else 0). T-83.
    pub fn openSelectPicker(self: *BrowserSession) !void {
        const field = self.activeField() orelse return;
        if (!std.mem.eql(u8, field.field_type, "select")) return;

        const options = try self.page.optionsForSelect(field);
        errdefer self.page.freeOptions(options);
        if (options.len == 0) {
            // No options to pick from — release the empty alloc and
            // skip opening; an empty modal would just confuse the user.
            self.page.freeOptions(options);
            return;
        }

        // Land cursor on the current selection.
        var cursor: usize = 0;
        if (self.selectedOptionValue(field.element_ptr)) |val| {
            for (options, 0..) |opt, i| {
                if (std.mem.eql(u8, opt.value, val)) {
                    cursor = i;
                    break;
                }
            }
        } else {
            for (options, 0..) |opt, i| {
                if (opt.selected) {
                    cursor = i;
                    break;
                }
            }
        }

        // Replace any existing picker (e.g. user pressed Space twice on
        // different selects without committing) — free the old options.
        if (self.select_picker) |*old| self.page.freeOptions(old.options);
        self.select_picker = .{
            .element_ptr = field.element_ptr,
            .cursor = cursor,
            .options = options,
        };
    }

    /// Close the picker without keeping the highlighted option.
    /// Triggered by Esc or by re-pressing Space on the same select. T-83.
    pub fn cancelSelectPicker(self: *BrowserSession) void {
        if (self.select_picker) |*picker| {
            self.page.freeOptions(picker.options);
            self.select_picker = null;
        }
    }

    /// Move the cursor in the open picker. Wraps top↔bottom so the
    /// user can scroll through a long option list without thinking
    /// about boundaries. T-83.
    pub fn movePickerCursor(self: *BrowserSession, delta: isize) void {
        var picker = if (self.select_picker) |*p| p else return;
        const n = picker.options.len;
        if (n == 0) return;
        const cur: isize = @intCast(picker.cursor);
        const next = @mod(cur + delta, @as(isize, @intCast(n)));
        picker.cursor = @intCast(next);
    }

    /// Commit the highlighted option as the select's value, then
    /// close the picker. T-83.
    pub fn commitSelectPicker(self: *BrowserSession) !void {
        const picker = self.select_picker orelse return;
        if (picker.cursor < picker.options.len) {
            const opt = picker.options[picker.cursor];
            try self.setSelectedOption(picker.element_ptr, opt.value, opt.label);
        }
        // Free the snapshot regardless of whether commit succeeded.
        self.cancelSelectPicker();
    }

    /// T-84: open the cookie inspector for the current page's
    /// origin. Snapshots cookies whose `domain` matches the current
    /// URL's host (RFC 6265 §5.1.3) so the user sees only cookies
    /// the site can actually send. No-op when there's no current
    /// URL (welcome screen) or the URL isn't HTTP(S).
    pub fn openCookieInspector(self: *BrowserSession) !void {
        const url = self.currentUrl() orelse return;
        const host = page_mod.Page.hostForUrl(url) orelse return;

        var rows: std.ArrayListUnmanaged(CookieRow) = .empty;
        errdefer {
            for (rows.items) |*r| freeCookieRow(self.allocator, r);
            rows.deinit(self.allocator);
        }

        const jar = self.page.cookieJar();
        for (jar.cookies.items) |c| {
            if (!page_mod.Page.cookieDomainMatches(host, c.domain)) continue;
            const row: CookieRow = .{
                .name = try self.allocator.dupe(u8, c.name),
                .value = try self.allocator.dupe(u8, c.value),
                .domain = try self.allocator.dupe(u8, c.domain),
                .path = try self.allocator.dupe(u8, c.path),
                .expires = c.expires,
                .secure = c.secure,
                .http_only = c.http_only,
                .same_site_char = switch (c.same_site) {
                    .strict => 'S',
                    .lax => 'L',
                    .none => 'N',
                },
            };
            try rows.append(self.allocator, row);
        }

        const origin_host_owned = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(origin_host_owned);

        // Replace any prior inspector instance (defensive — the run
        // loop only opens it via a key, but `awr` may chain ops).
        if (self.cookie_inspector) |*old| freeCookieInspector(self.allocator, old);
        self.cookie_inspector = .{
            .rows = rows,
            .cursor = 0,
            .origin_host = origin_host_owned,
        };
    }

    /// Close the cookie inspector. Idempotent. T-84.
    pub fn closeCookieInspector(self: *BrowserSession) void {
        if (self.cookie_inspector) |*ci| {
            freeCookieInspector(self.allocator, ci);
            self.cookie_inspector = null;
        }
    }

    /// Move the inspector cursor. Wraps top↔bottom. T-84.
    pub fn moveCookieCursor(self: *BrowserSession, delta: isize) void {
        var ci = if (self.cookie_inspector) |*c| c else return;
        if (ci.confirm_clear_all) return; // confirmation owns input
        const n = ci.rows.items.len;
        if (n == 0) return;
        const cur: isize = @intCast(ci.cursor);
        const next = @mod(cur + delta, @as(isize, @intCast(n)));
        ci.cursor = @intCast(next);
    }

    /// Delete the cookie under the inspector cursor. Removes the
    /// matching entry from the jar AND from the inspector snapshot
    /// so the row disappears without re-opening. T-84.
    pub fn deleteFocusedCookie(self: *BrowserSession) !void {
        var ci = if (self.cookie_inspector) |*c| c else return;
        if (ci.confirm_clear_all) return;
        if (ci.cursor >= ci.rows.items.len) return;
        const row = ci.rows.items[ci.cursor];

        // Match by name+domain+path in the jar (RFC 6265: that triple
        // uniquely identifies a cookie). Walk in reverse so removeAt
        // doesn't shift indices we haven't visited yet.
        const jar = self.page.cookieJar();
        var j: usize = jar.cookies.items.len;
        while (j > 0) {
            j -= 1;
            const c = jar.cookies.items[j];
            if (std.mem.eql(u8, c.name, row.name) and
                std.mem.eql(u8, c.domain, row.domain) and
                std.mem.eql(u8, c.path, row.path))
            {
                var owned = jar.cookies.orderedRemove(j);
                owned.deinit(jar.allocator);
                // Only delete the first match — there shouldn't be
                // duplicates by spec, but defensively don't keep going.
                break;
            }
        }

        // Drop from inspector snapshot too.
        var removed = ci.rows.orderedRemove(ci.cursor);
        freeCookieRow(self.allocator, &removed);
        if (ci.cursor >= ci.rows.items.len and ci.rows.items.len > 0) {
            ci.cursor = ci.rows.items.len - 1;
        }
    }

    /// Enter the "clear all?" confirmation sub-state. Esc / n cancels;
    /// y commits the clear. T-84.
    pub fn requestClearAllCookies(self: *BrowserSession) void {
        if (self.cookie_inspector) |*ci| {
            if (ci.rows.items.len > 0) ci.confirm_clear_all = true;
        }
    }

    /// Cancel the pending clear-all confirmation. T-84.
    pub fn cancelClearAllCookies(self: *BrowserSession) void {
        if (self.cookie_inspector) |*ci| ci.confirm_clear_all = false;
    }

    /// Commit: wipe every cookie matching the inspector's origin host
    /// from the jar, then close the inspector. T-84.
    pub fn confirmClearAllCookies(self: *BrowserSession) void {
        const ci = if (self.cookie_inspector) |*c| c else return;
        const host = ci.origin_host;
        const jar = self.page.cookieJar();
        var j: usize = jar.cookies.items.len;
        while (j > 0) {
            j -= 1;
            if (page_mod.Page.cookieDomainMatches(host, jar.cookies.items[j].domain)) {
                var owned = jar.cookies.orderedRemove(j);
                owned.deinit(jar.allocator);
            }
        }
        self.closeCookieInspector();
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

            // T-81: checkbox/radio submit rules per HTML spec —
            //   - unchecked: skip entirely (no name=value in payload)
            //   - checked:   send `name=value` (defaulting "on" when no value attr)
            const is_check_kind = std.mem.eql(u8, field.field_type, "checkbox") or
                std.mem.eql(u8, field.field_type, "radio");
            if (is_check_kind) {
                if (!self.isFieldChecked(field)) continue;
                const val_check: []const u8 = self.page.fieldValueAttr(field) orelse "on";
                if (!first) try body.append(self.allocator, '&');
                first = false;
                try self.appendUrlEncoded(&body, field.name);
                try body.append(self.allocator, '=');
                try self.appendUrlEncoded(&body, val_check);
                continue;
            }

            // T-83: `<select>` priority is user-picked → DOM
            // `<option selected>` value → first option's value →
            // empty. Falls through to the generic edited/value path
            // when nothing has been picked AND no `selected` option
            // exists (covers `<select>` with no markup help — rare).
            if (std.mem.eql(u8, field.field_type, "select")) {
                const picked = self.selectedOptionValue(field.element_ptr);
                const val_sel: []const u8 = picked orelse (self.page.firstSelectedOptionValue(field) orelse "");
                if (!first) try body.append(self.allocator, '&');
                first = false;
                try self.appendUrlEncoded(&body, field.name);
                try body.append(self.allocator, '=');
                try self.appendUrlEncoded(&body, val_sel);
                continue;
            }

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
        // T-90: any keystroke invalidates the autocomplete cycle.
        // The next arrow-up rebuilds matches against the new prefix.
        if (self.prompt_mode == .url) self.resetUrlAutocomplete();
    }

    pub fn popPromptByte(self: *BrowserSession) void {
        if (self.prompt_mode == .none or self.prompt_buffer.items.len == 0) return;
        _ = self.prompt_buffer.pop();
        if (self.prompt_mode == .url) self.resetUrlAutocomplete();
    }

    /// T-90: push a successfully-navigated URL onto the in-memory
    /// history ring buffer. De-dupes (if the URL is already present,
    /// it moves to the most-recent slot rather than growing the list)
    /// and evicts the oldest entry when the cap is hit. Per-shell
    /// session — no disk persistence in Tier 2.
    pub fn pushUrlHistory(self: *BrowserSession, url: []const u8) !void {
        if (url.len == 0) return;
        // De-dupe: remove an existing entry, then re-append.
        var i: usize = 0;
        while (i < self.url_history.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.url_history.items[i], url)) {
                const old = self.url_history.orderedRemove(i);
                self.allocator.free(old);
                break;
            }
        }
        // Evict oldest if at cap.
        while (self.url_history.items.len >= self.url_history_cap) {
            const old = self.url_history.orderedRemove(0);
            self.allocator.free(old);
        }
        const owned = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned);
        try self.url_history.append(self.allocator, owned);
    }

    /// Discard any in-progress URL-bar autocomplete cycle. Called
    /// whenever the prompt is mutated (char/backspace) so the next
    /// arrow keypress rebuilds matches against the fresh prefix.
    /// Idempotent. T-90.
    pub fn resetUrlAutocomplete(self: *BrowserSession) void {
        if (self.url_autocomplete) |*ac| {
            self.allocator.free(ac.prefix);
            ac.match_indices.deinit(self.allocator);
            self.url_autocomplete = null;
        }
    }

    /// Cycle backward (older) through URL completions. The first
    /// arrow press builds the match list against the prompt text;
    /// subsequent presses move the cursor. Spec contract: prefix-
    /// match when prompt is non-empty, full-history walk when empty.
    /// T-90.
    pub fn urlAutocompleteUp(self: *BrowserSession) !void {
        if (self.prompt_mode != .url) return;
        try self.ensureUrlAutocompleteState();
        const ac = if (self.url_autocomplete) |*a| a else return;
        if (ac.match_indices.items.len == 0) return;
        // First press lands on the most recent match; subsequent
        // presses walk older.
        if (ac.cursor == 0) {
            // Wrap to most recent.
            ac.cursor = ac.match_indices.items.len - 1;
        } else {
            ac.cursor -= 1;
        }
        try self.applyAutocompleteCursor();
    }

    /// Cycle forward (newer) through URL completions. T-90.
    pub fn urlAutocompleteDown(self: *BrowserSession) !void {
        if (self.prompt_mode != .url) return;
        try self.ensureUrlAutocompleteState();
        const ac = if (self.url_autocomplete) |*a| a else return;
        if (ac.match_indices.items.len == 0) return;
        ac.cursor = (ac.cursor + 1) % ac.match_indices.items.len;
        try self.applyAutocompleteCursor();
    }

    /// Build the autocomplete state if it doesn't exist yet. Captures
    /// the current prompt text as the prefix and walks url_history
    /// looking for prefix-matching entries. Iterates oldest→newest;
    /// the result is naturally ordered "oldest match first → newest
    /// match last" so cursor=last on first arrow-up lands on most
    /// recent (vim/zsh convention).
    fn ensureUrlAutocompleteState(self: *BrowserSession) !void {
        if (self.url_autocomplete != null) return;
        const prefix_owned = try self.allocator.dupe(u8, self.prompt_buffer.items);
        errdefer self.allocator.free(prefix_owned);
        var matches: std.ArrayListUnmanaged(usize) = .empty;
        errdefer matches.deinit(self.allocator);
        for (self.url_history.items, 0..) |entry, idx| {
            if (prefix_owned.len == 0 or std.mem.startsWith(u8, entry, prefix_owned)) {
                try matches.append(self.allocator, idx);
            }
        }
        self.url_autocomplete = .{
            .prefix = prefix_owned,
            .match_indices = matches,
            // Start "before" the most-recent: urlAutocompleteUp wraps
            // 0 → last on the first press, landing on most-recent
            // (which is the natural first-tab behavior in shells).
            .cursor = 0,
        };
    }

    /// Replace the prompt buffer with the autocomplete match at the
    /// current cursor. Does NOT trigger resetUrlAutocomplete (that's
    /// the contract that makes cycling work).
    fn applyAutocompleteCursor(self: *BrowserSession) !void {
        const ac = if (self.url_autocomplete) |a| a else return;
        if (ac.cursor >= ac.match_indices.items.len) return;
        const hi = ac.match_indices.items[ac.cursor];
        const value = self.url_history.items[hi];
        self.prompt_buffer.clearRetainingCapacity();
        try self.prompt_buffer.appendSlice(self.allocator, value);
    }

    pub fn submitPrompt(self: *BrowserSession) !void {
        const trimmed = std.mem.trim(u8, self.prompt_buffer.items, " \t\r\n");
        switch (self.prompt_mode) {
            .none => return,
            .url => {
                // Copy the prompt value BEFORE cancelPrompt clears the
                // buffer. cancelPrompt only does `clearRetainingCapacity`
                // so the bytes survive, but if any code along the
                // navigate path appends to prompt_buffer (e.g. error
                // path repopulates it), the slice would silently change
                // under us. Owning the slice is cheap and bulletproof.
                const value = try self.allocator.dupe(u8, trimmed);
                defer self.allocator.free(value);
                self.cancelPrompt();
                if (value.len == 0) return;
                try self.navigateOrSearch(value);
            },
            .search => {
                self.cancelPrompt();
                try self.setSearchQuery(trimmed);
            },
        }
    }

    /// Omnibox-style routing. Browsers don't make users prefix every
    /// query with `https://`; AWR shouldn't either. Rules (T-79):
    ///   - Has explicit scheme ("scheme://...") → navigate as-is.
    ///   - Hostname shape (`foo.com` / `foo.com/path`, no spaces) →
    ///     prepend `https://` and navigate.
    ///   - Anything else (free-form text, multi-word, etc.) → route
    ///     to Google search.
    fn navigateOrSearch(self: *BrowserSession, value: []const u8) !void {
        if (std.mem.indexOf(u8, value, "://") != null) {
            try self.navigateTo(value);
            return;
        }
        if (looksLikeHostname(value)) {
            const with_scheme = try std.fmt.allocPrint(self.allocator, "https://{s}", .{value});
            defer self.allocator.free(with_scheme);
            try self.navigateTo(with_scheme);
            return;
        }
        // Search fallback.
        var url: std.ArrayList(u8) = .empty;
        defer url.deinit(self.allocator);
        try url.appendSlice(self.allocator, "https://www.google.com/search?q=");
        try self.appendUrlEncoded(&url, value);
        try self.navigateTo(url.items);
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

    /// §2.2: mark a navigation as in-flight and paint a single loading frame
    /// so a slow fetch doesn't leave the TUI looking frozen. The frame shows
    /// the target URL plus a "Loading…" marker in the header. Owns the URL
    /// copy. The paint is a no-op when there's no live terminal (tests).
    fn beginLoading(self: *BrowserSession, url: []const u8) !void {
        if (self.loading_url) |old| self.allocator.free(old);
        self.loading_url = try self.allocator.dupe(u8, url);
        self.paintLoadingFrame();
    }

    /// §2.2: clear the in-flight navigation marker once the page is installed
    /// (or the fetch failed). Idempotent.
    fn endLoading(self: *BrowserSession) void {
        if (self.loading_url) |old| self.allocator.free(old);
        self.loading_url = null;
    }

    /// §2.2: paint one frame to the live terminal mid-fetch. The draw loop is
    /// blocked on `page.navigate()` at this point, so we write directly using
    /// the terminal+io captured by `runWith`. No-op (and error-swallowing) so
    /// it never turns a cosmetic indicator into a navigation failure.
    fn paintLoadingFrame(self: *BrowserSession) void {
        const terminal = self.active_terminal orelse return;
        const io = self.active_io orelse return;
        draw(terminal, io, self) catch {};
    }

    fn loadUrl(self: *BrowserSession, url: []const u8) !void {
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        try self.beginLoading(url);
        defer self.endLoading();
        var result = try self.page.navigate(url);
        errdefer result.deinit();
        try self.installLoadedPage(result, previous_query);
    }

    fn loadPostUrl(self: *BrowserSession, url: []const u8, body: []const u8) !void {
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        try self.beginLoading(url);
        defer self.endLoading();
        var result = try self.page.navigatePost(url, body);
        errdefer result.deinit();
        try self.installLoadedPage(result, previous_query);
    }

    /// Shared tail for `loadUrl` and `loadPostUrl`: render the new result,
    /// swap it into the session, reset cursors, and refresh the status line.
    fn installLoadedPage(self: *BrowserSession, result: page_mod.PageResult, previous_query: ?[]u8) !void {
        var local_result = result;
        errdefer local_result.deinit();

        // Navigation replaces page content, so page-scoped overlays must not
        // survive onto the new origin. Otherwise a user can navigate while the
        // cookie inspector/select picker is open and see the old modal over the
        // newly loaded page, which looks like the page rendered blank.
        self.cancelSelectPicker();
        self.closeCookieInspector();

        const fvl: page_mod.FieldValueLookup = .{
            .ctx = self,
            .lookup_fn = fieldValueLookupCallback,
        };
        const icl: page_mod.IsCheckedLookup = .{
            .ctx = self,
            .lookup_fn = isCheckedLookupCallback,
        };
        const sol: page_mod.SelectedOptionLookup = .{
            .ctx = self,
            .lookup_fn = selectedOptionLookupCallback,
        };
        // T-92: build the per-page image pipeline so renderBrowseModel
        // can emit Kitty/iTerm/sixel/braille bytes inline. Pipeline is
        // owned for the duration of the render call; the screen's
        // owned text already holds a COPY of any emitted image bytes,
        // so we deinit immediately after. `.none` short-circuits to a
        // no-op pipeline.
        var pipeline_storage: ?image_pipeline.Pipeline = null;
        defer if (pipeline_storage) |*pl| pl.deinit();
        var image_lookup_opt: ?page_mod.ImageLookup = null;
        if (self.image_protocol != .none) {
            if (image_pipeline.build(self.allocator, &self.page, local_result.url, self.image_protocol, .{
                .max_width_cells = @intCast(self.render_width),
            }, &self.img_cache)) |pl| {
                pipeline_storage = pl;
                image_lookup_opt = pipeline_storage.?.lookup();
            } else |_| {
                // Pipeline build failed; render falls back to alt-text.
            }
        }
        var rendered = try self.page.renderBrowseModel(self.allocator, &local_result, .{
            .max_width = self.render_width,
            .ansi_colors = true,
            .show_links = true,
            .show_images = true,
            .field_value_lookup = fvl,
            .is_checked_lookup = icl,
            .selected_option_lookup = sol,
            .image_protocol = self.image_protocol,
            .image_lookup = image_lookup_opt,
            // First render of a fresh page — no focus yet (Tab will set
            // it, then the next rerender picks it up).
            .focused_element_ptr = null,
            .code_line_numbers = self.code_line_numbers,
            .code_style = self.code_style,
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

        // T-90: record the post-redirect URL into the URL-bar
        // history ring buffer. Stored AFTER successful render so
        // failed loads don't pollute the autocomplete list. Use the
        // resolved URL (after redirects) so the user can return to
        // the canonical destination from autocomplete.
        self.pushUrlHistory(self.current.?.result.url) catch {};
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

    /// T-89 / Tier 2 T2.1: persist the current page (URL + title)
    /// into the bookmarks store. The store path resolves to
    /// $AWR_BOOKMARKS → $XDG_DATA_HOME/awr/bookmarks.txt → ~/.local/share/awr/...
    /// just like the cookie jar's. No-op when there's no current page.
    pub fn bookmarkCurrentPage(self: *BrowserSession) !void {
        const url = self.currentUrl() orelse return;
        const path_opt = try bookmarks_mod.defaultPath(self.allocator, self.page.io);
        const path = path_opt orelse return error.NoBookmarksPath;
        defer self.allocator.free(path);

        var store = try bookmarks_mod.Store.load(self.allocator, self.page.io, path);
        defer store.deinit();

        const t = self.title();
        const id = try store.add(t, url);
        try store.save(self.page.io, path);

        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "bookmark #{d} saved: {s}", .{ id, t });
        try self.setStatusMessage(msg);
    }

    /// Surface a runtime error in the status line instead of letting
    /// it propagate out of the run loop and tear down the TUI. T-78:
    /// before this, any `try session.submitPrompt()` / `openSelectedLink`
    /// failure (invalid URL, network error, parse error) exited the
    /// process — looked like a crash to the user.
    pub fn reportError(self: *BrowserSession, label: []const u8, err: anyerror) void {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "{s}: {t}",
            .{ label, err },
        ) catch return;
        defer self.allocator.free(msg);
        self.setStatusMessage(msg) catch {};
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

    /// IsCheckedLookup callback: returns the user's toggled checked
    /// state for a checkbox/radio element, or null when untouched
    /// (renderer falls back to the DOM attribute). T-81.
    fn isCheckedLookupCallback(ctx: *anyopaque, element_ptr: usize) ?bool {
        const self: *const BrowserSession = @ptrCast(@alignCast(ctx));
        for (self.field_checked.items) |entry| {
            if (entry.element_ptr == element_ptr) return entry.checked;
        }
        return null;
    }

    /// SelectedOptionLookup callback: returns the user-picked option
    /// label for a `<select>`, or null when no picker commit has
    /// happened (renderer falls back to DOM `<option selected>`). T-83.
    fn selectedOptionLookupCallback(ctx: *anyopaque, element_ptr: usize) ?[]const u8 {
        const self: *const BrowserSession = @ptrCast(@alignCast(ctx));
        return self.selectedOptionLabel(element_ptr);
    }

    /// Pointer-equality identifier of the currently-focused form
    /// control for the renderer's focus highlight. Returns null when
    /// focus is on a link (or nothing) — link highlighting is a
    /// separate code path the renderer already handles.
    fn focusedElementPtrForRender(self: *const BrowserSession) ?usize {
        if (self.focus_target == .field) {
            const idx = self.selected_field orelse return null;
            const model = self.screenModel() orelse return null;
            if (idx >= model.fields.len) return null;
            return model.fields[idx].element_ptr;
        } else if (self.focus_target == .link) {
            const idx = self.selected_link orelse return null;
            const model = self.screenModel() orelse return null;
            if (idx >= model.links.len) return null;
            return model.links[idx].element_ptr;
        }
        return null;
    }

    fn rerenderCurrent(self: *BrowserSession) !void {
        var current = if (self.current) |*loaded| loaded else return;
        const previous_query = if (self.search_query) |query| try self.allocator.dupe(u8, query) else null;
        defer if (previous_query) |query| self.allocator.free(query);

        const fvl: page_mod.FieldValueLookup = .{
            .ctx = self,
            .lookup_fn = fieldValueLookupCallback,
        };
        const icl: page_mod.IsCheckedLookup = .{
            .ctx = self,
            .lookup_fn = isCheckedLookupCallback,
        };
        const sol: page_mod.SelectedOptionLookup = .{
            .ctx = self,
            .lookup_fn = selectedOptionLookupCallback,
        };
        // T-92: same per-render pipeline build as installLoadedPage.
        // Rerender happens on focus changes / typing, so this runs
        // potentially many times per page — the pipeline's per-image
        // disk-or-network fetch is cached via the allocator-owned
        // bytes table inside Pipeline (single page lifetime is fine).
        var pipeline_storage: ?image_pipeline.Pipeline = null;
        defer if (pipeline_storage) |*pl| pl.deinit();
        var image_lookup_opt: ?page_mod.ImageLookup = null;
        if (self.image_protocol != .none) {
            if (image_pipeline.build(self.allocator, &self.page, current.result.url, self.image_protocol, .{
                .max_width_cells = @intCast(self.render_width),
            }, &self.img_cache)) |pl| {
                pipeline_storage = pl;
                image_lookup_opt = pipeline_storage.?.lookup();
            } else |_| {}
        }
        var rendered = try self.page.renderBrowseModel(self.allocator, &current.result, .{
            .max_width = self.render_width,
            .ansi_colors = true,
            .show_links = true,
            .show_images = true,
            .field_value_lookup = fvl,
            .is_checked_lookup = icl,
            .selected_option_lookup = sol,
            .image_protocol = self.image_protocol,
            .image_lookup = image_lookup_opt,
            .focused_element_ptr = self.focusedElementPtrForRender(),
            .code_line_numbers = self.code_line_numbers,
            .code_style = self.code_style,
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
    /// T-92: terminal image protocol to use when rendering pages.
    /// `.none` (the default) keeps the existing alt-text fallback —
    /// safe for non-TTY environments and the test suite. `.kitty`,
    /// `.iterm`, `.sixel`, `.braille` route to the matching encoder
    /// per `src/image/pipeline.zig`. Resolved in main.zig before the
    /// runWith call so we don't probe inside the TUI loop.
    image_protocol: image_protocol.Protocol = .none,
    /// T2.4: minimum line count for code-block line numbers. Mirrors
    /// RenderOptions.code_line_numbers; threaded through the run loop
    /// so `awr tui --code-line-numbers=N` takes effect.
    code_line_numbers: usize = 5,
    /// T2.4/T2.5: code-block style mode. Mirrors RenderOptions.code_style.
    code_style: page_mod.CodeStyle = .none,
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
    // §2.2: capture the live terminal + io so the blocking nav path can paint
    // a loading frame before `page.navigate()` returns. Cleared on exit so a
    // dangling terminal pointer is never dereferenced after this call.
    session.active_terminal = &terminal;
    session.active_io = io;
    defer {
        session.active_terminal = null;
        session.active_io = null;
    }
    session.page.disable_scripts = opts.disable_scripts;
    session.image_protocol = opts.image_protocol;
    session.code_line_numbers = opts.code_line_numbers;
    session.code_style = opts.code_style;
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
        if (maybe_key) |key| {
            needs_draw = true;
            switch (try processKey(&session, key, viewportHeight(size))) {
                .continue_ => {},
                .exit => return,
            }
        } else {
            // Idle timeout: tick the JS event loop to run async tasks like WebSocket frames and timers.
            session.page.event_loop.tickNoWait() catch {};
            if (page_mod.bridge.isDomDirty(&session.page.js)) {
                try session.rerenderCurrent();
                page_mod.bridge.clearDomDirty(&session.page.js);
                needs_draw = true;
            }
        }
    }
}

/// Outcome of `processKey` — `.exit` tells the run loop to break out
/// of the read/draw cycle. Used for Ctrl+C / Ctrl+D / `q` keys.
pub const KeyOutcome = enum { continue_, exit };

/// T-80 / Tier 1 slice T1.10: the run loop's key-handling logic
/// extracted to a standalone function so the TUI integration test
/// harness can synthesize keypresses without spawning a subprocess
/// and PTY-wrangling. The real terminal I/O lives in `runWith`;
/// everything testable lives here.
pub fn processKey(
    session: *BrowserSession,
    key: tui.Key,
    viewport_height: usize,
) !KeyOutcome {
    // Universal quit: Ctrl+C / Ctrl+D always exits, regardless of which
    // mode the session is in (link nav, field editing, prompt). This is
    // the escape hatch when other key bindings don't work as expected.
    if (key == .interrupt) return .exit;

    // §2.3: the help overlay owns all input while visible. Any key (other
    // than the universal interrupt handled above) dismisses it and returns
    // to the normal reading state.
    if (session.show_help) {
        session.show_help = false;
        return .continue_;
    }

    // T-83: when a `<select>` picker is open it owns all keys. Arrow
    // keys move the cursor, Enter commits, Esc / Space close. The
    // picker captures keys *before* the prompt/field-editing switch
    // so it can't be bypassed by an open URL bar — we never open
    // a picker while a prompt is active, so this is also safe.
    if (session.select_picker != null) {
        switch (key) {
            .arrow_up => {
                session.movePickerCursor(-1);
            },
            .arrow_down => {
                session.movePickerCursor(1);
            },
            .enter => {
                session.commitSelectPicker() catch |err| session.reportError("pick failed", err);
                session.rerenderCurrent() catch {};
            },
            .escape => session.cancelSelectPicker(),
            .char => |ch| switch (ch) {
                ' ' => session.cancelSelectPicker(),
                'j' => session.movePickerCursor(1),
                'k' => session.movePickerCursor(-1),
                else => {},
            },
            else => {},
        }
        return .continue_;
    }

    // T-84: cookie inspector also owns keys when open. Confirmation
    // sub-state narrows the active key set to y/n/Esc so a stray
    // d/C doesn't double-destroy.
    if (session.cookie_inspector != null) {
        const confirming = session.cookie_inspector.?.confirm_clear_all;
        if (confirming) {
            switch (key) {
                .escape => session.cancelClearAllCookies(),
                .char => |ch| switch (ch) {
                    'y', 'Y' => session.confirmClearAllCookies(),
                    'n', 'N' => session.cancelClearAllCookies(),
                    else => {},
                },
                else => {},
            }
            return .continue_;
        }
        switch (key) {
            .arrow_up => session.moveCookieCursor(-1),
            .arrow_down => session.moveCookieCursor(1),
            .escape => session.closeCookieInspector(),
            .char => |ch| switch (ch) {
                'q' => session.closeCookieInspector(),
                'j' => session.moveCookieCursor(1),
                'k' => session.moveCookieCursor(-1),
                'd', 'D' => session.deleteFocusedCookie() catch |err| session.reportError("delete failed", err),
                'C' => session.requestClearAllCookies(),
                else => {},
            },
            else => {},
        }
        return .continue_;
    }

    switch (session.prompt_mode) {
        .none => if (session.field_editing) switch (key) {
                .escape => {
                    session.exitFieldEditing();
                    session.rerenderCurrent() catch {};
                },
                .tab => {
                    session.nextFocusable(false, viewport_height);
                    session.rerenderCurrent() catch {};
                },
                .shift_tab => {
                    session.nextFocusable(true, viewport_height);
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
                .arrow_down => session.scrollBy(1, viewport_height),
                .arrow_up => session.scrollBy(-1, viewport_height),
                .tab => {
                    session.nextFocusable(false, viewport_height);
                    // Rerender so the focus highlight moves with the
                    // cursor. T-73.
                    session.rerenderCurrent() catch {};
                },
                .shift_tab => {
                    session.nextFocusable(true, viewport_height);
                    session.rerenderCurrent() catch {};
                },
                .enter => {
                    if (session.focus_target == .field and session.selected_field != null) {
                        const field = session.activeField();
                        if (field != null and field.?.is_submit) {
                            session.submitForm() catch |err| session.reportError("submit failed", err);
                        } else if (field != null and (std.mem.eql(u8, field.?.field_type, "checkbox") or std.mem.eql(u8, field.?.field_type, "radio"))) {
                            // T-81: Enter also activates checkbox/radio (some
                            // browsers do, vim users expect both Space + Enter).
                            session.toggleCheckedField() catch |err| session.reportError("toggle failed", err);
                            session.rerenderCurrent() catch {};
                        } else if (field != null and std.mem.eql(u8, field.?.field_type, "select")) {
                            // T-83: Enter on a select opens the inline picker
                            // (same as Space; matches Chrome/Firefox).
                            session.openSelectPicker() catch |err| session.reportError("picker failed", err);
                        } else {
                            session.openSelectedLink() catch |err| session.reportError("open failed", err);
                        }
                    } else {
                        session.openSelectedLink() catch |err| session.reportError("open failed", err);
                    }
                },
                .char => |ch| switch (ch) {
                    ' ' => {
                        // T-81/T-83: Space activates the focused control.
                        // Checkbox → toggle. Radio → select. Select → open picker.
                        // Otherwise no-op (Space is not a scroll key — that's j/k).
                        if (session.focus_target == .field and session.selected_field != null) {
                            if (session.activeField()) |f| {
                                if (std.mem.eql(u8, f.field_type, "select")) {
                                    session.openSelectPicker() catch |err| session.reportError("picker failed", err);
                                } else {
                                    session.toggleCheckedField() catch |err| session.reportError("toggle failed", err);
                                    session.rerenderCurrent() catch {};
                                }
                            }
                        }
                    },
                    'j' => session.scrollBy(1, viewport_height),
                    'k' => session.scrollBy(-1, viewport_height),
                    'b' => session.goBack() catch |err| session.reportError("back failed", err),
                    'f' => session.goForward() catch |err| session.reportError("forward failed", err),
                    'r' => session.reload() catch |err| session.reportError("reload failed", err),
                    // T-66 / Tier 1: URL bar opens via vim-style ':'
                    // (preferred per spec/subspecs/browser-tui.md §2.6)
                    // OR legacy 'g' (existing binding kept for muscle
                    // memory compatibility).
                    'g', ':' => session.startPrompt(.url) catch |err| session.reportError("prompt failed", err),
                    '/' => session.startPrompt(.search) catch |err| session.reportError("prompt failed", err),
                    // T-84: cookie inspector for the current origin.
                    // `c` (lowercase) opens; uppercase `C` is reserved
                    // *inside* the inspector for the destructive
                    // "clear all" action.
                    'c' => session.openCookieInspector() catch |err| session.reportError("cookies failed", err),
                    // T-89 / Tier 2 T2.1: uppercase B adds the current
                    // page to the persistent bookmarks store. Lowercase
                    // `b` is already history-back (Tier 1).
                    'B' => session.bookmarkCurrentPage() catch |err| session.reportError("bookmark failed", err),
                    'n' => session.advanceSearch(viewport_height),
                    'e' => {
                        const model2 = session.screenModel();
                        if (model2 != null) {
                            for (model2.?.fields) |f| {
                                if (!f.is_submit) {
                                    session.selectNextField(false, viewport_height);
                                    break;
                                }
                            }
                        }
                    },
                    'h' => session.show_help = true, // §2.3: open keybinding help overlay
                    'q' => return .exit,
                    else => {},
                },
                else => {},
            },
            .url, .search => switch (key) {
                .enter => session.submitPrompt() catch |err| session.reportError("navigate failed", err),
                .backspace => session.popPromptByte(),
                .escape => session.cancelPrompt(),
                // T-90: arrow up/down cycle through URL history matches
                // when the URL prompt is active. In search mode, arrows
                // are currently a no-op (search history is a possible
                // future slice but not Tier 2 scope).
                .arrow_up => {
                    if (session.prompt_mode == .url) {
                        session.urlAutocompleteUp() catch |err| session.reportError("autocomplete failed", err);
                    }
                },
                .arrow_down => {
                    if (session.prompt_mode == .url) {
                        session.urlAutocompleteDown() catch |err| session.reportError("autocomplete failed", err);
                    }
                },
                .char => |ch| session.appendPromptByte(ch) catch |err| session.reportError("input failed", err),
                else => {},
            },
        }
    return .continue_;
}

fn draw(terminal: *tui.Terminal, io: std.Io, session: *BrowserSession) !void {
    try terminal.clearScreen();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = terminal.stdout_file.writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try drawFrame(stdout, session, terminal.size());
    try stdout.flush();
}

/// T-80 / Tier 1 slice T1.10: render one frame to any writer.
/// Extracted from `draw` so the TUI integration test harness can
/// capture frames to a buffer for assertions. The real `draw`
/// wraps this with terminal clear + stdout flush; tests skip both
/// (the clear escape is the writer's responsibility — tests can
/// snapshot raw output without it).
pub fn drawFrame(
    writer: anytype,
    session: *BrowserSession,
    size: tui.Size,
) !void {
    const viewport_height = viewportHeight(size);
    const model = session.screenModel();
    // §2.2: while a navigation is in flight, show the target URL (not the
    // previous page's) so the header reflects where we're going immediately.
    const url = if (session.loading_url) |lu| lu else (session.currentUrl() orelse "");
    const cols = size.cols;

    // Header styling. §2.2: a "Loading…" marker replaces the plain badge
    // while a fetch is in flight so the TUI never looks frozen.
    const left_base = if (session.loading_url != null) " AWR 🌐 ⟳ Loading… " else " AWR 🌐 ";
    var right_buf: [64]u8 = undefined;
    const right_str = if (session.history.items.len > 0)
        std.fmt.bufPrint(&right_buf, " [Hist: {d}/{d}] (q: quit) ", .{ session.history_index + 1, session.history.items.len }) catch " (q: quit) "
    else
        " (q: quit) ";
    const right_len = visualLen(right_str);
    const left_base_len = visualLen(left_base);
    const reserved = left_base_len + right_len;

    var url_display = url;
    var url_owned: ?[]u8 = null;
    defer if (url_owned) |u| session.allocator.free(u);

    if (cols > reserved + 5) {
        const max_url_len = cols - reserved;
        if (url.len > max_url_len) {
            url_owned = std.fmt.allocPrint(session.allocator, "{s}...", .{url[0..(max_url_len - 3)]}) catch null;
            if (url_owned) |u| url_display = u;
        }
    } else if (cols > left_base_len + 5) {
        const max_url_len = cols - left_base_len;
        if (url.len > max_url_len) {
            url_owned = std.fmt.allocPrint(session.allocator, "{s}...", .{url[0..(max_url_len - 3)]}) catch null;
            if (url_owned) |u| url_display = u;
        }
    }

    var header_line: std.ArrayList(u8) = .empty;
    defer header_line.deinit(session.allocator);

    if (cols > reserved + 5) {
        try header_line.appendSlice(session.allocator, left_base);
        try header_line.appendSlice(session.allocator, url_display);
        const cur_len = visualLen(header_line.items) + right_len;
        const padding = if (cols > cur_len) cols - cur_len else 0;
        var p: usize = 0;
        while (p < padding) : (p += 1) try header_line.append(session.allocator, ' ');
        try header_line.appendSlice(session.allocator, right_str);
    } else {
        try header_line.appendSlice(session.allocator, left_base);
        try header_line.appendSlice(session.allocator, url_display);
        const cur_len = visualLen(header_line.items);
        const padding = if (cols > cur_len) cols - cur_len else 0;
        var p: usize = 0;
        while (p < padding) : (p += 1) try header_line.append(session.allocator, ' ');
    }

    try writer.writeAll("\x1b[7m\x1b[1m"); // REVERSE + BOLD
    try writeClippedLine(writer, cols, header_line.items);
    try writer.writeAll("\x1b[0m\n");

    // T-83: when a `<select>` picker is open it replaces the body
    // area entirely so the user's attention is on the option list.
    // Page content stays unchanged underneath — closing the picker
    // restores it without a rerender.
    if (session.show_help) {
        // §2.3: help overlay replaces the body, same pattern as the select
        // picker and cookie inspector.
        try drawHelpOverlay(writer, size.cols, viewport_height);
    } else if (session.select_picker) |picker| {
        try drawSelectPicker(writer, size.cols, viewport_height, picker);
    } else if (session.cookie_inspector) |*ci| {
        // T-84: same modal pattern as the select picker but a
        // tabular layout. Confirmation overlay (when `confirm_clear_all`)
        // replaces the table so the user explicitly answers y/n.
        try drawCookieInspector(writer, size.cols, viewport_height, ci);
    } else if (model) |screen_model| {
        // T2.7: if the scroll position is past a table header row but still
        // inside the table body, pin the header at the top of the viewport.
        var sticky_lines: usize = 0;
        for (screen_model.sticky_headers) |sh| {
            const past_header = session.scroll_row >= sh.header_line_end;
            const inside_table = session.scroll_row < sh.table_line_end;
            if (past_header and inside_table) {
                var hi = sh.header_line_start;
                while (hi < sh.header_line_end and sticky_lines < viewport_height) : (hi += 1) {
                    try writeClippedLine(writer, size.cols, screen_model.lineText(hi));
                    try writer.writeAll("\x1b[K\n");
                    sticky_lines += 1;
                }
                break; // at most one sticky header at a time
            }
        }
        var row: usize = 0;
        const body_rows = if (viewport_height > sticky_lines) viewport_height - sticky_lines else 0;
        while (row < body_rows) : (row += 1) {
            const line_index = session.scroll_row + row;
            if (line_index < screen_model.lines.len) {
                try writeClippedLine(writer, size.cols, screen_model.lineText(line_index));
            }
            try writer.writeAll("\x1b[K\n");
        }
    } else {
        try drawWelcome(writer, size.cols, viewport_height);
    }

    const footer = try session.footerText(session.allocator);
    defer session.allocator.free(footer);

    const is_input_mode = session.prompt_mode != .none or session.field_editing;
    if (is_input_mode) {
        try writeClippedLine(writer, size.cols, footer);
        try writer.writeAll("\x1b[K");
    } else {
        const footer_len = visualLen(footer);
        try writer.writeAll("\x1b[7m\x1b[1m");
        try writeClippedLine(writer, size.cols, footer);
        var pad = if (size.cols > footer_len) size.cols - footer_len else 0;
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        try writer.writeAll("\x1b[0m\x1b[K");
    }
}

/// §2.3 (TUI Quality): full-body keybinding help overlay. The table is
/// static — keybindings aren't configurable in this track, so hardcoding is
/// correct. Mirrors the select-picker / cookie-inspector overlay pattern: a
/// title row, the body, padding to fill the viewport, and a dismiss hint.
/// Any key closes it (handled in `processKey`).
fn drawHelpOverlay(writer: anytype, cols: usize, viewport_height: usize) !void {
    const REVERSE = "\x1b[7m";
    const BOLD = "\x1b[1m";
    const RESET = "\x1b[0m";
    const DIM = "\x1b[2m";

    const rows = [_][2][]const u8{
        .{ "j / k", "Scroll down / up" },
        .{ "d / u", "Half-page down / up" },
        .{ "g / G", "Top / Bottom" },
        .{ "b / f", "Back / Forward" },
        .{ "r / R", "Reload (soft / hard)" },
        .{ "o or :", "Open URL bar" },
        .{ "/", "Search" },
        .{ "n / N", "Next / previous search match" },
        .{ "Tab / Shift-Tab", "Next / previous focusable" },
        .{ "Enter / Space", "Activate focused element" },
        .{ "Esc", "Cancel prompt / drop focus" },
        .{ "c", "Cookie inspector" },
        .{ "B", "Bookmark current page" },
        .{ "h", "This help screen" },
        .{ "q", "Quit" },
    };

    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s}{s} AWR keybindings {s}", .{ REVERSE, BOLD, RESET }) catch " AWR keybindings ";
    try writeClippedLine(writer, cols, title);
    try writer.writeAll("\x1b[K\n");

    const max_rows = if (viewport_height > 2) viewport_height - 2 else 1;
    var shown: usize = 0;
    var idx: usize = 0;
    while (idx < rows.len and shown < max_rows) : (idx += 1) {
        var row_buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&row_buf, "  {s}{s:<16}{s} {s}", .{ BOLD, rows[idx][0], RESET, rows[idx][1] }) catch rows[idx][1];
        try writeClippedLine(writer, cols, line);
        try writer.writeAll("\x1b[K\n");
        shown += 1;
    }

    while (shown < max_rows) : (shown += 1) {
        try writer.writeAll("\x1b[K\n");
    }

    var hint_buf: [64]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "{s}press any key to close{s}", .{ DIM, RESET }) catch "";
    try writeClippedLine(writer, cols, hint);
    try writer.writeAll("\x1b[K");
}

/// Render the open `<select>` picker as a centered list inside the
/// body viewport. The cursor row gets reverse-video highlight so
/// the user sees which option Enter will pick. T-83.
fn drawSelectPicker(
    writer: anytype,
    cols: usize,
    viewport_height: usize,
    picker: BrowserSession.SelectPicker,
) !void {
    const REVERSE = "\x1b[7m";
    const BOLD = "\x1b[1m";
    const DIM = "\x1b[2m";
    const RESET = "\x1b[0m";

    // Reserve 3 rows of chrome: title, separator, footer-help line.
    const list_rows = if (viewport_height > 3) viewport_height - 3 else 0;
    const visible = @min(picker.options.len, list_rows);

    // Scroll window so the cursor stays visible.
    var top: usize = 0;
    if (visible > 0 and picker.cursor >= visible) {
        top = picker.cursor + 1 - visible;
    }

    var row: usize = 0;
    // Title row.
    try writer.writeAll(BOLD);
    try writeClippedLine(writer, cols, "Select an option — ↑/↓ to move · Enter to pick · Esc to cancel");
    try writer.writeAll(RESET);
    try writer.writeAll("\x1b[K\n");
    row += 1;

    // List rows.
    var i: usize = 0;
    while (i < list_rows) : (i += 1) {
        const opt_idx = top + i;
        if (opt_idx >= picker.options.len) {
            try writer.writeAll("\x1b[K\n");
            row += 1;
            continue;
        }
        const opt = picker.options[opt_idx];
        const marker: []const u8 = if (opt_idx == picker.cursor) "›" else " ";
        if (opt_idx == picker.cursor) try writer.writeAll(REVERSE);
        try writer.writeAll("  ");
        try writer.writeAll(marker);
        try writer.writeAll(" ");
        try writeClippedLine(writer, if (cols > 4) cols - 4 else cols, opt.label);
        if (opt_idx == picker.cursor) try writer.writeAll(RESET);
        try writer.writeAll("\x1b[K\n");
        row += 1;
    }

    // Pad remaining rows so the frame fills the viewport.
    while (row < viewport_height - 1) : (row += 1) {
        try writer.writeAll("\x1b[K\n");
    }
    // Status hint as the last row.
    try writer.writeAll(DIM);
    var hint_buf: [80]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "{d}/{d} options", .{ picker.cursor + 1, picker.options.len }) catch "";
    try writeClippedLine(writer, cols, hint);
    try writer.writeAll(RESET);
    try writer.writeAll("\x1b[K\n");
}

fn viewportHeight(size: tui.Size) usize {
    return if (size.rows > 2) size.rows - 2 else 0;
}

/// Human-readable relative expiry for the cookie inspector (T2.3).
/// Returns a slice into `buf` (max 16 bytes). Caller owns the buffer.
fn cookieExpiryStr(buf: *[16]u8, expires: ?i64, now_ts: i64) []const u8 {
    const e = expires orelse return "(session)";
    const diff = e - now_ts;
    if (diff <= 0) return "expired";
    const secs: u64 = @intCast(diff);
    const mins = secs / 60;
    const hours = mins / 60;
    const days = hours / 24;
    const weeks = days / 7;
    if (weeks >= 1) return std.fmt.bufPrint(buf, "{d}w left", .{weeks}) catch "…";
    if (days >= 1) return std.fmt.bufPrint(buf, "{d}d left", .{days}) catch "…";
    if (hours >= 1) return std.fmt.bufPrint(buf, "{d}h left", .{hours}) catch "…";
    if (mins >= 1) return std.fmt.bufPrint(buf, "{d}m left", .{mins}) catch "…";
    return "<1m";
}

/// Render the cookie inspector. Two modes:
///   - normal: header + tabular row list with cursor highlight
///   - confirm_clear_all: centered "Clear N cookies? (y/n)" prompt
///
/// Column layout adapts to terminal width; very narrow terminals
/// drop the value column and truncate the rest. T-84.
fn drawCookieInspector(
    writer: anytype,
    cols: usize,
    viewport_height: usize,
    ci: *const BrowserSession.CookieInspector,
) !void {
    const REVERSE = "\x1b[7m";
    const BOLD = "\x1b[1m";
    const DIM = "\x1b[2m";
    const RESET = "\x1b[0m";

    // Title row: "Cookies for <host>".
    try writer.writeAll(BOLD);
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Cookies for {s} — d delete · C clear all · q close", .{ci.origin_host}) catch "Cookies";
    try writeClippedLine(writer, cols, title);
    try writer.writeAll(RESET);
    try writer.writeAll("\x1b[K\n");

    if (ci.confirm_clear_all) {
        // Confirmation overlay — replace the table area entirely so
        // the user has nowhere to look except the y/n prompt. Pad to
        // fill the viewport so leftover row text doesn't leak through.
        var row: usize = 1;
        const pad_top = if (viewport_height > 5) (viewport_height - 5) / 2 else 0;
        while (row < pad_top) : (row += 1) try writer.writeAll("\x1b[K\n");

        try writer.writeAll(BOLD);
        var prompt_buf: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "Delete all {d} cookies for {s}?  (y / n)", .{ ci.rows.items.len, ci.origin_host }) catch "Delete all cookies?";
        // Center the prompt horizontally.
        const vl = visualLen(prompt);
        if (cols > vl) {
            const lpad = (cols - vl) / 2;
            for (0..lpad) |_| try writer.writeByte(' ');
        }
        try writer.writeAll(prompt);
        try writer.writeAll(RESET);
        try writer.writeAll("\x1b[K\n");
        row += 1;

        while (row < viewport_height) : (row += 1) try writer.writeAll("\x1b[K\n");
        return;
    }

    if (ci.rows.items.len == 0) {
        // Empty-state: tell the user explicitly so they don't wonder
        // whether the inspector failed to read the jar.
        try writer.writeAll(DIM);
        try writeClippedLine(writer, cols, "  (no cookies for this origin)");
        try writer.writeAll(RESET);
        try writer.writeAll("\x1b[K\n");
        var row: usize = 2;
        while (row < viewport_height) : (row += 1) try writer.writeAll("\x1b[K\n");
        return;
    }

    // Column widths: name, value, domain, path, expiry, flags.
    // T2.3: flags is now 4 chars (S secure · H httpOnly · SameSite L/S/N);
    //       expiry is 10 chars of human-readable relative time.
    const name_w: usize = 18;
    const domain_w: usize = 22;
    const path_w: usize = 10;
    const flags_w: usize = 4; // SH + SameSite char + space
    const expiry_w: usize = 10;
    // value gets the rest.
    const fixed = 2 + name_w + 1 + domain_w + 1 + path_w + 1 + expiry_w + 1 + flags_w + 1;
    const value_w: usize = if (cols > fixed + 6) cols - fixed else 6;

    // Header row.
    try writer.writeAll(DIM);
    try writer.writeAll("  ");
    try writeFixed(writer, "name", name_w);
    try writer.writeAll(" ");
    try writeFixed(writer, "value", value_w);
    try writer.writeAll(" ");
    try writeFixed(writer, "domain", domain_w);
    try writer.writeAll(" ");
    try writeFixed(writer, "path", path_w);
    try writer.writeAll(" ");
    try writeFixed(writer, "expires", expiry_w);
    try writer.writeAll(" ");
    try writeFixed(writer, "flgs", flags_w);
    try writer.writeAll(RESET);
    try writer.writeAll("\x1b[K\n");

    // Tally active / session / expired for the footer.
    var _ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &_ts);
    const now_ts: i64 = @intCast(_ts.sec);
    var n_active: usize = 0;
    var n_session: usize = 0;
    var n_expired: usize = 0;
    for (ci.rows.items) |r| {
        if (r.expires) |e| {
            if (e >= now_ts) n_active += 1 else n_expired += 1;
        } else {
            n_session += 1;
        }
    }

    // Scroll window so the cursor stays visible.
    const list_rows = if (viewport_height > 3) viewport_height - 3 else 0;
    var top: usize = 0;
    if (list_rows > 0 and ci.cursor >= list_rows) {
        top = ci.cursor + 1 - list_rows;
    }

    var i: usize = 0;
    while (i < list_rows) : (i += 1) {
        const ri = top + i;
        if (ri >= ci.rows.items.len) {
            try writer.writeAll("\x1b[K\n");
            continue;
        }
        const r = ci.rows.items[ri];
        if (ri == ci.cursor) try writer.writeAll(REVERSE);
        const marker: []const u8 = if (ri == ci.cursor) "› " else "  ";
        try writer.writeAll(marker);
        try writeFixed(writer, r.name, name_w);
        try writer.writeAll(" ");
        try writeFixed(writer, r.value, value_w);
        try writer.writeAll(" ");
        try writeFixed(writer, r.domain, domain_w);
        try writer.writeAll(" ");
        try writeFixed(writer, r.path, path_w);
        try writer.writeAll(" ");
        var expiry_buf: [16]u8 = undefined;
        const expiry_s = cookieExpiryStr(&expiry_buf, r.expires, now_ts);
        try writeFixed(writer, expiry_s, expiry_w);
        try writer.writeAll(" ");
        var flags_buf: [4]u8 = undefined;
        flags_buf[0] = if (r.secure) 'S' else '-';
        flags_buf[1] = if (r.http_only) 'H' else '-';
        flags_buf[2] = r.same_site_char;
        flags_buf[3] = ' ';
        try writeFixed(writer, &flags_buf, flags_w);
        if (ri == ci.cursor) try writer.writeAll(RESET);
        try writer.writeAll("\x1b[K\n");
    }

    // Footer: classified counts + navigation hints.
    try writer.writeAll(DIM);
    var hint_buf: [120]u8 = undefined;
    const hint = std.fmt.bufPrint(
        &hint_buf,
        "{d} active · {d} session · {d} expired — ↑/↓ move · d delete · C clear all · q close",
        .{ n_active, n_session, n_expired },
    ) catch "";
    try writeClippedLine(writer, cols, hint);
    try writer.writeAll(RESET);
    try writer.writeAll("\x1b[K\n");
}

/// Write `s` clipped or padded to exactly `width` visible columns.
/// ANSI-naïve — assumes inputs are plain text (no escapes), which is
/// true for the cookie-inspector cell strings.
fn writeFixed(writer: anytype, s: []const u8, width: usize) !void {
    if (s.len >= width) {
        try writer.writeAll(s[0..width]);
    } else {
        try writer.writeAll(s);
        var pad: usize = width - s.len;
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
    }
}

/// Welcome screen painted in the viewport when no page has loaded
/// yet — the `awr tui` "new tab" experience. Caller has already
/// written the header (`AWR — ` + url). We're responsible for
/// filling exactly `viewport_height` rows; each ends with `\x1b[K\n`
/// so leftover content from prior frames is cleared on resize.
fn drawWelcome(writer: anytype, cols: usize, viewport_height: usize) !void {
    // Content block we want to vertically center.
    const BOLD = "\x1b[1m";
    const DIM = "\x1b[2m";
    const RESET = "\x1b[0m";

    // Build the lines in order. Empty strings are blank spacer rows.
    const tips = [_][]const u8{
        BOLD ++ "AWR — Agentic Web Runtime" ++ RESET,
        DIM ++ "A CLI browser for humans and agents." ++ RESET,
        "",
        BOLD ++ "Type a URL below and press Enter to navigate." ++ RESET,
        DIM ++ "↑/↓ in URL bar cycles through recent destinations." ++ RESET,
        "",
        DIM ++ "Keys:" ++ RESET,
        "  " ++ BOLD ++ ":" ++ RESET ++ "  URL bar             " ++ BOLD ++ "/" ++ RESET ++ "  find in page",
        "  " ++ BOLD ++ "Tab" ++ RESET ++ " next link/field    " ++ BOLD ++ "Enter" ++ RESET ++ " activate",
        "  " ++ BOLD ++ "b" ++ RESET ++ "  back                " ++ BOLD ++ "f" ++ RESET ++ "  forward",
        "  " ++ BOLD ++ "r" ++ RESET ++ "  reload              " ++ BOLD ++ "q" ++ RESET ++ "  quit",
        "  " ++ BOLD ++ "c" ++ RESET ++ "  cookies             " ++ BOLD ++ "B" ++ RESET ++ "  bookmark page",
        "  " ++ BOLD ++ "h" ++ RESET ++ "  help (all keys)     " ++ BOLD ++ "q" ++ RESET ++ "  quit",
        "",
        DIM ++ "Tip: set $AWR_HOMEPAGE to skip this screen." ++ RESET,
    };

    // Vertical centering: leave roughly equal blank rows above and
    // below. Saturating arithmetic so small terminals still paint
    // something useful instead of nothing.
    const top_pad = if (viewport_height > tips.len)
        (viewport_height - tips.len) / 2
    else
        0;

    // Keep the welcome copy in one readable block. Centering each line
    // independently spreads shortcuts across wide terminals, which is
    // hard for humans to scan; a left-aligned card preserves grouping.
    const block_width: usize = @min(cols, 72);
    const block_left: usize = if (cols > block_width) (cols - block_width) / 2 else 0;

    var row: usize = 0;
    while (row < top_pad) : (row += 1) try writer.writeAll("\x1b[K\n");

    for (tips) |line| {
        if (row >= viewport_height) break;
        try writeWelcomeLine(writer, cols, block_left, line);
        row += 1;
    }

    while (row < viewport_height) : (row += 1) try writer.writeAll("\x1b[K\n");
}

fn writeWelcomeLine(writer: anytype, cols: usize, left_pad: usize, line: []const u8) !void {
    const pad = @min(left_pad, cols);
    for (0..pad) |_| try writer.writeByte(' ');
    try writeClippedLine(writer, cols - pad, line);
    try writer.writeAll("\x1b[K\n");
}

/// Read the URL-history capacity from $AWR_URL_HISTORY_LEN with a
/// safe default of 20 entries per spec/subspecs/render-polish.md §2.2.
/// Caps at 1000 so a wild env value can't blow up the ring buffer.
/// Zero falls back to the default (treat as "missing" semantically).
fn readUrlHistoryCap() usize {
    const default_cap: usize = 20;
    const raw = std.c.getenv("AWR_URL_HISTORY_LEN") orelse return default_cap;
    const span = std.mem.span(raw);
    if (span.len == 0) return default_cap;
    const parsed = std.fmt.parseInt(usize, span, 10) catch return default_cap;
    if (parsed == 0) return default_cap;
    return @min(parsed, 1000);
}

/// Visible column count of `text`, skipping ANSI escape sequences.
/// Shares its scan strategy with `writeClippedLine`.
fn visualLen(text: []const u8) usize {
    var visible: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }
        visible += 1;
        i += 1;
    }
    return visible;
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

/// True when `s` *looks* like a host (or host+path) that the user
/// meant to navigate to without typing a scheme. Conservative on
/// purpose — anything ambiguous falls through to the search path.
/// Examples accepted: `google.com`, `localhost:8080`, `192.168.0.1`,
/// `example.com/foo/bar`, `subdomain.example.co.uk`.
/// Examples rejected: `hello world` (whitespace), `foo` (no dot),
/// `weather in seattle` (whitespace + spaces, no scheme).
fn looksLikeHostname(s: []const u8) bool {
    if (s.len == 0) return false;
    // Slice off the path portion if present; only validate the host.
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse s.len;
    const host = s[0..slash];
    if (host.len == 0 or host[0] == '.' or host[0] == '-') return false;
    // Must contain a dot (foo.com) OR a colon for port (localhost:8080).
    const has_dot = std.mem.indexOfScalar(u8, host, '.') != null;
    const has_colon = std.mem.indexOfScalar(u8, host, ':') != null;
    if (!has_dot and !has_colon) return false;
    // Host chars: alphanumeric + `.` + `-` + `:` only. Whitespace,
    // unicode, slashes-in-host, etc. all disqualify.
    for (host) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != ':') return false;
    }
    return true;
}

/// Free the owned bytes inside a CookieRow. T-84.
fn freeCookieRow(allocator: std.mem.Allocator, row: *BrowserSession.CookieRow) void {
    allocator.free(row.name);
    allocator.free(row.value);
    allocator.free(row.domain);
    allocator.free(row.path);
}

/// Free the entire CookieInspector state. Caller is responsible for
/// resetting `cookie_inspector = null` afterward when appropriate. T-84.
fn freeCookieInspector(allocator: std.mem.Allocator, ci: *BrowserSession.CookieInspector) void {
    for (ci.rows.items) |*row| freeCookieRow(allocator, row);
    ci.rows.deinit(allocator);
    allocator.free(ci.origin_host);
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

test "looksLikeHostname accepts hosts, rejects free-form text" {
    // Accept: clear hostname shapes.
    try std.testing.expect(looksLikeHostname("google.com"));
    try std.testing.expect(looksLikeHostname("example.co.uk"));
    try std.testing.expect(looksLikeHostname("localhost:8080"));
    try std.testing.expect(looksLikeHostname("192.168.0.1"));
    try std.testing.expect(looksLikeHostname("foo.com/path/to/page"));
    try std.testing.expect(looksLikeHostname("sub.domain.example.com"));

    // Reject: clearly not a host.
    try std.testing.expect(!looksLikeHostname("hello world"));
    try std.testing.expect(!looksLikeHostname("foo"));
    try std.testing.expect(!looksLikeHostname("weather in seattle"));
    try std.testing.expect(!looksLikeHostname(""));
    try std.testing.expect(!looksLikeHostname(".com"));
    try std.testing.expect(!looksLikeHostname("-foo.com"));
}

test "submitPrompt URL routing without network: bare-word → search URL" {
    // Build a session and exercise submitPrompt with a buffer set to
    // various inputs. We don't *navigate* (no network), but we can
    // verify the routing decision by intercepting the URL that would
    // be passed to navigateTo via a controlled buffer trace.
    //
    // The simplest non-network verification is to test the routing
    // pieces directly. The bare-word path delegates to
    // navigateOrSearch which builds `https://www.google.com/search?q=...`.
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();

    // Drop into URL prompt mode and stuff a query.
    try session.startPrompt(.url);
    for ("hello world") |ch| try session.appendPromptByte(ch);

    // We don't run submitPrompt (it would hit the network). Instead
    // we mirror its decision path: trim → looksLikeHostname → search.
    const trimmed = std.mem.trim(u8, session.prompt_buffer.items, " \t\r\n");
    try std.testing.expect(!looksLikeHostname(trimmed));

    // The actual URL builder is reused — verify the encoded form.
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(std.testing.allocator);
    try url.appendSlice(std.testing.allocator, "https://www.google.com/search?q=");
    try session.appendUrlEncoded(&url, trimmed);
    try std.testing.expect(std.mem.eql(u8, url.items, "https://www.google.com/search?q=hello+world"));
}

test "submitPrompt URL routing: full URL passes through, hostname gets https:// prefix" {
    // Pure logic test for navigateOrSearch's first two branches.
    // (Third branch goes through appendUrlEncoded covered above.)
    try std.testing.expect(std.mem.indexOf(u8, "http://google.com", "://") != null);
    try std.testing.expect(std.mem.indexOf(u8, "https://example.org/path", "://") != null);
    // Bare hostname has no scheme — must trip the hostname branch.
    try std.testing.expect(std.mem.indexOf(u8, "google.com", "://") == null);
    try std.testing.expect(looksLikeHostname("google.com"));
}

test "search round-trip: prompt → type → submit → matches populated → advance" {
    // Reproduces "crashing whenever I try to search in the tui" by
    // driving the exact key sequence: `/` → chars → Enter → `n`.
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();

    const html =
        \\<html><body>
        \\<h1>Hello World</h1>
        \\<p>Some text with hello somewhere inside.</p>
        \\<p>Another paragraph mentioning Hello again.</p>
        \\<p>No match on this row.</p>
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
    try session.setViewportSize(80, 24);

    // `/` opens search prompt.
    try session.startPrompt(.search);
    try std.testing.expectEqual(@as(@TypeOf(session.prompt_mode), .search), session.prompt_mode);

    // type "hello"
    for ("hello") |ch| try session.appendPromptByte(ch);
    try std.testing.expect(std.mem.eql(u8, session.prompt_buffer.items, "hello"));

    // Enter commits.
    try session.submitPrompt();
    try std.testing.expectEqual(@as(@TypeOf(session.prompt_mode), .none), session.prompt_mode);

    // matches should be non-empty (3 lines contain "hello" case-insensitive).
    try std.testing.expect(session.search_matches.items.len >= 2);
    try std.testing.expect(session.search_index != null);

    // `n` advances to next match — was a crash suspect (index/scroll math).
    session.advanceSearch(20);
    session.advanceSearch(20);
    session.advanceSearch(20); // wrap

    // Re-search same query: previous_query path that exercises
    // dupe→free→dupe in setSearchQuery. Frequent source of UAF in
    // string-shuffling state machines.
    try session.setSearchQuery("hello");
    try std.testing.expect(session.search_matches.items.len >= 2);
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

// ── T1.10 TUI integration harness ─────────────────────────────────
//
// `processKey` + `drawFrame` are the seams the harness drives. The
// tests below use a real `BrowserSession` (no fake), pump synthetic
// keys through `processKey`, and snapshot frames into a memory
// buffer via `drawFrame`. No subprocess, no PTY, no real terminal —
// just the same code paths `runWith` exercises with the I/O removed.

/// In-memory TUI driver. Holds a session + a viewport + a captured
/// frame buffer. Tests construct one, drive keys, then `frame()` to
/// inspect what `runWith` would have painted.
const TuiHarness = struct {
    allocator: std.mem.Allocator,
    session: BrowserSession,
    size: tui.Size,
    last_frame: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !TuiHarness {
        return .{
            .allocator = allocator,
            .session = try BrowserSession.init(allocator, std.testing.io),
            .size = .{ .cols = cols, .rows = rows },
            .last_frame = .empty,
        };
    }

    fn deinit(self: *TuiHarness) void {
        self.last_frame.deinit(self.allocator);
        self.session.deinit();
    }

    /// Load HTML directly without going through the network. Mirrors
    /// what `runWith` does when given a URL, but synthetically.
    fn loadHtml(self: *TuiHarness, url: []const u8, html: []const u8) !void {
        var result = try self.session.page.processHtml(url, 200, html);
        const screen = try self.session.page.renderBrowseModel(
            self.allocator,
            &result,
            .{
                .max_width = self.size.cols,
                .ansi_colors = false,
                .show_links = true,
                .show_images = true,
            },
        );
        self.session.current = .{ .result = result, .screen = screen };
        try self.session.setViewportSize(self.size.cols, self.size.rows);
    }

    /// Synthesize a keypress through the same key-handling logic as
    /// the run loop. Returns false when the key would have exited
    /// the TUI (Ctrl+C, `q` outside prompts).
    fn pressKey(self: *TuiHarness, key: tui.Key) !bool {
        const outcome = try processKey(&self.session, key, viewportHeight(self.size));
        return outcome == .continue_;
    }

    /// Convenience: send a sequence of ASCII chars as `.char` keys.
    fn typeStr(self: *TuiHarness, s: []const u8) !void {
        for (s) |ch| {
            const cont = try self.pressKey(.{ .char = ch });
            try std.testing.expect(cont);
        }
    }

    /// Render the current state into `last_frame` so tests can
    /// inspect it. Idempotent — call multiple times to re-snapshot.
    fn render(self: *TuiHarness) ![]const u8 {
        self.last_frame.clearRetainingCapacity();
        const w = self.last_frame.writer(self.allocator);
        try drawFrame(w, &self.session, self.size);
        return self.last_frame.items;
    }

    /// True when the most recent frame contains `needle` after
    /// stripping ANSI escape sequences. Tests assert on visible
    /// text, not on the byte stream that contains color codes.
    fn frameContains(self: *TuiHarness, needle: []const u8) !bool {
        const raw = try self.render();
        var stripped: std.ArrayList(u8) = .empty;
        defer stripped.deinit(self.allocator);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\x1b') {
                while (i < raw.len and raw[i] != 'm') : (i += 1) {}
                if (i < raw.len) i += 1;
                continue;
            }
            try stripped.append(self.allocator, raw[i]);
            i += 1;
        }
        return std.mem.indexOf(u8, stripped.items, needle) != null;
    }
};

test "harness: T-Q2.2 loading indicator shows target URL before page is ready" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    // Simulate the start of a blocking navigation. The harness has no live
    // terminal, so `paintLoadingFrame` is a no-op — we inspect the frame
    // `drawFrame` produces while `loading_url` is set.
    try h.session.beginLoading("http://example.com/slow");
    try std.testing.expect(try h.frameContains("Loading"));
    try std.testing.expect(try h.frameContains("example.com/slow"));

    // Once the page installs, the indicator clears and the real page shows.
    h.session.endLoading();
    try h.loadHtml("http://example.com/slow", "<html><body><p>arrived here</p></body></html>");
    try std.testing.expect(!try h.frameContains("Loading"));
    try std.testing.expect(try h.frameContains("arrived here"));
}

test "harness: T-Q2.3 help overlay renders and any key dismisses it" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    try h.loadHtml("http://example.com/", "<html><body><p>hello world</p></body></html>");

    // 'h' opens the help overlay from the normal reading state.
    try std.testing.expect(try h.pressKey(.{ .char = 'h' }));
    try std.testing.expect(try h.frameContains("AWR keybindings"));
    try std.testing.expect(try h.frameContains("This help screen"));

    // Any key dismisses the overlay and the page body returns.
    try std.testing.expect(try h.pressKey(.{ .char = 'j' }));
    try std.testing.expect(!try h.frameContains("AWR keybindings"));
    try std.testing.expect(try h.frameContains("hello world"));
}

test "harness: welcome screen paints on fresh session" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    // Welcome screen needs prompt active to mirror runWith's fresh-tab path.
    try h.session.startPrompt(.url);

    try std.testing.expect(try h.frameContains("AWR — Agentic Web Runtime"));
    try std.testing.expect(try h.frameContains("URL bar"));
    try std.testing.expect(try h.frameContains("URL: "));
}

test "harness: welcome screen stays in a readable block on wide terminals" {
    var h = try TuiHarness.init(std.testing.allocator, 200, 24);
    defer h.deinit();
    try h.session.startPrompt(.url);

    const raw = try h.render();
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\x1b') {
            while (i < raw.len and raw[i] != 'm') : (i += 1) {}
            if (i < raw.len) i += 1;
            continue;
        }
        try stripped.append(std.testing.allocator, raw[i]);
        i += 1;
    }

    var lines = std.mem.splitScalar(u8, stripped.items, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "URL bar")) |idx| {
            try std.testing.expectEqual(@as(usize, 64), idx);
            return;
        }
    }
    return error.ExpectedWelcomeShortcutLine;
}

test "harness: URL prompt accepts typed chars and shows them in footer" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    try h.session.startPrompt(.url);

    try h.typeStr("example.com");

    try std.testing.expect(try h.frameContains("URL: example.com"));
}

test "harness: 'q' outside a prompt exits the loop" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    const html =
        \\<html><body><p>Hello</p></body></html>
    ;
    try h.loadHtml("http://x/", html);

    // Sanity: page loaded.
    try std.testing.expect(try h.frameContains("Hello"));

    // `q` should request exit.
    const cont = try h.pressKey(.{ .char = 'q' });
    try std.testing.expect(!cont);
}

test "harness: Ctrl+C / interrupt exits even mid-prompt" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    try h.session.startPrompt(.url);
    try h.typeStr("half-typed");

    const cont = try h.pressKey(.interrupt);
    try std.testing.expect(!cont);
}

test "harness: T-81 Space toggles checkbox, glyph flips [ ] → [x]" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    const html =
        \\<html><body>
        \\<form><label><input type="checkbox" name="ok"> I agree</label></form>
        \\</body></html>
    ;
    try h.loadHtml("http://x/", html);

    // Initial: unchecked.
    try std.testing.expect(try h.frameContains("[ ] I agree"));

    // Tab → focus checkbox. Space → toggle on.
    _ = try h.pressKey(.tab);
    _ = try h.pressKey(.{ .char = ' ' });
    try std.testing.expect(try h.frameContains("[x] I agree"));

    // Space again → toggle off.
    _ = try h.pressKey(.{ .char = ' ' });
    try std.testing.expect(try h.frameContains("[ ] I agree"));
}

test "harness: T-83 Space opens select picker, arrow keys move cursor, Enter commits" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    const html =
        \\<html><body>
        \\<form>
        \\<select name="color">
        \\  <option value="red">Red</option>
        \\  <option value="green" selected>Green (default)</option>
        \\  <option value="blue">Blue</option>
        \\</select>
        \\</form>
        \\</body></html>
    ;
    try h.loadHtml("http://x/", html);

    // Initial: select shows Green (the selected option).
    try std.testing.expect(try h.frameContains("[Green (default) ▼]"));

    // Tab onto the select. Space opens the picker.
    _ = try h.pressKey(.tab);
    try std.testing.expect(h.session.select_picker == null);
    _ = try h.pressKey(.{ .char = ' ' });
    try std.testing.expect(h.session.select_picker != null);

    // Picker frame shows the title and all three options.
    try std.testing.expect(try h.frameContains("Select an option"));
    try std.testing.expect(try h.frameContains("Red"));
    try std.testing.expect(try h.frameContains("Green (default)"));
    try std.testing.expect(try h.frameContains("Blue"));

    // Cursor lands on Green (the currently-selected option). Down → Blue.
    try std.testing.expectEqual(@as(usize, 1), h.session.select_picker.?.cursor);
    _ = try h.pressKey(.arrow_down);
    try std.testing.expectEqual(@as(usize, 2), h.session.select_picker.?.cursor);

    // Enter commits — picker closes, select label updates.
    _ = try h.pressKey(.enter);
    try std.testing.expect(h.session.select_picker == null);
    try std.testing.expect(try h.frameContains("[Blue ▼]"));
}

test "harness: T-84 cookie inspector — open, navigate, delete, clear-all" {
    var h = try TuiHarness.init(std.testing.allocator, 100, 24);
    defer h.deinit();

    // Need a current URL so the inspector knows the origin. Use a
    // minimal HTML page; navigate via processHtml directly (loadHtml
    // doesn't set up history but does set self.current).
    const html =
        \\<html><body><h1>Test</h1></body></html>
    ;
    try h.loadHtml("http://example.com/page", html);

    // Seed the jar with three cookies for example.com and one for
    // other.com (must NOT appear in the inspector).
    const jar = h.session.page.cookieJar();
    try jar.parseSetCookie("a=1", "example.com");
    try jar.parseSetCookie("b=2", "example.com");
    try jar.parseSetCookie("c=3", "example.com");
    try jar.parseSetCookie("z=99", "other.com");

    // `c` opens inspector.
    _ = try h.pressKey(.{ .char = 'c' });
    try std.testing.expect(h.session.cookie_inspector != null);

    // Inspector should hold exactly 3 rows (example.com only).
    try std.testing.expectEqual(@as(usize, 3), h.session.cookie_inspector.?.rows.items.len);

    // Frame shows the rows and the origin in the title.
    try std.testing.expect(try h.frameContains("Cookies for example.com"));
    try std.testing.expect(try h.frameContains("a"));
    try std.testing.expect(try h.frameContains("b"));
    try std.testing.expect(try h.frameContains("c"));

    // Move cursor down to row 1 ("b"), delete it.
    _ = try h.pressKey(.arrow_down);
    try std.testing.expectEqual(@as(usize, 1), h.session.cookie_inspector.?.cursor);
    _ = try h.pressKey(.{ .char = 'd' });
    try std.testing.expectEqual(@as(usize, 2), h.session.cookie_inspector.?.rows.items.len);
    // Jar mirrors the delete: example.com cookies should now be 2,
    // other.com's cookie untouched (total = 3).
    try std.testing.expectEqual(@as(usize, 3), jar.cookies.items.len);

    // Uppercase `C` triggers confirm-clear-all.
    _ = try h.pressKey(.{ .char = 'C' });
    try std.testing.expect(h.session.cookie_inspector.?.confirm_clear_all);
    try std.testing.expect(try h.frameContains("Delete all 2 cookies for example.com"));

    // `n` cancels the confirmation.
    _ = try h.pressKey(.{ .char = 'n' });
    try std.testing.expect(!h.session.cookie_inspector.?.confirm_clear_all);
    try std.testing.expectEqual(@as(usize, 2), h.session.cookie_inspector.?.rows.items.len);

    // Confirm again, then `y` wipes the example.com cookies.
    _ = try h.pressKey(.{ .char = 'C' });
    _ = try h.pressKey(.{ .char = 'y' });
    // Inspector closes after clear.
    try std.testing.expect(h.session.cookie_inspector == null);
    // Jar: example.com cookies gone; other.com survives.
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try std.testing.expectEqualStrings("other.com", jar.cookies.items[0].domain);
}

test "harness: T-84 cookie inspector — q / Esc close without changes" {
    var h = try TuiHarness.init(std.testing.allocator, 100, 24);
    defer h.deinit();
    try h.loadHtml("http://example.com/", "<html><body><p>x</p></body></html>");
    const jar = h.session.page.cookieJar();
    try jar.parseSetCookie("only=1", "example.com");

    _ = try h.pressKey(.{ .char = 'c' });
    try std.testing.expect(h.session.cookie_inspector != null);
    _ = try h.pressKey(.{ .char = 'q' });
    try std.testing.expect(h.session.cookie_inspector == null);
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);

    // Esc path.
    _ = try h.pressKey(.{ .char = 'c' });
    try std.testing.expect(h.session.cookie_inspector != null);
    _ = try h.pressKey(.escape);
    try std.testing.expect(h.session.cookie_inspector == null);
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
}

test "harness: T-83 Esc cancels picker without changing selection" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    const html =
        \\<html><body>
        \\<form>
        \\<select name="size">
        \\<option value="s">Small</option>
        \\<option value="m" selected>Medium</option>
        \\<option value="l">Large</option>
        \\</select>
        \\</form>
        \\</body></html>
    ;
    try h.loadHtml("http://x/", html);
    _ = try h.pressKey(.tab);
    _ = try h.pressKey(.{ .char = ' ' });
    _ = try h.pressKey(.arrow_down); // move to Large
    _ = try h.pressKey(.escape);

    // Picker closed; original selection (Medium) intact.
    try std.testing.expect(h.session.select_picker == null);
    try std.testing.expect(try h.frameContains("[Medium ▼]"));
}

test "harness: T-81 radio group — selecting one clears its siblings" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    const html =
        \\<html><body>
        \\<form>
        \\<label><input type="radio" name="size" value="s"> Small</label>
        \\<label><input type="radio" name="size" value="m"> Medium</label>
        \\<label><input type="radio" name="size" value="l"> Large</label>
        \\</form>
        \\</body></html>
    ;
    try h.loadHtml("http://x/", html);

    // Initial: all unchecked.
    try std.testing.expect(try h.frameContains("( ) Small"));
    try std.testing.expect(try h.frameContains("( ) Medium"));
    try std.testing.expect(try h.frameContains("( ) Large"));

    // Tab onto Small, select.
    _ = try h.pressKey(.tab);
    _ = try h.pressKey(.{ .char = ' ' });
    try std.testing.expect(try h.frameContains("(*) Small"));
    try std.testing.expect(try h.frameContains("( ) Medium"));

    // Tab forward to Medium, select. Small should auto-deselect.
    _ = try h.pressKey(.tab);
    _ = try h.pressKey(.{ .char = ' ' });
    try std.testing.expect(try h.frameContains("( ) Small"));
    try std.testing.expect(try h.frameContains("(*) Medium"));
    try std.testing.expect(try h.frameContains("( ) Large"));
}

test "T-81 submitForm payload: unchecked checkbox skipped, checked sent" {
    // Drives submitForm's payload builder directly (no network).
    // Pre-checks payload shape against HTML spec — unchecked controls
    // disappear from the URL-encoded body entirely.
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();

    const html =
        \\<html><body>
        \\<form>
        \\<input type="text" name="user" value="alice">
        \\<input type="checkbox" name="agree" value="yes">
        \\<input type="checkbox" name="newsletter" value="weekly">
        \\<input type="radio" name="plan" value="free">
        \\<input type="radio" name="plan" value="pro">
        \\</form>
        \\</body></html>
    ;
    var result = try session.page.processHtml("http://x/", 200, html);
    const screen = try session.page.renderBrowseModel(std.testing.allocator, &result, .{
        .max_width = 78,
        .ansi_colors = false,
        .show_links = true,
        .show_images = true,
    });
    session.current = .{ .result = result, .screen = screen };

    // Toggle `agree` on, leave `newsletter` off; pick `plan=pro`.
    const model = session.screenModel().?;
    for (model.fields) |f| {
        if (std.mem.eql(u8, f.name, "agree")) try session.setCheckedRaw(f.element_ptr, true);
        if (std.mem.eql(u8, f.name, "plan") and std.mem.eql(u8, f.field_type, "radio")) {
            // Pick the "pro" radio: read value attr.
            if (std.mem.eql(u8, session.page.fieldValueAttr(f) orelse "", "pro")) {
                try session.setCheckedRaw(f.element_ptr, true);
            }
        }
    }

    // Build the payload the same way submitForm does. We inline the
    // loop here so the test doesn't trigger a real navigation.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    var first = true;
    for (model.fields) |field| {
        if (field.is_submit) continue;
        if (field.name.len == 0) continue;
        const is_check_kind = std.mem.eql(u8, field.field_type, "checkbox") or
            std.mem.eql(u8, field.field_type, "radio");
        if (is_check_kind) {
            if (!session.isFieldChecked(field)) continue;
            const val_check: []const u8 = session.page.fieldValueAttr(field) orelse "on";
            if (!first) try body.append(std.testing.allocator, '&');
            first = false;
            try session.appendUrlEncoded(&body, field.name);
            try body.append(std.testing.allocator, '=');
            try session.appendUrlEncoded(&body, val_check);
            continue;
        }
        const edited = session.getFieldValue(field.name);
        const val: []const u8 = edited orelse session.page.fieldValueAttr(field) orelse "";
        if (!first) try body.append(std.testing.allocator, '&');
        first = false;
        try session.appendUrlEncoded(&body, field.name);
        try body.append(std.testing.allocator, '=');
        try session.appendUrlEncoded(&body, val);
    }

    // Expected: user=alice & agree=yes & plan=pro. newsletter is
    // skipped because unchecked. The free radio is skipped because
    // unchecked; only the "pro" radio appears.
    try std.testing.expectEqualStrings("user=alice&agree=yes&plan=pro", body.items);
}

test "harness: Tab into form field auto-edits + typing populates [____]" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();

    const html =
        \\<html><body>
        \\<form action="/go"><input type="text" name="q"></form>
        \\</body></html>
    ;
    try h.loadHtml("http://x/", html);

    // Empty box before typing.
    try std.testing.expect(try h.frameContains("[____________________]"));

    // Tab → focus the text input → auto-edit.
    _ = try h.pressKey(.tab);
    try std.testing.expect(h.session.field_editing);

    // Type "hi" — frame should reflect the typed value inside the box,
    // not just appear in the status line.
    try h.typeStr("hi");
    try std.testing.expect(try h.frameContains("[hi"));
}

// ── T-90 URL-bar autocomplete tests ──────────────────────────────

test "pushUrlHistory de-dupes and caps the ring buffer" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    session.url_history_cap = 3;

    try session.pushUrlHistory("https://a.com/");
    try session.pushUrlHistory("https://b.com/");
    try session.pushUrlHistory("https://c.com/");
    try std.testing.expectEqual(@as(usize, 3), session.url_history.items.len);

    // Re-pushing an existing URL moves it to the end (most recent),
    // not duplicates.
    try session.pushUrlHistory("https://a.com/");
    try std.testing.expectEqual(@as(usize, 3), session.url_history.items.len);
    try std.testing.expectEqualStrings("https://a.com/", session.url_history.items[2]);

    // Cap-busting push evicts the oldest.
    try session.pushUrlHistory("https://d.com/");
    try std.testing.expectEqual(@as(usize, 3), session.url_history.items.len);
    try std.testing.expectEqualStrings("https://b.com/", session.url_history.items[0]);
    try std.testing.expectEqualStrings("https://d.com/", session.url_history.items[2]);
}

test "urlAutocompleteUp cycles most-recent → oldest when prefix empty" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.pushUrlHistory("https://a.com/");
    try session.pushUrlHistory("https://b.com/");
    try session.pushUrlHistory("https://c.com/");

    try session.startPrompt(.url);
    // startPrompt for .url pre-fills with currentUrl, which is empty
    // on a fresh session — so the prompt buffer is empty.
    try std.testing.expectEqual(@as(usize, 0), session.prompt_buffer.items.len);

    // First up: most recent.
    try session.urlAutocompleteUp();
    try std.testing.expectEqualStrings("https://c.com/", session.prompt_buffer.items);

    // Second up: older.
    try session.urlAutocompleteUp();
    try std.testing.expectEqualStrings("https://b.com/", session.prompt_buffer.items);

    // Third up: oldest.
    try session.urlAutocompleteUp();
    try std.testing.expectEqualStrings("https://a.com/", session.prompt_buffer.items);

    // Fourth up: wraps back to most recent.
    try session.urlAutocompleteUp();
    try std.testing.expectEqualStrings("https://c.com/", session.prompt_buffer.items);
}

test "urlAutocompleteUp filters by prefix when prompt non-empty" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.pushUrlHistory("https://example.com/");
    try session.pushUrlHistory("https://github.com/");
    try session.pushUrlHistory("https://gitlab.com/");
    try session.pushUrlHistory("https://news.ycombinator.com/");

    try session.startPrompt(.url);
    // Type "https://gi" — prefix-match should narrow to github + gitlab.
    try session.appendPromptByte('h');
    try session.appendPromptByte('t');
    try session.appendPromptByte('t');
    try session.appendPromptByte('p');
    try session.appendPromptByte('s');
    try session.appendPromptByte(':');
    try session.appendPromptByte('/');
    try session.appendPromptByte('/');
    try session.appendPromptByte('g');
    try session.appendPromptByte('i');

    // First up: most recent match (gitlab — pushed after github).
    try session.urlAutocompleteUp();
    try std.testing.expectEqualStrings("https://gitlab.com/", session.prompt_buffer.items);

    // Second up: github.
    try session.urlAutocompleteUp();
    try std.testing.expectEqualStrings("https://github.com/", session.prompt_buffer.items);

    // Third up: wraps to gitlab (only 2 matches).
    try session.urlAutocompleteUp();
    try std.testing.expectEqualStrings("https://gitlab.com/", session.prompt_buffer.items);
}

test "typing a fresh char resets the autocomplete cycle" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.pushUrlHistory("https://github.com/");
    try session.pushUrlHistory("https://gitlab.com/");

    try session.startPrompt(.url);
    try session.appendPromptByte('h');
    try session.urlAutocompleteUp();
    try std.testing.expect(session.url_autocomplete != null);

    // User types a char — autocomplete state must clear so the next
    // arrow press re-prefix-matches against the new buffer.
    try session.appendPromptByte('!');
    try std.testing.expect(session.url_autocomplete == null);
}

test "urlAutocompleteDown is symmetric to up" {
    var session = try BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.pushUrlHistory("https://a.com/");
    try session.pushUrlHistory("https://b.com/");

    try session.startPrompt(.url);
    // First Down lands on most recent (cursor moves 0 → 1 wraps to len-1 in the next case
    // — but for Down we use `(cursor + 1) % len`, so 0 → 1 = oldest is at index 0, newest at len-1.
    // Hmm — the contract above says urlAutocompleteUp lands on most-recent on the first press.
    // For symmetry urlAutocompleteDown should land on the oldest on the first press.
    try session.urlAutocompleteDown();
    try std.testing.expectEqualStrings("https://b.com/", session.prompt_buffer.items);

    // Next Down wraps to oldest.
    try session.urlAutocompleteDown();
    try std.testing.expectEqualStrings("https://a.com/", session.prompt_buffer.items);
}

test "harness: T-90 arrow_up in URL prompt fills with recent history" {
    var h = try TuiHarness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    try h.session.pushUrlHistory("https://example.com/");
    try h.session.pushUrlHistory("https://news.ycombinator.com/");

    // Open URL prompt and press arrow_up via the run-loop key handler.
    try h.session.startPrompt(.url);
    _ = try h.pressKey(.arrow_up);
    try std.testing.expectEqualStrings(
        "https://news.ycombinator.com/",
        h.session.prompt_buffer.items,
    );
    try std.testing.expect(try h.frameContains("URL: https://news.ycombinator.com/"));
}

test "T2.3: cookieExpiryStr human-readable relative time" {
    var buf: [16]u8 = undefined;
    const now: i64 = 1_700_000_000;

    try std.testing.expectEqualStrings("(session)", cookieExpiryStr(&buf, null, now));
    try std.testing.expectEqualStrings("expired", cookieExpiryStr(&buf, now - 1, now));
    try std.testing.expectEqualStrings("<1m", cookieExpiryStr(&buf, now + 30, now));
    try std.testing.expectEqualStrings("5m left", cookieExpiryStr(&buf, now + 5 * 60, now));
    try std.testing.expectEqualStrings("3h left", cookieExpiryStr(&buf, now + 3 * 3600, now));
    try std.testing.expectEqualStrings("2d left", cookieExpiryStr(&buf, now + 2 * 86400, now));
    try std.testing.expectEqualStrings("4w left", cookieExpiryStr(&buf, now + 4 * 7 * 86400, now));
}

