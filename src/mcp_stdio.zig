/// mcp_stdio.zig — native MCP server over stdin/stdout.
///
/// > **Status:** DEFERRED. Per `spec/subspecs/mcp-stdio.md` this track is
/// > not part of the active work queue and promoting it from DEFERRED to
/// > shipped requires a `spec/MVP.md §8` change-control amendment. This
/// > file is a ready-to-review implementation, not a promised surface.
///
/// A thin MCP (Model Context Protocol) JSON-RPC 2.0 server. It is a thin
/// client of the existing runtime: it loads a single WebMCP page through
/// `page.zig` and re-exports that page's `navigator.modelContext` tools
/// over the MCP wire, mapping:
///
///   - `initialize`        → server capabilities + info
///   - `tools/list`        → `PageResult.tools_json` (WebMCP descriptors)
///   - `tools/call`        → `Page.callTool` (WebMCP invocation)
///   - `ping`              → `{}`
///   - `notifications/*`   → silently absorbed (no response)
///
/// Wire framing, request parsing, and response/error envelopes are reused
/// verbatim from `jsonrpc.zig` (the same module the daemon uses), so this
/// file owns only the MCP method contract, not the transport. Mirrors the
/// `main_daemon.zig` shim pattern but over stdin/stdout instead of a Unix
/// socket.
///
/// No stubs: every advertised method really executes against the loaded
/// page. Tools the page did not register are reported as MCP errors, not
/// faked.
const std = @import("std");
const build_opts = @import("build_opts");
const page_mod = @import("page");
const jsonrpc = @import("jsonrpc.zig");

/// Defensive cap on a single inbound JSON-RPC body. Tool arguments are
/// small; 1 MiB is generous and bounds per-request memory the same way
/// the daemon does.
const MAX_BODY_BYTES: usize = 1 << 20;

/// MCP protocol version this server implements. The client states its own
/// preference in `initialize`; we always answer with the version we speak,
/// which is the spec-compliant behavior.
const PROTOCOL_VERSION = "2025-06-18";

/// Run the MCP stdio server against `url`. Loads the page once, then
/// serves JSON-RPC requests on stdin until EOF (or a `shutdown`). Each
/// request gets exactly one framed response unless it is a notification
/// (no `id`), which is absorbed silently per JSON-RPC.
pub fn serve(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    var page = try page_mod.Page.init(allocator, io);
    defer page.deinit();

    var loaded = try loadPage(&page, allocator, io, url);
    defer loaded.deinit();

    const tools_json = try allocator.dupe(u8, loaded.tools_json orelse "[]");
    defer allocator.free(tools_json);

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    const read_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(write_buf);

    var in_reader = stdin.reader(io, read_buf);
    var out_writer = stdout.writer(io, write_buf);

    var rshim: ReaderShim = .{ .src = &in_reader.interface };
    var wshim: WriterShim = .{ .dst = &out_writer.interface };

    var should_exit = false;
    while (!should_exit) {
        const body = jsonrpc.readFrame(&rshim, allocator, MAX_BODY_BYTES) catch |err| switch (err) {
            // Clean EOF or a peer that hung up mid-frame: end the session.
            // readFrame remaps the reader's EndOfStream to UnexpectedEof.
            jsonrpc.FramingError.UnexpectedEof => break,
            // Malformed framing: there is no id to answer to, so emit a
            // parse error against a null id and stop (the stream framing
            // is no longer trustworthy).
            else => {
                try jsonrpc.writeError(&wshim, allocator, "null", .parse_error, "invalid frame");
                try out_writer.interface.flush();
                break;
            },
        };
        defer allocator.free(body);

        try handleMessage(allocator, &page, tools_json, body, &wshim, &should_exit);
        try out_writer.interface.flush();
    }
}

/// Load a page from either an http(s):// URL or a local file path.
/// Mirrors `main.zig:loadPage` so the MCP surface and the CLI surface
/// agree on what "a page" means.
fn loadPage(
    p: *page_mod.Page,
    allocator: std.mem.Allocator,
    io: std.Io,
    location: []const u8,
) !page_mod.PageResult {
    if (std.mem.startsWith(u8, location, "http://") or
        std.mem.startsWith(u8, location, "https://"))
    {
        return p.navigate(location);
    }

    const path: []const u8 = if (std.mem.startsWith(u8, location, "file://"))
        location[7..]
    else
        location;

    const html = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(html);

    const synthetic_url = if (std.mem.startsWith(u8, location, "file://"))
        try allocator.dupe(u8, location)
    else
        try std.fmt.allocPrint(allocator, "file://{s}", .{path});
    defer allocator.free(synthetic_url);

    return p.processHtml(synthetic_url, 200, html);
}

