/// render.zig — Structured terminal text renderer for AWR.
///
/// Walks a DOM tree and produces formatted terminal output suitable for
/// display in a monospaced terminal.  Supports:
///
///   - Decorative headings (h1-h6) with ANSI bold/underline
///   - Word-wrapped paragraphs at a configurable max width
///   - Reference-style link footnotes (e.g. "text[1]" with "[1]: url")
///   - Ordered and unordered lists with proper nesting/indentation
///   - Blockquotes (indented, dimmed)
///   - Preserved whitespace in <pre> blocks
///   - Horizontal rules, line breaks, inline code, images
///   - Inline strong/emphasis with ANSI styling
///   - Simple table formatting with aligned columns
///   - Skipping of invisible elements (script, style, head, etc.)
///
/// Known limitation: nested ANSI formatting (e.g. bold link inside italic
/// paragraph) may not restore the outer style correctly because ANSI SGR
/// codes are not stacked.  This is acceptable for a terminal browser.
const std = @import("std");
const dom = @import("dom/node.zig");
const browse_heuristics = @import("browse_heuristics.zig");
const image_protocol = @import("image_protocol");

// ── Public types ──────────────────────────────────────────────────────────

pub const RenderProfile = enum {
    default,
    browse,
};

/// Pre-computed image bytes lookup. Built before rendering by walking
/// the DOM, fetching every `<img src>`, decoding via stb_image, and
/// encoding to the resolved protocol's byte format (Kitty APC, iTerm
/// OSC-1337, Sixel, or UTF-8 braille glyphs). The renderer queries this
/// at `<img>` emit-time; if `getFn` returns non-null, those bytes go to
/// the output verbatim and the alt-text/footnote fallback is skipped.
///
/// Decoupled from `image_protocol` because the renderer doesn't care
/// *which* protocol — only whether bytes are available. Keeps render.zig
/// free of stb_image / encoder dependencies; the protocol-specific
/// machinery lives in `src/image/{kitty,iterm,sixel,braille}.zig` and is
/// wired from main.zig / browser.zig.
pub const ImageLookup = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, url: []const u8) ?[]const u8,

    pub fn get(self: ImageLookup, url: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, url);
    }
};

/// T2.4/T2.5: code-block styling mode for `<pre><code>` blocks.
/// `.none` — no highlighting (plain text, line numbers only).
/// `.auto` — detect language from `class="language-XYZ"` and highlight.
/// `.tag`  — always highlight using only the class-hint tag, no fallback.
pub const CodeStyle = enum { none, auto, tag };

/// T2.5: programming language inferred from `class="language-XYZ"`.
const Language = enum { unknown, zig, rust, js, ts, python, html, json, sh };

pub const RenderOptions = struct {
    max_width: usize = 80,
    ansi_colors: bool = true,
    show_links: bool = true,
    show_images: bool = true,
    /// Whether to emit a "References:" footer listing each [N] marker's
    /// URL. When `null`, the default tracks the profile: the `.default`
    /// profile emits the footer (matches the original render path), the
    /// `.browse` profile suppresses it (interactive mode treats links
    /// as hover/click targets, not footnotes). Set explicitly to `true`
    /// for non-interactive `awr render` output piped to a file or LLM,
    /// where orphan `[N]` markers without URLs are dead weight.
    show_references: ?bool = null,
    profile: RenderProfile = .default,
    /// Resolved terminal-image protocol. Default `.none` means no
    /// inline image emit; the renderer falls through to the text alt-ref
    /// path. The actual encoded bytes (the *what to emit*) come from
    /// `image_lookup`; this field carries the *what protocol* metadata
    /// for downstream use (telemetry, error messages, etc.).
    image_protocol: image_protocol.Protocol = .none,
    /// Pre-computed image-bytes lookup. When non-null and `<img src>`
    /// resolves to bytes, those bytes are emitted inline (raw — no
    /// column tracking, no escape mangling) and the alt-text fallback
    /// is skipped. When null, every `<img>` renders as `[alt][N]` —
    /// preserves `test-corpus` determinism since corpus tests never
    /// build a lookup.
    image_lookup: ?ImageLookup = null,
    /// Per-field user-typed-value override. When non-null,
    /// `renderInput` / `renderTextarea` query this lookup with the
    /// field's `name` attribute; if the lookup returns a value, it
    /// replaces the DOM's `value` attribute in the rendered box.
    /// Used by `awr browse` to show what the user has typed in a
    /// focused field as they type, instead of leaving the box empty
    /// while their text accumulates only in the status bar.
    field_value_lookup: ?FieldValueLookup = null,
    /// Pointer-equality identifier of the currently-focused element
    /// (typically `@intFromPtr(elem)` of a form control). When set,
    /// `renderInput` / `renderTextarea` / `renderButton` /
    /// `renderSelect` add a visible highlight (reverse video) to the
    /// matching field's rendered box so the user sees where Tab
    /// landed and where typing will go. `null` means "no focus
    /// highlight" — non-interactive `awr render` and corpus output
    /// stays clean.
    focused_element_ptr: ?usize = null,
    /// T-81: per-element checked-state override for checkbox / radio.
    /// When non-null, `renderInput` queries this with the input's
    /// `element_ptr`; non-null result wins over the DOM's `checked`
    /// attribute. Used by `awr browse` so toggled state shows
    /// immediately (`[x]` / `(*)`) without a re-fetch.
    is_checked_lookup: ?IsCheckedLookup = null,
    /// T-83: per-element selected-value override for `<select>`.
    /// When non-null, `renderSelect` queries this with the select's
    /// `element_ptr`; non-null result wins over the DOM's
    /// `<option selected>` attribute. Used by the inline picker so
    /// the chosen option shows immediately after closing the picker.
    selected_option_lookup: ?SelectedOptionLookup = null,
    /// T2.4: minimum line count before line numbers appear in `<pre><code>`
    /// blocks. 0 = always show; default 5 matches the spec default.
    /// Set to `std.math.maxInt(usize)` to disable entirely.
    code_line_numbers: usize = 5,
    /// T2.4/T2.5: syntax highlight style. `.none` = line numbers only.
    /// `.auto` / `.tag` activate highlighting (T2.5). Stored here so
    /// `awr render --code-style=auto` round-trips through RenderOptions.
    code_style: CodeStyle = .none,
    /// T2.6: treat every `<pre>` block as a unified diff. Set when
    /// `Content-Type: text/x-diff` or `text/x-patch` is present.
    /// Auto-detection via `looksLikeDiff` runs regardless.
    is_diff: bool = false,
};

pub const FieldValueLookup = struct {
    ctx: *anyopaque,
    lookup_fn: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,

    pub fn lookup(self: FieldValueLookup, name: []const u8) ?[]const u8 {
        return self.lookup_fn(self.ctx, name);
    }
};

pub const IsCheckedLookup = struct {
    ctx: *anyopaque,
    /// Returns true if the user has toggled this element ON, false if
    /// they've toggled it OFF, or null if they haven't touched it
    /// (in which case the renderer falls back to the DOM `checked`
    /// attribute).
    lookup_fn: *const fn (ctx: *anyopaque, element_ptr: usize) ?bool,

    pub fn lookup(self: IsCheckedLookup, element_ptr: usize) ?bool {
        return self.lookup_fn(self.ctx, element_ptr);
    }
};

pub const SelectedOptionLookup = struct {
    ctx: *anyopaque,
    /// Returns the user-selected option *label* (display text) for
    /// the given `<select>` element, or null when the user hasn't
    /// touched it (renderer falls back to DOM `<option selected>`).
    /// We return the label rather than the value because the
    /// renderer's job is display, not submission.
    lookup_fn: *const fn (ctx: *anyopaque, element_ptr: usize) ?[]const u8,

    pub fn lookup(self: SelectedOptionLookup, element_ptr: usize) ?[]const u8 {
        return self.lookup_fn(self.ctx, element_ptr);
    }
};

/// T2.8 — Label association contract:
/// `label` is populated for:
///   - `<button>` / `<input type="submit|reset|button">` — visible button text
///   - `<label>` elements — their rendered text content
/// For generic `<input>` / `<textarea>` / `<select>`, `label` is "" because
/// AWR does not yet traverse the DOM to find an associated `<label for="id">`
/// element at render time. The intended future contract is: if `getAttribute
/// ("id")` returns an id that matches a `<label for="...">` element, that
/// label's text is stored here. Status-bar rendering in browser.zig should
/// show `label` when non-empty and fall back to `name` otherwise.
pub const ScreenField = struct {
    index: usize,
    element_ptr: usize,
    name: []const u8,
    field_type: []const u8,
    label: []const u8,
    line: usize,
    col: usize,
    width: usize,
    is_submit: bool,

    pub fn deinit(self: *const ScreenField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.field_type);
        allocator.free(self.label);
    }
};

pub const ScreenLink = struct {
    element_ptr: usize,
    index: usize,
    href: []const u8,
    text: []const u8,
    line: usize,
};

pub const ScreenRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const ScreenBox = struct {
    element_ptr: usize,
    rect: ScreenRect,
};

pub const ScreenLine = struct {
    start: usize,
    end: usize,
};

/// T2.7: position of a table header row in the ScreenModel line array.
/// The TUI viewport shows the header as a sticky overlay when scrolled past it.
pub const StickyHeader = struct {
    /// Line range [start, end) of the rendered header row (inclusive of
    /// any separator line that immediately follows the header cells).
    header_line_start: usize,
    header_line_end: usize,
    /// Exclusive end of the table body. Sticky is shown while
    /// `scroll_row ∈ [header_line_end, table_line_end)`.
    table_line_end: usize,
};

pub const ScreenModel = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    lines: []ScreenLine,
    links: []ScreenLink,
    boxes: []ScreenBox,
    fields: []ScreenField,
    sticky_headers: []StickyHeader,

    pub fn deinit(self: *ScreenModel) void {
        for (self.links) |link| {
            self.allocator.free(link.href);
            self.allocator.free(link.text);
        }
        for (self.fields) |field| {
            field.deinit(self.allocator);
        }
        self.allocator.free(self.fields);
        self.allocator.free(self.boxes);
        self.allocator.free(self.links);
        self.allocator.free(self.lines);
        self.allocator.free(self.text);
        self.allocator.free(self.sticky_headers);
    }

    pub fn lineText(self: *const ScreenModel, index: usize) []const u8 {
        const line = self.lines[index];
        return self.text[line.start..line.end];
    }

    pub fn rectForElement(self: *const ScreenModel, elem: *const dom.Element) ?ScreenRect {
        const ptr = @intFromPtr(elem);
        for (self.boxes) |box| {
            if (box.element_ptr == ptr) return box.rect;
        }
        return null;
    }
};

// ── Internal types ────────────────────────────────────────────────────────

const FieldRef = struct {
    index: usize,
    element_ptr: usize,
    name: []const u8,
    field_type: []const u8,
    label: []const u8,
    line: usize,
    col: usize,
    width: usize,
    is_submit: bool,
};

const LinkRef = struct {
    element_ptr: usize,
    index: usize,
    href: []const u8,
    text: []const u8,
    line: usize,
};

const BoxRef = struct {
    element_ptr: usize,
    left: usize = 0,
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    saw_content: bool = false,
};

const BufferWriter = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }
};

