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
    declarations: style_mod.StyleDeclaration,
    specificity: cascade_mod.Specificity,

    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.selector_text);
        for (self.selectors.items) |sel| {
            allocator.free(sel.value);
        }
        self.selectors.deinit(allocator);
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

    var pos: usize = 0;
    while (pos < css.len) {
        const open_rel = std.mem.indexOfScalarPos(u8, css, pos, '{') orelse break;
        const close_rel = std.mem.indexOfScalarPos(u8, css, open_rel + 1, '}') orelse break;
        const selector_text = std.mem.trim(u8, css[pos..open_rel], " \t\r\n");
        const body = css[open_rel + 1 .. close_rel];
        pos = close_rel + 1;

        if (selector_text.len == 0) continue;
        if (selector_text[0] == '@') continue;

        var decls = try style_mod.StyleDeclaration.parse(allocator, body);
        errdefer decls.deinit();

        var rule = Rule{
            .selector_text = try allocator.dupe(u8, selector_text),
            .declarations = decls,
            .specificity = cascade_mod.Specificity.calculate(selector_text),
        };
        errdefer rule.deinit(allocator);

        // Pre-parse comma-separated selectors for fast matching
        var parts = std.mem.splitScalar(u8, selector_text, ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len == 0) continue;

            // A combinator (descendant/child/adjacent/sibling) makes this part
            // a complex selector the flat token list can't represent.
            if (std.mem.indexOfAny(u8, trimmed, " \t>+~") != null) rule.complex = true;
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

    return sheet;
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

    try std.testing.expectEqual(@as(usize, 2), sheet.rules.items.len);
    try std.testing.expectEqualStrings(".a, #b", sheet.rules.items[0].selector_text);
    try std.testing.expectEqualStrings("none", sheet.rules.items[0].declarations.getPropertyValue("display"));
    try std.testing.expectEqualStrings("red", sheet.rules.items[1].declarations.getPropertyValue("color"));
    try std.testing.expect(sheet.rules.items[1].declarations.declarations.items[0].important);

    // Verify pre-parsed selectors
    const rule1 = sheet.rules.items[0];
    try std.testing.expectEqual(@as(usize, 2), rule1.selectors.items.len);
    try std.testing.expect(rule1.selectors.items[0].sel_type == .class);
    try std.testing.expectEqualStrings("a", rule1.selectors.items[0].value);
    try std.testing.expect(rule1.selectors.items[1].sel_type == .id);
    try std.testing.expectEqualStrings("b", rule1.selectors.items[1].value);
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
