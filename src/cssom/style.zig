const std = @import("std");

pub const Declaration = struct {
    name: []u8,
    value: []u8,
    important: bool = false,
};

pub const StyleDeclaration = struct {
    allocator: std.mem.Allocator,
    declarations: std.ArrayList(Declaration) = .empty,

    pub fn init(allocator: std.mem.Allocator) StyleDeclaration {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StyleDeclaration) void {
        for (self.declarations.items) |decl| {
            self.allocator.free(decl.name);
            self.allocator.free(decl.value);
        }
        self.declarations.deinit(self.allocator);
    }

    pub fn parse(allocator: std.mem.Allocator, css_text: []const u8) !StyleDeclaration {
        var style = StyleDeclaration.init(allocator);
        errdefer style.deinit();

        var parts = std.mem.splitScalar(u8, css_text, ';');
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\r\n");
            if (part.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
            const raw_name = std.mem.trim(u8, part[0..colon], " \t\r\n");
            const raw_value = std.mem.trim(u8, part[colon + 1 ..], " \t\r\n");
            if (raw_name.len == 0) continue;
            try style.setProperty(raw_name, raw_value, false);
        }
        return style;
    }

    pub fn getPropertyValue(self: *const StyleDeclaration, name: []const u8) []const u8 {
        var name_buf: [128]u8 = undefined;
        const canonical = canonicalName(&name_buf, name) orelse return "";
        for (self.declarations.items) |decl| {
            if (std.ascii.eqlIgnoreCase(decl.name, canonical)) return decl.value;
        }
        return "";
    }

    pub fn setProperty(self: *StyleDeclaration, name: []const u8, value: []const u8, important: bool) !void {
        const trimmed_name = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed_name.len == 0) return;
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const parsed = parsePriority(trimmed_value, important);

        var name_buf: [128]u8 = undefined;
        const canonical = canonicalName(&name_buf, trimmed_name) orelse return;
        for (self.declarations.items) |*decl| {
            if (std.mem.eql(u8, decl.name, canonical)) {
                self.allocator.free(decl.value);
                decl.value = try self.allocator.dupe(u8, parsed.value);
                decl.important = parsed.important;
                return;
            }
        }
        try self.declarations.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, canonical),
            .value = try self.allocator.dupe(u8, parsed.value),
            .important = parsed.important,
        });
    }

    pub fn removeProperty(self: *StyleDeclaration, name: []const u8) void {
        var name_buf: [128]u8 = undefined;
        const canonical = canonicalName(&name_buf, name) orelse return;
        for (self.declarations.items, 0..) |decl, i| {
            if (std.mem.eql(u8, decl.name, canonical)) {
                self.allocator.free(decl.name);
                self.allocator.free(decl.value);
                _ = self.declarations.orderedRemove(i);
                return;
            }
        }
    }

    pub fn cssText(self: *const StyleDeclaration, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.declarations.items) |decl| {
            try out.appendSlice(allocator, decl.name);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, decl.value);
            if (decl.important) try out.appendSlice(allocator, " !important");
            try out.appendSlice(allocator, ";");
            try out.append(allocator, ' ');
        }
        return out.toOwnedSlice(allocator);
    }
};

const ParsedValue = struct { value: []const u8, important: bool };

fn parsePriority(value: []const u8, important: bool) ParsedValue {
    const needle = "!important";
    if (value.len >= needle.len) {
        const suffix = std.mem.trim(u8, value[value.len - needle.len ..], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(suffix, needle)) {
            return .{ .value = std.mem.trim(u8, value[0 .. value.len - needle.len], " \t\r\n"), .important = true };
        }
    }
    return .{ .value = value, .important = important };
}

fn canonicalName(buf: *[128]u8, name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len > buf.len) return null;
    for (trimmed, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..trimmed.len];
}

test "CSSOM style parses declarations" {
    var style = try StyleDeclaration.parse(std.testing.allocator, " color: red; display: none !important; bad ");
    defer style.deinit();
    try std.testing.expectEqualStrings("red", style.getPropertyValue("color"));
    try std.testing.expectEqualStrings("none", style.getPropertyValue("display"));
    try std.testing.expect(style.declarations.items[1].important);
}

test "CSSOM style set/remove and cssText" {
    var style = StyleDeclaration.init(std.testing.allocator);
    defer style.deinit();
    try style.setProperty("font-weight", "700", false);
    try style.setProperty("font-weight", "bold", true);
    try std.testing.expectEqualStrings("bold", style.getPropertyValue("font-weight"));
    const text = try style.cssText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("font-weight: bold !important; ", text);
    style.removeProperty("font-weight");
    try std.testing.expectEqualStrings("", style.getPropertyValue("font-weight"));
}