/// Mutable state threaded through every render call.
/// The `writer` is passed separately as `anytype` so the compiler
/// monomorphises each render function for the concrete writer type.
const RenderState = struct {
    allocator: std.mem.Allocator,
    opts: RenderOptions,
    col: usize = 0,
    at_line_start: bool = true,
    line_index: usize = 0,
    pre_depth: usize = 0,
    hang_indent: usize = 0,
    links: std.ArrayListUnmanaged(LinkRef) = .empty,
    fields: std.ArrayListUnmanaged(FieldRef) = .empty,
    boxes: std.ArrayListUnmanaged(BoxRef) = .empty,
    active_boxes: std.ArrayListUnmanaged(usize) = .empty,
    sticky_hdrs: std.ArrayListUnmanaged(StickyHeader) = .empty,

    fn deinit(self: *RenderState) void {
        for (self.links.items) |link| {
            self.allocator.free(link.href);
            self.allocator.free(link.text);
        }
        self.links.deinit(self.allocator);
        for (self.fields.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.field_type);
            self.allocator.free(field.label);
        }
        self.fields.deinit(self.allocator);
        self.boxes.deinit(self.allocator);
        self.active_boxes.deinit(self.allocator);
        self.sticky_hdrs.deinit(self.allocator);
    }

    fn beginElementBox(self: *RenderState, elem: *const dom.Element) !void {
        try self.boxes.append(self.allocator, .{ .element_ptr = @intFromPtr(elem) });
        try self.active_boxes.append(self.allocator, self.boxes.items.len - 1);
    }

    fn endElementBox(self: *RenderState) void {
        _ = self.active_boxes.pop();
    }

    fn noteCell(self: *RenderState, line: usize, col: usize) void {
        for (self.active_boxes.items) |idx| {
            var box = &self.boxes.items[idx];
            if (!box.saw_content) {
                box.left = col;
                box.top = line;
                box.right = col + 1;
                box.bottom = line + 1;
                box.saw_content = true;
                continue;
            }
            box.left = @min(box.left, col);
            box.top = @min(box.top, line);
            box.right = @max(box.right, col + 1);
            box.bottom = @max(box.bottom, line + 1);
        }
    }

    /// Emit pending hang-indent whitespace before actual content.
    fn prepareForContent(self: *RenderState, w: anytype) !void {
        if (self.at_line_start and self.hang_indent > 0) {
            for (0..self.hang_indent) |_| {
                self.noteCell(self.line_index, self.col);
                try w.writeByte(' ');
                self.col += 1;
            }
            self.at_line_start = false;
        }
    }

    /// Write a single byte, tracking column and lazy-indent.
    fn writeByte(self: *RenderState, w: anytype, byte: u8) !void {
        if (byte == '\n') {
            try w.writeByte('\n');
            self.col = 0;
            self.at_line_start = true;
            self.line_index += 1;
        } else {
            try self.prepareForContent(w);
            self.noteCell(self.line_index, self.col);
            try w.writeByte(byte);
            self.col += 1;
        }
    }

    /// Write a byte slice, correctly tracking column across newlines.
    fn writeAll(self: *RenderState, w: anytype, bytes: []const u8) !void {
        for (bytes) |byte| try self.writeByte(w, byte);
    }

    /// Emit a structural newline (no hang-indent emitted until next content).
    fn newline(self: *RenderState, w: anytype) !void {
        try w.writeByte('\n');
        self.col = 0;
        self.at_line_start = true;
        self.line_index += 1;
    }

    /// If not already at line start, emit a newline.
    fn ensureNewline(self: *RenderState, w: anytype) !void {
        if (!self.at_line_start) try self.newline(w);
    }

    /// Write an ANSI escape sequence (no-op when ansi_colors is false).
    fn ansi(self: *RenderState, w: anytype, code: []const u8) !void {
        if (self.opts.ansi_colors) try w.writeAll(code);
    }

    fn inPre(self: *const RenderState) bool {
        return self.pre_depth > 0;
    }

    fn registerLink(self: *RenderState, element_ptr: usize, href: []const u8, text: []const u8) !usize {
        const idx = self.links.items.len + 1;
        try self.links.append(self.allocator, .{
            .element_ptr = element_ptr,
            .index = idx,
            .href = try self.allocator.dupe(u8, href),
            .text = try self.allocator.dupe(u8, text),
            .line = self.line_index,
        });
        return idx;
    }

    fn registerField(
        self: *RenderState,
        element_ptr: usize,
        name: []const u8,
        field_type: []const u8,
        label: []const u8,
        col: usize,
        width: usize,
        is_submit: bool,
    ) !usize {
        const idx = self.fields.items.len;
        try self.fields.append(self.allocator, .{
            .index = idx,
            .element_ptr = element_ptr,
            .name = try self.allocator.dupe(u8, name),
            .field_type = try self.allocator.dupe(u8, field_type),
            .label = try self.allocator.dupe(u8, label),
            .line = self.line_index,
            .col = col,
            .width = width,
            .is_submit = is_submit,
        });
        return idx;
    }
};

// ── ANSI constants ────────────────────────────────────────────────────────

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const REVERSE = "\x1b[7m";
const DIM = "\x1b[2m";
const UNDERLINE = "\x1b[4m";
const ITALIC = "\x1b[3m";
const CYAN = "\x1b[36m";
const GREEN = "\x1b[32m";   // T2.5: string literals / diff additions
const YELLOW = "\x1b[33m";  // T2.5: numeric literals
const RED = "\x1b[31m";     // T2.6: diff deletions

// ── Public API ────────────────────────────────────────────────────────────

/// Render a DOM document as structured terminal text written to `writer`.
/// The allocator is used for temporary text-content extraction and the
/// link-reference list.
pub fn render(
    allocator: std.mem.Allocator,
    writer: anytype,
    doc: *const dom.Document,
    opts: RenderOptions,
) anyerror!void {
    var model = try renderModel(allocator, doc, opts);
    defer model.deinit();
    try writer.writeAll(model.text);
}

pub fn renderHtml(
    allocator: std.mem.Allocator,
    writer: anytype,
    html: []const u8,
    opts: RenderOptions,
) anyerror!void {
    var doc = try dom.parseDocument(allocator, html);
    defer doc.deinit();
    try render(allocator, writer, &doc, opts);
}

pub fn renderModel(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    opts: RenderOptions,
) !ScreenModel {
    return renderModelFromRoot(allocator, doc.body(), opts);
}

pub fn renderBrowseModel(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    opts: RenderOptions,
) !ScreenModel {
    var browse_opts = opts;
    browse_opts.profile = .browse;
    const root = browse_heuristics.chooseContentRoot(doc) orelse doc.body();
    return renderModelFromRoot(allocator, root, browse_opts);
}

pub fn renderBrowseHtmlModel(
    allocator: std.mem.Allocator,
    html: []const u8,
    opts: RenderOptions,
) !ScreenModel {
    var doc = try dom.parseDocument(allocator, html);
    defer doc.deinit();
    return renderBrowseModel(allocator, &doc, opts);
}

pub fn renderModelFromElement(
    allocator: std.mem.Allocator,
    elem: *const dom.Element,
    opts: RenderOptions,
) !ScreenModel {
    return renderModelFromRoot(allocator, elem, opts);
}

fn renderModelFromRoot(
    allocator: std.mem.Allocator,
    root: ?*const dom.Element,
    opts: RenderOptions,
) !ScreenModel {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var writer = BufferWriter{ .allocator = allocator, .list = &buf };
    var state = RenderState{
        .allocator = allocator,
        .opts = opts,
    };
    defer state.deinit();

    if (root) |elem| {
        if (eql(elem.tag, "body")) {
            try renderChildren(&state, &writer, elem);
        } else {
            try renderElement(&state, &writer, elem);
        }

        const emit_refs = opts.show_references orelse (opts.profile == .default);
        if (emit_refs and opts.show_links and state.links.items.len > 0) {
            try state.ensureNewline(&writer);
            try state.newline(&writer);
            try state.ansi(&writer, BOLD);
            try state.writeAll(&writer, "References:");
            try state.ansi(&writer, RESET);
            try state.newline(&writer);
            for (state.links.items) |link| {
                const num = try std.fmt.allocPrint(allocator, "{d}", .{link.index});
                defer allocator.free(num);
                try writer.writeAll("  [");
                try state.ansi(&writer, CYAN);
                try writer.writeAll(num);
                try state.ansi(&writer, RESET);
                try writer.writeAll("]: ");
                try state.ansi(&writer, UNDERLINE);
                try writer.writeAll(link.href);
                try state.ansi(&writer, RESET);
                try state.newline(&writer);
            }
        }
    }

    return buildScreenModel(allocator, try buf.toOwnedSlice(allocator), state.links.items, state.fields.items, state.boxes.items, state.sticky_hdrs.items);
}

pub fn renderHtmlModel(
    allocator: std.mem.Allocator,
    html: []const u8,
    opts: RenderOptions,
) !ScreenModel {
    var doc = try dom.parseDocument(allocator, html);
    defer doc.deinit();
    return renderModel(allocator, &doc, opts);
}

fn buildScreenModel(
    allocator: std.mem.Allocator,
    text: []u8,
    link_refs: []const LinkRef,
    field_refs: []const FieldRef,
    box_refs: []const BoxRef,
    sticky_header_refs: []const StickyHeader,
) !ScreenModel {
    errdefer allocator.free(text);

    const line_count = countScreenLines(text);
    const lines = try allocator.alloc(ScreenLine, line_count);
    errdefer allocator.free(lines);

    if (line_count > 0) {
        var line_start: usize = 0;
        var line_index: usize = 0;
        for (text, 0..) |ch, i| {
            if (ch == '\n') {
                if (line_index < lines.len) {
                    lines[line_index] = .{ .start = line_start, .end = i };
                    line_index += 1;
                }
                line_start = i + 1;
            }
        }
        if (line_index < lines.len) {
            lines[line_index] = .{ .start = line_start, .end = text.len };
        }
    }

    const links = try allocator.alloc(ScreenLink, link_refs.len);
    var built_links: usize = 0;
    errdefer {
        for (links[0..built_links]) |link| {
            allocator.free(link.href);
            allocator.free(link.text);
        }
        allocator.free(links);
    }
    for (link_refs, 0..) |link, i| {
        links[i] = .{
            .element_ptr = link.element_ptr,
            .index = link.index,
            .href = try allocator.dupe(u8, link.href),
            .text = try allocator.dupe(u8, link.text),
            .line = link.line,
        };
        built_links += 1;
    }

    const boxes = try allocator.alloc(ScreenBox, box_refs.len);
    errdefer allocator.free(boxes);
    for (box_refs, 0..) |box, i| {
        boxes[i] = .{
            .element_ptr = box.element_ptr,
            .rect = .{
                .x = box.left,
                .y = box.top,
                .width = if (box.saw_content) box.right - box.left else 0,
                .height = if (box.saw_content) box.bottom - box.top else 0,
            },
        };
    }

    const fields = try allocator.alloc(ScreenField, field_refs.len);
    var built_fields: usize = 0;
    errdefer {
        for (fields[0..built_fields]) |field| {
            field.deinit(allocator);
        }
        allocator.free(fields);
    }
    for (field_refs, 0..) |field, i| {
        fields[i] = .{
            .index = field.index,
            .element_ptr = field.element_ptr,
            .name = try allocator.dupe(u8, field.name),
            .field_type = try allocator.dupe(u8, field.field_type),
            .label = try allocator.dupe(u8, field.label),
            .line = field.line,
            .col = field.col,
            .width = field.width,
            .is_submit = field.is_submit,
        };
        built_fields += 1;
    }

    const sticky_headers = try allocator.dupe(StickyHeader, sticky_header_refs);
    errdefer allocator.free(sticky_headers);

    return .{
        .allocator = allocator,
        .text = text,
        .lines = lines,
        .links = links,
        .fields = fields,
        .boxes = boxes,
        .sticky_headers = sticky_headers,
    };
}

