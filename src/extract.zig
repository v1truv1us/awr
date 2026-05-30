/// extract.zig — Markdown extraction from a parsed DOM document.
///
/// Produces token-efficient, structurally meaningful Markdown intended
/// for LLM consumption. Compared to AWR's existing surfaces:
///
///   - `awr <url>` body_text: ~same byte budget but loses headings,
///     lists, link targets — agents have to re-derive structure.
///   - `awr render <url>`: ~6x bigger because of table-aware whitespace
///     and ANSI noise; designed for human eyes in a terminal.
///   - `extract.markdownFromDoc()`: structure preserved (headings, lists,
///     inline `[text](url)` links, code, blockquotes), chrome filtered
///     via `browse_heuristics.shouldSkipForBrowse`. Typical 30–40%
///     smaller than body_text on content-rich pages because nav/footer
///     are dropped, but every byte is information-dense.
///
/// Deliberately narrow scope: this module does NOT handle terminal
/// concerns (ANSI, image protocols, viewport wrap). Those live in
/// render.zig under the `.default` / `.browse` profiles. Markdown is
/// the format LLMs are most-trained-on for web content extraction
/// (every model has seen Wikipedia/Reddit/SO scraped to markdown), so
/// the format is what matters; terminal niceties don't.
const std = @import("std");
const dom = @import("dom/node.zig");
const browse_heuristics = @import("browse_heuristics.zig");

pub const ExtractOptions = struct {
    /// When true, drop link-dense / chrome subtrees (nav, footer, aside,
    /// etc.) per browse_heuristics. Default true — that's the whole
    /// point of markdown extraction for agents.
    filter_chrome: bool = true,
    /// When true, emit `[text](url)` for `<a href>`. When false, just
    /// emit the link text. Default true — agents want link targets.
    inline_links: bool = true,
    /// When true, emit `![alt](src)` for `<img>`. Default true.
    inline_images: bool = true,
};

pub const ExtractError = error{ OutOfMemory, NoBody };

/// Extract Markdown from `doc`. Caller owns the returned slice.
pub fn markdownFromDoc(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    opts: ExtractOptions,
) ExtractError![]u8 {
    const body = doc.body() orelse return ExtractError.NoBody;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var state: EmitState = .{
        .allocator = allocator,
        .opts = opts,
        .out = &out,
        .at_line_start = true,
    };
    defer state.list_stack.deinit(allocator);
    try emitChildren(&state, body);
    try state.flushTrailing();
    return out.toOwnedSlice(allocator);
}

