const std = @import("std");
const style_mod = @import("style.zig");
const cascade_mod = @import("cascade.zig");

pub const SelectorType = enum {
    universal,
    tag,
    class,
    id,
};

pub const Selector = struct {
    sel_type: SelectorType,
    value: []const u8,
};

pub const Rule = struct {
    selector_text: []u8,
    // Pre-parsed individual simple selectors for the fast OR-matching path.
    // Only valid (i.e. sufficient for matching) when `complex` is false.
    selectors: std.ArrayListUnmanaged(Selector) = .empty,
    // True when at least one comma-part is a compound selector (e.g. `div.foo`)
    // or uses a combinator (descendant/child/sibling). The flat `selectors`
    // list can't represent those, so matchers must fall back to the full DOM
    // selector engine (`dom.Element.matches`) for correct semantics.
    complex: bool = false,
    /// The `@media` condition this rule is nested under (e.g. `(min-width:
    /// 600px)`), owned, or null for unconditional rules. Cascades must skip the
    /// rule when the condition does not match the viewport (`mediaMatches`).
    media: ?[]u8 = null,
    declarations: style_mod.StyleDeclaration,
    specificity: cascade_mod.Specificity,

    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.selector_text);
        for (self.selectors.items) |sel| {
            allocator.free(sel.value);
        }
        self.selectors.deinit(allocator);
        if (self.media) |m| allocator.free(m);
        self.declarations.deinit();
    }
};

pub const Stylesheet = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,

    pub fn init(allocator: std.mem.Allocator) Stylesheet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Stylesheet) void {
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
    }
};

pub fn parseStylesheet(allocator: std.mem.Allocator, css: []const u8) !Stylesheet {
    var sheet = Stylesheet.init(allocator);
    errdefer sheet.deinit();
    try parseRuleBlock(allocator, &sheet, css, null);
    return sheet;
}

