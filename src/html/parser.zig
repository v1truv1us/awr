/// parser.zig — Lexbor HTML parser wrapper for AWR Phase 2.
///
/// Thin Zig wrapper around the Lexbor C HTML parser.
/// Parses an HTML byte-string into a Lexbor lxb_html_document_t that owns the
/// DOM tree.  The document must be destroyed with HtmlDocument.deinit().
///
/// Usage:
///   var parser = try HtmlParser.init();
///   defer parser.deinit();
///   var doc = try parser.parse("<html><body><h1>Hello</h1></body></html>");
///   defer doc.deinit();
///
/// Design notes:
///   - The parser is NOT thread-safe.  Create one per thread.
///   - The parser can be reused across multiple parse() calls.
///   - Use the public API functions (lxb_dom_node_text_content etc.) rather
///     than accessing Lexbor struct fields directly; Zig's @cImport marks
///     some nested struct fields as inaccessible.

const std = @import("std");
const c = @cImport({
    @cInclude("lexbor/html/html.h");
});

// ── Error types ───────────────────────────────────────────────────────────

pub const ParseError = error{
    ParserCreateFailed,
    ParserInitFailed,
    ParseFailed,
};

// ── HtmlDocument ─────────────────────────────────────────────────────────

/// Owns a parsed Lexbor HTML document.
pub const HtmlDocument = struct {
    doc: *c.lxb_html_document_t,

    pub fn deinit(self: *HtmlDocument) void {
        _ = c.lxb_html_document_destroy(self.doc);
    }

    pub fn rawDocument(self: *const HtmlDocument) *c.lxb_html_document_t {
        return self.doc;
    }

    /// Return the <head> element, or null.
    pub fn head(self: *const HtmlDocument) ?*c.lxb_html_head_element_t {
        return c.lxb_html_document_head_element(self.doc);
    }

    /// Return the <body> element, or null.
    pub fn body(self: *const HtmlDocument) ?*c.lxb_html_body_element_t {
        return c.lxb_html_document_body_element(self.doc);
    }

    /// Return the document title, or null.
    /// Returned slice is valid until document is destroyed.
    pub fn title(self: *const HtmlDocument, out_len: *usize) ?[]const u8 {
        var tlen: usize = 0;
        const ptr = c.lxb_html_document_title(self.doc, &tlen);
        out_len.* = tlen;
        if (ptr == null or tlen == 0) return null;
        return ptr[0..tlen];
    }
};

// ── HtmlParser ───────────────────────────────────────────────────────────

/// Reusable HTML parser.  Not thread-safe.
pub const HtmlParser = struct {
    parser: *c.lxb_html_parser_t,

    pub fn init() ParseError!HtmlParser {
        const p = c.lxb_html_parser_create() orelse return ParseError.ParserCreateFailed;
        if (c.lxb_html_parser_init(p) != c.LXB_STATUS_OK) {
            _ = c.lxb_html_parser_destroy(p);
            return ParseError.ParserInitFailed;
        }
        return HtmlParser{ .parser = p };
    }

    pub fn deinit(self: *HtmlParser) void {
        _ = c.lxb_html_parser_destroy(self.parser);
    }

    /// Parse an HTML string. Caller must call doc.deinit() when done.
    pub fn parse(self: *HtmlParser, html: []const u8) ParseError!HtmlDocument {
        c.lxb_html_parser_clean(self.parser);
        const doc = c.lxb_html_parse(self.parser, html.ptr, html.len)
            orelse return ParseError.ParseFailed;
        return HtmlDocument{ .doc = doc };
    }
};

// ── Node helpers (free functions) ─────────────────────────────────────────

/// Return the tag name of an element node (e.g. "div", "h1").
/// Returns null for non-element nodes.
pub fn elementTagName(node: *c.lxb_dom_node_t) ?[]const u8 {
    if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) return null;
    var len: usize = 0;
    const ptr = c.lxb_dom_element_qualified_name(
        @as(*c.lxb_dom_element_t, @ptrCast(node)),
        &len,
    );
    if (ptr == null or len == 0) return null;
    return ptr[0..len];
}

/// Return the text content of a node (works on text nodes and elements).
/// Uses Lexbor's lxb_dom_node_text_content() API.
/// The returned slice is valid until the document is destroyed.
pub fn nodeTextContent(node: *c.lxb_dom_node_t) ?[]const u8 {
    var len: usize = 0;
    const ptr = c.lxb_dom_node_text_content(node, &len);
    if (ptr == null or len == 0) return null;
    return ptr[0..len];
}

/// Return an attribute value by name on an element node.
pub fn getAttribute(node: *c.lxb_dom_node_t, name: []const u8) ?[]const u8 {
    if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) return null;
    const elem: *c.lxb_dom_element_t = @ptrCast(node);
    var vlen: usize = 0;
    const vptr = c.lxb_dom_element_get_attribute(elem, name.ptr, name.len, &vlen);
    if (vptr == null) return null;
    return vptr[0..vlen];
}

