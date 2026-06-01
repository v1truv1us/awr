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
    @cInclude("lexbor/html/interfaces/template_element.h");
});

// ── Node build error set ──────────────────────────────────────────────────
// Declared explicitly so mutually-recursive build functions compile cleanly.

const BuildError = error{OutOfMemory};

// ── Public types ──────────────────────────────────────────────────────────

pub const NodeKind = enum { document, element, text, comment, other };

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// CSS attribute-selector operator (Selectors §6).
const AttrOp = enum {
    presence, //  [attr]
    exact, //     [attr=val]
    includes, //  [attr~=val]  whitespace-separated word match
    dash, //      [attr|=val]  exact or `val-` prefix
    prefix, //    [attr^=val]
    suffix, //    [attr$=val]
    substring, // [attr*=val]
};

const AttrSelector = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    op: AttrOp = .presence,
};

/// Structural pseudo-class (CSS Selectors §13). `nth_child` / `nth_of_type`
/// carry the `an+b` coefficients; the boolean forms set a=0,b=fixed.
const PseudoKind = enum {
    first_child,
    last_child,
    only_child,
    nth_child,
    first_of_type,
    last_of_type,
    only_of_type,
    nth_of_type,
};

const Pseudo = struct {
    kind: PseudoKind,
    a: i32 = 0,
    b: i32 = 0,
};

