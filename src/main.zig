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
    \\  awr <url>                    Load URL/path, print JSON {url, status, title, body_text, window_data, tools}
    \\  awr tools <url>              Load URL/path, print the JSON array of registered WebMCP tools
    \\  awr call <url> <name> <json> Load URL/path, invoke tool <name> with <json> args, print result envelope
    \\  awr --version                Print version and exit
    \\
    \\<url> may be an http(s):// URL, a file:// URL, or a local filesystem path.
    \\
;

fn stdoutWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

/// Load a page from either an http(s):// URL or a local file path.
/// The returned PageResult is owned by the caller.
fn loadPage(
    p: *page_mod.Page,
    alloc: std.mem.Allocator,
    io: std.Io,
    location: []const u8,
) !page_mod.PageResult {
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        return p.navigate(location);
    }

    const path: []const u8 = if (std.mem.startsWith(u8, location, "file://"))
        location[7..]
    else
        location;

    const html = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024));
    defer alloc.free(html);

    const synthetic_url = if (std.mem.startsWith(u8, location, "file://"))
        try alloc.dupe(u8, location)
    else
        try std.fmt.allocPrint(alloc, "file://{s}", .{path});
    defer alloc.free(synthetic_url);

    return p.processHtml(synthetic_url, 200, html);
}

// We accept `Init.Minimal` instead of the richer `Init` so that Zig's
// startup code in `std/start.zig` skips its own `DebugAllocator` setup.
// That allocator captures a stack trace on every allocation, which in Zig
// 0.16 panics with `integer overflow` inside
// `std/debug/SelfInfo/Elf.zig:{460,472}` — the VDSO's `phdr.vaddr =
// 0xffffffffff700000` is added to `info.addr` without wrapping arithmetic.
// The buggy code path runs before `main`, so instrumenting here is too
// late; the only in-repo fix is to never take that path. Upstream needs
// `info.addr +% phdr.vaddr` on those two lines (line 497 already does
// this for the .LOAD case).
pub fn main(minimal: std.process.Init.Minimal) !void {
    // `c_allocator` because build.zig links libc; this matches what
    // `std/start.zig` does in ReleaseSafe/Fast and keeps the CLI well away
    // from the `DebugAllocator` path above.
    const alloc = std.heap.c_allocator;

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();

    var threaded: std.Io.Threaded = .init(alloc, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const args = try minimal.args.toSlice(arena_state.allocator());

    if (args.len < 2) {
        try stdoutWrite(io, USAGE);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        const out = try std.fmt.allocPrint(alloc, "0.0.{s}\n", .{build_opts.git_hash});
        defer alloc.free(out);
        try stdoutWrite(io, out);
        return;
    }

    // Subcommand: awr tools <url>
    if (std.mem.eql(u8, args[1], "tools")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr tools <url>\n");
            std.process.exit(1);
        }
        var p = try page_mod.Page.init(alloc);
        defer p.deinit();
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            std.process.fatal("error loading {s}: {t}", .{ args[2], err });
        };
        defer result.deinit();
        const tj = result.tools_json orelse "[]";
        try stdoutWrite(io, tj);
        try stdoutWrite(io, "\n");
        return;
    }

    // Subcommand: awr call <url> <tool> <json>
    if (std.mem.eql(u8, args[1], "call")) {
        if (args.len < 5) {
            try stdoutWrite(io, "usage: awr call <url> <tool-name> <json-args>\n");
            std.process.exit(1);
        }
        var p = try page_mod.Page.init(alloc);
        defer p.deinit();
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            std.process.fatal("error loading {s}: {t}", .{ args[2], err });
        };
        defer result.deinit();
        const out = try p.callTool(args[3], args[4]);
        defer alloc.free(out);
        try stdoutWrite(io, out);
        try stdoutWrite(io, "\n");
        return;
    }

    // Default: treat arg as a URL/path and print the full JSON envelope.
    const url = args[1];
    var p = try page_mod.Page.init(alloc);
    defer p.deinit();

    var result = loadPage(&p, alloc, io, url) catch |err| {
        std.process.fatal("error fetching {s}: {t}", .{ url, err });
    };
    defer result.deinit();

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

    try stdoutWrite(io, buf.items);
}