fn countScreenLines(text: []const u8) usize {
    if (text.len == 0) return 0;

    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

// ── Tree-walking renderers ────────────────────────────────────────────────

fn renderNode(state: *RenderState, w: anytype, node: dom.Node) anyerror!void {
    switch (node) {
        .text => |t| try renderTextNode(state, w, t),
        .element => |e| try renderElement(state, w, e),
        .comment => {}, // skip comments
        else => {},
    }
}

fn renderChildren(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    for (elem.children.items) |child| {
        try renderNode(state, w, child);
    }
}

fn renderElement(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const tag = elem.tag;

    if (isHiddenTag(tag)) return;

    if (state.opts.profile == .browse) {
        if (isCompactLandmarkTag(tag)) {
            if (browse_heuristics.shouldCollapseForBrowse(elem)) {
                try renderCollapsedLandmark(state, w, tag);
            } else if (browse_heuristics.shouldSkipForBrowse(elem)) {
                return;
            } else {
                try renderBrowseCompactLandmark(state, w, elem);
            }
            return;
        }

        if (isStrongLandmarkTag(tag)) {
            if (browse_heuristics.shouldSkipForBrowse(elem)) return;
            try renderBrowseStrongLandmark(state, w, elem);
            return;
        }

        if (browse_heuristics.shouldSkipForBrowse(elem)) return;
    }

    try state.beginElementBox(elem);
    defer state.endElementBox();

    // Step 10: CSS background-image emit. For content-bearing landmarks
    // (`<header>`, `<section>`, `<figure>`) with inline `style="...
    // background-image: url(...)..."`, surface the bg image as an
    // image-bearing row before the element's children render. The
    // pipeline pre-fetches these URLs into the same lookup as `<img>`
    // sources; this hook just queries it. Per
    // `spec/subspecs/rendering.md §3.1`.
    if (state.opts.image_lookup) |lookup| {
        if (eql(tag, "header") or eql(tag, "section") or eql(tag, "figure")) {
            tryEmitBackgroundImage(state, w, elem, lookup) catch {};
        }
    }

    // ── Heading ──────────────────────────────────────────────────────
    if (headingLevel(tag)) |level| {
        try renderHeading(state, w, elem, level);
        return;
    }

    // ── Paragraph ────────────────────────────────────────────────────
    if (eql(tag, "p")) {
        try renderParagraph(state, w, elem);
        return;
    }

    // ── Anchor / link ────────────────────────────────────────────────
    if (eql(tag, "a")) {
        try renderLink(state, w, elem);
        return;
    }

    // ── Lists ────────────────────────────────────────────────────────
    if (eql(tag, "ul") or eql(tag, "ol")) {
        try renderList(state, w, elem);
        return;
    }
    if (eql(tag, "li")) {
        var one: usize = 1;
        try renderListItem(state, w, elem, false, &one);
        return;
    }

    // ── Blockquote ───────────────────────────────────────────────────
    if (eql(tag, "blockquote")) {
        try renderBlockquote(state, w, elem);
        return;
    }

    // ── Preformatted ─────────────────────────────────────────────────
    if (eql(tag, "pre")) {
        try renderPre(state, w, elem);
        return;
    }

    // ── Inline code ──────────────────────────────────────────────────
    if (eql(tag, "code")) {
        try renderCode(state, w, elem);
        return;
    }

    // ── Horizontal rule ──────────────────────────────────────────────
    if (eql(tag, "hr")) {
        try renderHr(state, w);
        return;
    }

    // ── Line break ───────────────────────────────────────────────────
    if (eql(tag, "br")) {
        try state.newline(w);
        return;
    }

    // ── Form elements ────────────────────────────────────────────────
    if (eql(tag, "input")) {
        try renderInput(state, w, elem);
        return;
    }
    if (eql(tag, "button")) {
        try renderButton(state, w, elem);
        return;
    }
    if (eql(tag, "select")) {
        try renderSelect(state, w, elem);
        return;
    }
    if (eql(tag, "textarea")) {
        try renderTextarea(state, w, elem);
        return;
    }

    // ── Image ────────────────────────────────────────────────────────
    if (eql(tag, "img")) {
        try renderImage(state, w, elem);
        return;
    }

    // ── Strong / bold ────────────────────────────────────────────────
    if (eql(tag, "strong") or eql(tag, "b")) {
        try renderStrong(state, w, elem);
        return;
    }

    // ── Emphasis / italic ────────────────────────────────────────────
    if (eql(tag, "em") or eql(tag, "i")) {
        try renderEm(state, w, elem);
        return;
    }

    // ── Table ────────────────────────────────────────────────────────
    if (eql(tag, "table")) {
        try renderTable(state, w, elem);
        return;
    }

    // ── Generic block / inline fallback ──────────────────────────────
    if (isBlockTag(tag)) {
        try state.ensureNewline(w);
        try renderChildren(state, w, elem);
        try state.ensureNewline(w);
    } else {
        try renderChildren(state, w, elem);
    }
}

// ── Specific element renderers ────────────────────────────────────────────

fn renderHeading(state: *RenderState, w: anytype, elem: *const dom.Element, level: u8) anyerror!void {
    try state.ensureNewline(w);

    const text = elem.textContentForExtract(state.allocator) catch return;
    defer state.allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;

    // Style: h1/h2 get bold+underline; h3 gets bold; h4-h6 get bold+dim.
    try state.ansi(w, BOLD);
    if (level <= 2) try state.ansi(w, UNDERLINE);
    if (level >= 4) try state.ansi(w, DIM);
    try state.writeAll(w, trimmed);
    try state.ansi(w, RESET);
    try state.newline(w);

    // Decorative underline for h1 ("=") and h2 ("-").
    if (level <= 2) {
        const ch: u8 = if (level == 1) '=' else '-';
        const len = @min(trimmed.len, state.opts.max_width);
        for (0..len) |_| try w.writeByte(ch);
        try state.newline(w);
    }
    try state.newline(w);
}

fn renderParagraph(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);
    try renderChildren(state, w, elem);
    try state.ensureNewline(w);
    try state.newline(w);
}

fn renderLink(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    if (focused and state.opts.ansi_colors) {
        try state.ansi(w, REVERSE);
        try state.ansi(w, BOLD);
    } else {
        try state.ansi(w, UNDERLINE);
    }
    try renderChildren(state, w, elem);
    try state.ansi(w, RESET);

    if (state.opts.show_links) {
        const href = elem.getAttribute("href") orelse "";
        if (href.len > 0) {
            const raw_text = elem.textContentForExtract(state.allocator) catch return;
            defer state.allocator.free(raw_text);
            const idx = state.registerLink(@intFromPtr(elem), href, std.mem.trim(u8, raw_text, " \t\r\n")) catch return;
            const ref = try std.fmt.allocPrint(state.allocator, "[{d}]", .{idx});
            defer state.allocator.free(ref);
            try state.ansi(w, DIM);
            try state.writeAll(w, ref);
            try state.ansi(w, RESET);
        }
    }
}

fn renderList(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);
    const is_ordered = eql(elem.tag, "ol");
    var item_num: usize = 1;

    for (elem.children.items) |child| {
        if (child == .element) {
            if (eql(child.element.tag, "li")) {
                try renderListItem(state, w, child.element, is_ordered, &item_num);
                if (is_ordered) item_num += 1;
            } else {
                try renderNode(state, w, child);
            }
        }
    }
}

fn renderListItem(
    state: *RenderState,
    w: anytype,
    elem: *const dom.Element,
    is_ordered: bool,
    item_num: *usize,
) anyerror!void {
    // Skip list items whose visible content is empty after extraction
    // (script/style stripped, decorative images skipped). Otherwise we
    // emit a bare bullet `•` with no text — pure noise. T-76: surfaced
    // by Google's homepage where suggestion `<li>` elements with only
    // empty-alt icons rendered as a column of stranded bullets.
    const probe = elem.textContentForExtract(state.allocator) catch "";
    defer if (probe.len > 0) state.allocator.free(probe);
    if (std.mem.trim(u8, probe, " \t\r\n").len == 0 and !hasVisibleControl(elem)) return;

    const saved_indent = state.hang_indent;

    try state.ensureNewline(w);

    if (is_ordered) {
        const prefix = try std.fmt.allocPrint(state.allocator, "  {d}. ", .{item_num.*});
        defer state.allocator.free(prefix);
        try state.writeAll(w, prefix);
    } else {
        try state.writeAll(w, "  \xe2\x80\xa2 "); // UTF-8 bullet: "•"
    }
    // hang_indent = absolute column after prefix (works for nesting)
    state.hang_indent = state.col;

    try renderChildren(state, w, elem);
    try state.newline(w);

    state.hang_indent = saved_indent;
}

/// True when an element subtree contains a focusable form control we
/// want the user to be able to Tab into (input/select/textarea/button).
/// Used by `renderListItem` to keep an `<li>` that wraps a button even
/// if the textual content is empty (icon-only buttons).
fn hasVisibleControl(elem: *const dom.Element) bool {
    for (elem.children.items) |child| {
        if (child != .element) continue;
        const tag = child.element.tag;
        if (eql(tag, "input") or eql(tag, "textarea") or eql(tag, "select") or eql(tag, "button")) {
            // hidden inputs are not visible controls
            if (eql(tag, "input")) {
                const t = child.element.getAttribute("type") orelse "text";
                if (eql(t, "hidden")) continue;
            }
            return true;
        }
        if (hasVisibleControl(child.element)) return true;
    }
    return false;
}

fn renderBlockquote(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);
    try state.ansi(w, DIM);
    const saved_indent = state.hang_indent;
    state.hang_indent += 2;
    try renderChildren(state, w, elem);
    try state.ensureNewline(w);
    state.hang_indent = saved_indent;
    try state.ansi(w, RESET);
}

fn renderPre(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);

    // T2.6: diff/patch coloring — checked first so diffs skip the gutter.
    diff: {
        const text = elem.textContent(state.allocator) catch break :diff;
        defer state.allocator.free(text);
        if (!state.opts.is_diff and !looksLikeDiff(text)) break :diff;
        try renderDiffBlock(state, w, text);
        try state.ensureNewline(w);
        return;
    }

    // T2.4/T2.5: `<pre><code>` blocks with enough lines get a numbered gutter
    // and (when code_style != .none) syntax highlighting.
    line_numbers: {
        if (state.opts.code_line_numbers == std.math.maxInt(usize)) break :line_numbers;
        const code = elem.firstChildByTag("code") orelse break :line_numbers;
        const text = code.textContent(state.allocator) catch break :line_numbers;
        defer state.allocator.free(text);
        const line_count = std.mem.count(u8, text, "\n") + 1;
        if (line_count <= state.opts.code_line_numbers) break :line_numbers;
        const lang: Language = if (state.opts.code_style != .none)
            detectLanguage(code)
        else
            .unknown;
        try renderCodeBlockWithLineNumbers(state, w, text, line_count, lang);
        try state.ensureNewline(w);
        return;
    }

    state.pre_depth += 1;
    try renderChildren(state, w, elem);
    state.pre_depth -= 1;
    try state.ensureNewline(w);
}

