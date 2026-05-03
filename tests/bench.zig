const std = @import("std");
const page_mod = @import("page");

/// Benchmark: measure page load + render time across different fixture types.
/// Run with: zig build test-bench

const Url = struct {
    label: []const u8,
    url: []const u8,
};

const urls = [_]Url{
    .{ .label = "example.com", .url = "https://example.com/" },
    .{ .label = "hackernews", .url = "https://news.ycombinator.com/" },
    .{ .label = "wikipedia", .url = "https://en.wikipedia.org/wiki/Octopus" },
    .{ .label = "mdn", .url = "https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select" },
};

fn measureAwr(allocator: std.mem.Allocator, io: std.Io, label: []const u8, url: []const u8) !void {
    var page = try page_mod.Page.init(allocator, io);
    defer page.deinit();

    var result = try page.navigate(url);
    defer result.deinit();

    _ = try page.renderBrowseModel(allocator, &result, .{
        .max_width = 78,
        .ansi_colors = false,
        .show_links = true,
        .show_images = false,
    });

    std.debug.print("OK {s}\n", .{label});
}

test "benchmark: page load times" {
    const allocator = std.testing.allocator;

    for (urls) |u| {
        try measureAwr(allocator, std.testing.io, u.label, u.url);
    }
}
