const std = @import("std");
const build_opts = @import("build_opts");
const page_mod = @import("page");

pub fn serve(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    var page = try page_mod.Page.init(allocator, io);
    defer page.deinit();

    var initial = try page.navigate(url);
    defer initial.deinit();

    const stdin = std.Io.File.stdin();
    var writer = struct { fn writeAll(self: @This(), bytes: []const u8) !void { _ = self; std.debug.print("{s}", .{bytes}); } }{};
    const out = &writer.interface;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    while (true) {
        var read_buf: [4096]u8 = undefined;
        const n = try stdin.read(&read_buf);
        if (n == 0) break;
        try pending.appendSlice(allocator, read_buf[0..n]);

        while (nextMessage(pending.items)) |message| {
            const trimmed = std.mem.trim(u8, message.payload, " \t\r");
            if (trimmed.len > 0) try handleMessage(allocator, out, &page, trimmed);
            const remaining = pending.items[message.consumed..];
            std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            pending.items.len = remaining.len;
        }
    }

    if (nextMessage(pending.items)) |message| {
        const trimmed = std.mem.trim(u8, message.payload, " \t\r");
        if (trimmed.len > 0) try handleMessage(allocator, out, &page, trimmed);
    } else {
        const trailing = std.mem.trim(u8, pending.items, " \t\r\n");
        if (trailing.len > 0) try handleMessage(allocator, out, &page, trailing);
    }

    try out.flush();
}

const MessageSlice = struct {
    consumed: usize,
    payload: []const u8,
};

fn nextMessage(buf: []const u8) ?MessageSlice {
    const trimmed = std.mem.trim(u8, buf, "\r\n");
    const skipped = buf.len - trimmed.len;
    if (trimmed.len == 0) return null;

    if (std.mem.indexOf(u8, trimmed, "\r\n\r\n")) |headers_end| {
        const headers = trimmed[0..headers_end];
        if (parseContentLength(headers)) |body_len| {
            const total = headers_end + 4 + body_len;
            if (trimmed.len < total) return null;
            return .{
                .consumed = skipped + total,
                .payload = trimmed[headers_end + 4 .. headers_end + 4 + body_len],
            };
        }
    }

    const newline_idx = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
    return .{
        .consumed = skipped + newline_idx + 1,
        .payload = trimmed[0..newline_idx],
    };
}

fn parseContentLength(headers: []const u8) ?usize {
    var header_it = std.mem.splitSequence(u8, headers, "\r\n");
    while (header_it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const raw = std.mem.trim(u8, line[15..], " ");
            return std.fmt.parseUnsigned(usize, raw, 10) catch null;
        }
    }
    return null;
}

fn handleMessage(
    allocator: std.mem.Allocator,
    out: anytype,
    page: *page_mod.Page,
    message: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch {
        try writeErrorResponse(allocator, out, .null, -32700, "Parse error");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writeErrorResponse(allocator, out, .null, -32600, "Invalid Request");
        return;
    }
    const root = parsed.value.object;
    const invalid_request_id = root.get("id") orelse .null;
    const method = if (root.get("method")) |value| switch (value) {
        .string => |s| s,
        else => {
            try writeErrorResponse(allocator, out, invalid_request_id, -32600, "Invalid Request");
            return;
        },
    } else {
        try writeErrorResponse(allocator, out, invalid_request_id, -32600, "Invalid Request");
        return;
    };
    const id = root.get("id");

    if (std.mem.eql(u8, method, "initialize")) {
        if (id == null) return;
        try writeInitializeResponse(allocator, out, id.?);
        return;
    }

    if (std.mem.eql(u8, method, "notifications/initialized")) return;

    if (std.mem.eql(u8, method, "ping")) {
        if (id == null) return;
        try writeSimpleResultResponse(allocator, out, id.?, "{}");
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        if (id == null) return;
        const tools = try page.loadedMcpToolsJson();
        defer allocator.free(tools);
        try writeToolsListResponse(allocator, out, id.?, tools);
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        if (id == null) return;
        const params = (root.get("params") orelse {
            try writeErrorResponse(allocator, out, id.?, -32602, "Missing tools/call params");
            return;
        });
        if (params != .object) {
            try writeErrorResponse(allocator, out, id.?, -32602, "Invalid tools/call params");
            return;
        }

        const name = switch (params.object.get("name") orelse {
            try writeErrorResponse(allocator, out, id.?, -32602, "Missing tool name");
            return;
        }) {
            .string => |s| s,
            else => {
                try writeErrorResponse(allocator, out, id.?, -32602, "Tool name must be a string");
                return;
            },
        };

        const args_json = if (params.object.get("arguments")) |args_value|
            try jsonValueToOwnedString(allocator, args_value)
        else
            null;
        defer if (args_json) |json| allocator.free(json);

        const result_json = page.callLoadedWebMcpTool(name, args_json) catch |err| {
            const err_text = try std.fmt.allocPrint(allocator, "WebMCP tool call failed: {s}", .{@errorName(err)});
            defer allocator.free(err_text);
            try writeToolErrorResponse(allocator, out, id.?, err_text);
            return;
        };
        defer allocator.free(result_json);

        try writeToolCallResponse(allocator, out, id.?, result_json);
        return;
    }

    if (id) |request_id| {
        const err_text = try std.fmt.allocPrint(allocator, "Method not found: {s}", .{method});
        defer allocator.free(err_text);
        try writeErrorResponse(allocator, out, request_id, -32601, err_text);
    }
}