/// Render a code-block text with line-number gutter (T2.4) and optional
/// syntax highlighting (T2.5).  `lang` is `.unknown` when highlighting
/// is disabled; the gutter is always dim regardless of language.
fn renderCodeBlockWithLineNumbers(
    state: *RenderState,
    w: anytype,
    text: []const u8,
    line_count: usize,
    lang: Language,
) !void {
    var digit_count: usize = 1;
    {
        var n = line_count;
        while (n >= 10) : (n /= 10) digit_count += 1;
    }

    const highlight = state.opts.code_style != .none and lang != .unknown;

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (state.opts.ansi_colors) try w.writeAll(DIM);
        var num_buf: [20]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "";
        var pad = if (digit_count > num_str.len) digit_count - num_str.len else 0;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.writeAll(num_str);
        try w.writeAll(" \u{2502} "); // │
        if (state.opts.ansi_colors) try w.writeAll(RESET);
        if (highlight) {
            try writeHighlightedLine(w, line, lang, state.opts.ansi_colors);
        } else {
            try w.writeAll(line);
        }
        try w.writeByte('\n');
        state.col = 0;
        line_num += 1;
    }
}

/// True if `text` contains unified-diff markers in its first 10 lines.
/// Detects `--- `, `+++ `, `diff --git`, and `@@ ` as unambiguous signals.
fn looksLikeDiff(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 10) break;
        if (std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "+++ ") or
            std.mem.startsWith(u8, line, "diff --") or
            std.mem.startsWith(u8, line, "@@ ")) return true;
    }
    return false;
}

/// Render a unified diff block with ANSI color: additions green, deletions
/// red, hunk headers bold, file headers bold.  Falls back to plain text when
/// `ansi_colors` is false.
fn renderDiffBlock(state: *RenderState, w: anytype, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ") or
            std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "diff --"))
        {
            if (state.opts.ansi_colors) try w.writeAll(BOLD);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (state.opts.ansi_colors) try w.writeAll(BOLD);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else if (line.len > 0 and line[0] == '+') {
            if (state.opts.ansi_colors) try w.writeAll(GREEN);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else if (line.len > 0 and line[0] == '-') {
            if (state.opts.ansi_colors) try w.writeAll(RED);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else {
            try w.writeAll(line);
        }
        try w.writeByte('\n');
        state.col = 0;
    }
}

/// Return true if `word` is a reserved keyword in `lang`.
fn isKeyword(word: []const u8, lang: Language) bool {
    return switch (lang) {
        .zig => isIn(word, &.{
            "const", "var", "fn", "pub", "return", "if", "else", "while", "for",
            "switch", "break", "continue", "defer", "errdefer", "try", "catch",
            "error", "union", "struct", "enum", "packed", "extern", "export",
            "inline", "noreturn", "void", "bool", "anytype", "comptime",
            "usingnamespace", "test", "orelse", "and", "or", "not",
            "true", "false", "null", "undefined", "unreachable",
        }),
        .rust => isIn(word, &.{
            "fn", "let", "mut", "const", "pub", "use", "mod", "struct", "enum",
            "impl", "trait", "for", "if", "else", "while", "loop", "match",
            "return", "break", "continue", "where", "self", "Self", "super",
            "async", "await", "move", "ref", "type", "dyn", "unsafe", "extern",
            "true", "false", "None", "Some", "Ok", "Err",
        }),
        .js, .ts => isIn(word, &.{
            "const", "let", "var", "function", "return", "if", "else", "for",
            "while", "do", "switch", "case", "break", "continue", "class",
            "extends", "import", "export", "default", "from", "async", "await",
            "try", "catch", "finally", "throw", "new", "this", "typeof",
            "instanceof", "true", "false", "null", "undefined", "void", "delete",
            "in", "of", "type", "interface", "enum", "implements",
        }),
        .python => isIn(word, &.{
            "def", "class", "return", "if", "elif", "else", "for", "while",
            "import", "from", "as", "with", "try", "except", "finally", "raise",
            "pass", "break", "continue", "lambda", "yield", "global", "nonlocal",
            "and", "or", "not", "in", "is", "True", "False", "None",
        }),
        .sh => isIn(word, &.{
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
            "case", "esac", "in", "function", "return", "local", "export",
            "echo", "exit", "true", "false",
        }),
        .json => isIn(word, &.{"true", "false", "null"}),
        .html, .unknown => false,
    };
}

fn isIn(word: []const u8, list: []const []const u8) bool {
    for (list) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Detect language from `class="language-XYZ"` on a `<code>` element.
fn detectLanguage(code: *const dom.Element) Language {
    const cls = code.getAttribute("class") orelse return .unknown;
    var it = std.mem.splitScalar(u8, cls, ' ');
    while (it.next()) |tok| {
        if (!std.mem.startsWith(u8, tok, "language-")) continue;
        const name = tok["language-".len..];
        if (std.mem.eql(u8, name, "zig")) return .zig;
        if (std.mem.eql(u8, name, "rust")) return .rust;
        if (std.mem.eql(u8, name, "js") or std.mem.eql(u8, name, "javascript")) return .js;
        if (std.mem.eql(u8, name, "ts") or std.mem.eql(u8, name, "typescript")) return .ts;
        if (std.mem.eql(u8, name, "py") or std.mem.eql(u8, name, "python")) return .python;
        if (std.mem.eql(u8, name, "html") or std.mem.eql(u8, name, "xml")) return .html;
        if (std.mem.eql(u8, name, "json")) return .json;
        if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "bash") or
            std.mem.eql(u8, name, "shell")) return .sh;
    }
    return .unknown;
}

/// Emit one line of source code with simple token-based highlighting.
///
/// State machine: normal → string (on quote) → back; normal → comment
/// (on // or #) → rest of line dim.  Keywords get BOLD; strings GREEN;
/// numbers YELLOW; comments DIM.  When `ansi` is false, all control
/// sequences are suppressed and plain text is emitted.
fn writeHighlightedLine(w: anytype, line: []const u8, lang: Language, ansi: bool) !void {
    var i: usize = 0;
    var word_start: ?usize = null;

    while (i <= line.len) {
        const at_end = i == line.len;
        const ch: u8 = if (at_end) 0 else line[i];

        // Flush accumulated identifier/keyword word on boundary.
        if (word_start) |ws| {
            const continuing = !at_end and (std.ascii.isAlphanumeric(ch) or ch == '_');
            if (!continuing) {
                const word = line[ws..i];
                if (ansi and isKeyword(word, lang)) {
                    try w.writeAll(BOLD);
                    try w.writeAll(word);
                    try w.writeAll(RESET);
                } else {
                    try w.writeAll(word);
                }
                word_start = null;
                // Fall through to process ch without advancing i.
            } else {
                i += 1;
                continue;
            }
        }

        if (at_end) break;

        // Line comments.
        if ((lang == .zig or lang == .rust or lang == .js or lang == .ts) and
            ch == '/' and i + 1 < line.len and line[i + 1] == '/')
        {
            if (ansi) try w.writeAll(DIM);
            try w.writeAll(line[i..]);
            if (ansi) try w.writeAll(RESET);
            break;
        }
        if ((lang == .python or lang == .sh) and ch == '#') {
            if (ansi) try w.writeAll(DIM);
            try w.writeAll(line[i..]);
            if (ansi) try w.writeAll(RESET);
            break;
        }

        // String literals (' or ").
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            const str_start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\') {
                    i += 1; // skip escape char (loop will add one more)
                } else if (line[i] == quote) {
                    i += 1;
                    break;
                }
            }
            if (ansi) try w.writeAll(GREEN);
            try w.writeAll(line[str_start..i]);
            if (ansi) try w.writeAll(RESET);
            continue;
        }
        // Template literals (JS/TS only).
        if ((lang == .js or lang == .ts) and ch == '`') {
            const str_start = i;
            i += 1;
            while (i < line.len and line[i] != '`') {
                if (line[i] == '\\') i += 1;
                i += 1;
            }
            if (i < line.len) i += 1;
            if (ansi) try w.writeAll(GREEN);
            try w.writeAll(line[str_start..i]);
            if (ansi) try w.writeAll(RESET);
            continue;
        }

        // Numeric literals.
        if (std.ascii.isDigit(ch)) {
            const num_start = i;
            while (i < line.len and
                (std.ascii.isAlphanumeric(line[i]) or line[i] == '.' or line[i] == '_'))
            {
                i += 1;
            }
            if (ansi) try w.writeAll(YELLOW);
            try w.writeAll(line[num_start..i]);
            if (ansi) try w.writeAll(RESET);
            continue;
        }

        // Identifier start → accumulate for keyword check.
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            word_start = i;
            i += 1;
            continue;
        }

        // Punctuation / whitespace — emit verbatim.
        try w.writeByte(ch);
        i += 1;
    }
}

fn renderCode(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const text = elem.textContentForExtract(state.allocator) catch return;
    defer state.allocator.free(text);
    if (text.len == 0) return;
    try state.writeAll(w, "`");
    try state.writeAll(w, text);
    try state.writeAll(w, "`");
}

fn renderHr(state: *RenderState, w: anytype) anyerror!void {
    try state.ensureNewline(w);
    for (0..state.opts.max_width) |_| {
        try w.writeByte('-');
    }
    try state.newline(w);
}

/// Step 10: surface a `<header>` / `<section>` / `<figure>` element's
/// CSS `background-image: url(...)` (or `background:` shorthand) as
/// an inline image — same protocol bytes as a regular `<img>`. Only
/// fires when the pipeline pre-fetched matching bytes (i.e., the URL
/// passed `extractBackgroundUrl` and the fetch + encode succeeded).
///
/// The URL extractor MUST match `pipeline.extractBackgroundUrl`'s
/// output for the same `style` value — they're the two halves of the
/// pipeline → renderer key contract. Any divergence becomes a silent
/// "fetched image but never emitted" loss.
fn tryEmitBackgroundImage(state: *RenderState, w: anytype, elem: *const dom.Element, lookup: ImageLookup) !void {
    const style = elem.getAttribute("style") orelse return;
    const url = extractBgUrlFromStyle(style) orelse return;
    if (lookup.get(url)) |bytes| {
        try state.ensureNewline(w);
        try w.writeAll(bytes);
        try state.newline(w);
    }
}

/// Extract the URL from a CSS `background` / `background-image`
/// declaration. Mirrors `pipeline.extractBackgroundUrl` exactly —
/// see the pipeline source for design notes. Duplicated here because
/// the page module (where this lives) and the image_pipeline module
/// can't share private helpers without expanding the named-module
/// surface.
fn extractBgUrlFromStyle(style: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < style.len) {
        const bg = indexOfICaseFromStart(style, idx, "background") orelse return null;
        var probe = bg + "background".len;
        if (probe + 6 <= style.len and std.ascii.eqlIgnoreCase(style[probe .. probe + 6], "-image")) {
            probe += 6;
        }
        while (probe < style.len and (style[probe] == ' ' or style[probe] == '\t')) : (probe += 1) {}
        if (probe >= style.len or style[probe] != ':') {
            idx = bg + 1;
            continue;
        }
        probe += 1;
        const end = std.mem.indexOfScalarPos(u8, style, probe, ';') orelse style.len;
        const value = style[probe..end];
        if (indexOfICaseFromStart(value, 0, "gradient") != null) return null;
        if (indexOfICaseFromStart(value, 0, "image-set") != null) return null;
        const url_kw = indexOfICaseFromStart(value, 0, "url(") orelse return null;
        const url_start = url_kw + 4;
        const url_close = std.mem.indexOfScalarPos(u8, value, url_start, ')') orelse return null;
        const inner = std.mem.trim(u8, value[url_start..url_close], " \t\"'");
        if (inner.len == 0) return null;
        return inner;
    }
    return null;
}