/// Dispatch one parsed JSON-RPC body to its MCP method handler. Notifications
/// (no `id`) are absorbed without a response. Unknown methods get a
/// `method_not_found` error. Setting `should_exit` ends the serve loop.
///
/// `out` is anything exposing `print` / `writeAll` (the `jsonrpc` writer
/// contract): the real `WriterShim` over stdout, or a test capture buffer.
fn handleMessage(
    allocator: std.mem.Allocator,
    page: *page_mod.Page,
    tools_json: []const u8,
    body: []const u8,
    out: anytype,
    should_exit: *bool,
) !void {
    var req = jsonrpc.parseRequest(allocator, body) catch {
        // Valid JSON but not a JSON-RPC Request shape (or bad version).
        // No reliable id to reply to, so answer null per JSON-RPC §5.
        try jsonrpc.writeError(out, allocator, "null", .invalid_request, "invalid request");
        return;
    };
    defer req.deinit();

    const method = req.method() orelse {
        try jsonrpc.writeError(out, allocator, "null", .invalid_request, "missing method");
        return;
    };

    // Notifications carry no id and never get a response. `initialized`
    // and `cancelled` are the common ones; absorb any `notifications/*`.
    if (req.isNotification()) return;

    const id_json = try jsonrpc.idToJson(allocator, req.id());
    defer allocator.free(id_json);

    if (std.mem.eql(u8, method, "initialize")) {
        const result = try buildInitializeResult(allocator);
        defer allocator.free(result);
        try jsonrpc.writeSuccess(out, allocator, id_json, result);
        return;
    }

    if (std.mem.eql(u8, method, "ping")) {
        try jsonrpc.writeSuccess(out, allocator, id_json, "{}");
        return;
    }

    if (std.mem.eql(u8, method, "shutdown")) {
        try jsonrpc.writeSuccess(out, allocator, id_json, "null");
        should_exit.* = true;
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        const result = try buildToolsListResult(allocator, tools_json);
        defer allocator.free(result);
        try jsonrpc.writeSuccess(out, allocator, id_json, result);
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(allocator, page, &req, id_json, out);
        return;
    }

    try jsonrpc.writeError(out, allocator, id_json, .method_not_found, method);
}

/// Handle `tools/call`: validate params, invoke the WebMCP tool through
/// `Page.callTool`, and translate the `{ok,value}|{ok,error,message}`
/// envelope into the MCP `tools/call` result shape.
fn handleToolsCall(
    allocator: std.mem.Allocator,
    page: *page_mod.Page,
    req: *const jsonrpc.Request,
    id_json: []const u8,
    out: anytype,
) !void {
    const params_val = req.params() orelse {
        try jsonrpc.writeError(out, allocator, id_json, .invalid_params, "missing params");
        return;
    };
    const params_obj = switch (params_val) {
        .object => |o| o,
        else => {
            try jsonrpc.writeError(out, allocator, id_json, .invalid_params, "params must be an object");
            return;
        },
    };

    const name = switch (params_obj.get("name") orelse {
        try jsonrpc.writeError(out, allocator, id_json, .invalid_params, "missing tool name");
        return;
    }) {
        .string => |s| s,
        else => {
            try jsonrpc.writeError(out, allocator, id_json, .invalid_params, "tool name must be a string");
            return;
        },
    };

    // MCP `arguments` is an optional object. Re-serialize it to the JSON
    // string `Page.callTool` expects; default to "{}" when absent so the
    // page's handler always receives a value.
    const args_json: []u8 = if (params_obj.get("arguments")) |args_val| blk: {
        if (args_val != .object) {
            try jsonrpc.writeError(out, allocator, id_json, .invalid_params, "arguments must be an object");
            return;
        }
        break :blk try jsonValueToOwnedString(allocator, args_val);
    } else try allocator.dupe(u8, "{}");
    defer allocator.free(args_json);

    const envelope = page.callTool(name, args_json) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "tool invocation failed: {t}", .{err});
        defer allocator.free(msg);
        try jsonrpc.writeError(out, allocator, id_json, .internal_error, msg);
        return;
    };
    defer allocator.free(envelope);

    const result = try buildToolCallResult(allocator, envelope);
    defer allocator.free(result);
    try jsonrpc.writeSuccess(out, allocator, id_json, result);
}

