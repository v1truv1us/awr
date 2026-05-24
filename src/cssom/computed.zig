const std = @import("std");
const dom = @import("dom");
const parser_mod = @import("parser.zig");
const style_mod = @import("style.zig");
const cascade_mod = @import("cascade.zig");

pub const StyleResolver = struct {
    allocator: std.mem.Allocator,
    stylesheets: []const parser_mod.Stylesheet,

    pub fn init(allocator: std.mem.Allocator, stylesheets: []const parser_mod.Stylesheet) StyleResolver {
        return .{
            .allocator = allocator,
            .stylesheets = stylesheets,
        };
    }

    pub fn resolveProperty(self: *const StyleResolver, elem: *const dom.Element, prop_name: []const u8) []const u8 {
        var best_match: ?cascade_mod.MatchResult = null;

        // 1. Resolve from stylesheets (Cascade Priority)
        for (self.stylesheets, 0..) |sheet, source_idx| {
            for (sheet.rules.items, 0..) |rule, rule_idx| {
                if (matchesElement(elem, &rule)) {
                    const val = rule.declarations.getPropertyValue(prop_name);
                    if (val.len > 0) {
                        const is_important = isImportantDecl(&rule.declarations, prop_name);
                        const match = cascade_mod.MatchResult{
                            .specificity = rule.specificity,
                            .source_index = source_idx,
                            .rule_index = rule_idx,
                            .value = val,
                            .important = is_important,
                        };
                        if (best_match == null or match.isPrecedentOver(best_match.?)) {
                            best_match = match;
                        }
                    }
                }
            }
        }

        // 2. Resolve from inline style attribute
        if (elem.getAttribute("style")) |style_attr| {
            var inline_decl = style_mod.StyleDeclaration.parse(self.allocator, style_attr) catch null;
            if (inline_decl) |*decl| {
                defer decl.deinit();
                const inline_val = decl.getPropertyValue(prop_name);
                if (inline_val.len > 0) {
                    const is_important = isImportantDecl(decl, prop_name);
                    const inline_match = cascade_mod.MatchResult{
                        .specificity = .{ .id = 9999, .class = 0, .element = 0 }, // inline specificity beats any stylesheet
                        .source_index = 9999,
                        .rule_index = 9999,
                        .value = inline_val,
                        .important = is_important,
                    };
                    if (best_match == null or inline_match.isPrecedentOver(best_match.?)) {
                        // Special case: if a stylesheet had an !important flag, and the inline style does NOT,
                        // the stylesheet !important wins. MatchResult.isPrecedentOver handles this!
                        best_match = inline_match;
                    }
                }
            }
        }

        if (best_match) |match| {
            // Note: Since match.value points to slices owned by Stylesheet or parsed inline attributes,
            // we return a temporary/safe slice context. Standard practice is page-allocator dupe if lifetime matters,
            // but for simple resolution standard pointers work if parents outlive resolveProperty.
            return match.value;
        }

        return "";
    }

    fn isImportantDecl(decl: *const style_mod.StyleDeclaration, prop_name: []const u8) bool {
        for (decl.declarations.items) |d| {
            if (std.ascii.eqlIgnoreCase(d.name, prop_name)) {
                return d.important;
            }
        }
        return false;
    }

    fn matchesElement(elem: *const dom.Element, rule: *const parser_mod.Rule) bool {
        if (rule.selectors.items.len == 0) return false;

        // An element matches a compound/list rule if it matches AT LEAST ONE individual component in the comma split.
        // For our pre-parsed list, we check if all sub-tokens of a selector segment match.
        // Note: For simple non-layout CSSOM, we match tag names, class list, and ids.
        for (rule.selectors.items) |sel| {
            switch (sel.sel_type) {
                .universal => return true,
                .tag => {
                    if (std.ascii.eqlIgnoreCase(elem.tag, sel.value)) return true;
                },
                .id => {
                    if (elem.getAttribute("id")) |id| {
                        if (std.mem.eql(u8, id, sel.value)) return true;
                    }
                },
                .class => {
                    if (elem.getAttribute("class")) |classes| {
                        var parts = std.mem.splitScalar(u8, classes, ' ');
                        while (parts.next()) |class_name| {
                            if (std.mem.eql(u8, class_name, sel.value)) return true;
                        }
                    }
                },
            }
        }
        return false;
    }
};

test "StyleResolver resolves computed cascade values" {
    // Emulate parsed stylesheet rules
    // Note: Rule owns its declarations. To avoid double-free during test teardown
    // when both rule and p_style/class_style are manually deinitialized, we let
    // the rules take ownership directly, or we deinit them properly.
    // Instead of parsing into p_style/class_style and copying, we parse directly
    // or we duplicate the styles.
    var rule_p = parser_mod.Rule{
        .selector_text = try std.testing.allocator.dupe(u8, "p"),
        .declarations = try style_mod.StyleDeclaration.parse(std.testing.allocator, "color: blue; display: block;"),
        .specificity = cascade_mod.Specificity.calculate("p"),
    };
    try rule_p.selectors.append(std.testing.allocator, .{ .sel_type = .tag, .value = try std.testing.allocator.dupe(u8, "p") });
    defer rule_p.deinit(std.testing.allocator);

    var rule_class = parser_mod.Rule{
        .selector_text = try std.testing.allocator.dupe(u8, ".hide-me"),
        .declarations = try style_mod.StyleDeclaration.parse(std.testing.allocator, "color: red !important;"),
        .specificity = cascade_mod.Specificity.calculate(".hide-me"),
    };
    try rule_class.selectors.append(std.testing.allocator, .{ .sel_type = .class, .value = try std.testing.allocator.dupe(u8, "hide-me") });
    defer rule_class.deinit(std.testing.allocator);

    var sheet = parser_mod.Stylesheet.init(std.testing.allocator);
    defer sheet.rules.deinit(std.testing.allocator); // rules themselves are freed by hand via rule_p/rule_class
    try sheet.rules.append(std.testing.allocator, rule_p);
    try sheet.rules.append(std.testing.allocator, rule_class);

    const doc_html = "<html><body><p class=\"hide-me\" style=\"color: yellow\">Text</p></body></html>";
    var doc = try dom.parseDocument(std.testing.allocator, doc_html);
    defer doc.deinit();

    const list = try doc.querySelectorAll("p", std.testing.allocator);
    defer std.testing.allocator.free(list);
    const p_elem = list[0];

    const resolver = StyleResolver.init(std.testing.allocator, &.{sheet});

    // 1. Color: stylesheet has `.hide-me { color: red !important }`, inline style has `style="color: yellow"`.
    // Red wins because !important beats normal inline style.
    try std.testing.expectEqualStrings("red", resolver.resolveProperty(p_elem, "color"));

    // 2. Display: stylesheet has `p { display: block }`. Block wins.
    try std.testing.expectEqualStrings("block", resolver.resolveProperty(p_elem, "display"));
}