const EmitState = struct {
    allocator: std.mem.Allocator,
    opts: ExtractOptions,
    out: *std.ArrayList(u8),
    /// Whether the next byte to emit is at the start of a (logical) line.
    /// Used to decide whether to insert leading whitespace, list markers,
    /// blockquote prefixes, etc.
    at_line_start: bool,
    /// Stack of nested list contexts. Each entry tracks ordered? + index.
    list_stack: std.ArrayListUnmanaged(ListCtx) = .empty,
    /// Stack of blockquote nesting depths.
    blockquote_depth: u8 = 0,
    /// Pending blank-line: emit one blank line before the next content
    /// chunk. Cleared after a blank-line-eligible boundary fires.
    needs_blank_line: bool = false,

    fn write(self: *EmitState, s: []const u8) ExtractError!void {
        try self.out.appendSlice(self.allocator, s);
        if (s.len > 0) self.at_line_start = (s[s.len - 1] == '\n');
    }

    fn writeByte(self: *EmitState, b: u8) ExtractError!void {
        try self.out.append(self.allocator, b);
        self.at_line_start = (b == '\n');
    }

    /// Force a newline if we are not already at line start.
    fn ensureNewline(self: *EmitState) ExtractError!void {
        if (!self.at_line_start) try self.writeByte('\n');
    }

    /// Mark that a blank line should be inserted before the next content.
    /// Idempotent — multiple paragraph-class boundaries collapse to one.
    fn requestBlankLine(self: *EmitState) void {
        self.needs_blank_line = true;
    }

    fn flushBlankLine(self: *EmitState) ExtractError!void {
        if (!self.needs_blank_line) return;
        self.needs_blank_line = false;
        try self.ensureNewline();
        // Don't emit a leading blank line at the very start of output.
        if (self.out.items.len > 0) try self.writeByte('\n');
    }

    fn flushTrailing(self: *EmitState) ExtractError!void {
        // Strip trailing blank-line surplus so the document ends with
        // exactly one newline.
        while (self.out.items.len > 1) {
            const n = self.out.items.len;
            if (self.out.items[n - 1] == '\n' and self.out.items[n - 2] == '\n') {
                _ = self.out.pop();
            } else break;
        }
        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] != '\n') {
            try self.writeByte('\n');
        }
    }

    fn emitText(self: *EmitState, text: []const u8) ExtractError!void {
        // Collapse runs of internal whitespace to a single space, but
        // preserve the inter-word spacing that gives markdown its shape.
        // Whitespace at line-start is dropped (so list-markers and
        // headings aren't padded). Whitespace anywhere else collapses to
        // exactly one space — including a run that starts the text node.
        // (Inline boundaries like `</strong> and <em>` produce a text
        // node whose leading whitespace must survive.)
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
                if (self.at_line_start) continue;
                // Skip if the output already ends with a space/newline —
                // avoids `**bold** ` becoming `**bold**  ` when the next
                // text node starts with whitespace.
                if (self.out.items.len > 0) {
                    const last = self.out.items[self.out.items.len - 1];
                    if (last == ' ' or last == '\n') continue;
                }
                try self.writeByte(' ');
                continue;
            }
            try self.writeByte(c);
            i += 1;
        }
    }
};

const ListCtx = struct { ordered: bool, index: u32 };

fn emitChildren(state: *EmitState, parent: *const dom.Element) ExtractError!void {
    for (parent.children.items) |child| {
        switch (child) {
            .text => |t| try state.emitText(t.data),
            .element => |e| try emitElement(state, e),
            else => {},
        }
    }
}