// ── Result builders (pure; unit-testable without a live Page) ────────────

/// Build the `initialize` result JSON. Advertises the `tools` capability
/// only — this server exposes WebMCP tools and nothing else.
fn buildInitializeResult(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":\"{s}\"," ++
            "\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}}," ++
            "\"serverInfo\":{{\"name\":\"awr\",\"version\":\"0.0.{s}\"}}," ++
            "\"instructions\":\"Loads a WebMCP page and exposes its registered tools over MCP stdio.\"}}",
        .{ PROTOCOL_VERSION, build_opts.git_hash },
    );
}

/// Build the `tools/list` result `{"tools":[...]}` from the page's WebMCP
/// descriptor array. WebMCP descriptors are `{name, description, inputSchema}`
/// which is already MCP-compatible, except `inputSchema` may be `null`; MCP
/// requires an object schema, so null is normalized to `{"type":"object"}`.
fn buildToolsListResult(allocator: std.mem.Allocator, tools_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, tools_json, .{}) catch {
        // The page bridge guarantees a JSON array; if it somehow isn't,
        // surface an empty list rather than a malformed response.
        return allocator.dupe(u8, "{\"tools\":[]}");
    };
    defer parsed.deinit();

    if (parsed.value != .array) return allocator.dupe(u8, "{\"tools\":[]}");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"tools\":[");
    for (parsed.value.array.items, 0..) |tool, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendNormalizedTool(&buf, allocator, tool);
    }
    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

/// Append one WebMCP descriptor as an MCP tool object, normalizing a
/// missing/null `inputSchema` to `{"type":"object"}` (MCP requires an
/// object schema). Non-object descriptors are emitted as a minimal valid
/// tool object rather than corrupting the array.
fn appendNormalizedTool(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, tool: std.json.Value) !void {
    if (tool != .object) {
        try buf.appendSlice(allocator, "{\"name\":\"\",\"inputSchema\":{\"type\":\"object\"}}");
        return;
    }
    const obj = tool.object;

    try buf.append(allocator, '{');
    var wrote_field = false;

    if (obj.get("name")) |name| {
        try buf.appendSlice(allocator, "\"name\":");
        try appendJsonValue(buf, allocator, name);
        wrote_field = true;
    }
    if (obj.get("description")) |desc| {
        if (wrote_field) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"description\":");
        try appendJsonValue(buf, allocator, desc);
        wrote_field = true;
    }

    if (wrote_field) try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "\"inputSchema\":");
    const schema = obj.get("inputSchema") orelse std.json.Value{ .null = {} };
    if (schema == .object) {
        try appendJsonValue(buf, allocator, schema);
    } else {
        try buf.appendSlice(allocator, "{\"type\":\"object\"}");
    }

    try buf.append(allocator, '}');
}

/// Translate a `Page.callTool` envelope into the MCP `tools/call` result.
///   {"ok":true,"value":X}                 →
///       {"content":[{"type":"text","text":"<X as JSON>"}],
///        "structuredContent":X,"isError":false}
///   {"ok":false,"error":E,"message":M}    →
///       {"content":[{"type":"text","text":"<E: M>"}],"isError":true}
/// A tool that reports failure is a successful JSON-RPC call carrying
/// `isError:true` content (MCP's model), not a JSON-RPC error.
fn buildToolCallResult(allocator: std.mem.Allocator, envelope: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, envelope, .{}) catch {
        return buildErrorContent(allocator, "tool returned malformed result");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return buildErrorContent(allocator, "tool returned malformed result");
    }
    const obj = parsed.value.object;

    const ok = switch (obj.get("ok") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };

    if (!ok) {
        const kind = stringField(obj, "error") orelse "ToolCallFailed";
        const message = stringField(obj, "message");
        const text = if (message) |m|
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ kind, m })
        else
            try allocator.dupe(u8, kind);
        defer allocator.free(text);
        return buildErrorContent(allocator, text);
    }

    const value = obj.get("value") orelse std.json.Value{ .null = {} };
    const value_json = try jsonValueToOwnedString(allocator, value);
    defer allocator.free(value_json);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonStr(&buf, allocator, value_json);
    try buf.appendSlice(allocator, "}],\"structuredContent\":");
    try buf.appendSlice(allocator, value_json);
    try buf.appendSlice(allocator, ",\"isError\":false}");
    return buf.toOwnedSlice(allocator);
}