fn writeInitializeResponse(allocator: std.mem.Allocator, out: anytype, id: std.json.Value) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const version = try std.fmt.allocPrint(allocator, "0.0.{s}", .{build_opts.git_hash});
    defer allocator.free(version);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(&buf, allocator, id);
    try buf.appendSlice(
        allocator,
        ",\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"awr\",\"version\":",
    );
    try writeJsonStr(&buf, allocator, version);
    try buf.appendSlice(allocator, "},\"instructions\":\"Loads a WebMCP page and exposes its registered tools over MCP stdio.\"}}");
    try writeFramedMessage(out, buf.items);
}

fn writeSimpleResultResponse(allocator: std.mem.Allocator, out: anytype, id: std.json.Value, result_json: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result_json);
    try buf.appendSlice(allocator, "}");
    try writeFramedMessage(out, buf.items);
}

fn writeToolsListResponse(allocator: std.mem.Allocator, out: anytype, id: std.json.Value, tools_json: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"tools\":");
    try buf.appendSlice(allocator, tools_json);
    try buf.appendSlice(allocator, "}}");
    try writeFramedMessage(out, buf.items);
}

fn writeToolCallResponse(allocator: std.mem.Allocator, out: anytype, id: std.json.Value, result_json: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonStr(&buf, allocator, result_json);
    try buf.appendSlice(allocator, "}],\"structuredContent\":");
    try buf.appendSlice(allocator, result_json);
    try buf.appendSlice(allocator, ",\"isError\":false}}");
    try writeFramedMessage(out, buf.items);
}

fn writeToolErrorResponse(allocator: std.mem.Allocator, out: anytype, id: std.json.Value, message: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonStr(&buf, allocator, message);
    try buf.appendSlice(allocator, "}],\"isError\":true}}");
    try writeFramedMessage(out, buf.items);
}

fn writeErrorResponse(allocator: std.mem.Allocator, out: anytype, id: std.json.Value, code: i32, message: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"error\":{\"code\":");
    const code_str = try std.fmt.allocPrint(allocator, "{d}", .{code});
    defer allocator.free(code_str);
    try buf.appendSlice(allocator, code_str);
    try buf.appendSlice(allocator, ",\"message\":");
    try writeJsonStr(&buf, allocator, message);
    try buf.appendSlice(allocator, "}}");
    try writeFramedMessage(out, buf.items);
}

fn writeFramedMessage(out: anytype, payload: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{payload.len});
    std.debug.print("{s}{s}", .{header, payload});
    try out.flush();
}

fn jsonValueToOwnedString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendJsonValue(&buf, allocator, value);
    return buf.toOwnedSlice(allocator);
}

fn appendJsonValue(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => try list.appendSlice(allocator, "null"),
        .bool => |v| try list.appendSlice(allocator, if (v) "true" else "false"),
        .integer => |v| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            defer allocator.free(s);
            try list.appendSlice(allocator, s);
        },
        .float => |v| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            defer allocator.free(s);
            try list.appendSlice(allocator, s);
        },
        .number_string => |v| try list.appendSlice(allocator, v),
        .string => |v| try writeJsonStr(list, allocator, v),
        .array => |items| {
            try list.append(allocator, '[');
            for (items.items, 0..) |item, idx| {
                if (idx > 0) try list.append(allocator, ',');
                try appendJsonValue(list, allocator, item);
            }
            try list.append(allocator, ']');
        },
        .object => |obj| {
            try list.append(allocator, '{');
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) {
                if (idx > 0) try list.append(allocator, ',');
                try writeJsonStr(list, allocator, entry.key_ptr.*);
                try list.append(allocator, ':');
                try appendJsonValue(list, allocator, entry.value_ptr.*);
            }
            try list.append(allocator, '}');
        },
    }
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

test "jsonValueToOwnedString serializes nested values" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"a\":[1,true,null],\"b\":\"x\"}", .{});
    defer parsed.deinit();

    const out = try jsonValueToOwnedString(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"a\":[1,true,null],\"b\":\"x\"}", out);
}

test "nextMessage parses content-length framing" {
    const msg = nextMessage("Content-Length: 18\r\n\r\n{\"jsonrpc\":\"2\"}") orelse return error.ExpectedMessage;
    try std.testing.expectEqual(@as(usize, 40), msg.consumed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2\"}", msg.payload);
}

test "nextMessage parses content-length when not first header" {
    const msg = nextMessage("Content-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}") orelse return error.ExpectedMessage;
    try std.testing.expectEqualStrings("{\"a\":1}", msg.payload);
}