const SimpleSelector = struct {
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: std.ArrayListUnmanaged([]const u8) = .empty,
    attrs: std.ArrayListUnmanaged(AttrSelector) = .empty,
    pseudos: std.ArrayListUnmanaged(Pseudo) = .empty,
    not_sel: ?*SimpleSelector = null,
    /// Set when the token carries an unsupported pseudo (state pseudo-classes
    /// like `:hover`, or any pseudo-element `::x`): the simple selector then
    /// never matches, so such rules don't apply rather than over-applying.
    never_match: bool = false,

    fn deinit(self: *SimpleSelector, alloc: std.mem.Allocator) void {
        if (self.not_sel) |n| {
            n.deinit(alloc);
            alloc.destroy(n);
        }
        self.classes.deinit(alloc);
        self.attrs.deinit(alloc);
        self.pseudos.deinit(alloc);
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

/// CSS Selectors §5: a comma-separated list of complex selectors. The
/// list is the *union* — an element matches if any of its complexes
/// match. AWR's public querySelector / querySelectorAll / matches /
/// closest surface always parses through SelectorList so callers can
/// pass a comma list (e.g. `'input,button,select,textarea'`).
pub const SelectorList = struct {
    parts: std.ArrayListUnmanaged(ComplexSelector) = .empty,

    pub fn deinit(self: *SelectorList, alloc: std.mem.Allocator) void {
        for (self.parts.items) |*p| p.deinit(alloc);
        self.parts.deinit(alloc);
    }
};

/// Compile a selector string into a reusable `SelectorList`. Callers own the
/// result and must `deinit` it. Lets hot-path cascades (the renderer, the JS
/// bridge) parse each CSS rule's selector once and match it against many
/// elements without re-parsing — see `matchesCompiled`.
pub fn compileSelectorList(alloc: std.mem.Allocator, sel: []const u8) !SelectorList {
    return Document.parseSelectorList(alloc, std.mem.trim(u8, sel, " \t\n\r"));
}

/// Match `elem` against a pre-compiled `SelectorList` (full Selectors §5/§6
/// semantics: compound AND, combinators, attribute operators, `:not`).
pub fn matchesCompiled(elem: *const Element, list: *const SelectorList) bool {
    return Document.matchesSelectorList(elem, list);
}

pub const Node = union(NodeKind) {
    document: *Document,
    element: *Element,
    text: *Text,
    comment: *Comment,
    other: void,
};

pub const Text = struct {
    data: []const u8,
    parent: ?*Element = null,
};

pub const Comment = struct {
    data: []const u8,
    parent: ?*Element = null,
};

// ── Element ───────────────────────────────────────────────────────────────

pub const Element = struct {
    tag: []const u8,
    attributes: []Attribute,
    children: std.ArrayListUnmanaged(Node),
    parent: ?*Element,

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
                .text => |t| buf.appendSlice(alloc, t.data) catch {},
                .element => |e| collectText(alloc, e, buf),
                else => {},
            }
        }
    }

    /// Like `textContent`, but skips descendants of opaque-content tags
    /// (`<style>`, `<script>`, `<noscript>`, `<template>`) whose text
    /// nodes are source code or fallback markup, not page prose.
    ///
    /// Use this for agent-facing extraction (e.g. the JSON envelope's
    /// `body_text` field). `textContent` itself remains spec-compliant
    /// per DOM and is asserted by the curated WPT corpus — do not
    /// route WPT consumers through this method.
    pub fn textContentForExtract(self: *const Element, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        collectTextForExtract(allocator, self, &buf);
        return buf.toOwnedSlice(allocator);
    }

    fn isOpaqueContentTag(tag: []const u8) bool {
        return std.ascii.eqlIgnoreCase(tag, "style") or
            std.ascii.eqlIgnoreCase(tag, "script") or
            std.ascii.eqlIgnoreCase(tag, "noscript") or
            std.ascii.eqlIgnoreCase(tag, "template");
    }

    fn collectTextForExtract(alloc: std.mem.Allocator, elem: *const Element, buf: *std.ArrayList(u8)) void {
        for (elem.children.items) |child| {
            switch (child) {
                .text => |t| buf.appendSlice(alloc, t.data) catch {},
                .element => |e| {
                    if (isOpaqueContentTag(e.tag)) continue;
                    collectTextForExtract(alloc, e, buf);
                },
                else => {},
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
        var parsed = Document.parseSelectorList(std.heap.page_allocator, trimmed) catch return null;
        defer parsed.deinit(std.heap.page_allocator);

        for (self.children.items) |child| {
            if (child == .element) {
                if (Document.findBySelectorList(child.element, &parsed)) |found| return found;
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
        var parsed = try Document.parseSelectorList(allocator, trimmed);
        defer parsed.deinit(allocator);

        for (self.children.items) |child| {
            if (child == .element) {
                Document.collectBySelectorList(allocator, child.element, &parsed, &out);
            }
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn matches(self: *const Element, sel: []const u8) bool {
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        var parsed = Document.parseSelectorList(std.heap.page_allocator, trimmed) catch return false;
        defer parsed.deinit(std.heap.page_allocator);
        return Document.matchesSelectorList(self, &parsed);
    }

    pub fn closest(self: *const Element, sel: []const u8) ?*Element {
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        var parsed = Document.parseSelectorList(std.heap.page_allocator, trimmed) catch return null;
        defer parsed.deinit(std.heap.page_allocator);

        var cur: ?*const Element = self;
        while (cur) |elem| : (cur = elem.parent) {
            if (Document.matchesSelectorList(elem, &parsed)) return @constCast(elem);
        }
        return null;
    }
};

// ── Document ──────────────────────────────────────────────────────────────

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: ?*Element, // <html> element

    /// Build a Zig Document by walking a live Lexbor document.
    pub fn fromLexbor(gpa: std.mem.Allocator, lxb_doc: *c.lxb_html_document_t) !Document {
        var doc = Document{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .root = null,
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

    pub fn htmlElement(self: *const Document) ?*Element {
        return self.root;
    }

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
        var parsed = parseSelectorList(std.heap.page_allocator, trimmed) catch return null;
        defer parsed.deinit(std.heap.page_allocator);
        return findBySelectorList(root, &parsed);
    }

    pub fn querySelectorAll(
        self: *const Document,
        sel: []const u8,
        allocator: std.mem.Allocator,
    ) ![]*Element {
        var out: std.ArrayList(*Element) = .empty;
        const trimmed = std.mem.trim(u8, sel, " \t\n\r");
        if (self.root) |root| {
            var parsed = try parseSelectorList(allocator, trimmed);
            defer parsed.deinit(allocator);
            collectBySelectorList(allocator, root, &parsed, &out);
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

    /// Element matches the list iff it matches at least one part.
    fn matchesSelectorList(elem: *const Element, list: *const SelectorList) bool {
        for (list.parts.items) |*part| {
            if (matchesComplexSelector(elem, part)) return true;
        }
        return false;
    }

    /// Tree-walk: first element matching any part wins. Document order
    /// (depth-first pre-order) — same as findByComplexSelector.
    fn findBySelectorList(elem: *Element, list: *const SelectorList) ?*Element {
        if (matchesSelectorList(elem, list)) return elem;
        for (elem.children.items) |child| {
            if (child == .element) {
                if (findBySelectorList(child.element, list)) |found| return found;
            }
        }
        return null;
    }

    /// Tree-walk: collect every element that matches any part. Each
    /// element is added at most once (matches simply stop checking
    /// further parts — we do not run a separate pass per part, so
    /// document order is preserved).
    fn collectBySelectorList(alloc: std.mem.Allocator, elem: *Element, list: *const SelectorList, out: *std.ArrayList(*Element)) void {
        if (matchesSelectorList(elem, list)) out.append(alloc, elem) catch {};
        for (elem.children.items) |child| {
            if (child == .element) collectBySelectorList(alloc, child.element, list, out);
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
        if (sel.never_match) return false;
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
            if (!attrMatches(a, v)) return false;
        }
        for (sel.pseudos.items) |ps| {
            if (!matchesPseudo(elem, ps)) return false;
        }
        if (sel.not_sel) |n| {
            if (matchesSimpleSelector(elem, n)) return false;
        }
        return true;
    }

    /// CSS Selectors §13: structural pseudo-classes. Computes the element's
    /// 1-based position among its element siblings (and among same-tag
    /// siblings) in one pass, then tests the requested form.
    fn matchesPseudo(elem: *const Element, ps: Pseudo) bool {
        var pos: i32 = 1;
        var total: i32 = 1;
        var pos_type: i32 = 1;
        var total_type: i32 = 1;
        if (elem.parent) |par| {
            var i: i32 = 0;
            var it: i32 = 0;
            for (par.children.items) |n| {
                if (n != .element) continue;
                i += 1;
                const same = std.ascii.eqlIgnoreCase(n.element.tag, elem.tag);
                if (same) it += 1;
                if (n.element == elem) {
                    pos = i;
                    pos_type = it;
                }
            }
            total = i;
            total_type = it;
        }
        return switch (ps.kind) {
            .first_child => pos == 1,
            .last_child => pos == total,
            .only_child => total == 1,
            .nth_child => nthMatches(pos, ps.a, ps.b),
            .first_of_type => pos_type == 1,
            .last_of_type => pos_type == total_type,
            .only_of_type => total_type == 1,
            .nth_of_type => nthMatches(pos_type, ps.a, ps.b),
        };
    }

    /// True when 1-based `idx` satisfies `an + b` for some integer `n >= 0`.
    fn nthMatches(idx: i32, a: i32, b: i32) bool {
        if (a == 0) return idx == b;
        const diff = idx - b;
        if (@rem(diff, a) != 0) return false;
        return @divTrunc(diff, a) >= 0;
    }

    /// CSS Selectors §6: test an attribute value `v` against a parsed
    /// attribute selector `a` per its operator.
    fn attrMatches(a: AttrSelector, v: []const u8) bool {
        const expected = a.value orelse return true; // [attr] — presence only
        return switch (a.op) {
            .presence => true,
            .exact => std.mem.eql(u8, v, expected),
            .includes => blk: {
                if (expected.len == 0) break :blk false;
                var it = std.mem.tokenizeAny(u8, v, " \t\r\n\x0c");
                while (it.next()) |word| {
                    if (std.mem.eql(u8, word, expected)) break :blk true;
                }
                break :blk false;
            },
            .dash => std.mem.eql(u8, v, expected) or
                (v.len > expected.len and std.mem.startsWith(u8, v, expected) and v[expected.len] == '-'),
            .prefix => expected.len > 0 and std.mem.startsWith(u8, v, expected),
            .suffix => expected.len > 0 and std.mem.endsWith(u8, v, expected),
            .substring => expected.len > 0 and std.mem.indexOf(u8, v, expected) != null,
        };
    }

    /// Split `sel` on top-level commas (respecting `[...]` attribute
    /// brackets and `:func(...)` parens) and parse each piece as a
    /// ComplexSelector. The pieces are unioned at match time per CSS
    /// Selectors §5. Empty pieces are skipped — `'a,,b'` is treated
    /// as `'a, b'` and trailing/leading commas are ignored, matching
    /// the lenient real-browser tokenizer.
    fn parseSelectorList(alloc: std.mem.Allocator, sel: []const u8) !SelectorList {
        var out: SelectorList = .{};
        errdefer out.deinit(alloc);

        var part_start: usize = 0;
        var i: usize = 0;
        var bracket_depth: i32 = 0;
        var paren_depth: i32 = 0;
        while (i < sel.len) : (i += 1) {
            const ch = sel[i];
            if (ch == '[') bracket_depth += 1;
            if (ch == ']') bracket_depth -= 1;
            if (ch == '(') paren_depth += 1;
            if (ch == ')') paren_depth -= 1;
            if (ch == ',' and bracket_depth == 0 and paren_depth == 0) {
                const part = std.mem.trim(u8, sel[part_start..i], " \t\n\r");
                if (part.len > 0) {
                    try out.parts.append(alloc, try parseComplexSelector(alloc, part));
                }
                part_start = i + 1;
            }
        }
        const last_part = std.mem.trim(u8, sel[part_start..], " \t\n\r");
        if (last_part.len > 0) {
            try out.parts.append(alloc, try parseComplexSelector(alloc, last_part));
        }
        return out;
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
                if (ch == '[') bracket_depth += 1 else if (ch == ']') bracket_depth -= 1 else if (ch == '(') paren_depth += 1 else if (ch == ')') paren_depth -= 1 else if (bracket_depth == 0 and paren_depth == 0 and (ch == '>' or ch == '+' or ch == '~' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r'))
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
                    if (token[i] == '(') depth += 1 else if (token[i] == ')') depth -= 1;
                }
                const end = if (i == 0) 0 else i - 1;
                if (end > start) {
                    const inner = try alloc.create(SimpleSelector);
                    inner.* = try parseSimpleSelector(alloc, std.mem.trim(u8, token[start..end], " \t\n\r"));
                    out.not_sel = inner;
                }
                continue;
            }
            if (ch == ':') {
                // Pseudo-element (`::x`) — unsupported, never matches.
                if (i + 1 < token.len and token[i + 1] == ':') {
                    out.never_match = true;
                    i += 2;
                    while (i < token.len and isIdentChar(token[i])) : (i += 1) {}
                    continue;
                }
                var p = i + 1;
                const nstart = p;
                while (p < token.len and isIdentChar(token[p])) : (p += 1) {}
                const name = token[nstart..p];
                var arg: ?[]const u8 = null;
                if (p < token.len and token[p] == '(') {
                    const astart = p + 1;
                    var d: i32 = 1;
                    p += 1;
                    while (p < token.len and d > 0) : (p += 1) {
                        if (token[p] == '(') d += 1 else if (token[p] == ')') d -= 1;
                    }
                    const aend = if (p > 0) p - 1 else 0;
                    arg = std.mem.trim(u8, token[astart..@min(aend, token.len)], " \t\n\r");
                }
                if (structuralPseudo(name, arg)) |ps| {
                    out.pseudos.append(alloc, ps) catch {};
                } else {
                    out.never_match = true; // state pseudo-class / unknown
                }
                i = p;
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
                            // An operator char (~ | ^ $ *) may immediately
                            // precede the `=`; otherwise it's a plain `=`.
                            var name_end = eq;
                            var op: AttrOp = .exact;
                            if (eq > 0) {
                                switch (inside[eq - 1]) {
                                    '~' => {
                                        op = .includes;
                                        name_end = eq - 1;
                                    },
                                    '|' => {
                                        op = .dash;
                                        name_end = eq - 1;
                                    },
                                    '^' => {
                                        op = .prefix;
                                        name_end = eq - 1;
                                    },
                                    '$' => {
                                        op = .suffix;
                                        name_end = eq - 1;
                                    },
                                    '*' => {
                                        op = .substring;
                                        name_end = eq - 1;
                                    },
                                    else => {},
                                }
                            }
                            const name = std.mem.trim(u8, inside[0..name_end], " \t\n\r");
                            var value = std.mem.trim(u8, inside[eq + 1 ..], " \t\n\r");
                            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\'')))
                                value = value[1 .. value.len - 1];
                            try out.attrs.append(alloc, .{ .name = name, .value = value, .op = op });
                        } else {
                            try out.attrs.append(alloc, .{ .name = inside, .op = .presence });
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

    /// Parse a structural pseudo-class name (+ optional `an+b` argument) into
    /// a `Pseudo`, or null for unsupported pseudo-classes.
    fn structuralPseudo(name: []const u8, arg: ?[]const u8) ?Pseudo {
        if (std.ascii.eqlIgnoreCase(name, "first-child")) return .{ .kind = .first_child };
        if (std.ascii.eqlIgnoreCase(name, "last-child")) return .{ .kind = .last_child };
        if (std.ascii.eqlIgnoreCase(name, "only-child")) return .{ .kind = .only_child };
        if (std.ascii.eqlIgnoreCase(name, "first-of-type")) return .{ .kind = .first_of_type };
        if (std.ascii.eqlIgnoreCase(name, "last-of-type")) return .{ .kind = .last_of_type };
        if (std.ascii.eqlIgnoreCase(name, "only-of-type")) return .{ .kind = .only_of_type };
        if (std.ascii.eqlIgnoreCase(name, "nth-child")) {
            const ab = parseNth(arg orelse return null) orelse return null;
            return .{ .kind = .nth_child, .a = ab[0], .b = ab[1] };
        }
        if (std.ascii.eqlIgnoreCase(name, "nth-of-type")) {
            const ab = parseNth(arg orelse return null) orelse return null;
            return .{ .kind = .nth_of_type, .a = ab[0], .b = ab[1] };
        }
        return null;
    }

    /// Parse an `An+B` micro-syntax (`odd`, `even`, `n`, `2n+1`, `-n+3`, `5`)
    /// into `[a, b]`, or null if malformed.
    fn parseNth(raw: []const u8) ?[2]i32 {
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (raw) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') continue;
            if (n >= buf.len) return null;
            buf[n] = ch;
            n += 1;
        }
        const s = buf[0..n];
        if (s.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(s, "odd")) return .{ 2, 1 };
        if (std.ascii.eqlIgnoreCase(s, "even")) return .{ 2, 0 };

        var npos: ?usize = null;
        for (s, 0..) |ch, idx| {
            if (ch == 'n' or ch == 'N') {
                npos = idx;
                break;
            }
        }
        if (npos) |np| {
            var a: i32 = 1;
            const acoef = s[0..np];
            if (acoef.len == 0 or std.mem.eql(u8, acoef, "+")) {
                a = 1;
            } else if (std.mem.eql(u8, acoef, "-")) {
                a = -1;
            } else {
                a = std.fmt.parseInt(i32, acoef, 10) catch return null;
            }
            var b: i32 = 0;
            if (np + 1 < s.len) b = std.fmt.parseInt(i32, s[np + 1 ..], 10) catch return null;
            return .{ a, b };
        }
        const b = std.fmt.parseInt(i32, s, 10) catch return null;
        return .{ 0, b };
    }

    fn isIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '-';
    }

    fn isIdentChar(ch: u8) bool {
        // Per CSS Syntax §4.2, code points >= U+0080 are identifier code
        // points. Treat any UTF-8 continuation/lead byte (>= 0x80) as part
        // of an identifier so non-ASCII class/id names (e.g. Arabic
        // `.إعلام`, CJK) parse to the actual name rather than an empty
        // token — an empty token yields a constraint-less selector that
        // matches every element and (with display:none) blanks the page.
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch >= 0x80;
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
    alloc: std.mem.Allocator,
    lxb_node: [*c]c.lxb_dom_node_t,
    parent: ?*Element,
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
    alloc: std.mem.Allocator,
    node: *c.lxb_dom_node_t,
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
        .tag = try alloc.dupe(u8, tag_src),
        .attributes = try buildAttributes(alloc, @as(*c.lxb_dom_element_t, @ptrCast(node))),
        .children = .empty,
        .parent = parent,
    };
    const first_child = if (std.ascii.eqlIgnoreCase(tag_src, "template")) blk: {
        const template_elem: *c.lxb_html_template_element_t = @ptrCast(node);
        if (template_elem.content) |content| {
            const content_node: *c.lxb_dom_node_t = @ptrCast(content);
            break :blk content_node.first_child;
        }
        break :blk node.first_child;
    } else node.first_child;

    try buildChildren(alloc, elem, first_child);
    return elem;
}

fn buildAttributes(
    alloc: std.mem.Allocator,
    elem_node: *c.lxb_dom_element_t,
) BuildError![]Attribute {
    var list: std.ArrayListUnmanaged(Attribute) = .empty;
    var attr: [*c]c.lxb_dom_attr_t = c.lxb_dom_element_first_attribute(elem_node);
    while (attr != null) : (attr = c.lxb_dom_element_next_attribute(attr)) {
        var nlen: usize = 0;
        const name_ptr = c.lxb_dom_attr_qualified_name(attr, &nlen);
        if (name_ptr == null or nlen == 0) continue;

        var vlen: usize = 0;
        const val_ptr = c.lxb_dom_attr_value(attr, &vlen);
        const val_src: []const u8 = if (val_ptr != null and vlen > 0) val_ptr[0..vlen] else "";

        try list.append(alloc, .{
            .name = try alloc.dupe(u8, name_ptr[0..nlen]),
            .value = try alloc.dupe(u8, val_src),
        });
    }
    return list.toOwnedSlice(alloc);
}

fn buildChildren(
    alloc: std.mem.Allocator,
    parent: *Element,
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
    var doc = try parseDocument(std.testing.allocator, "<html><head><title>T</title></head><body></body></html>");
    defer doc.deinit();
    const head = doc.head();
    try std.testing.expect(head != null);
    try std.testing.expectEqualStrings("head", head.?.tag);
}

test "Document.getElementById — finds by id" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><div id=\"main\">content</div></body></html>");
    defer doc.deinit();
    const elem = doc.getElementById("main");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("div", elem.?.tag);
}

test "Document.getElementById — null for missing id" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><div id=\"other\">content</div></body></html>");
    defer doc.deinit();
    try std.testing.expectEqual(@as(?*Element, null), doc.getElementById("nope"));
}

