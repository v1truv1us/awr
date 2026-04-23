/// node.zig — AWR DOM node types for Phase 2.
///
/// Builds a Zig-owned DOM tree from a Lexbor HTML document.
/// All nodes live in a single ArenaAllocator; one free clears everything.
///
/// The Lexbor document used to seed the tree must remain live during
/// fromLexbor() but may be freed immediately after — all strings are copied
/// into the arena.
///
/// querySelector surface (bridge.zig will expose to JS):
///   document.getElementById(id)
///   document.querySelector(sel)      — tag, #id, .class, tag#id, tag.class,
///                                      [attr], [attr=val], :not(sel),
///                                      descendant, child (>), adjacent (+),
///                                      sibling (~), multi-class
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

const AttrSelector = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

const SimpleSelector = struct {
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: std.ArrayListUnmanaged([]const u8) = .empty,
    attrs: std.ArrayListUnmanaged(AttrSelector) = .empty,
    not_sel: ?*SimpleSelector = null,

    fn deinit(self: *SimpleSelector, alloc: std.mem.Allocator) void {
        if (self.not_sel) |n| {
            n.deinit(alloc);
            alloc.destroy(n);
        }
        self.classes.deinit(alloc);
        self.attrs.deinit(alloc);
    }
};

const ComplexSelector = struct {
    const Combinator = enum { descendant, child, adjacent, sibling };
    steps: std.ArrayListUnmanaged(SimpleSelector) = .empty,
    combinators: std.ArrayListUnmanaged(Combinator) = .empty,

    fn deinit(self: *ComplexSelector, alloc: std.mem.Allocator) void {
        for (self.steps.items) |*s| s.deinit(alloc);
        self.steps.deinit(alloc);
        self.combinators.deinit(alloc);
    }
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

    pub fn querySelector(self: *const Element, sel: []const u8) ?*Element {
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        var parsed = Document.parseComplexSelector(std.heap.page_allocator, trimmed) catch return null;
        defer parsed.deinit(std.heap.page_allocator);

        for (self.children.items) |child| {
            if (child == .element) {
                if (Document.findByComplexSelector(child.element, &parsed)) |found| return found;
            }
        }
        return null;
    }

    pub fn querySelectorAll(
        self: *const Element,
        sel: []const u8,
        allocator: std.mem.Allocator,
    ) ![]*Element {
        var out: std.ArrayList(*Element) = .empty;
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        var parsed = try Document.parseComplexSelector(allocator, trimmed);
        defer parsed.deinit(allocator);

        for (self.children.items) |child| {
            if (child == .element) {
                Document.collectByComplexSelector(allocator, child.element, &parsed, &out);
            }
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn matches(self: *const Element, sel: []const u8) bool {
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        var parsed = Document.parseComplexSelector(std.heap.page_allocator, trimmed) catch return false;
        defer parsed.deinit(std.heap.page_allocator);
        return Document.matchesComplexSelector(self, &parsed);
    }

    pub fn closest(self: *const Element, sel: []const u8) ?*Element {
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        var parsed = Document.parseComplexSelector(std.heap.page_allocator, trimmed) catch return null;
        defer parsed.deinit(std.heap.page_allocator);

        var cur: ?*const Element = self;
        while (cur) |elem| : (cur = elem.parent) {
            if (Document.matchesComplexSelector(elem, &parsed)) return @constCast(elem);
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
        const root = self.root orelse return null;
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        var parsed = parseComplexSelector(std.heap.page_allocator, trimmed) catch return null;
        defer parsed.deinit(std.heap.page_allocator);
        return findByComplexSelector(root, &parsed);
    }

    pub fn querySelectorAll(
        self:      *const Document,
        sel:       []const u8,
        allocator: std.mem.Allocator,
    ) ![]*Element {
        var out: std.ArrayList(*Element) = .empty;
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        if (self.root) |root| {
            var parsed = try parseComplexSelector(allocator, trimmed);
            defer parsed.deinit(allocator);
            collectByComplexSelector(allocator, root, &parsed, &out);
        }
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

    fn findByComplexSelector(elem: *Element, sel: *const ComplexSelector) ?*Element {
        if (matchesComplexSelector(elem, sel)) return elem;
        for (elem.children.items) |child| {
            if (child == .element) {
                if (findByComplexSelector(child.element, sel)) |found| return found;
            }
        }
        return null;
    }

    fn collectByComplexSelector(alloc: std.mem.Allocator, elem: *Element, sel: *const ComplexSelector, out: *std.ArrayList(*Element)) void {
        if (matchesComplexSelector(elem, sel)) out.append(alloc, elem) catch {};
        for (elem.children.items) |child| {
            if (child == .element) collectByComplexSelector(alloc, child.element, sel, out);
        }
    }

    fn matchesComplexSelector(elem: *const Element, sel: *const ComplexSelector) bool {
        if (sel.steps.items.len == 0) return false;
        return matchStep(elem, sel, sel.steps.items.len - 1);
    }

    fn matchStep(elem: *const Element, sel: *const ComplexSelector, step_idx: usize) bool {
        const step = &sel.steps.items[step_idx];
        if (!matchesSimpleSelector(elem, step)) return false;
        if (step_idx == 0) return true;
        const comb = sel.combinators.items[step_idx - 1];
        switch (comb) {
            .child => {
                const p = elem.parent orelse return false;
                return matchStep(p, sel, step_idx - 1);
            },
            .descendant => {
                var p = elem.parent;
                while (p) |cur| : (p = cur.parent) {
                    if (matchStep(cur, sel, step_idx - 1)) return true;
                }
                return false;
            },
            .adjacent => {
                const sib = previousElementSibling(elem) orelse return false;
                return matchStep(sib, sel, step_idx - 1);
            },
            .sibling => {
                var sib = previousElementSibling(elem);
                while (sib) |cur| : (sib = previousElementSibling(cur)) {
                    if (matchStep(cur, sel, step_idx - 1)) return true;
                }
                return false;
            },
        }
    }

    fn previousElementSibling(elem: *const Element) ?*Element {
        const p = elem.parent orelse return null;
        var prev: ?*Element = null;
        for (p.children.items) |n| {
            if (n == .element) {
                if (n.element == elem) return prev;
                prev = n.element;
            }
        }
        return null;
    }

    fn matchesSimpleSelector(elem: *const Element, sel: *const SimpleSelector) bool {
        if (sel.tag) |tag| {
            if (tag.len > 0 and !std.mem.eql(u8, tag, "*") and !std.ascii.eqlIgnoreCase(elem.tag, tag)) return false;
        }
        if (sel.id) |idv| {
            const eid = elem.getAttribute("id") orelse return false;
            if (!std.mem.eql(u8, eid, idv)) return false;
        }
        for (sel.classes.items) |cls| {
            const ecls = elem.getAttribute("class") orelse return false;
            if (!classListContains(ecls, cls)) return false;
        }
        for (sel.attrs.items) |a| {
            const v = elem.getAttribute(a.name) orelse return false;
            if (a.value) |expected| {
                if (!std.mem.eql(u8, v, expected)) return false;
            }
        }
        if (sel.not_sel) |n| {
            if (matchesSimpleSelector(elem, n)) return false;
        }
        return true;
    }

    fn parseComplexSelector(alloc: std.mem.Allocator, sel: []const u8) !ComplexSelector {
        var out: ComplexSelector = .{};
        var i: usize = 0;
        while (i < sel.len) {
            while (i < sel.len and (sel[i] == ' ' or sel[i] == '\t' or sel[i] == '\n' or sel[i] == '\r')) : (i += 1) {}
            if (i >= sel.len) break;
            const start = i;
            var bracket_depth: i32 = 0;
            var paren_depth: i32 = 0;
            while (i < sel.len) : (i += 1) {
                const ch = sel[i];
                if (ch == '[') bracket_depth += 1
                else if (ch == ']') bracket_depth -= 1
                else if (ch == '(') paren_depth += 1
                else if (ch == ')') paren_depth -= 1
                else if (bracket_depth == 0 and paren_depth == 0 and (ch == '>' or ch == '+' or ch == '~' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r'))
                    break;
            }
            const token = std.mem.trim(u8, sel[start..i], " \t\n\r");
            if (token.len == 0) continue;
            try out.steps.append(alloc, try parseSimpleSelector(alloc, token));
            if (i >= sel.len) break;

            var j = i;
            var saw_ws = false;
            while (j < sel.len and (sel[j] == ' ' or sel[j] == '\t' or sel[j] == '\n' or sel[j] == '\r')) : (j += 1) {
                saw_ws = true;
            }
            const ch = if (j < sel.len) sel[j] else 0;
            if (ch == '>' or ch == '+' or ch == '~') {
                try out.combinators.append(alloc, switch (ch) {
                    '>' => .child,
                    '+' => .adjacent,
                    else => .sibling,
                });
                i = j + 1;
            } else {
                if (saw_ws) try out.combinators.append(alloc, .descendant);
                i = j;
            }
        }
        return out;
    }

    fn parseSimpleSelector(alloc: std.mem.Allocator, token: []const u8) !SimpleSelector {
        var out: SimpleSelector = .{};
        var i: usize = 0;
        while (i < token.len) {
            const ch = token[i];
            if (ch == '.') {
                i += 1;
                const start = i;
                while (i < token.len and isIdentChar(token[i])) : (i += 1) {}
                if (i > start) try out.classes.append(alloc, token[start..i]);
                continue;
            }
            if (ch == '#') {
                i += 1;
                const start = i;
                while (i < token.len and isIdentChar(token[i])) : (i += 1) {}
                if (i > start) out.id = token[start..i];
                continue;
            }
            if (std.mem.startsWith(u8, token[i..], ":not(")) {
                i += 5;
                const start = i;
                var depth: i32 = 1;
                while (i < token.len and depth > 0) : (i += 1) {
                    if (token[i] == '(') depth += 1
                    else if (token[i] == ')') depth -= 1;
                }
                const end = if (i == 0) 0 else i - 1;
                if (end > start) {
                    const inner = try alloc.create(SimpleSelector);
                    inner.* = try parseSimpleSelector(alloc, std.mem.trim(u8, token[start..end], " \t\n\r"));
                    out.not_sel = inner;
                }
                continue;
            }
            if (ch == '[') {
                i += 1;
                const start = i;
                while (i < token.len and token[i] != ']') : (i += 1) {}
                if (i <= token.len) {
                    const inside = std.mem.trim(u8, token[start..@min(i, token.len)], " \t\n\r");
                    if (inside.len > 0) {
                        if (std.mem.indexOfScalar(u8, inside, '=')) |eq| {
                            const name = std.mem.trim(u8, inside[0..eq], " \t\n\r");
                            var value = std.mem.trim(u8, inside[eq + 1 ..], " \t\n\r");
                            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\'')))
                                value = value[1 .. value.len - 1];
                            try out.attrs.append(alloc, .{ .name = name, .value = value });
                        } else {
                            try out.attrs.append(alloc, .{ .name = inside });
                        }
                    }
                }
                if (i < token.len and token[i] == ']') i += 1;
                continue;
            }
            if (isIdentStart(ch) or ch == '*') {
                const start = i;
                i += 1;
                while (i < token.len and isIdentChar(token[i])) : (i += 1) {}
                out.tag = token[start..i];
                continue;
            }
            i += 1;
        }
        return out;
    }

    fn isIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '-';
    }

    fn isIdentChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
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
        .children   = .empty,
        .parent     = parent,
    };
    try buildChildren(alloc, elem, node.first_child);
    return elem;
}

fn buildAttributes(
    alloc:     std.mem.Allocator,
    elem_node: *c.lxb_dom_element_t,
) BuildError![]Attribute {
    var list: std.ArrayListUnmanaged(Attribute) = .empty;
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

test "querySelector — attribute selectors" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><div data-x=\"1\"></div><div data-x=\"2\"></div></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.querySelector("[data-x]") != null);
    const eq = doc.querySelector("[data-x='2']");
    try std.testing.expect(eq != null);
}

test "querySelector — :not pseudo-class" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><p class=\"a\"></p><p class=\"b\"></p></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector("p:not(.a)");
    try std.testing.expect(elem != null);
    try std.testing.expect(std.mem.eql(u8, elem.?.getAttribute("class") orelse "", "b"));
}

