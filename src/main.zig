const std = @import("std");
const build_opts = @import("build_opts");
const page_mod = @import("page");

fn writeJsonStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"'  => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const esc = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c});
                defer alloc.free(esc);
                try list.appendSlice(alloc, esc);
            },
            else => try list.append(alloc, c),
        }
    }
    try list.append(alloc, '"');
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("AWR v0.0.{s}\nUsage: awr <url>\n       awr --version\n", .{build_opts.git_hash});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        const out = try std.fmt.allocPrint(alloc, "0.0.{s}\n", .{build_opts.git_hash});
        defer alloc.free(out);
        _ = try std.posix.write(std.posix.STDOUT_FILENO, out);
        return;
    }

    const url = args[1];
    var p = try page_mod.Page.init(alloc);
    defer p.deinit();

    var result = p.navigate(url) catch |err| {
        std.debug.print("error fetching {s}: {any}\n", .{ url, err });
        std.process.exit(1);
    };
    defer result.deinit();

    // Build JSON output into a managed buffer
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, '{');
    try buf.appendSlice(alloc, "\"url\":");
    try writeJsonStr(&buf, alloc, result.url);
    const status_str = try std.fmt.allocPrint(alloc, ",\"status\":{d}", .{result.status});
    defer alloc.free(status_str);
    try buf.appendSlice(alloc, status_str);
    try buf.appendSlice(alloc, ",\"title\":");
    if (result.title) |t| try writeJsonStr(&buf, alloc, t) else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"body_text\":");
    try writeJsonStr(&buf, alloc, result.body_text);
    try buf.appendSlice(alloc, ",\"window_data\":");
    if (result.window_data) |wd| try buf.appendSlice(alloc, wd) else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, "}\n");

    _ = try std.posix.write(std.posix.STDOUT_FILENO, buf.items);
}
