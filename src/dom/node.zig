/// node.zig — AWR DOM node types for Phase 2.
///
/// Builds a Zig-owned DOM tree from a Lexbor HTML document.
/// All nodes live in a single ArenaAllocator; one free clears everything.
///
/// The Lexbor document used to seed the tree must remain live during
/// fromLexbor() but may be freed immediately after — all strings are copied
/// into the arena.
///
/// Phase 2 querySelector surface (bridge.zig will expose to JS):
///   document.getElementById(id)
///   document.querySelector(sel)      — tag, #id, .class, tag#id, tag.class
///   document.querySelectorAll(sel)
///   element.getAttribute(name)
///   element.textContent              (concatenated text nodes)

const std = @import("std");
const c = @cImport({
    @cInclude("lexbor/html/html.h");
});

// ── Node build error set ──────────────────────────────────────────────────
// Declared explicitly so mutually-recursive build functions compile cleanly.

const BuildError = error{OutOfMemory};

// ── Public types ──────────────────────────────────────────────────────────

pub const NodeKind = enum { document, element, text, comment, other };

pub const Attribute = struct {
    name:  []const u8,
    value: []const u8,
};

pub const Node = union(NodeKind) {
    document: *Document,
    element:  *Element,
    text:     *Text,
    comment:  *Comment,
    other:    void,
};

pub const Text = struct {
    data:   []const u8,
    parent: ?*Element = null,
};

pub const Comment = struct {
    data:   []const u8,
    parent: ?*Element = null,
};

// ── Element ───────────────────────────────────────────────────────────────

pub const Element = struct {
    tag:        []const u8,
    attributes: []Attribute,
    children:   std.ArrayListUnmanaged(Node),
    parent:     ?*Element,

    pub fn getAttribute(self: *const Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |attr| {
            if (std.ascii.eqlIgnoreCase(attr.name, name)) return attr.value;
        }
        return null;
    }

    /// Concatenate all descendant text node data into a new allocation.
    pub fn textContent(self: *const Element, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        collectText(allocator, self, &buf);
        return buf.toOwnedSlice(allocator);
    }

    fn collectText(alloc: std.mem.Allocator, elem: *const Element, buf: *std.ArrayList(u8)) void {
        for (elem.children.items) |child| {
            switch (child) {
                .text    => |t| buf.appendSlice(alloc, t.data) catch {},
                .element => |e| collectText(alloc, e, buf),
                else     => {},
            }
        }
    }

    pub fn firstChildByTag(self: *const Element, tag: []const u8) ?*Element {
        for (self.children.items) |child| {
            if (child == .element and std.ascii.eqlIgnoreCase(child.element.tag, tag))
                return child.element;
        }
        return null;
    }
};

// ── Document ──────────────────────────────────────────────────────────────

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root:  ?*Element, // <html> element

    /// Build a Zig Document by walking a live Lexbor document.
    pub fn fromLexbor(gpa: std.mem.Allocator, lxb_doc: *c.lxb_html_document_t) !Document {
        var doc = Document{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .root  = null,
        };
        const alloc = doc.arena.allocator();
        const doc_node: *c.lxb_dom_node_t = @ptrCast(lxb_doc);
        doc.root = try buildFirstElementChild(alloc, doc_node.first_child, null);
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    // ── Accessors ────────────────────────────────────────────────────

    pub fn htmlElement(self: *const Document) ?*Element { return self.root; }

    pub fn head(self: *const Document) ?*Element {
        return (self.root orelse return null).firstChildByTag("head");
    }

    pub fn body(self: *const Document) ?*Element {
        return (self.root orelse return null).firstChildByTag("body");
    }

    // ── querySelector surface ────────────────────────────────────────

    pub fn getElementById(self: *const Document, id: []const u8) ?*Element {
        return findById(self.root orelse return null, id);
    }

    pub fn querySelector(self: *const Document, sel: []const u8) ?*Element {
        return findBySelector(self.root orelse return null, sel);
    }

    pub fn querySelectorAll(
        self:      *const Document,
        sel:       []const u8,
        allocator: std.mem.Allocator,
    ) ![]*Element {
        var out: std.ArrayList(*Element) = .empty;
        if (self.root) |root| collectBySelector(allocator, root, sel, &out);
        return out.toOwnedSlice(allocator);
    }

    // ── Private search helpers ───────────────────────────────────────

    fn findById(elem: *Element, id: []const u8) ?*Element {
        if (elem.getAttribute("id")) |eid| {
            if (std.mem.eql(u8, eid, id)) return elem;
        }
        for (elem.children.items) |child| {
            if (child == .element) {
                if (findById(child.element, id)) |found| return found;
            }
        }
        return null;
    }

    fn findBySelector(elem: *Element, sel: []const u8) ?*Element {
        if (matchesSelector(elem, sel)) return elem;
        for (elem.children.items) |child| {
            if (child == .element) {
                if (findBySelector(child.element, sel)) |found| return found;
            }
        }
        return null;
    }

    fn collectBySelector(alloc: std.mem.Allocator, elem: *Element, sel: []const u8, out: *std.ArrayList(*Element)) void {
        if (matchesSelector(elem, sel)) out.append(alloc, elem) catch {};
        for (elem.children.items) |child| {
            if (child == .element) collectBySelector(alloc, child.element, sel, out);
        }
    }

    /// Simple CSS selector: tag | #id | .class | tag#id | tag.class
    fn matchesSelector(elem: *const Element, sel: []const u8) bool {
        if (sel.len == 0) return false;
        if (sel[0] == '#') {
            const eid = elem.getAttribute("id") orelse return false;
            return std.mem.eql(u8, eid, sel[1..]);
        }
        if (sel[0] == '.') {
            const ecls = elem.getAttribute("class") orelse return false;
            return classListContains(ecls, sel[1..]);
        }
        if (std.mem.indexOfScalar(u8, sel, '#')) |hp| {
            if (!std.ascii.eqlIgnoreCase(elem.tag, sel[0..hp])) return false;
            const eid = elem.getAttribute("id") orelse return false;
            return std.mem.eql(u8, eid, sel[hp + 1..]);
        }
        if (std.mem.indexOfScalar(u8, sel, '.')) |dp| {
            if (!std.ascii.eqlIgnoreCase(elem.tag, sel[0..dp])) return false;
            const ecls = elem.getAttribute("class") orelse return false;
            return classListContains(ecls, sel[dp + 1..]);
        }
        return std.ascii.eqlIgnoreCase(elem.tag, sel);
    }

    fn classListContains(class_attr: []const u8, needle: []const u8) bool {
        var it = std.mem.splitScalar(u8, class_attr, ' ');
        while (it.next()) |cls| {
            if (std.mem.eql(u8, cls, needle)) return true;
        }
        return false;
    }
};