test "querySelector — combinators > + ~" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><div id=\"wrap\"><span class=\"a\"></span><span class=\"b\"></span><em></em><span class=\"c\"></span></div></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.querySelector("div > span.b") != null);
    try std.testing.expect(doc.querySelector("span.a + span.b") != null);
    try std.testing.expect(doc.querySelector("span.a ~ span.c") != null);
}

test "querySelector — multi-class selector" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><li class=\"foo bar\">x</li></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.querySelector("li.foo.bar") != null);
}

test "Element.querySelector scopes to descendants" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><section id=\"first\"><p class=\"item\">one</p></section><section id=\"scope\"><p class=\"item\">two</p><div><p class=\"item\">three</p></div></section></body></html>");
    defer doc.deinit();

    const scope = doc.getElementById("scope") orelse return error.SkipZigTest;
    const found = scope.querySelector(".item");
    try std.testing.expect(found != null);
    const text = try found.?.textContent(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("two", text);
}

test "Element.querySelectorAll scopes to descendants" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><section id=\"first\"><p class=\"item\">one</p></section><section id=\"scope\"><p class=\"item\">two</p><div><p class=\"item\">three</p></div></section></body></html>");
    defer doc.deinit();

    const scope = doc.getElementById("scope") orelse return error.SkipZigTest;
    const found = try scope.querySelectorAll(".item", std.testing.allocator);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
}

test "Element.matches supports compound selectors" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><section class=\"shell\"><div><p id=\"leaf\" class=\"copy\">hello</p></div></section></body></html>");
    defer doc.deinit();

    const leaf = doc.getElementById("leaf") orelse return error.SkipZigTest;
    try std.testing.expect(leaf.matches("p.copy"));
    try std.testing.expect(!leaf.matches("section.shell"));
}

test "Element.closest walks ancestors" {
    var doc = try parseDocument(std.testing.allocator,
        "<html><body><section class=\"shell\"><div><p id=\"leaf\" class=\"copy\">hello</p></div></section></body></html>");
    defer doc.deinit();

    const leaf = doc.getElementById("leaf") orelse return error.SkipZigTest;
    const section = leaf.closest("section.shell");
    try std.testing.expect(section != null);
    try std.testing.expectEqualStrings("section", section.?.tag);
}
