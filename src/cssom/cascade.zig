const std = @import("std");

pub const Specificity = struct {
    id: u16 = 0,
    class: u16 = 0,
    element: u16 = 0,

    pub fn compare(self: Specificity, other: Specificity) std.math.Order {
        if (self.id != other.id) {
            return if (self.id < other.id) .lt else .gt;
        }
        if (self.class != other.class) {
            return if (self.class < other.class) .lt else .gt;
        }
        if (self.element != other.element) {
            return if (self.element < other.element) .lt else .gt;
        }
        return .eq;
    }

    pub fn isLessThan(self: Specificity, other: Specificity) bool {
        return self.compare(other) == .lt;
    }

    pub fn calculate(selector: []const u8) Specificity {
        var spec = Specificity{};
        var i: usize = 0;
        const s = std.mem.trim(u8, selector, " \t\r\n");

        while (i < s.len) {
            const char = s[i];
            if (char == '#') {
                spec.id += 1;
                i += 1;
                while (i < s.len and isIdentChar(s[i])) : (i += 1) {}
            } else if (char == '.') {
                spec.class += 1;
                i += 1;
                while (i < s.len and isIdentChar(s[i])) : (i += 1) {}
            } else if (isIdentStart(char)) {
                spec.element += 1;
                i += 1;
                while (i < s.len and isIdentChar(s[i])) : (i += 1) {}
            } else {
                i += 1;
            }
        }
        return spec;
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

test "Specificity calculation" {
    const s1 = Specificity.calculate("div");
    try std.testing.expectEqual(@as(u16, 0), s1.id);
    try std.testing.expectEqual(@as(u16, 0), s1.class);
    try std.testing.expectEqual(@as(u16, 1), s1.element);

    const s2 = Specificity.calculate(".class");
    try std.testing.expectEqual(@as(u16, 0), s2.id);
    try std.testing.expectEqual(@as(u16, 1), s2.class);
    try std.testing.expectEqual(@as(u16, 0), s2.element);

    const s3 = Specificity.calculate("#id");
    try std.testing.expectEqual(@as(u16, 1), s3.id);
    try std.testing.expectEqual(@as(u16, 0), s3.class);
    try std.testing.expectEqual(@as(u16, 0), s3.element);

    const s4 = Specificity.calculate("div.class#id");
    try std.testing.expectEqual(@as(u16, 1), s4.id);
    try std.testing.expectEqual(@as(u16, 1), s4.class);
    try std.testing.expectEqual(@as(u16, 1), s4.element);
}

test "Specificity comparison" {
    const s1 = Specificity.calculate("div");
    const s2 = Specificity.calculate(".class");
    const s3 = Specificity.calculate("#id");

    try std.testing.expect(s1.isLessThan(s2));
    try std.testing.expect(s2.isLessThan(s3));
    try std.testing.expect(!s3.isLessThan(s1));
}