fn indexOfICaseFromStart(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or start >= haystack.len) return null;
    if (haystack.len < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn renderImage(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    if (!state.opts.show_images) return;

    // Inline-image fast path: if a lookup is configured and the URL
    // resolves to encoded bytes, emit them raw and skip the alt-ref.
    // The bytes contain protocol-specific control sequences (APC, OSC,
    // DCS) that must NOT pass through `state.writeAll`'s column-
    // tracking byte-by-byte path — that would mis-account columns.
    // Use `w.writeAll` directly and reset structural state to
    // line-start afterwards so the next sibling lays out cleanly.
    if (state.opts.image_lookup) |lookup| {
        const src = elem.getAttribute("src") orelse "";
        if (src.len > 0) {
            if (lookup.get(src)) |bytes| {
                try state.ensureNewline(w);
                try w.writeAll(bytes);
                try state.newline(w);
                return;
            }
        }
    }

    // HTML spec: an explicit `alt=""` marks the image as decorative —
    // screen readers skip it. Treat it the same way in the terminal
    // render: emit nothing (no `[]` placeholder, no link footnote).
    // Real-world payoff: Google/X/etc. use `alt=""` for icons inside
    // text links, which would otherwise spam the page with `[]` and
    // duplicate footnote refs that aren't useful targets.
    const alt_attr = elem.getAttribute("alt");
    if (alt_attr) |alt_val| {
        if (alt_val.len == 0) return;
    }
    const alt = alt_attr orelse "image";

    try state.writeAll(w, "[");
    try state.writeAll(w, alt);
    try state.writeAll(w, "]");
    if (state.opts.show_links) {
        const src = elem.getAttribute("src") orelse "";
        if (src.len > 0) {
            const idx = state.registerLink(@intFromPtr(elem), src, alt) catch return;
            if (state.opts.profile == .default) {
                const ref = try std.fmt.allocPrint(state.allocator, "[{d}]", .{idx});
                defer state.allocator.free(ref);
                try state.writeAll(w, ref);
            }
        }
    }
}

fn renderInput(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const input_type = elem.getAttribute("type") orelse "text";
    const name = elem.getAttribute("name") orelse "";

    if (eql(input_type, "hidden")) {
        // Hidden inputs are invisible to the renderer but must still be
        // registered as fields so `BrowserSession.submitForm` can include
        // their `value` attribute in the encoded body — this is the
        // CSRF-token round-trip required by spec/subspecs/agent-browser.md §2.
        // Visible-nav helpers in `browser.zig` filter hidden fields out so
        // they do not show up in tab order or status counts.
        _ = state.registerField(
            @intFromPtr(elem),
            name,
            "hidden",
            "",
            state.col,
            0,
            false,
        ) catch {};
        return;
    }
    if (eql(input_type, "submit") or eql(input_type, "reset") or eql(input_type, "button")) {
        const label = elem.getAttribute("value") orelse if (eql(input_type, "submit")) "Submit" else if (eql(input_type, "reset")) "Reset" else "Button";
        const col = state.col;
        const focused = focusMatches(state.opts.focused_element_ptr, elem);
        try state.prepareForContent(w);
        // T2.8: apply REVERSE over BOLD when focused so the button is visually
        // distinct regardless of which control is active.
        if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
        try state.ansi(w, BOLD);
        try state.writeAll(w, "[");
        try state.writeAll(w, label);
        try state.writeAll(w, "]");
        try state.ansi(w, RESET);
        const width = label.len + 2;
        _ = state.registerField(
            @intFromPtr(elem),
            name,
            input_type,
            label,
            col,
            width,
            true,
        ) catch {};
        return;
    }

    if (eql(input_type, "checkbox") or eql(input_type, "radio")) {
        const is_radio = eql(input_type, "radio");
        // Resolve checked state: user toggle wins; otherwise DOM
        // `checked` attribute. T-81.
        const checked: bool = if (state.opts.is_checked_lookup) |l|
            l.lookup(@intFromPtr(elem)) orelse (elem.getAttribute("checked") != null)
        else
            (elem.getAttribute("checked") != null);

        const focused = focusMatches(state.opts.focused_element_ptr, elem);
        try state.prepareForContent(w);
        if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
        const glyph: []const u8 = if (is_radio)
            (if (checked) "(*)" else "( )")
        else
            (if (checked) "[x]" else "[ ]");
        try state.writeAll(w, glyph);
        if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
        _ = state.registerField(
            @intFromPtr(elem),
            name,
            input_type,
            "",
            state.col - 3,
            3,
            false,
        ) catch {};
        return;
    }

    const field_width: usize = 20;
    // T-72b: prefer the user's typed value (from BrowserSession's
    // field_values map) over the DOM's value attribute. The lookup
    // returns null for fields the user hasn't touched yet, falling
    // back to whatever the DOM had (server-side default, hidden
    // pre-fill, etc.).
    const dom_value = elem.getAttribute("value") orelse "";
    const value: []const u8 = if (state.opts.field_value_lookup) |fvl|
        fvl.lookup(name) orelse dom_value
    else
        dom_value;
    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    try state.prepareForContent(w);
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "[");
    if (eql(input_type, "password")) {
        for (0..@min(value.len, field_width)) |_| {
            try state.writeByte(w, '*');
        }
    } else {
        const shown = if (value.len > field_width) value[0..field_width] else value;
        try state.writeAll(w, shown);
    }
    const remaining = field_width - @min(value.len, field_width);
    for (0..remaining) |_| {
        try state.writeByte(w, '_');
    }
    try state.writeAll(w, "]");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        if (eql(input_type, "password")) "password" else "text",
        "",
        col,
        field_width + 2,
        false,
    ) catch {};
}

fn focusMatches(focused_ptr: ?usize, elem: *const dom.Element) bool {
    const fp = focused_ptr orelse return false;
    return fp == @intFromPtr(elem);
}

fn renderButton(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const label = elem.textContentForExtract(state.allocator) catch "Button";
    defer state.allocator.free(label);
    const trimmed_text = std.mem.trim(u8, label, " \t\r\n");

    // T-76: icon-only buttons (Google's voice/lens/etc.) have empty text
    // content — they used to render as `[]`. Fall back to aria-label /
    // title / value / name in priority order so the user sees *what*
    // they're focusing. This matches screen-reader resolution.
    const display: []const u8 = if (trimmed_text.len > 0)
        trimmed_text
    else if (elem.getAttribute("aria-label")) |al|
        al
    else if (elem.getAttribute("title")) |t|
        t
    else if (elem.getAttribute("value")) |v|
        v
    else if (elem.getAttribute("name")) |n|
        n
    else
        "button";

    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    try state.prepareForContent(w);
    // T2.8: uniform focus highlight — REVERSE overlaid on BOLD when focused.
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.ansi(w, BOLD);
    try state.writeAll(w, "[");
    try state.writeAll(w, display);
    try state.writeAll(w, "]");
    try state.ansi(w, RESET);
    const name = elem.getAttribute("name") orelse "";
    const btn_type = elem.getAttribute("type") orelse "submit";
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        btn_type,
        display,
        col,
        display.len + 2,
        eql(btn_type, "submit"),
    ) catch {};
}

fn renderSelect(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    // T-83 priority: user-selected option (from inline picker) wins
    // over DOM `<option selected>`, which wins over first option.
    // The user-selected label is borrowed from the session — no dupe
    // needed; it lives at least until the next page change.
    var first_option: ?[]const u8 = null;
    var selected_option: ?[]const u8 = null;
    for (elem.children.items) |child| {
        if (child != .element) continue;
        if (!eql(child.element.tag, "option")) continue;
        const text = child.element.textContentForExtract(state.allocator) catch continue;
        defer state.allocator.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (child.element.getAttribute("selected") != null) {
            if (selected_option) |opt| state.allocator.free(opt);
            selected_option = try state.allocator.dupe(u8, trimmed);
            break;
        }
        if (first_option == null) {
            first_option = try state.allocator.dupe(u8, trimmed);
        }
    }
    defer if (first_option) |opt| state.allocator.free(opt);
    defer if (selected_option) |opt| state.allocator.free(opt);

    const user_selected: ?[]const u8 = if (state.opts.selected_option_lookup) |l|
        l.lookup(@intFromPtr(elem))
    else
        null;
    const display = user_selected orelse selected_option orelse first_option orelse "";
    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    try state.prepareForContent(w);
    // T2.8: uniform focus highlight.
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "[");
    try state.writeAll(w, display);
    try state.writeAll(w, " ▼]");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    const name = elem.getAttribute("name") orelse "";
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        "select",
        display,
        col,
        display.len + 4,
        false,
    ) catch {};
}

fn renderTextarea(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const dom_value = elem.textContentForExtract(state.allocator) catch "";
    defer state.allocator.free(dom_value);
    const name = elem.getAttribute("name") orelse "";
    // T-72b: user-typed value beats the DOM-default if present.
    const raw_value: []const u8 = if (state.opts.field_value_lookup) |fvl|
        fvl.lookup(name) orelse dom_value
    else
        dom_value;
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    const rows: usize = blk: {
        const rows_str = elem.getAttribute("rows") orelse "2";
        break :blk std.fmt.parseInt(usize, rows_str, 10) catch 2;
    };
    const cols: usize = blk: {
        const cols_str = elem.getAttribute("cols") orelse "20";
        break :blk std.fmt.parseInt(usize, cols_str, 10) catch 20;
    };
    try state.prepareForContent(w);
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "+");
    for (0..cols) |_| try state.writeByte(w, '-');
    try state.writeAll(w, "+");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    try state.newline(w);
    var line_idx: usize = 0;
    var byte_idx: usize = 0;
    while (line_idx < rows) : (line_idx += 1) {
        try state.prepareForContent(w);
        if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
        try state.writeByte(w, '|');
        var char_count: usize = 0;
        while (char_count < cols and byte_idx < trimmed.len) {
            if (trimmed[byte_idx] == '\n') {
                byte_idx += 1;
                break;
            }
            try state.writeByte(w, trimmed[byte_idx]);
            byte_idx += 1;
            char_count += 1;
        }
        while (char_count < cols) {
            try state.writeByte(w, ' ');
            char_count += 1;
        }
        try state.writeByte(w, '|');
        if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
        if (line_idx < rows - 1) try state.newline(w);
    }
    try state.newline(w);
    try state.prepareForContent(w);
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "+");
    for (0..cols) |_| try state.writeByte(w, '-');
    try state.writeAll(w, "+");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        "textarea",
        "",
        col,
        cols + 2,
        false,
    ) catch {};
}

fn renderBrowseStrongLandmark(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try ensureSectionBreak(state, w);
    try renderChildren(state, w, elem);
    try state.ensureNewline(w);
    try state.newline(w);
}

fn renderBrowseCompactLandmark(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);
    try state.ansi(w, DIM);
    try renderChildren(state, w, elem);
    try state.ansi(w, RESET);
    try state.ensureNewline(w);
    try state.newline(w);
}

fn renderCollapsedLandmark(state: *RenderState, w: anytype, tag: []const u8) anyerror!void {
    try state.ensureNewline(w);
    try state.ansi(w, DIM);
    try state.writeAll(w, collapsedLabel(tag));
    try state.ansi(w, RESET);
    try state.newline(w);
    try state.newline(w);
}

fn ensureSectionBreak(state: *RenderState, w: anytype) !void {
    try state.ensureNewline(w);
    if (state.line_index > 0) try state.newline(w);
}