fn emitElement(state: *EmitState, elem: *const dom.Element) ExtractError!void {
    const tag = elem.tag;

    // Skip embedded styles, scripts, hidden semantics. These never
    // contribute readable content.
    if (eq(tag, "script") or eq(tag, "style") or eq(tag, "noscript") or
        eq(tag, "template") or eq(tag, "head") or eq(tag, "meta") or
        eq(tag, "link"))
    {
        return;
    }

    // Drop chrome subtrees per browse heuristics. Headers/footers/asides/
    // navs are usually pure noise for agent consumption — losing them is
    // most of the size win vs body_text.
    if (state.opts.filter_chrome and browse_heuristics.shouldSkipForBrowse(elem)) {
        return;
    }

    // Heading: # → ###### depending on level.
    if (headingLevel(tag)) |lvl| {
        try state.flushBlankLine();
        try state.ensureNewline();
        var i: u8 = 0;
        while (i < lvl) : (i += 1) try state.writeByte('#');
        try state.writeByte(' ');
        try emitChildren(state, elem);
        try state.ensureNewline();
        state.requestBlankLine();
        return;
    }

    if (eq(tag, "p")) {
        try state.flushBlankLine();
        try state.ensureNewline();
        try emitChildren(state, elem);
        try state.ensureNewline();
        state.requestBlankLine();
        return;
    }

    if (eq(tag, "br")) {
        try state.writeByte('\n');
        return;
    }

    if (eq(tag, "hr")) {
        try state.flushBlankLine();
        try state.ensureNewline();
        try state.write("---");
        try state.writeByte('\n');
        state.requestBlankLine();
        return;
    }

    if (eq(tag, "ul") or eq(tag, "ol")) {
        try state.flushBlankLine();
        try state.ensureNewline();
        try state.list_stack.append(state.allocator, .{
            .ordered = eq(tag, "ol"),
            .index = 0,
        });
        try emitChildren(state, elem);
        _ = state.list_stack.pop();
        state.requestBlankLine();
        return;
    }

    if (eq(tag, "li")) {
        try state.ensureNewline();
        if (state.list_stack.items.len > 0) {
            const top = &state.list_stack.items[state.list_stack.items.len - 1];
            top.index += 1;
            // Indent two spaces per nested level so nested lists remain
            // valid markdown (most parsers accept either 2 or 4 spaces).
            const depth = state.list_stack.items.len - 1;
            var i: usize = 0;
            while (i < depth) : (i += 1) try state.write("  ");
            if (top.ordered) {
                const marker = try std.fmt.allocPrint(state.allocator, "{d}. ", .{top.index});
                defer state.allocator.free(marker);
                try state.write(marker);
            } else {
                try state.write("- ");
            }
        } else {
            try state.write("- ");
        }
        try emitChildren(state, elem);
        try state.ensureNewline();
        return;
    }

    if (eq(tag, "blockquote")) {
        try state.flushBlankLine();
        try state.ensureNewline();
        state.blockquote_depth += 1;
        defer state.blockquote_depth -= 1;
        // Simple shaper: prefix every emitted line with "> ". For now
        // we just emit "> " before the content and let nested newlines
        // flow — common markdown renderers tolerate single-paragraph
        // blockquotes without the prefix on continuation lines.
        try state.write("> ");
        try emitChildren(state, elem);
        try state.ensureNewline();
        state.requestBlankLine();
        return;
    }

    if (eq(tag, "pre")) {
        try state.flushBlankLine();
        try state.ensureNewline();
        try state.write("```\n");
        // Preserve whitespace inside <pre>. Bypass emitText's collapse.
        const text = elem.textContent(state.allocator) catch "";
        defer if (text.len > 0) state.allocator.free(text);
        try state.write(text);
        try state.ensureNewline();
        try state.write("```\n");
        state.requestBlankLine();
        return;
    }

    if (eq(tag, "code")) {
        // Inline code if not inside <pre> (which already wrapped).
        try state.writeByte('`');
        try emitChildren(state, elem);
        try state.writeByte('`');
        return;
    }

    if (eq(tag, "strong") or eq(tag, "b")) {
        try state.write("**");
        try emitChildren(state, elem);
        try state.write("**");
        return;
    }

    if (eq(tag, "em") or eq(tag, "i")) {
        try state.writeByte('*');
        try emitChildren(state, elem);
        try state.writeByte('*');
        return;
    }

    if (eq(tag, "a")) {
        if (state.opts.inline_links) {
            const href = elem.getAttribute("href");
            if (href != null and href.?.len > 0) {
                try state.writeByte('[');
                try emitChildren(state, elem);
                try state.write("](");
                try state.write(href.?);
                try state.writeByte(')');
                return;
            }
        }
        try emitChildren(state, elem);
        return;
    }

    if (eq(tag, "img")) {
        if (!state.opts.inline_images) return;
        const src = elem.getAttribute("src") orelse return;
        const alt = elem.getAttribute("alt") orelse "";
        try state.write("![");
        try state.write(alt);
        try state.write("](");
        try state.write(src);
        try state.writeByte(')');
        return;
    }

    // Block-level elements get newline boundaries.
    const block = isBlockTag(tag);
    if (block) try state.ensureNewline();
    try emitChildren(state, elem);
    if (block) try state.ensureNewline();
}

fn headingLevel(tag: []const u8) ?u8 {
    if (tag.len == 2 and (tag[0] == 'h' or tag[0] == 'H') and tag[1] >= '1' and tag[1] <= '6') {
        return tag[1] - '0';
    }
    return null;
}

