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

const USAGE =
    \\AWR — Agentic Web Runtime
    \\
    \\Usage:
    \\  awr <url>                    Load URL, print JSON {url, status, title, body_text, window_data, tools}
    \\  awr tools <url>              Load URL, print the JSON array of registered WebMCP tools
    \\  awr call <url> <name> <json> Load URL, invoke tool <name> with <json> args, print result envelope
    \\  awr --version                Print version and exit
    \\
    \\<url> may be an http(s):// URL, a file:// URL, or a local path.
    \\
;

/// Load a page from either an http(s):// URL or a local file path.
/// Returns the PageResult; caller owns it.
fn loadPage(p: *page_mod.Page, alloc: std.mem.Allocator, location: []const u8) !page_mod.PageResult {
    // http(s)://  → network navigate
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        return p.navigate(location);
    }

    // file://path  → strip prefix and read from disk
    const path: []const u8 = if (std.mem.startsWith(u8, location, "file://"))
        location[7..]
    else
        location;

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const html = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(html);

    // Synthesize a file:// URL so window.location.href is sensible.
    const synthetic_url = if (std.mem.startsWith(u8, location, "file://"))
        try alloc.dupe(u8, location)
    else
        try std.fmt.allocPrint(alloc, "file://{s}", .{path});
    defer alloc.free(synthetic_url);

    return p.processHtml(synthetic_url, 200, html);
}

fn writeAllStdout(bytes: []const u8) !void {
    _ = try std.posix.write(std.posix.STDOUT_FILENO, bytes);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        try writeAllStdout(USAGE);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        const out = try std.fmt.allocPrint(alloc, "0.0.{s}\n", .{build_opts.git_hash});
        defer alloc.free(out);
        try writeAllStdout(out);
        return;
    }

    // Subcommand: awr tools <url>
    if (std.mem.eql(u8, args[1], "tools")) {
        if (args.len < 3) {
            try writeAllStdout("usage: awr tools <url>\n");
            std.process.exit(1);
        }
        var p = try page_mod.Page.init(alloc);
        defer p.deinit();
        var result = loadPage(&p, alloc, args[2]) catch |err| {
            std.debug.print("error loading {s}: {any}\n", .{ args[2], err });
            std.process.exit(1);
        };
        defer result.deinit();
        const tj = result.tools_json orelse "[]";
        try writeAllStdout(tj);
        try writeAllStdout("\n");
        return;
    }

    // Subcommand: awr call <url> <tool> <json>
    if (std.mem.eql(u8, args[1], "call")) {
        if (args.len < 5) {
            try writeAllStdout("usage: awr call <url> <tool-name> <json-args>\n");
            std.process.exit(1);
        }
        var p = try page_mod.Page.init(alloc);
        defer p.deinit();
        var result = loadPage(&p, alloc, args[2]) catch |err| {
            std.debug.print("error loading {s}: {any}\n", .{ args[2], err });
            std.process.exit(1);
        };
        defer result.deinit();
        const out = try p.callTool(args[3], args[4]);
        defer alloc.free(out);
        try writeAllStdout(out);
        try writeAllStdout("\n");
        return;
    }

    // Default: treat arg as a URL/path and print the full JSON envelope.
    const url = args[1];
    var p = try page_mod.Page.init(alloc);
    defer p.deinit();

    var result = loadPage(&p, alloc, url) catch |err| {
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
    try buf.appendSlice(alloc, ",\"tools\":");
    if (result.tools_json) |tj| try buf.appendSlice(alloc, tj) else try buf.appendSlice(alloc, "[]");
    try buf.appendSlice(alloc, "}\n");

    try writeAllStdout(buf.items);
}