/// Build an MCP `tools/call` error result (a normal JSON-RPC success
/// carrying `isError:true` content), with `text` as the message.
fn buildErrorContent(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonStr(&buf, allocator, text);
    try buf.appendSlice(allocator, "}],\"isError\":true}");
    return buf.toOwnedSlice(allocator);
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// ── JSON value re-serialization ──────────────────────────────────────────

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
        .integer => |v| try list.print(allocator, "{d}", .{v}),
        .float => |v| try list.print(allocator, "{d}", .{v}),
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

fn writeJsonStr(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var esc: [6]u8 = undefined;
                const slice = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                try list.appendSlice(allocator, slice);
            },
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
}

// ── Reader/Writer shims for jsonrpc's anytype helpers ────────────────────
// Mirror main_daemon.zig's shims: adapt std.Io.Reader/Writer to the
// readUntilDelimiter/readNoEof/print/writeAll shape jsonrpc expects.

const ReaderShim = struct {
    src: *std.Io.Reader,

    pub fn readUntilDelimiter(self: *ReaderShim, out: []u8, delim: u8) ![]u8 {
        var len: usize = 0;
        while (len < out.len) {
            var single: [1]u8 = undefined;
            const n = try self.src.readSliceShort(&single);
            if (n == 0) {
                if (len == 0) return error.EndOfStream;
                return out[0..len];
            }
            out[len] = single[0];
            len += 1;
            if (single[0] == delim) return out[0..len];
        }
        return error.StreamTooLong;
    }

    pub fn readNoEof(self: *ReaderShim, dest: []u8) !void {
        var filled: usize = 0;
        while (filled < dest.len) {
            const n = try self.src.readSliceShort(dest[filled..]);
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }
};

const WriterShim = struct {
    dst: *std.Io.Writer,

    pub fn print(self: *WriterShim, comptime fmt: []const u8, args: anytype) !void {
        try self.dst.print(fmt, args);
    }

    pub fn writeAll(self: *WriterShim, bytes: []const u8) !void {
        try self.dst.writeAll(bytes);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────
//
// These cover the pure MCP-mapping helpers and the request-dispatch
// surface for the methods that need no live Page: initialize / ping /
// tools/list / shutdown, unknown method, bad tools/call params, and
// notification absorption. handleMessage and the jsonrpc helpers are
// generic over the writer, so an in-memory CaptureWriter drives them
// without stdin/stdout. The network-dependent serve() loop is exercised
// end-to-end out of band; these unit tests pin the protocol contract.

const testing = std.testing;

/// In-memory writer matching the jsonrpc writer contract (print/writeAll)
/// so handleMessage can be driven without stdin/stdout. Captures the
/// framed bytes for assertions.
const CaptureWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *CaptureWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn print(self: *CaptureWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.print(self.allocator, fmt, args);
    }

    pub fn writeAll(self: *CaptureWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// Return the JSON body of the single framed message captured.
    fn body(self: *const CaptureWriter) ![]const u8 {
        const marker = std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") orelse return error.NoFraming;
        return self.buf.items[marker + 4 ..];
    }
};

test "buildInitializeResult advertises tools capability and serverInfo" {
    const out = try buildInitializeResult(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"protocolVersion\":\"2025-06-18\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"capabilities\":{\"tools\":{\"listChanged\":false}}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"serverInfo\":{\"name\":\"awr\"") != null);
}

test "buildToolsListResult passes through descriptors and wraps in tools array" {
    const descriptors =
        "[{\"name\":\"echo\",\"description\":\"Echoes\",\"inputSchema\":{\"type\":\"object\"}}]";
    const out = try buildToolsListResult(testing.allocator, descriptors);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "{\"tools\":[{\"name\":\"echo\",\"description\":\"Echoes\"," ++
            "\"inputSchema\":{\"type\":\"object\"}}]}",
        out,
    );
}

test "buildToolsListResult normalizes null inputSchema to object schema" {
    const descriptors = "[{\"name\":\"noargs\",\"description\":\"\",\"inputSchema\":null}]";
    const out = try buildToolsListResult(testing.allocator, descriptors);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"inputSchema\":{\"type\":\"object\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "null") == null);
}

test "buildToolsListResult returns empty list for empty array" {
    const out = try buildToolsListResult(testing.allocator, "[]");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"tools\":[]}", out);
}