test "Document.querySelector — finds by tag" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><h1>Title</h1></body></html>");
    defer doc.deinit();
    const h1 = doc.querySelector("h1");
    try std.testing.expect(h1 != null);
    try std.testing.expectEqualStrings("h1", h1.?.tag);
}

test "Document.querySelector — finds by #id" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><p id=\"intro\">text</p></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector("#intro");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("p", elem.?.tag);
}

test "Document.querySelector — finds by .class" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><span class=\"highlight bold\">text</span></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector(".highlight");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("span", elem.?.tag);
}

test "Document.querySelector — null when not found" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><p>text</p></body></html>");
    defer doc.deinit();
    try std.testing.expectEqual(@as(?*Element, null), doc.querySelector("h2"));
}

test "Document.querySelectorAll — finds all <p> elements" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><p>a</p><p>b</p><p>c</p></body></html>");
    defer doc.deinit();
    const results = try doc.querySelectorAll("p", std.testing.allocator);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
}

test "Element.getAttribute — returns value" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><a href=\"/page\">link</a></body></html>");
    defer doc.deinit();
    const a = doc.querySelector("a");
    try std.testing.expect(a != null);
    const href = a.?.getAttribute("href");
    try std.testing.expect(href != null);
    try std.testing.expectEqualStrings("/page", href.?);
}

