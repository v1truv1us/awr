const std = @import("std");
const build_opts = @import("build_opts");
const browser = @import("browser.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const page_mod = @import("page");

const FetchOptions = struct {
    json: bool = false,
    mcp: bool = false,
    no_color: bool = false,
    width: usize = 80,
    url: ?[]const u8 = null,
};

const PostOptions = struct {
    url: []const u8,
    data: []const u8,
};

const EvalOptions = struct {
    url: []const u8,
    expr: []const u8,
};

const McpCallOptions = struct {
    url: []const u8,
    tool_name: []const u8,
    input_json: ?[]const u8 = null,
};

const CliCommand = union(enum) {
    browse: []const u8,
    fetch: FetchOptions,
    post: PostOptions,
    eval_expr: EvalOptions,
    mcp_call: McpCallOptions,
    mcp_stdio: []const u8,
};

fn printUsage(writer: anytype) !void {
    try writer.writeAll("AWR v0.0.");
    try writer.writeAll(build_opts.git_hash);
    try writer.writeAll("\nUsage:\n  awr [options] <url>\n  awr browse <url>\n  awr post <url> --data <body>\n  awr eval <url> <expr>\n  awr mcp-call <url> <tool-name> [--input <json>]\n  awr mcp-stdio <url>\n\nOptions:\n  --json      Output JSON\n  --mcp       Output discovered WebMCP tools as JSON\n  --width N   Set render width (default: 80)\n  --no-color  Disable ANSI styling\n  --help      Show this help\n  --version   Show version\n");
}

fn parseBrowseArgs(args: []const []const u8) ![]const u8 {
    if (args.len < 3) return error.MissingUrl;
    if (args.len > 3) return error.UnexpectedArgument;
    return args[2];
}

fn parseFetchArgs(args: []const []const u8) !FetchOptions {
    var opts = FetchOptions{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) return error.ShowHelp;
        if (std.mem.eql(u8, arg, "--version")) return error.ShowVersion;
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--mcp")) {
            opts.mcp = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= args.len) return error.MissingWidthValue;
            opts.width = try std.fmt.parseUnsigned(usize, args[i], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        if (opts.url != null) return error.UnexpectedArgument;
        opts.url = arg;
    }

    if (opts.url == null) return error.MissingUrl;
    return opts;
}

fn parsePostArgs(args: []const []const u8) !PostOptions {
    if (args.len < 4) return error.MissingUrl;
    const url = args[2];
    if (!std.mem.eql(u8, args[3], "--data")) return error.MissingDataValue;
    if (args.len < 5) return error.MissingDataValue;
    if (args.len > 5) return error.UnexpectedArgument;
    return .{ .url = url, .data = args[4] };
}

fn parseEvalArgs(args: []const []const u8) !EvalOptions {
    if (args.len < 4) return error.MissingUrl;
    if (args.len > 4) return error.UnexpectedArgument;
    return .{ .url = args[2], .expr = args[3] };
}

fn parseMcpCallArgs(args: []const []const u8) !McpCallOptions {
    if (args.len < 4) return error.MissingUrl;

    var opts = McpCallOptions{
        .url = args[2],
        .tool_name = args[3],
    };

    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.MissingInputValue;
            opts.input_json = args[i];
            continue;
        }
        return error.UnknownOption;
    }

    return opts;
}

fn parseMcpStdioArgs(args: []const []const u8) ![]const u8 {
    if (args.len < 3) return error.MissingUrl;
    if (args.len > 3) return error.UnexpectedArgument;
    return args[2];
}

fn parseArgs(args: []const []const u8) !CliCommand {
    if (args.len <= 1) return error.MissingUrl;
    if (std.mem.eql(u8, args[1], "--help")) return error.ShowHelp;
    if (std.mem.eql(u8, args[1], "--version")) return error.ShowVersion;
    if (std.mem.eql(u8, args[1], "browse")) return .{ .browse = try parseBrowseArgs(args) };
    if (std.mem.eql(u8, args[1], "post")) return .{ .post = try parsePostArgs(args) };
    if (std.mem.eql(u8, args[1], "eval")) return .{ .eval_expr = try parseEvalArgs(args) };
    if (std.mem.eql(u8, args[1], "mcp-call")) return .{ .mcp_call = try parseMcpCallArgs(args) };
    if (std.mem.eql(u8, args[1], "mcp-stdio")) return .{ .mcp_stdio = try parseMcpStdioArgs(args) };
    return .{ .fetch = try parseFetchArgs(args) };
}