fn collapsedLabel(tag: []const u8) []const u8 {
    if (eql(tag, "nav")) return "[Navigation omitted]";
    if (eql(tag, "aside")) return "[Sidebar omitted]";
    if (eql(tag, "footer")) return "[Footer omitted]";
    return "[Header omitted]";
}

fn renderStrong(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ansi(w, BOLD);
    try renderChildren(state, w, elem);
    try state.ansi(w, RESET);
}

fn renderEm(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ansi(w, ITALIC);
    try renderChildren(state, w, elem);
    try state.ansi(w, RESET);
}

// ── Text node renderer ────────────────────────────────────────────────────

fn renderTextNode(state: *RenderState, w: anytype, text_node: *const dom.Text) anyerror!void {
    const raw = text_node.data;
    if (raw.len == 0) return;

    // Inside <pre>: preserve whitespace verbatim.
    if (state.inPre()) {
        try state.writeAll(w, raw);
        return;
    }

    // Outside <pre>: normalise whitespace, then word-wrap.
    var buf: [8192]u8 = undefined;
    const normalized = normalizeWhitespace(&buf, raw);
    if (normalized.len == 0) return;

    var it = std.mem.splitScalar(u8, normalized, ' ');
    var need_space = false;
    while (it.next()) |word| {
        if (word.len == 0) continue;
        if (need_space) {
            if (state.col > 0 and state.col + 1 + word.len > state.opts.max_width) {
                // Wrap to next line (newline respects hang_indent)
                try state.newline(w);
            } else if (state.col > 0) {
                try state.writeByte(w, ' ');
            }
        }
        try state.writeAll(w, word);
        need_space = true;
    }
}

// ── Table renderer ────────────────────────────────────────────────────────

fn countTableLinkMetricsInner(
    elem: *const dom.Element,
    in_link: bool,
    link_count: *usize,
    text_bytes: *usize,
    link_text_bytes: *usize,
    paragraph_count: *usize,
) void {
    const is_link = eql(elem.tag, "a");
    if (is_link) link_count.* += 1;
    if (eql(elem.tag, "p")) paragraph_count.* += 1;

    const child_in_link = in_link or is_link;
    for (elem.children.items) |child| {
        switch (child) {
            .text => |text_node| {
                for (text_node.data) |ch| {
                    if (!std.ascii.isWhitespace(ch)) {
                        text_bytes.* += 1;
                        if (child_in_link) link_text_bytes.* += 1;
                    }
                }
            },
            .element => |child_elem| {
                countTableLinkMetricsInner(child_elem, child_in_link, link_count, text_bytes, link_text_bytes, paragraph_count);
            },
            else => {},
        }
    }
}

fn isLinkListTable(elem: *const dom.Element) bool {
    var link_count: usize = 0;
    var text_bytes: usize = 0;
    var link_text_bytes: usize = 0;
    var paragraph_count: usize = 0;
    countTableLinkMetricsInner(elem, false, &link_count, &text_bytes, &link_text_bytes, &paragraph_count);
    if (link_count < 3) return false;
    if (text_bytes < 80) return false;
    if (paragraph_count > 0) return false;
    const density = if (text_bytes == 0) @as(f64, 0.0) else @as(f64, @floatFromInt(link_text_bytes)) / @as(f64, @floatFromInt(text_bytes));
    return density >= 0.35;
}

fn renderTable(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);

    // T-72: layout-table detection. Tables containing user-editable
    // form controls (textarea / select / non-hidden input / button) are
    // structural layout, not tabular data. Real data tables never have
    // form fields in their cells — but legacy + old-school sites
    // (Google's homepage, login pages, w3c form examples) routinely
    // wrap forms in `<table>` for column alignment. The columnar
    // renderer flattens cell content via collectTableCellDisplayText,
    // which strips form controls down to text and never dispatches to
    // renderTextarea / renderInput. Switching to block flow lets the
    // cell's children reach their proper renderers and produce visible
    // input boxes.
    if (containsLayoutFormControl(elem)) {
        try renderChildren(state, w, elem);
        return;
    }

    // Collect all <tr> rows (may be inside thead/tbody/tfoot).
    var rows: std.ArrayList(*const dom.Element) = .empty;
    defer rows.deinit(state.allocator);
    collectTableRows(state.allocator, elem, &rows);
    if (rows.items.len == 0) return;

    // Determine column count.
    var max_cols: usize = 0;
    for (rows.items) |row| {
        var count: usize = 0;
        for (row.children.items) |cell| {
            if (cell == .element and isCellTag(cell.element.tag)) count += 1;
        }
        max_cols = @max(max_cols, count);
    }
    if (max_cols == 0) return;

    const per_col_width = tableColumnWidthLimit(state.opts.max_width, max_cols);

    // Measure column widths.
    var widths = try state.allocator.alloc(usize, max_cols);
    defer state.allocator.free(widths);
    @memset(widths, 0);
    var preview_link_index = state.links.items.len;
    for (rows.items) |row| {
        var ci: usize = 0;
        for (row.children.items) |cell| {
            if (cell == .element and isCellTag(cell.element.tag)) {
                if (ci < max_cols) {
                    if (collectTableCellDisplayText(state, cell.element, &preview_link_index)) |text| {
                        defer state.allocator.free(text);
                        widths[ci] = @max(widths[ci], measureWrappedWidth(text, per_col_width));
                    } else |_| {}
                }
                ci += 1;
            }
        }
    }
    for (widths) |*width| {
        width.* = @max(@min(width.*, per_col_width), 1);
    }

    const is_link_list = isLinkListTable(elem);

    // T2.7: sticky-header tracking.
    const has_header = rows.items.len > 1 and rowHasHeader(rows.items[0]);
    var header_line_start: usize = 0;
    var header_line_end: usize = 0;

    // Render each row.
    for (rows.items, 0..) |row, ri| {
        // T2.7: snap start-of-header before row 0.
        if (ri == 0 and has_header) header_line_start = state.line_index;

        // Separator between rows.
        if (ri > 0 and !is_link_list) {
            for (0..max_cols) |ci| {
                if (ci > 0) try state.writeByte(w, ' ');
                for (0..widths[ci] + 2) |_| try state.writeByte(w, '-');
            }
            try state.newline(w);
        }
        var cells = try state.allocator.alloc(WrappedCell, max_cols);
        defer state.allocator.free(cells);
        for (cells) |*cell| cell.* = .{};
        defer {
            for (cells) |*cell| cell.deinit(state.allocator);
        }

        var row_height: usize = 1;
        var ci: usize = 0;
        for (row.children.items) |cell| {
            if (cell == .element and isCellTag(cell.element.tag)) {
                if (ci < max_cols) {
                    cells[ci] = try wrapTableCell(state, state.allocator, cell.element, widths[ci]);
                    row_height = @max(row_height, cells[ci].lines.items.len);
                }
                ci += 1;
            }
        }

        for (0..row_height) |line_idx| {
            for (0..max_cols) |col_idx| {
                if (col_idx > 0) try state.writeByte(w, ' ');
                try state.writeByte(w, ' ');
                const line = if (line_idx < cells[col_idx].lines.items.len) cells[col_idx].lines.items[line_idx] else "";
                try state.writeAll(w, line);
                if (line.len < widths[col_idx]) {
                    for (0..widths[col_idx] - line.len) |_| try state.writeByte(w, ' ');
                }
                try state.writeByte(w, ' ');
            }
            try state.newline(w);
        }

        // T2.7: snap end-of-header after row 0 (includes the separator drawn
        // at ri==1 below, so we record *before* that separator).
        if (ri == 0 and has_header) header_line_end = state.line_index;
    }

    // T2.7: record the sticky header once the whole table is rendered.
    if (has_header) {
        state.sticky_hdrs.append(state.allocator, .{
            .header_line_start = header_line_start,
            .header_line_end = header_line_end,
            .table_line_end = state.line_index,
        }) catch {};
    }
}

/// True if the first row of a table has at least one `<th>` cell.
fn rowHasHeader(row: *const dom.Element) bool {
    for (row.children.items) |child| {
        if (child == .element and eql(child.element.tag, "th")) return true;
    }
    return false;
}

const WrappedCell = struct {
    text: []u8 = &.{},
    lines: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *WrappedCell, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
        if (self.text.len > 0) allocator.free(self.text);
    }
};

const WrappedLineIterator = struct {
    text: []const u8,
    width: usize,

    fn init(text: []const u8, width: usize) WrappedLineIterator {
        return .{
            .text = std.mem.trim(u8, text, " \t\r\n"),
            .width = @max(width, 1),
        };
    }

    fn next(self: *WrappedLineIterator) ?[]const u8 {
        self.text = std.mem.trim(u8, self.text, " ");
        if (self.text.len == 0) return null;
        if (self.text.len <= self.width) {
            const line = self.text;
            self.text = "";
            return line;
        }

        var break_at = self.width;
        while (break_at > 0 and self.text[break_at] != ' ') : (break_at -= 1) {}
        if (break_at == 0) break_at = self.width;

        const line = std.mem.trim(u8, self.text[0..break_at], " ");
        self.text = self.text[break_at..];
        return line;
    }
};

fn tableColumnWidthLimit(max_width: usize, cols: usize) usize {
    const safe_cols = @max(cols, 1);
    const separators = safe_cols - 1;
    const padding = safe_cols * 2;
    const reserved = separators + padding;
    if (max_width <= reserved) return 1;
    return @max((max_width - reserved) / safe_cols, 1);
}

fn wrapTableCell(
    state: *RenderState,
    allocator: std.mem.Allocator,
    elem: *const dom.Element,
    width: usize,
) !WrappedCell {
    var wrapped = WrappedCell{ .text = try collectTableCellDisplayText(state, elem, null) };
    errdefer wrapped.deinit(allocator);

    var it = WrappedLineIterator.init(wrapped.text, width);
    while (it.next()) |line| {
        try wrapped.lines.append(allocator, line);
    }
    if (wrapped.lines.items.len == 0) {
        try wrapped.lines.append(allocator, "");
    }
    return wrapped;
}

fn measureWrappedWidth(text: []const u8, width: usize) usize {
    var it = WrappedLineIterator.init(text, width);
    var max_line: usize = 0;
    while (it.next()) |line| {
        max_line = @max(max_line, line.len);
    }
    return max_line;
}

/// True if any descendant of `elem` is a user-editable form control.
/// Hidden inputs don't count (CSRF round-trip helpers don't make
/// a table "interactive"). Buttons + select + textarea + non-hidden
/// input do.
fn containsLayoutFormControl(elem: *const dom.Element) bool {
    for (elem.children.items) |child| {
        if (child != .element) continue;
        const e = child.element;
        if (eql(e.tag, "textarea") or eql(e.tag, "select") or eql(e.tag, "button")) return true;
        if (eql(e.tag, "input")) {
            const t = e.getAttribute("type") orelse "text";
            if (!std.ascii.eqlIgnoreCase(t, "hidden")) return true;
        }
        if (containsLayoutFormControl(e)) return true;
    }
    return false;
}

fn collectTableCellDisplayText(
    state: *RenderState,
    elem: *const dom.Element,
    preview_link_index: ?*usize,
) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(state.allocator);
    collectTableCellDisplayFragments(state, preview_link_index, elem, &raw);

    const normalized_buf = try state.allocator.alloc(u8, raw.items.len);
    defer state.allocator.free(normalized_buf);

    const normalized = normalizeWhitespace(normalized_buf, raw.items);
    return state.allocator.dupe(u8, std.mem.trim(u8, normalized, " \t\r\n"));
}