test "Element.getAttribute — case-insensitive" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><input type=\"text\"/></body></html>");
    defer doc.deinit();
    const input = doc.querySelector("input");
    try std.testing.expect(input != null);
    try std.testing.expect(input.?.getAttribute("type") != null);
    try std.testing.expect(input.?.getAttribute("TYPE") != null);
}

test "Element.getAttribute — null for missing attr" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><div>hello</div></body></html>");
    defer doc.deinit();
    const div = doc.querySelector("div");
    try std.testing.expect(div != null);
    try std.testing.expectEqual(@as(?[]const u8, null), div.?.getAttribute("class"));
}

test "Element.textContent — contains inner text" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><p>hello <strong>world</strong></p></body></html>");
    defer doc.deinit();
    const p = doc.querySelector("p") orelse return error.SkipZigTest;
    const text = try p.textContent(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "world") != null);
}

test "Element.textContentForExtract — skips <style>, <script>, <noscript>, <template>" {
    var doc = try parseDocument(
        std.testing.allocator,
        "<html><body>" ++
            "<style>.x{color:red}</style>" ++
            "<p>hi</p>" ++
            "<script>alert(1)</script>" ++
            "<noscript>js disabled</noscript>" ++
            "<template><span>tpl</span></template>" ++
            "<p>bye</p>" ++
            "</body></html>",
    );
    defer doc.deinit();
    const body = doc.querySelector("body") orelse return error.SkipZigTest;

    // Spec-compliant textContent still includes everything (WPT contract).
    const raw = try body.textContent(std.testing.allocator);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "color:red") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "alert(1)") != null);

    // Agent-facing extract drops opaque-content descendants.
    const clean = try body.textContentForExtract(std.testing.allocator);
    defer std.testing.allocator.free(clean);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, clean, "color:red"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, clean, "alert(1)"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, clean, "js disabled"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, clean, "tpl"));
    try std.testing.expect(std.mem.indexOf(u8, clean, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "bye") != null);
}