test "buildToolsListResult degrades to empty list on non-array input" {
    const out = try buildToolsListResult(testing.allocator, "{\"oops\":true}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"tools\":[]}", out);
}

test "buildToolCallResult maps ok:true to text + structuredContent" {
    const envelope = "{\"ok\":true,\"value\":{\"total\":7}}";
    const out = try buildToolCallResult(testing.allocator, envelope);
    defer testing.allocator.free(out);

    // structuredContent is the raw value; text is its JSON stringification.
    try testing.expect(std.mem.indexOf(u8, out, "\"structuredContent\":{\"total\":7}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"text\":\"{\\\"total\\\":7}\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":false") != null);
}

test "buildToolCallResult maps ok:false to isError content" {
    const envelope = "{\"ok\":false,\"error\":\"ToolNotFound\",\"message\":\"no such tool\"}";
    const out = try buildToolCallResult(testing.allocator, envelope);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ToolNotFound: no such tool") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"structuredContent\"") == null);
}

test "buildToolCallResult tolerates ok:false without message" {
    const envelope = "{\"ok\":false,\"error\":\"BridgeNotLoaded\"}";
    const out = try buildToolCallResult(testing.allocator, envelope);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "BridgeNotLoaded") != null);
}

test "buildToolCallResult degrades to error content on malformed envelope" {
    const out = try buildToolCallResult(testing.allocator, "not json");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
}

// ── Dispatch tests (drive handleMessage with a CaptureWriter) ────────────
// Cover routing + JSON-RPC framing/id handling for the methods that need
// no live Page. The page pointer is never dereferenced on these paths.

test "dispatch: initialize returns a framed result with echoed id" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined; // not touched by initialize
    try handleMessage(testing.allocator, &fake_page, "[]", body, &cap, &should_exit);

    const resp = try cap.body();
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"result\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"protocolVersion\"") != null);
    try testing.expect(!should_exit);
}

test "dispatch: ping returns empty object result" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"ping\"}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined;
    try handleMessage(testing.allocator, &fake_page, "[]", body, &cap, &should_exit);

    const resp = try cap.body();
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":\"abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"result\":{}") != null);
}

test "dispatch: tools/list returns the page's descriptors" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const tools = "[{\"name\":\"echo\",\"description\":\"\",\"inputSchema\":{\"type\":\"object\"}}]";
    const body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined;
    try handleMessage(testing.allocator, &fake_page, tools, body, &cap, &should_exit);

    const resp = try cap.body();
    try testing.expect(std.mem.indexOf(u8, resp, "\"tools\":[{\"name\":\"echo\"") != null);
}

test "dispatch: unknown method yields method_not_found error" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"frobnicate\"}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined;
    try handleMessage(testing.allocator, &fake_page, "[]", body, &cap, &should_exit);

    const resp = try cap.body();
    try testing.expect(std.mem.indexOf(u8, resp, "\"error\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":-32601") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "frobnicate") != null);
}

test "dispatch: tools/call with non-object params yields invalid_params" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":[1,2]}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined;
    try handleMessage(testing.allocator, &fake_page, "[]", body, &cap, &should_exit);

    const resp = try cap.body();
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":-32602") != null);
}

test "dispatch: tools/call missing name yields invalid_params" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{}}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined;
    try handleMessage(testing.allocator, &fake_page, "[]", body, &cap, &should_exit);

    const resp = try cap.body();
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":-32602") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "missing tool name") != null);
}

test "dispatch: notification (no id) produces no response" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined;
    try handleMessage(testing.allocator, &fake_page, "[]", body, &cap, &should_exit);

    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

test "dispatch: shutdown sets should_exit and acks" {
    var cap: CaptureWriter = .{ .allocator = testing.allocator };
    defer cap.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}";
    var should_exit = false;
    var fake_page: page_mod.Page = undefined;
    try handleMessage(testing.allocator, &fake_page, "[]", body, &cap, &should_exit);

    try testing.expect(should_exit);
    const resp = try cap.body();
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":9") != null);
}