// ── Tree builder (Lexbor → Zig nodes) ────────────────────────────────────

/// Walk sibling list starting at lxb_node, return the first Element built.
fn buildFirstElementChild(
    alloc:    std.mem.Allocator,
    lxb_node: [*c]c.lxb_dom_node_t,
    parent:   ?*Element,
) BuildError!?*Element {
    var cur: [*c]c.lxb_dom_node_t = lxb_node;
    while (cur != null) : (cur = cur[0].next) {
        if (cur[0].type == c.LXB_DOM_NODE_TYPE_ELEMENT) {
            return try buildElementNode(alloc, @ptrCast(cur), parent);
        }
    }
    return null;
}

fn buildElementNode(
    alloc:  std.mem.Allocator,
    node:   *c.lxb_dom_node_t,
    parent: ?*Element,
) BuildError!*Element {
    const elem = try alloc.create(Element);

    // Tag name
    var tlen: usize = 0;
    const tag_ptr = c.lxb_dom_element_qualified_name(
        @as(*c.lxb_dom_element_t, @ptrCast(node)),
        &tlen,
    );
    const tag_src: []const u8 = if (tag_ptr != null and tlen > 0) tag_ptr[0..tlen] else "unknown";

    elem.* = .{
        .tag        = try alloc.dupe(u8, tag_src),
        .attributes = try buildAttributes(alloc, @as(*c.lxb_dom_element_t, @ptrCast(node))),
        .children   = .{},
        .parent     = parent,
    };
    try buildChildren(alloc, elem, node.first_child);
    return elem;
}

fn buildAttributes(
    alloc:     std.mem.Allocator,
    elem_node: *c.lxb_dom_element_t,
) BuildError![]Attribute {
    var list = std.ArrayListUnmanaged(Attribute){};
    var attr: [*c]c.lxb_dom_attr_t = c.lxb_dom_element_first_attribute(elem_node);
    while (attr != null) : (attr = c.lxb_dom_element_next_attribute(attr)) {
        var nlen: usize = 0;
        const name_ptr = c.lxb_dom_attr_qualified_name(attr, &nlen);
        if (name_ptr == null or nlen == 0) continue;

        var vlen: usize = 0;
        const val_ptr  = c.lxb_dom_attr_value(attr, &vlen);
        const val_src: []const u8  = if (val_ptr != null and vlen > 0) val_ptr[0..vlen] else "";

        try list.append(alloc, .{
            .name  = try alloc.dupe(u8, name_ptr[0..nlen]),
            .value = try alloc.dupe(u8, val_src),
        });
    }
    return list.toOwnedSlice(alloc);
}