test "Element.textContentForExtract — case-insensitive tag matching" {
    // HTML tags are case-insensitive in markup but the parser may
    // normalize. Assert by feeding mixed-case markup; if the parser
    // lowercases tags, the filter still applies; if it preserves
    // case, the std.ascii.eqlIgnoreCase guard still applies.
    var doc = try parseDocument(
        std.testing.allocator,
        "<html><body><STYLE>.y{}</STYLE><p>kept</p></body></html>",
    );
    defer doc.deinit();
    const body = doc.querySelector("body") orelse return error.SkipZigTest;
    const clean = try body.textContentForExtract(std.testing.allocator);
    defer std.testing.allocator.free(clean);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, clean, ".y{}"));
    try std.testing.expect(std.mem.indexOf(u8, clean, "kept") != null);
}

test "template content is included in DOM queries and text" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><template><section id=\"inside\"><p>Template text</p></section></template></body></html>");
    defer doc.deinit();

    const inside = doc.getElementById("inside");
    try std.testing.expect(inside != null);
    try std.testing.expectEqualStrings("section", inside.?.tag);

    const template = doc.querySelector("template") orelse return error.SkipZigTest;
    const text = try template.textContent(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Template text") != null);
}

test "querySelector — tag.class compound selector" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><p class=\"note\">text</p></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector("p.note");
    try std.testing.expect(elem != null);
    try std.testing.expectEqualStrings("p", elem.?.tag);
}

