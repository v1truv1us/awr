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

// ── Public types ──────────────────────────────────────────────────────────

pub const RenderProfile = enum {
    default,
    browse,
};

pub const RenderOptions = struct {
    max_width: usize = 80,
    ansi_colors: bool = true,
    show_links: bool = true,
    show_images: bool = true,
    profile: RenderProfile = .default,
};

pub const ScreenLink = struct {
    index: usize,
    href: []const u8,
    text: []const u8,
    line: usize,
};

pub const ScreenLine = struct {
    start: usize,
    end: usize,
};

pub const ScreenModel = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    lines: []ScreenLine,
    links: []ScreenLink,

    pub fn deinit(self: *ScreenModel) void {
        for (self.links) |link| {
            self.allocator.free(link.href);
            self.allocator.free(link.text);
        }
        self.allocator.free(self.links);
        self.allocator.free(self.lines);
        self.allocator.free(self.text);
    }

    pub fn lineText(self: *const ScreenModel, index: usize) []const u8 {
        const line = self.lines[index];
        return self.text[line.start..line.end];
    }
};

// ── Internal types ────────────────────────────────────────────────────────

const LinkRef = struct {
    index: usize,
    href: []const u8,
    text: []const u8,
    line: usize,
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

    fn deinit(self: *RenderState) void {
        for (self.links.items) |link| {
            self.allocator.free(link.href);
            self.allocator.free(link.text);
        }
        self.links.deinit(self.allocator);
    }

    /// Emit pending hang-indent whitespace before actual content.
    fn prepareForContent(self: *RenderState, w: anytype) !void {
        if (self.at_line_start and self.hang_indent > 0) {
            for (0..self.hang_indent) |_| try w.writeByte(' ');
            self.col = self.hang_indent;
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
            try w.writeByte(byte);
            self.col += 1;
        }
    }

    /// Write a byte slice, correctly tracking column across newlines.
    fn writeAll(self: *RenderState, w: anytype, bytes: []const u8) !void {
        var start: usize = 0;
        for (bytes, 0..) |byte, i| {
            if (byte == '\n') {
                if (i > start) {
                    try self.prepareForContent(w);
                    try w.writeAll(bytes[start..i]);
                    self.col += i - start;
                    self.at_line_start = false;
                }
                try w.writeByte('\n');
                self.col = 0;
                self.at_line_start = true;
                self.line_index += 1;
                start = i + 1;
            }
        }
        if (start < bytes.len) {
            try self.prepareForContent(w);
            try w.writeAll(bytes[start..]);
            self.col += bytes.len - start;
            self.at_line_start = false;
        }
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

    fn registerLink(self: *RenderState, href: []const u8, text: []const u8) !usize {
        const idx = self.links.items.len + 1;
        try self.links.append(self.allocator, .{
            .index = idx,
            .href = try self.allocator.dupe(u8, href),
            .text = try self.allocator.dupe(u8, text),
            .line = self.line_index,
        });
        return idx;
    }
};

// ── ANSI constants ────────────────────────────────────────────────────────

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const UNDERLINE = "\x1b[4m";
const ITALIC = "\x1b[3m";
const CYAN = "\x1b[36m";

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

        if (opts.profile == .default and opts.show_links and state.links.items.len > 0) {
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

    return buildScreenModel(allocator, try buf.toOwnedSlice(allocator), state.links.items);
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
            .index = link.index,
            .href = try allocator.dupe(u8, link.href),
            .text = try allocator.dupe(u8, link.text),
            .line = link.line,
        };
        built_links += 1;
    }

    return .{
        .allocator = allocator,
        .text = text,
        .lines = lines,
        .links = links,
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

    const text = elem.textContent(state.allocator) catch return;
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
    // Render visible text (underlined)
    try state.ansi(w, UNDERLINE);
    try renderChildren(state, w, elem);
    try state.ansi(w, RESET);

    if (state.opts.show_links) {
        const href = elem.getAttribute("href") orelse "";
        if (href.len > 0) {
            const raw_text = elem.textContent(state.allocator) catch return;
            defer state.allocator.free(raw_text);
            const idx = state.registerLink(href, std.mem.trim(u8, raw_text, " \t\r\n")) catch return;
            if (state.opts.profile == .default) {
                const ref = try std.fmt.allocPrint(state.allocator, "[{d}]", .{idx});
                defer state.allocator.free(ref);
                try state.ansi(w, DIM);
                try state.writeAll(w, ref);
                try state.ansi(w, RESET);
            }
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
    state.pre_depth += 1;
    try renderChildren(state, w, elem);
    state.pre_depth -= 1;
    try state.ensureNewline(w);
}

fn renderCode(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const text = elem.textContent(state.allocator) catch return;
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

fn renderImage(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    if (!state.opts.show_images) return;
    const alt = elem.getAttribute("alt") orelse "image";
    try state.writeAll(w, "[");
    try state.writeAll(w, alt);
    try state.writeAll(w, "]");
    if (state.opts.show_links) {
        const src = elem.getAttribute("src") orelse "";
        if (src.len > 0) {
            const idx = state.registerLink(src, alt) catch return;
            if (state.opts.profile == .default) {
                const ref = try std.fmt.allocPrint(state.allocator, "[{d}]", .{idx});
                defer state.allocator.free(ref);
                try state.writeAll(w, ref);
            }
        }
    }
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

    // Render each row.
    for (rows.items, 0..) |row, ri| {
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
    }
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

    const raw_text = elem.textContent(state.allocator) catch return;
    defer state.allocator.free(raw_text);
    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");

    const idx = if (preview_link_index) |next| blk: {
        next.* += 1;
        break :blk next.*;
    } else state.registerLink(href, trimmed) catch return;

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
        "script", "style", "noscript", "head", "template", "svg", "math",
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
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Beta story") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, model.text, "[1]") == null);
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