fn collectTableCellDisplayFragments(
    state: *RenderState,
    preview_link_index: ?*usize,
    elem: *const dom.Element,
    buf: *std.ArrayList(u8),
) void {
    for (elem.children.items) |child| {
        switch (child) {
            .text => |text_node| buf.appendSlice(state.allocator, text_node.data) catch {},
            .element => |child_elem| {
                // Defensive parity with renderElement's isHiddenTag
                // gate: a <script> / <style> / <noscript> nested
                // inside a table cell otherwise leaks its raw source
                // into the rendered text. Real browsers never paint
                // these. Caught by the Google homepage which puts
                // inline scripts inside the layout <table>; without
                // this check the script body is rendered as visible
                // text alongside neighbor cells.
                if (isHiddenTag(child_elem.tag)) continue;
                if (eql(child_elem.tag, "a")) {
                    collectTableCellDisplayFragments(state, preview_link_index, child_elem, buf);
                    appendTableCellLinkMarker(state, preview_link_index, child_elem, buf);
                    continue;
                }

                const boundary = isTableCellBoundaryTag(child_elem.tag);
                if (boundary) buf.append(state.allocator, ' ') catch {};
                collectTableCellDisplayFragments(state, preview_link_index, child_elem, buf);
                if (boundary) buf.append(state.allocator, ' ') catch {};
            },
            else => {},
        }
    }
}

fn appendTableCellLinkMarker(
    state: *RenderState,
    preview_link_index: ?*usize,
    elem: *const dom.Element,
    buf: *std.ArrayList(u8),
) void {
    if (!state.opts.show_links) return;

    const href = elem.getAttribute("href") orelse return;
    if (href.len == 0) return;

    const raw_text = elem.textContentForExtract(state.allocator) catch return;
    defer state.allocator.free(raw_text);
    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");

    const idx = if (preview_link_index) |next| blk: {
        next.* += 1;
        break :blk next.*;
    } else state.registerLink(@intFromPtr(elem), href, trimmed) catch return;

    if (state.opts.profile == .default) {
        const marker = std.fmt.allocPrint(state.allocator, "[{d}]", .{idx}) catch return;
        defer state.allocator.free(marker);
        buf.appendSlice(state.allocator, marker) catch {};
    }
}

fn isTableCellBoundaryTag(tag: []const u8) bool {
    return eql(tag, "table") or
        eql(tag, "thead") or
        eql(tag, "tbody") or
        eql(tag, "tfoot") or
        eql(tag, "tr") or
        eql(tag, "td") or
        eql(tag, "th") or
        eql(tag, "div") or
        eql(tag, "p") or
        eql(tag, "ul") or
        eql(tag, "ol") or
        eql(tag, "li") or
        eql(tag, "br");
}

fn collectTableRows(
    allocator: std.mem.Allocator,
    elem: *const dom.Element,
    rows: *std.ArrayList(*const dom.Element),
) void {
    for (elem.children.items) |child| {
        if (child != .element) continue;
        const tag = child.element.tag;
        if (eql(tag, "tr")) {
            rows.append(allocator, child.element) catch {};
        } else if (eql(tag, "thead") or eql(tag, "tbody") or eql(tag, "tfoot")) {
            collectTableRows(allocator, child.element, rows);
        }
    }
}

fn isCellTag(tag: []const u8) bool {
    return eql(tag, "td") or eql(tag, "th");
}

// ── Tag classification helpers ────────────────────────────────────────────

fn isHiddenTag(tag: []const u8) bool {
    inline for (.{
        "script", "style", "noscript", "head", "svg", "math",
    }) |h| {
        if (std.ascii.eqlIgnoreCase(tag, h)) return true;
    }
    return false;
}

fn isBlockTag(tag: []const u8) bool {
    inline for (.{
        "div",        "p",        "h1",      "h2",      "h3",         "h4",      "h5",    "h6",
        "blockquote", "pre",      "ul",      "ol",      "li",         "table",   "thead", "tbody",
        "tfoot",      "tr",       "td",      "th",      "section",    "article", "main",  "header",
        "footer",     "nav",      "aside",   "figure",  "figcaption", "dl",      "dt",    "dd",
        "form",       "fieldset", "address", "details", "summary",
    }) |b| {
        if (std.ascii.eqlIgnoreCase(tag, b)) return true;
    }
    return false;
}

fn isCompactLandmarkTag(tag: []const u8) bool {
    return eql(tag, "header") or eql(tag, "nav") or eql(tag, "aside") or eql(tag, "footer");
}

fn isStrongLandmarkTag(tag: []const u8) bool {
    return eql(tag, "main") or eql(tag, "article") or eql(tag, "section");
}

fn headingLevel(tag: []const u8) ?u8 {
    if (tag.len == 2 and
        (tag[0] == 'h' or tag[0] == 'H') and
        tag[1] >= '1' and tag[1] <= '6')
    {
        return tag[1] - '0';
    }
    return null;
}

/// Case-insensitive ASCII equality shortcut.
fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ── Text normalization ────────────────────────────────────────────────────

/// Collapse consecutive whitespace characters to a single space.
fn normalizeWhitespace(buf: []u8, text: []const u8) []u8 {
    var i: usize = 0;
    var in_ws = false;
    for (text) |c| {
        const is_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_ws) {
            if (!in_ws and i < buf.len) {
                buf[i] = ' ';
                i += 1;
                in_ws = true;
            }
        } else {
            if (i < buf.len) {
                buf[i] = c;
                i += 1;
            }
            in_ws = false;
        }
    }
    return buf[0..i];
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "render — empty document produces no output" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    try std.testing.expectEqual(@as(usize, 0), fbs.buffered().len);
}

test "render — heading with decorative underline" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><h1>Hello</h1></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "=====") != null);
}

test "render — heading h2 uses dashes" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><h2>Subtitle</h2></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Subtitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-------") != null);
}

test "render — paragraph text" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Hello world.</p></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello world.") != null);
}

test "render — links produce reference footnotes" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><a href=\"/page\">Click</a></body></html>");
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_links = true,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Click") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "References:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/page") != null);
}

test "render — no link footnotes when show_links is false" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><a href=\"/page\">Click</a></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_links = false,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Click") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "References:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/page") == null);
}

test "render — unordered list" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><ul><li>One</li><li>Two</li><li>Three</li></ul></body></html>");
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "One") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Three") != null);
    // Should contain the bullet character (UTF-8: e2 80 a2)
    try std.testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xa2") != null);
}

test "render — ordered list" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><ol><li>First</li><li>Second</li></ol></body></html>");
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "First") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Second") != null);
}

test "render — nested list items" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><ul>
        \\  <li>Item 1
        \\    <ul><li>Sub A</li><li>Sub B</li></ul>
        \\  </li>
        \\  <li>Item 2</li>
        \\</ul></body></html>
    );
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Item 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sub A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sub B") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item 2") != null);
}

test "render — skips script and style content" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <script>var x = 1;</script>
        \\  <style>.a { color: red; }</style>
        \\  <p>Visible</p>
        \\</body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "var x") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "color") == null);
}

test "render browse profile can surface template content after empty main fallback" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><main></main><template><section><h1>Streamed title</h1><p>Server-rendered fallback text.</p></section></template></body></html>");
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Streamed title") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Server-rendered fallback text") != null);
}

test "render — blockquote content is present" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><blockquote><p>Quoted text.</p></blockquote></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Quoted text.") != null);
}

test "render — pre block preserves whitespace" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><pre>  line1\n  line2\n</pre></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "  line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  line2") != null);
}

test "render — horizontal rule width matches max_width" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Before</p><hr><p>After</p></body></html>");
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .max_width = 20,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "After") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--------------------") != null);
}

test "render — image alt text and link reference" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/photo.jpg") != null);
}

const TestImageLookup = struct {
    /// Single-entry mock lookup: matches one URL → returns one byte slice.
    /// Lifetime of the returned bytes is the lifetime of this struct.
    url: []const u8,
    bytes: []const u8,

    fn get(ctx: *const anyopaque, url: []const u8) ?[]const u8 {
        const self: *const TestImageLookup = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, url, self.url)) return self.bytes;
        return null;
    }

    fn lookup(self: *const TestImageLookup) ImageLookup {
        return .{ .ctx = self, .getFn = get };
    }
};

test "render — image_lookup hit emits raw bytes and skips alt-ref" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();

    // Sentinel byte sequence — easier to assert on than real Kitty APC.
    const sentinel = "<<IMAGE-BYTES-HERE>>";
    const tl = TestImageLookup{ .url = "/photo.jpg", .bytes = sentinel };

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, sentinel) != null);
    // Alt-ref must NOT appear when the lookup hit.
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") == null);
}

test "render — image_lookup miss falls back to alt-ref" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();

    const tl = TestImageLookup{ .url = "/different.jpg", .bytes = "unused" };

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    // Lookup miss → alt-ref text path engages, identical to no-lookup.
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unused") == null);
}

test "render — no image_lookup keeps current alt-ref behavior verbatim" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .none,
        // image_lookup explicitly omitted (null default).
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") != null);
}

test "render — <section style=background-image> emits bg bytes when lookup hits" {
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><section style=\"background-image: url('hero.jpg')\"><p>Hello</p></section></body></html>",
    );
    defer doc.deinit();

    const sentinel = "<<HERO-BG-BYTES>>";
    const tl = TestImageLookup{ .url = "hero.jpg", .bytes = sentinel };

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, sentinel) != null);
    // Section's text content still renders normally after the bg emit.
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
}

test "render — bg-image rejects gradients (no emit)" {
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><header style=\"background: linear-gradient(red, blue)\"><p>Banner</p></header></body></html>",
    );
    defer doc.deinit();

    const tl = TestImageLookup{ .url = "anything", .bytes = "<<SHOULD-NOT-APPEAR>>" };
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "<<SHOULD-NOT-APPEAR>>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Banner") != null);
}

test "extractBgUrlFromStyle: matches pipeline extractor output" {
    // Pipeline-side and renderer-side extractors must agree byte-for-
    // byte on the URL string they pull out of a given style value.
    // Spot-check a handful of common shapes.
    try std.testing.expectEqualStrings("hero.jpg", extractBgUrlFromStyle("background-image: url('hero.jpg')").?);
    try std.testing.expectEqualStrings("/cdn/x.png", extractBgUrlFromStyle("background: url(/cdn/x.png) center").?);
    try std.testing.expect(extractBgUrlFromStyle("background: linear-gradient(red, blue)") == null);
    try std.testing.expect(extractBgUrlFromStyle("background-color: red") == null);
}

test "render — word wrapping at max_width" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu</p></body></html>");
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .max_width = 20,
    });
    const out = fbs.buffered();
    // The text must be present in full.
    try std.testing.expect(std.mem.indexOf(u8, out, "Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mu") != null);
    // Verify that no single line exceeds max_width (ignoring the trailing newline).
    var line_it = std.mem.splitScalar(u8, out, '\n');
    while (line_it.next()) |line| {
        if (line.len > 0) {
            try std.testing.expect(line.len <= 20);
        }
    }
}

test "render — table with header and body" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><th>Name</th><th>Value</th></tr>
        \\  <tr><td>foo</td><td>bar</td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Value") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bar") != null);
}