fn buildChildren(
    alloc:       std.mem.Allocator,
    parent:      *Element,
    first_child: [*c]c.lxb_dom_node_t,
) BuildError!void {
    var cur: [*c]c.lxb_dom_node_t = first_child;
    while (cur != null) : (cur = cur[0].next) {
        switch (cur[0].type) {
            c.LXB_DOM_NODE_TYPE_ELEMENT => {
                const child = try buildElementNode(alloc, @ptrCast(cur), parent);
                try parent.children.append(alloc, .{ .element = child });
            },
            c.LXB_DOM_NODE_TYPE_TEXT, c.LXB_DOM_NODE_TYPE_CDATA_SECTION => {
                // Use the public API to get text content safely.
                var tlen: usize = 0;
                const tptr = c.lxb_dom_node_text_content(@ptrCast(cur), &tlen);
                if (tptr != null and tlen > 0) {
                    const t = try alloc.create(Text);
                    t.* = .{ .data = try alloc.dupe(u8, tptr[0..tlen]), .parent = parent };
                    try parent.children.append(alloc, .{ .text = t });
                }
            },
            c.LXB_DOM_NODE_TYPE_COMMENT => {
                var tlen: usize = 0;
                const tptr = c.lxb_dom_node_text_content(@ptrCast(cur), &tlen);
                if (tptr != null and tlen > 0) {
                    const cmt = try alloc.create(Comment);
                    cmt.* = .{ .data = try alloc.dupe(u8, tptr[0..tlen]), .parent = parent };
                    try parent.children.append(alloc, .{ .comment = cmt });
                }
            },
            else => {},
        }
    }
}

// ── Convenience: parse HTML → Document ───────────────────────────────────

pub fn parseDocument(gpa: std.mem.Allocator, html: []const u8) !Document {
    const p = c.lxb_html_parser_create() orelse return error.ParserCreateFailed;
    defer _ = c.lxb_html_parser_destroy(p);
    if (c.lxb_html_parser_init(p) != c.LXB_STATUS_OK) return error.ParserInitFailed;
    const lxb_doc = c.lxb_html_parse(p, html.ptr, html.len) orelse return error.ParseFailed;
    defer _ = c.lxb_html_document_destroy(lxb_doc);
    return Document.fromLexbor(gpa, lxb_doc);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "parseDocument — html root exists" {
    var doc = try parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.htmlElement() != null);
}

test "parseDocument — body element tag is 'body'" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><p>Hello</p></body></html>");
    defer doc.deinit();
    const body = doc.body();
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("body", body.?.tag);
}

test "parseDocument — head element tag is 'head'" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><head><title>T</title></head><body></body></html>");
    defer doc.deinit();
    const head = doc.head();
    try std.testing.expect(head != null);
    try std.testing.expectEqualStrings("head", head.?.tag);
}

test "Document.getElementById — finds by id" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><div id=\"main\">content</div></body></html>");
    defer doc.deinit();
    const elem = doc.getElementById("main");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("div", elem.?.tag);
}

test "Document.getElementById — null for missing id" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><div id=\"other\">content</div></body></html>");
    defer doc.deinit();
    try std.testing.expectEqual(@as(?*Element, null), doc.getElementById("nope"));
}

test "Document.querySelector — finds by tag" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><h1>Title</h1></body></html>");
    defer doc.deinit();
    const h1 = doc.querySelector("h1");
    try std.testing.expect(h1 != null);
    try std.testing.expectEqualStrings("h1", h1.?.tag);
}

test "Document.querySelector — finds by #id" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><p id=\"intro\">text</p></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector("#intro");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("p", elem.?.tag);
}

test "Document.querySelector — finds by .class" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><span class=\"highlight bold\">text</span></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector(".highlight");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("span", elem.?.tag);
}

test "Document.querySelector — null when not found" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><p>text</p></body></html>");
    defer doc.deinit();
    try std.testing.expectEqual(@as(?*Element, null), doc.querySelector("h2"));
}

test "Document.querySelectorAll — finds all <p> elements" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><p>a</p><p>b</p><p>c</p></body></html>");
    defer doc.deinit();
    const results = try doc.querySelectorAll("p", std.testing.allocator);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
}

test "Element.getAttribute — returns value" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><a href=\"/page\">link</a></body></html>");
    defer doc.deinit();
    const a = doc.querySelector("a");
    try std.testing.expect(a != null);
    const href = a.?.getAttribute("href");
    try std.testing.expect(href != null);
    try std.testing.expectEqualStrings("/page", href.?);
}

test "Element.getAttribute — case-insensitive" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><input type=\"text\"/></body></html>");
    defer doc.deinit();
    const input = doc.querySelector("input");
    try std.testing.expect(input != null);
    try std.testing.expect(input.?.getAttribute("type") != null);
    try std.testing.expect(input.?.getAttribute("TYPE") != null);
}

test "Element.getAttribute — null for missing attr" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><div>hello</div></body></html>");
    defer doc.deinit();
    const div = doc.querySelector("div");
    try std.testing.expect(div != null);
    try std.testing.expectEqual(@as(?[]const u8, null), div.?.getAttribute("class"));
}

test "Element.textContent — contains inner text" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><p>hello <strong>world</strong></p></body></html>");
    defer doc.deinit();
    const p = doc.querySelector("p") orelse return error.SkipZigTest;
    const text = try p.textContent(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "world") != null);
}

test "querySelector — tag.class compound selector" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><p class=\"note\">text</p></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector("p.note");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("p", elem.?.tag);
}