fn writeJsonStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
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
    const alloc = std.heap.c_allocator;

    const stdout = std.fs.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const cmd = parseArgs(args) catch |err| switch (err) {
        error.ShowHelp => {
            try printUsage(out);
            try out.flush();
            return;
        },
        error.ShowVersion => {
            try out.writeAll("0.0.");
            try out.writeAll(build_opts.git_hash);
            try out.writeAll("\n");
            try out.flush();
            return;
        },
        else => {
            try printUsage(out);
            try out.writeAll("\nerror: ");
            try out.writeAll(@errorName(err));
            try out.writeAll("\n");
            try out.flush();
            std.process.exit(1);
        },
    };

    switch (cmd) {
        .browse => |url| {
            browser.run(alloc, url) catch |err| {
                std.debug.print("error browsing {s}: {any}\n", .{ url, err });
                std.process.exit(1);
            };
        },
        .fetch => |opts| {
            const url = opts.url.?;
            var p = try page_mod.Page.init(alloc);
            defer p.deinit();

            if (opts.mcp) {
                var result = p.navigate(url) catch |err| {
                    std.debug.print("error discovering WebMCP tools from {s}: {any}\n", .{ url, err });
                    std.process.exit(1);
                };
                defer result.deinit();

                const tools = p.loadedMcpToolsJson() catch |err| {
                    std.debug.print("error discovering WebMCP tools from {s}: {any}\n", .{ url, err });
                    std.process.exit(1);
                };
                defer alloc.free(tools);

                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(alloc);
                try buf.appendSlice(alloc, "{\"url\":");
                try writeJsonStr(&buf, alloc, result.url);
                try buf.appendSlice(alloc, ",\"tools\":");
                try buf.appendSlice(alloc, tools);
                try buf.appendSlice(alloc, "}\n");

                try out.writeAll(buf.items);
                try out.flush();
                return;
            }

            var result = p.navigate(url) catch |err| {
                std.debug.print("error fetching {s}: {any}\n", .{ url, err });
                std.process.exit(1);
            };
            defer result.deinit();

            if (opts.json) {
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

                try out.writeAll(buf.items);
                try out.flush();
                return;
            }

            try page_mod.renderHtml(alloc, out, result.html, .{
                .max_width = opts.width,
                .ansi_colors = !opts.no_color and stdout.isTty(),
            });
            try out.flush();
        },
        .post => |opts| {
            var http_client = page_mod.Client.init(alloc, .{ .use_chrome_headers = false });
            defer http_client.deinit();

            var resp = http_client.post(opts.url, opts.data) catch |err| {
                std.debug.print("error posting {s}: {any}\n", .{ opts.url, err });
                std.process.exit(1);
            };
            defer resp.deinit();

            try out.writeAll(resp.body);
            if (resp.body.len == 0 or resp.body[resp.body.len - 1] != '\n') {
                try out.writeAll("\n");
            }
            try out.flush();
        },
        .eval_expr => |opts| {
            var p = try page_mod.Page.init(alloc);
            defer p.deinit();

            const value = p.evaluate(opts.url, opts.expr) catch {
                std.debug.print("error: eval failed\n", .{});
                std.process.exit(1);
            };
            defer alloc.free(value);

            try out.writeAll(value);
            try out.writeAll("\n");
            try out.flush();
        },
        .mcp_call => |opts| {
            var p = try page_mod.Page.init(alloc);
            defer p.deinit();

            const value = p.callWebMcpTool(opts.url, opts.tool_name, opts.input_json) catch |err| {
                std.debug.print("error calling WebMCP tool {s} at {s}: {any}\n", .{ opts.tool_name, opts.url, err });
                std.process.exit(1);
            };
            defer alloc.free(value);

            try out.writeAll(value);
            try out.writeAll("\n");
            try out.flush();
        },
        .mcp_stdio => |url| {
            mcp_stdio.serve(alloc, url) catch |err| {
                std.debug.print("error serving MCP stdio for {s}: {any}\n", .{ url, err });
                std.process.exit(1);
            };
        },
    }
}

test "parseArgs defaults to fetch command" {
    const cmd = try parseArgs(&.{ "awr", "https://example.com" });
    switch (cmd) {
        .fetch => |opts| try std.testing.expectEqualStrings("https://example.com", opts.url.?),
        else => return error.UnexpectedArgument,
    }
}

test "parseArgs parses browse command" {
    const cmd = try parseArgs(&.{ "awr", "browse", "https://example.com" });
    switch (cmd) {
        .browse => |url| try std.testing.expectEqualStrings("https://example.com", url),
        else => return error.UnexpectedArgument,
    }
}

test "parseArgs parses post command" {
    const cmd = try parseArgs(&.{ "awr", "post", "https://example.com", "--data", "x=1" });
    switch (cmd) {
        .post => |opts| {
            try std.testing.expectEqualStrings("https://example.com", opts.url);
            try std.testing.expectEqualStrings("x=1", opts.data);
        },
        else => return error.UnexpectedArgument,
    }
}

test "parseArgs parses eval command" {
    const cmd = try parseArgs(&.{ "awr", "eval", "https://example.com", "document.title" });
    switch (cmd) {
        .eval_expr => |opts| {
            try std.testing.expectEqualStrings("https://example.com", opts.url);
            try std.testing.expectEqualStrings("document.title", opts.expr);
        },
        else => return error.UnexpectedArgument,
    }
}

test "parseArgs parses fetch mcp flag" {
    const cmd = try parseArgs(&.{ "awr", "--mcp", "https://example.com" });
    switch (cmd) {
        .fetch => |opts| {
            try std.testing.expect(opts.mcp);
            try std.testing.expectEqualStrings("https://example.com", opts.url.?);
        },
        else => return error.UnexpectedArgument,
    }
}

test "parseArgs parses mcp-call command" {
    const cmd = try parseArgs(&.{ "awr", "mcp-call", "https://example.com", "tool-a", "--input", "{\"x\":1}" });
    switch (cmd) {
        .mcp_call => |opts| {
            try std.testing.expectEqualStrings("https://example.com", opts.url);
            try std.testing.expectEqualStrings("tool-a", opts.tool_name);
            try std.testing.expectEqualStrings("{\"x\":1}", opts.input_json.?);
        },
        else => return error.UnexpectedArgument,
    }
}

test "parseArgs parses mcp-stdio command" {
    const cmd = try parseArgs(&.{ "awr", "mcp-stdio", "https://example.com" });
    switch (cmd) {
        .mcp_stdio => |url| try std.testing.expectEqualStrings("https://example.com", url),
        else => return error.UnexpectedArgument,
    }
}