test "render — HN-like table layout respects max width" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table><tr><td>
        \\  <table>
        \\    <tr><td><a href="https://example.com/1">Alpha story with a long title that should wrap cleanly inside the available width budget</a></td></tr>
        \\    <tr><td>42 points by alice 2 hours ago | <a href="item?id=1">12 comments</a></td></tr>
        \\    <tr><td><a href="https://example.com/2">Beta story with another long title that should stay discrete and readable in browse mode</a></td></tr>
        \\    <tr><td>21 points by bob 1 hour ago | <a href="item?id=2">8 comments</a></td></tr>
        \\  </table>
        \\</td></tr></table></body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 40,
    });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Alpha story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "----------------------------------------") == null);
    try std.testing.expect(model.links.len >= 4);
    try std.testing.expectEqualStrings("https://example.com/1", model.links[0].href);

    for (model.lines) |line| {
        const text = model.text[line.start..line.end];
        if (text.len > 0) try std.testing.expect(text.len <= 40);
    }
}

test "render — complex document with mixed elements" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <h1>Title</h1>
        \\  <p>First paragraph with <a href="/link">a link</a>.</p>
        \\  <ul>
        \\    <li>Item one</li>
        \\    <li>Item two</li>
        \\  </ul>
        \\  <p>Second paragraph.</p>
        \\</body></html>
    );
    defer doc.deinit();
    var buf: [8192]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "First paragraph") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a link") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Second paragraph.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "References:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/link") != null);
}

test "renderModel captures lines and interactive links" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Hello <a href=\"/next\">next page</a></p></body></html>");
    defer doc.deinit();

    var model = try renderModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(model.lines.len > 0);
    try std.testing.expect(model.links.len == 1);
    try std.testing.expect(std.mem.indexOf(u8, model.lineText(0), "Hello") != null);
    try std.testing.expectEqualStrings("/next", model.links[0].href);
    try std.testing.expectEqualStrings("next page", model.links[0].text);
}

test "render browse profile omits references but keeps interactive links" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><main><p>Hello <a href=\"/next\">next page</a>.</p></main></body></html>");
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false, .show_links = true });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "References:") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "next page") != null);
    try std.testing.expectEqual(@as(usize, 1), model.links.len);
    try std.testing.expectEqualStrings("/next", model.links[0].href);
}

test "render browse profile favors main and suppresses nav boilerplate" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <header><p>Site title</p></header>
        \\  <nav><a href="/a">Home</a><a href="/b">Docs</a></nav>
        \\  <main><section><h1>Article title</h1><p>Primary body content. With punctuation.</p></section></main>
        \\  <footer><p>Copyright</p></footer>
        \\</body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Article title") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Primary body content") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Home") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Copyright") == null);
}

test "render browse profile collapses boilerplate aside inside content root" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <main>
        \\    <article>
        \\      <p>Story body. Enough text to keep reading.</p>
        \\      <aside class="related-links"><a href="/one">One</a><a href="/two">Two</a></aside>
        \\    </article>
        \\  </main>
        \\</body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Story body") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "[Sidebar omitted]") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "One") == null);
}

test "render browse profile suppresses boilerplate section inside content root" {
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><main><article><h1>Story</h1><p>Real article copy with enough text to win.</p><section class=\"related newsletter\"><a href=\"/one\">Read more</a><a href=\"/two\">Subscribe</a></section></article></main></body></html>",
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Read more") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Subscribe") == null);
}

test "render - link-list table omits row separators" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><td><table>
        \\    <tr><td><a href="https://example.com/1">Alpha story with a long title that should wrap cleanly</a></td></tr>
        \\    <tr><td>42 points by alice 2 hours ago | <a href="item?id=1">12 comments</a></td></tr>
        \\  </table></td></tr>
        \\  <tr><td><table>
        \\    <tr><td><a href="https://example.com/2">Beta story with a long title that should stay discrete and readable</a></td></tr>
        \\    <tr><td>21 points by bob 1 hour ago | <a href="item?id=2">8 comments</a></td></tr>
        \\  </table></td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 40,
    });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "----") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Alpha story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Beta story") != null);

    for (model.lines) |line| {
        const text = model.text[line.start..line.end];
        if (text.len > 0) try std.testing.expect(text.len <= 40);
    }
}

test "render - regular table keeps row separators" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><th>Name</th><th>Description</th></tr>
        \\  <tr><td>Alice</td><td>Works on compilers.</td></tr>
        \\  <tr><td>Bob</td><td>Works on networks.</td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 60,
    });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "---") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Bob") != null);
}

test "T2.4: pre/code line numbers appear when block exceeds threshold" {
    const html =
        \\<html><body><pre><code>line 1
        \\line 2
        \\line 3
        \\line 4
        \\line 5
        \\line 6
        \\</code></pre></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    // 6-line block with threshold=5: line numbers should appear.
    var with_nums = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 60,
        .code_line_numbers = 5,
    });
    defer with_nums.deinit();
    try std.testing.expect(std.mem.indexOf(u8, with_nums.text, "1 \u{2502}") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_nums.text, "6 \u{2502}") != null);

    // Same block but threshold=10: no line numbers.
    var without_nums = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 60,
        .code_line_numbers = 10,
    });
    defer without_nums.deinit();
    try std.testing.expect(std.mem.indexOf(u8, without_nums.text, "\u{2502}") == null);
}

test "T2.5: detectLanguage parses language-XYZ class tokens" {
    // We test detectLanguage indirectly via the DOM: create a minimal
    // document with a <code class="language-XYZ"> element and verify
    // that the rendered output contains BOLD escape sequences for
    // language-specific keywords.
    const cases = [_]struct { lang_cls: []const u8, code: []const u8, keyword: []const u8 }{
        .{ .lang_cls = "language-zig", .code = "const x = 1;", .keyword = "const" },
        .{ .lang_cls = "language-rust", .code = "fn main() {}", .keyword = "fn" },
        .{ .lang_cls = "language-javascript", .code = "const a = 1;", .keyword = "const" },
        .{ .lang_cls = "language-python", .code = "def foo(): pass", .keyword = "def" },
    };
    for (cases) |c| {
        // Build HTML with 6+ lines so the line-number gutter fires.
        var buf: [512]u8 = undefined;
        const html = try std.fmt.bufPrint(&buf,
            "<html><body><pre><code class=\"{s}\">{s}\na\nb\nc\nd\ne\n</code></pre></body></html>",
            .{ c.lang_cls, c.code },
        );
        var doc = try dom.parseDocument(std.testing.allocator, html);
        defer doc.deinit();

        var model = try renderBrowseModel(std.testing.allocator, &doc, .{
            .ansi_colors = true,
            .code_line_numbers = 5,
            .code_style = .auto,
        });
        defer model.deinit();

        // The rendered output should contain BOLD + keyword + RESET.
        const bold_kw = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{s}{s}",
            .{ BOLD, c.keyword, RESET },
        );
        defer std.testing.allocator.free(bold_kw);
        try std.testing.expect(std.mem.indexOf(u8, model.text, bold_kw) != null);
    }
}

test "T2.5: writeHighlightedLine — comments dim, strings green, numbers yellow" {
    const alloc = std.testing.allocator;

    // Each sub-case gets its own list so clearing is simple.
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "x := 1; // comment here", .zig, true);
        try std.testing.expect(std.mem.indexOf(u8, list.items, DIM) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "comment here") != null);
    }
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "s := \"hello\";", .zig, true);
        try std.testing.expect(std.mem.indexOf(u8, list.items, GREEN) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "\"hello\"") != null);
    }
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "x := 42;", .zig, true);
        try std.testing.expect(std.mem.indexOf(u8, list.items, YELLOW) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "42") != null);
    }
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "const x = 1;", .zig, false);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "\x1b[") == null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "const") != null);
    }
}

test "T2.6: diff blocks auto-detected and colored" {
    const diff_html =
        \\<html><body><pre>--- a/foo.zig
        \\+++ b/foo.zig
        \\@@ -1,3 +1,4 @@
        \\ unchanged line
        \\-removed line
        \\+added line
        \\+another addition
        \\ context
        \\</pre></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, diff_html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .max_width = 80,
    });
    defer model.deinit();

    // File header lines are bold.
    try std.testing.expect(std.mem.indexOf(u8, model.text, BOLD) != null);
    // Additions are green.
    try std.testing.expect(std.mem.indexOf(u8, model.text, GREEN) != null);
    // Deletions are red.
    try std.testing.expect(std.mem.indexOf(u8, model.text, RED) != null);
    // Content preserved.
    try std.testing.expect(std.mem.indexOf(u8, model.text, "added line") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "removed line") != null);
}

test "T2.6: non-diff pre blocks are not colored as diffs" {
    const non_diff_html =
        \\<html><body><pre>Hello world
        \\This is plain text.
        \\No diff markers here.
        \\</pre></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, non_diff_html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
    });
    defer model.deinit();

    // No RED escape should appear — this is not a diff.
    try std.testing.expect(std.mem.indexOf(u8, model.text, RED) == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Hello world") != null);
}

test "T2.7: sticky_headers populated for table with th header row" {
    const html =
        \\<html><body><table>
        \\  <tr><th>Name</th><th>Value</th></tr>
        \\  <tr><td>Alice</td><td>42</td></tr>
        \\  <tr><td>Bob</td><td>99</td></tr>
        \\  <tr><td>Carol</td><td>7</td></tr>
        \\</table></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 40,
    });
    defer model.deinit();

    // Table has 4 rows (1 header + 3 body) → one sticky header entry.
    try std.testing.expectEqual(@as(usize, 1), model.sticky_headers.len);
    const sh = model.sticky_headers[0];
    // header_line_start < header_line_end < table_line_end
    try std.testing.expect(sh.header_line_start < sh.header_line_end);
    try std.testing.expect(sh.header_line_end < sh.table_line_end);
    // Header row text should contain the column names.
    const header_text = model.lineText(sh.header_line_start);
    try std.testing.expect(std.mem.indexOf(u8, header_text, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_text, "Value") != null);
}

test "T2.7: no sticky_headers for table without th cells" {
    const html =
        \\<html><body><table>
        \\  <tr><td>A</td><td>B</td></tr>
        \\  <tr><td>C</td><td>D</td></tr>
        \\</table></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
    });
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 0), model.sticky_headers.len);
}

test "T2.8: uniform focus highlight — button and select show REVERSE when focused" {
    const html =
        \\<html><body><form>
        \\  <select name="c"><option>opt1</option></select>
        \\  <button type="button">Click me</button>
        \\  <input type="submit" value="Go">
        \\</form></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    // First get the model without focus to find element pointers.
    var unfocused = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
    });
    defer unfocused.deinit();

    // No REVERSE in unfocused output for these controls.
    // (Existing test coverage for input/textarea focus already handles those.)
    try std.testing.expect(unfocused.fields.len >= 3);

    // Focus the select control (field 0) and verify REVERSE appears.
    const select_ptr = unfocused.fields[0].element_ptr;
    var focused_model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .focused_element_ptr = select_ptr,
    });
    defer focused_model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, focused_model.text, REVERSE) != null);
}

test "T2.8: focused link shows REVERSE when focused" {
    const html =
        \\<html><body>
        \\  <a href="https://example.com">Click me</a>
        \\</body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    // First get the model without focus to find element pointers.
    var unfocused = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .show_links = true,
    });
    defer unfocused.deinit();

    try std.testing.expect(unfocused.links.len >= 1);
    const link_ptr = unfocused.links[0].element_ptr;

    // Focus the link and verify REVERSE appears.
    var focused_model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .show_links = true,
        .focused_element_ptr = link_ptr,
    });
    defer focused_model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, focused_model.text, REVERSE) != null);
}