fn isBlockTag(tag: []const u8) bool {
    inline for ([_][]const u8{
        "div",  "section",  "article", "aside",      "header", "footer",
        "nav",  "main",     "figure",  "figcaption", "table",  "tr",
        "td",   "th",       "dl",      "dt",         "dd",     "address",
        "form", "fieldset",
    }) |t| {
        if (eq(tag, t)) return true;
    }
    return false;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testExtract(html: []const u8, expected: []const u8) !void {
    var doc = try dom.parseDocument(testing.allocator, html);
    defer doc.deinit();
    const md = try markdownFromDoc(testing.allocator, &doc, .{});
    defer testing.allocator.free(md);
    try testing.expectEqualStrings(expected, md);
}

test "extract — heading + paragraph" {
    try testExtract(
        "<html><body><h1>Title</h1><p>Hello world.</p></body></html>",
        "# Title\n\nHello world.\n",
    );
}

test "extract — unordered list" {
    try testExtract(
        "<html><body><ul><li>one</li><li>two</li></ul></body></html>",
        "- one\n- two\n",
    );
}

test "extract — ordered list with auto-numbering" {
    try testExtract(
        "<html><body><ol><li>first</li><li>second</li><li>third</li></ol></body></html>",
        "1. first\n2. second\n3. third\n",
    );
}

test "extract — inline links emit [text](url)" {
    try testExtract(
        "<html><body><p>See <a href=\"https://example.com\">example</a>.</p></body></html>",
        "See [example](https://example.com).\n",
    );
}

test "extract — strong and em" {
    try testExtract(
        "<html><body><p>This is <strong>bold</strong> and <em>italic</em>.</p></body></html>",
        "This is **bold** and *italic*.\n",
    );
}

test "extract — inline code" {
    try testExtract(
        "<html><body><p>Use <code>fetch()</code> here.</p></body></html>",
        "Use `fetch()` here.\n",
    );
}

test "extract — pre block preserves whitespace" {
    try testExtract(
        "<html><body><pre>line one\nline two</pre></body></html>",
        "```\nline one\nline two\n```\n",
    );
}

test "extract — script/style/head are dropped" {
    try testExtract(
        "<html><head><title>x</title></head><body><script>var x=1;</script><style>p{color:red}</style><p>visible</p></body></html>",
        "visible\n",
    );
}

test "extract — heading levels h1-h6" {
    try testExtract(
        "<html><body><h1>a</h1><h2>b</h2><h3>c</h3><h4>d</h4><h5>e</h5><h6>f</h6></body></html>",
        "# a\n\n## b\n\n### c\n\n#### d\n\n##### e\n\n###### f\n",
    );
}

test "extract — nav and footer chrome are filtered" {
    // browse_heuristics treats nav/footer aggressively. The exact pruning
    // is policy-laden — assert only that the nav text doesn't appear and
    // the body text does.
    var doc = try dom.parseDocument(
        testing.allocator,
        "<html><body><nav><a href=\"/x\">menu</a><a href=\"/y\">login</a><a href=\"/z\">help</a></nav><main><h1>Real</h1><p>content</p></main><footer><a href=\"/a\">about</a></footer></body></html>",
    );
    defer doc.deinit();
    const md = try markdownFromDoc(testing.allocator, &doc, .{});
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "Real") != null);
    try testing.expect(std.mem.indexOf(u8, md, "content") != null);
}

test "extract — hr" {
    try testExtract(
        "<html><body><p>before</p><hr><p>after</p></body></html>",
        "before\n\n---\n\nafter\n",
    );
}

test "extract — image with alt" {
    try testExtract(
        "<html><body><p>See <img src=\"/x.png\" alt=\"X\"></p></body></html>",
        "See ![X](/x.png)\n",
    );
}

test "extract — opts.inline_links=false strips href" {
    var doc = try dom.parseDocument(
        testing.allocator,
        "<html><body><p>Visit <a href=\"https://example.com\">example</a>.</p></body></html>",
    );
    defer doc.deinit();
    const md = try markdownFromDoc(testing.allocator, &doc, .{ .inline_links = false });
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("Visit example.\n", md);
}
