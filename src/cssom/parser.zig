const std = @import("std");
const style_mod = @import("style.zig");

pub const Rule = struct {
    selector_text: []u8,
    declarations: style_mod.StyleDeclaration,

    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.selector_text);
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
        const selector = std.mem.trim(u8, css[pos..open_rel], " \t\r\n");
        const body = css[open_rel + 1 .. close_rel];
        pos = close_rel + 1;

        if (selector.len == 0) continue;
        if (selector[0] == '@') continue;

        var decls = try style_mod.StyleDeclaration.parse(allocator, body);
        errdefer decls.deinit();
        try sheet.rules.append(allocator, .{
            .selector_text = try allocator.dupe(u8, selector),
            .declarations = decls,
        });
    }

    return sheet;
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
}