/// Count the number of direct children of a node.
pub fn childCount(node: *c.lxb_dom_node_t) usize {
    var n: usize = 0;
    // node.first_child is [*c]lxb_dom_node_t (nullable C pointer)
    var child: [*c]c.lxb_dom_node_t = node.first_child;
    while (child != null) {
        n += 1;
        child = child[0].next;
    }
    return n;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "HtmlParser.init and deinit" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
}

test "HtmlParser.parse — basic document" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><head><title>Test</title></head><body></body></html>");
    defer doc.deinit();
    // rawDocument() returns *T (non-null), so just check it compiles
    _ = doc.rawDocument();
}

test "HtmlParser.parse — empty string produces document" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("");
    defer doc.deinit();
    _ = doc.rawDocument();
}

test "HtmlDocument.body — returns non-null for document with body" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body><p>Hello</p></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.body() != null);
}

test "HtmlDocument.head — returns non-null for document with head" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><head></head><body></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.head() != null);
}

test "HtmlDocument.title — returns document title" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><head><title>Hello AWR</title></head><body></body></html>");
    defer doc.deinit();
    var tlen: usize = 0;
    const t = doc.title(&tlen);
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("Hello AWR", t.?);
}

test "HtmlDocument.title — empty for document without title" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body></body></html>");
    defer doc.deinit();
    var tlen: usize = 0;
    const t = doc.title(&tlen);
    if (t) |txt| try std.testing.expect(txt.len == 0);
}

test "HtmlParser — reuse across multiple parses" {
    var parser = try HtmlParser.init();
    defer parser.deinit();

    var doc1 = try parser.parse("<html><head><title>First</title></head></html>");
    defer doc1.deinit();
    var tlen1: usize = 0;
    const t1 = doc1.title(&tlen1);
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("First", t1.?);

    var doc2 = try parser.parse("<html><head><title>Second</title></head></html>");
    defer doc2.deinit();
    var tlen2: usize = 0;
    const t2 = doc2.title(&tlen2);
    try std.testing.expect(t2 != null);
    try std.testing.expectEqualStrings("Second", t2.?);
}

test "elementTagName — returns body for body element node" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body></body></html>");
    defer doc.deinit();

    const body_elem = doc.body() orelse return error.SkipZigTest;
    const body_node: *c.lxb_dom_node_t = @ptrCast(body_elem);
    const tag = elementTagName(body_node);
    try std.testing.expect(tag != null);
    try std.testing.expectEqualStrings("body", tag.?);
}

test "elementTagName — returns null for text node" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body>hello</body></html>");
    defer doc.deinit();

    const body_elem = doc.body() orelse return error.SkipZigTest;
    const body_node: *c.lxb_dom_node_t = @ptrCast(body_elem);
    const first = body_node.first_child;
    if (first == null) return error.SkipZigTest;
    const text_node: *c.lxb_dom_node_t = @ptrCast(first);
    try std.testing.expectEqual(@as(?[]const u8, null), elementTagName(text_node));
}

test "nodeTextContent — returns text for body with text" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body>hello world</body></html>");
    defer doc.deinit();

    const body_elem = doc.body() orelse return error.SkipZigTest;
    const body_node: *c.lxb_dom_node_t = @ptrCast(body_elem);
    const text = nodeTextContent(body_node);
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("hello world", text.?);
}

test "getAttribute — returns attribute value" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body><a href=\"https://example.com\">link</a></body></html>");
    defer doc.deinit();

    const body_elem = doc.body() orelse return error.SkipZigTest;
    const body_node: *c.lxb_dom_node_t = @ptrCast(body_elem);
    if (body_node.first_child == null) return error.SkipZigTest;
    const a_node: *c.lxb_dom_node_t = @ptrCast(body_node.first_child);
    const href = getAttribute(a_node, "href");
    try std.testing.expect(href != null);
    try std.testing.expectEqualStrings("https://example.com", href.?);
}

test "getAttribute — returns null for missing attribute" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body><div>hello</div></body></html>");
    defer doc.deinit();

    const body_elem = doc.body() orelse return error.SkipZigTest;
    const body_node: *c.lxb_dom_node_t = @ptrCast(body_elem);
    if (body_node.first_child == null) return error.SkipZigTest;
    const div_node: *c.lxb_dom_node_t = @ptrCast(body_node.first_child);
    try std.testing.expectEqual(@as(?[]const u8, null), getAttribute(div_node, "class"));
}

test "childCount — counts direct children" {
    var parser = try HtmlParser.init();
    defer parser.deinit();
    var doc = try parser.parse("<html><body><p>a</p><p>b</p><p>c</p></body></html>");
    defer doc.deinit();

    const body_elem = doc.body() orelse return error.SkipZigTest;
    const body_node: *c.lxb_dom_node_t = @ptrCast(body_elem);
    try std.testing.expectEqual(@as(usize, 3), childCount(body_node));
}