test "querySelector — attribute selectors" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><div data-x=\"1\"></div><div data-x=\"2\"></div></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.querySelector("[data-x]") != null);
    const eq = doc.querySelector("[data-x='2']");
    try std.testing.expect(eq != null);
}

test "querySelector — :not pseudo-class" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><p class=\"a\"></p><p class=\"b\"></p></body></html>");
    defer doc.deinit();
    const elem = doc.querySelector("p:not(.a)");
    try std.testing.expect(elem != null);
    try std.testing.expect(std.mem.eql(u8, elem.?.getAttribute("class") orelse "", "b"));
}

test "querySelector — combinators > + ~" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><div id=\"wrap\"><span class=\"a\"></span><span class=\"b\"></span><em></em><span class=\"c\"></span></div></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.querySelector("div > span.b") != null);
    try std.testing.expect(doc.querySelector("span.a + span.b") != null);
    try std.testing.expect(doc.querySelector("span.a ~ span.c") != null);
}

test "querySelector — multi-class selector" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><li class=\"foo bar\">x</li></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.querySelector("li.foo.bar") != null);
}

test "Element.querySelector scopes to descendants" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><section id=\"first\"><p class=\"item\">one</p></section><section id=\"scope\"><p class=\"item\">two</p><div><p class=\"item\">three</p></div></section></body></html>");
    defer doc.deinit();

    const scope = doc.getElementById("scope") orelse return error.SkipZigTest;
    const found = scope.querySelector(".item");
    try std.testing.expect(found != null);
    const text = try found.?.textContent(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("two", text);
}