/// Index of the `}` matching the `{` at `open`, or `css.len` if unterminated.
fn matchBrace(css: []const u8, open: usize) usize {
    var depth: i32 = 0;
    var i = open;
    while (i < css.len) : (i += 1) {
        if (css[i] == '{') depth += 1 else if (css[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return css.len;
}

/// Parse top-level rules out of `css`, attaching `media` (the enclosing
/// `@media` condition, or null) to each. `@media` blocks recurse with their
/// condition; other at-rules (`@font-face`, `@keyframes`, …) are skipped.
fn parseRuleBlock(allocator: std.mem.Allocator, sheet: *Stylesheet, css: []const u8, media: ?[]const u8) anyerror!void {
    var pos: usize = 0;
    while (pos < css.len) {
        const open_rel = std.mem.indexOfScalarPos(u8, css, pos, '{') orelse break;
        const prelude = std.mem.trim(u8, css[pos..open_rel], " \t\r\n");

        if (prelude.len > 0 and prelude[0] == '@') {
            const block_end = matchBrace(css, open_rel);
            if (std.ascii.startsWithIgnoreCase(prelude, "@media")) {
                const cond = std.mem.trim(u8, prelude["@media".len..], " \t\r\n");
                // Nested @media: the inner condition wins for simplicity
                // (nested media queries are rare); otherwise inherit outer.
                const eff = if (media) |outer| (if (cond.len == 0) outer else cond) else cond;
                const inner_end = @min(block_end, css.len);
                try parseRuleBlock(allocator, sheet, css[open_rel + 1 .. inner_end], eff);
            }
            pos = if (block_end < css.len) block_end + 1 else css.len;
            continue;
        }

        const close_rel = std.mem.indexOfScalarPos(u8, css, open_rel + 1, '}') orelse break;
        const selector_text = prelude;
        const body = css[open_rel + 1 .. close_rel];
        pos = close_rel + 1;

        if (selector_text.len == 0) continue;

        var decls = try style_mod.StyleDeclaration.parse(allocator, body);
        errdefer decls.deinit();

        var rule = Rule{
            .selector_text = try allocator.dupe(u8, selector_text),
            .media = if (media) |m| try allocator.dupe(u8, m) else null,
            .declarations = decls,
            .specificity = cascade_mod.Specificity.calculate(selector_text),
        };
        errdefer rule.deinit(allocator);

        // Pre-parse comma-separated selectors for fast matching
        var parts = std.mem.splitScalar(u8, selector_text, ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len == 0) continue;

            // A combinator (descendant/child/adjacent/sibling), an attribute
            // selector (`[...]`), or a pseudo-class (`:...`) makes this part a
            // complex selector the flat token list can't represent — defer it
            // to the full DOM engine.
            if (std.mem.indexOfAny(u8, trimmed, " \t>+~[:") != null) rule.complex = true;
            const tokens_before = rule.selectors.items.len;

            // Split compound selectors (e.g. tag.class or tag#id) into matchable pieces
            var idx: usize = 0;
            while (idx < trimmed.len) {
                const char = trimmed[idx];
                if (char == '.') {
                    idx += 1;
                    const start = idx;
                    while (idx < trimmed.len and isIdentChar(trimmed[idx])) : (idx += 1) {}
                    if (start < idx) {
                        try rule.selectors.append(allocator, .{
                            .sel_type = .class,
                            .value = try allocator.dupe(u8, trimmed[start..idx]),
                        });
                    }
                } else if (char == '#') {
                    idx += 1;
                    const start = idx;
                    while (idx < trimmed.len and isIdentChar(trimmed[idx])) : (idx += 1) {}
                    if (start < idx) {
                        try rule.selectors.append(allocator, .{
                            .sel_type = .id,
                            .value = try allocator.dupe(u8, trimmed[start..idx]),
                        });
                    }
                } else if (isIdentStart(char)) {
                    const start = idx;
                    while (idx < trimmed.len and isIdentChar(trimmed[idx])) : (idx += 1) {}
                    if (start < idx) {
                        try rule.selectors.append(allocator, .{
                            .sel_type = .tag,
                            .value = try allocator.dupe(u8, trimmed[start..idx]),
                        });
                    }
                } else if (char == '*') {
                    try rule.selectors.append(allocator, .{
                        .sel_type = .universal,
                        .value = try allocator.dupe(u8, "*"),
                    });
                    idx += 1;
                } else {
                    idx += 1;
                }
            }

            // More than one simple selector in a single comma-part means a
            // compound selector (e.g. `div.foo`), which requires AND semantics
            // the flat OR list can't express.
            if (rule.selectors.items.len - tokens_before > 1) rule.complex = true;
        }

        try sheet.rules.append(allocator, rule);
    }
}

/// Evaluate a CSS media-query condition against a viewport sized `vw_px` ×
/// `vh_px` CSS pixels. Mirrors the JS `matchMedia` evaluator
/// (`src/js/engine.zig`): comma = OR, `and` = AND of parenthesized features;
/// supports `(min|max)-width`, `(min|max)-height`, `prefers-color-scheme`
/// (terminal default is dark), and the `screen`/`all` media types. Unknown
/// features are treated as non-matching (conservative).
pub fn mediaMatches(query: []const u8, vw_px: i64, vh_px: i64) bool {
    var ors = std.mem.splitScalar(u8, query, ',');
    while (ors.next()) |part| {
        if (mediaConjunctionMatches(std.mem.trim(u8, part, " \t\r\n"), vw_px, vh_px)) return true;
    }
    return false;
}

fn mediaConjunctionMatches(q: []const u8, vw_px: i64, vh_px: i64) bool {
    if (q.len == 0) return true; // empty == `all`
    var negate = false;
    var rest = q;
    if (std.ascii.startsWithIgnoreCase(rest, "not ")) {
        negate = true;
        rest = std.mem.trim(u8, rest[4..], " \t\r\n");
    } else if (std.ascii.startsWithIgnoreCase(rest, "only ")) {
        rest = std.mem.trim(u8, rest[5..], " \t\r\n");
    }
    var result = true;
    var it = std.mem.splitSequence(u8, rest, " and ");
    while (it.next()) |raw_term| {
        const term = std.mem.trim(u8, raw_term, " \t\r\n");
        if (term.len == 0) continue;
        if (!mediaTermMatches(term, vw_px, vh_px)) {
            result = false;
            break;
        }
    }
    return result != negate;
}

fn mediaTermMatches(term_in: []const u8, vw_px: i64, vh_px: i64) bool {
    var term = term_in;
    // A bare media type: screen/all match; print/speech don't.
    if (term.len > 0 and term[0] != '(') {
        if (std.ascii.eqlIgnoreCase(term, "screen") or std.ascii.eqlIgnoreCase(term, "all")) return true;
        return false;
    }
    // Strip one outer paren pair.
    if (term.len >= 2 and term[0] == '(' and term[term.len - 1] == ')') {
        term = std.mem.trim(u8, term[1 .. term.len - 1], " \t\r\n");
    }
    const colon = std.mem.indexOfScalar(u8, term, ':') orelse return false;
    const feat = std.mem.trim(u8, term[0..colon], " \t\r\n");
    const val = std.mem.trim(u8, term[colon + 1 ..], " \t\r\n");

    if (std.ascii.eqlIgnoreCase(feat, "prefers-color-scheme")) {
        return std.ascii.eqlIgnoreCase(val, "dark"); // terminal default is dark
    }
    const is_width = std.ascii.eqlIgnoreCase(feat, "min-width") or std.ascii.eqlIgnoreCase(feat, "max-width");
    const is_height = std.ascii.eqlIgnoreCase(feat, "min-height") or std.ascii.eqlIgnoreCase(feat, "max-height");
    if (is_width or is_height) {
        const px = parsePx(val) orelse return false;
        const actual = if (is_width) vw_px else vh_px;
        const is_min = std.ascii.startsWithIgnoreCase(feat, "min");
        return if (is_min) actual >= px else actual <= px;
    }
    return false;
}

fn parsePx(val: []const u8) ?i64 {
    const trimmed = if (std.ascii.endsWithIgnoreCase(val, "px")) val[0 .. val.len - 2] else val;
    const t = std.mem.trim(u8, trimmed, " \t\r\n");
    const dot = std.mem.indexOfScalar(u8, t, '.');
    const int_part = if (dot) |d| t[0..d] else t;
    return std.fmt.parseInt(i64, int_part, 10) catch null;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

test "CSSOM parser parses simple stylesheet rules" {
    var sheet = try parseStylesheet(std.testing.allocator,
        \\ .a, #b { display: none; visibility: hidden; }
        \\ @media screen { .ignored { display: block; } }
        \\ p { color: red !important; }
    );
    defer sheet.deinit();

    // The @media block's inner rule is now parsed (tagged with its condition),
    // so the sheet has three rules: `.a, #b`, the media-nested `.ignored`, `p`.
    try std.testing.expectEqual(@as(usize, 3), sheet.rules.items.len);
    try std.testing.expectEqualStrings(".a, #b", sheet.rules.items[0].selector_text);
    try std.testing.expectEqualStrings("none", sheet.rules.items[0].declarations.getPropertyValue("display"));
    try std.testing.expectEqualStrings(".ignored", sheet.rules.items[1].selector_text);
    try std.testing.expectEqualStrings("screen", sheet.rules.items[1].media.?);
    try std.testing.expectEqualStrings("red", sheet.rules.items[2].declarations.getPropertyValue("color"));
    try std.testing.expect(sheet.rules.items[2].declarations.declarations.items[0].important);

    // Verify pre-parsed selectors
    const rule1 = sheet.rules.items[0];
    try std.testing.expectEqual(@as(usize, 2), rule1.selectors.items.len);
    try std.testing.expect(rule1.selectors.items[0].sel_type == .class);
    try std.testing.expectEqualStrings("a", rule1.selectors.items[0].value);
    try std.testing.expect(rule1.selectors.items[1].sel_type == .id);
    try std.testing.expectEqualStrings("b", rule1.selectors.items[1].value);
}

test "CSSOM parser attaches @media conditions and mediaMatches evaluates them" {
    var sheet = try parseStylesheet(std.testing.allocator,
        \\ p { color: black; }
        \\ @media (min-width: 600px) { p { color: red; } .wide { display: block; } }
        \\ @media (max-width: 100px) { p { color: blue; } }
    );
    defer sheet.deinit();

    try std.testing.expectEqual(@as(usize, 4), sheet.rules.items.len);
    try std.testing.expect(sheet.rules.items[0].media == null); // unconditional
    try std.testing.expectEqualStrings("(min-width: 600px)", sheet.rules.items[1].media.?);
    try std.testing.expectEqualStrings("red", sheet.rules.items[1].declarations.getPropertyValue("color"));
    try std.testing.expectEqualStrings("(max-width: 100px)", sheet.rules.items[3].media.?);

    // 640 CSS px viewport (80 cols * 8): min-width:600 matches, max-width:100 does not.
    try std.testing.expect(mediaMatches("(min-width: 600px)", 640, 384));
    try std.testing.expect(!mediaMatches("(min-width: 700px)", 640, 384));
    try std.testing.expect(!mediaMatches("(max-width: 100px)", 640, 384));
    try std.testing.expect(mediaMatches("(max-width: 640px)", 640, 384));
    try std.testing.expect(mediaMatches("screen and (min-width: 600px)", 640, 384));
    try std.testing.expect(mediaMatches("(prefers-color-scheme: dark)", 640, 384));
    try std.testing.expect(!mediaMatches("(prefers-color-scheme: light)", 640, 384));
    try std.testing.expect(mediaMatches("(max-width: 100px), (min-width: 600px)", 640, 384));
}

test "CSSOM parser flags compound and combinator selectors as complex" {
    var sheet = try parseStylesheet(std.testing.allocator,
        \\ p { color: red; }
        \\ .a, #b { color: red; }
        \\ div.foo { color: red; }
        \\ section p { color: red; }
        \\ ul > li { color: red; }
    );
    defer sheet.deinit();

    try std.testing.expectEqual(@as(usize, 5), sheet.rules.items.len);
    try std.testing.expect(!sheet.rules.items[0].complex); // `p` — simple
    try std.testing.expect(!sheet.rules.items[1].complex); // `.a, #b` — comma list of simples
    try std.testing.expect(sheet.rules.items[2].complex); // `div.foo` — compound
    try std.testing.expect(sheet.rules.items[3].complex); // `section p` — descendant
    try std.testing.expect(sheet.rules.items[4].complex); // `ul > li` — child
}