test "Element.querySelectorAll scopes to descendants" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><section id=\"first\"><p class=\"item\">one</p></section><section id=\"scope\"><p class=\"item\">two</p><div><p class=\"item\">three</p></div></section></body></html>");
    defer doc.deinit();

    const scope = doc.getElementById("scope") orelse return error.SkipZigTest;
    const found = try scope.querySelectorAll(".item", std.testing.allocator);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
}

test "Element.matches supports compound selectors" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><section class=\"shell\"><div><p id=\"leaf\" class=\"copy\">hello</p></div></section></body></html>");
    defer doc.deinit();

    const leaf = doc.getElementById("leaf") orelse return error.SkipZigTest;
    try std.testing.expect(leaf.matches("p.copy"));
    try std.testing.expect(!leaf.matches("section.shell"));
}

test "Element.closest walks ancestors" {
    var doc = try parseDocument(std.testing.allocator, "<html><body><section class=\"shell\"><div><p id=\"leaf\" class=\"copy\">hello</p></div></section></body></html>");
    defer doc.deinit();

    const leaf = doc.getElementById("leaf") orelse return error.SkipZigTest;
    const section = leaf.closest("section.shell");
    try std.testing.expect(section != null);
    try std.testing.expectEqualStrings("section", section.?.tag);
}
