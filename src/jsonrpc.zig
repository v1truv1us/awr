/// jsonrpc.zig — JSON-RPC 2.0 framing + envelope helpers.
///
/// Used by both the daemon-side accept loop (`src/main_daemon.zig`,
/// added in B3.2) and the daemon-aware CLI client
/// (`src/daemon_client.zig`, added in B3.4) to exchange messages
/// over a Unix domain socket per `spec/subspecs/daemon-mode.md §2.3`.
///
/// Wire format (LSP / MCP-style):
///
///   Content-Length: <bytes>\r\n
///   \r\n
///   <body — exactly <bytes> octets of JSON>
///
/// Other headers (e.g. `Content-Type`) are accepted-and-ignored on
/// read so that future protocol extensions don't break us. We never
/// emit anything besides Content-Length on write.
///
/// This module deliberately stays narrow: framing + raw envelope
/// parsing. Per-method param / result types live in the daemon and
/// client code that owns the method's contract — keeping this layer
/// generic means the same module serves both the request side
/// (parses incoming frames, writes outgoing responses) and the
/// response side (writes outgoing frames, parses incoming responses).
const std = @import("std");

/// Standard JSON-RPC 2.0 error codes plus AWR-specific extensions.
/// Spec: https://www.jsonrpc.org/specification#error_object §5.1.
pub const ErrorCode = enum(i32) {
    /// Invalid JSON received.
    parse_error = -32700,
    /// JSON is valid but doesn't match the Request object shape.
    invalid_request = -32600,
    /// Method does not exist.
    method_not_found = -32601,
    /// Method exists but params are wrong.
    invalid_params = -32602,
    /// Implementation-side bug or unhandled error.
    internal_error = -32603,
    // ── AWR-specific (per spec/subspecs/daemon-mode.md §2.3) ────────────
    /// Per-method 30s timeout exceeded.
    request_timeout = -32001,
    /// Daemon is shutting down (idle timeout, memory cap, etc.).
    server_shutting_down = -32099,
};

pub const FramingError = error{
    HeaderTooLong,
    InvalidHeader,
    BodyTooLarge,
    UnexpectedEof,
    InvalidContentLength,
    MissingContentLength,
};

/// Maximum bytes we accept for a single header line. 4 KiB is huge
/// for `Content-Length: <number>\r\n`; defensive against malicious
/// or buggy peers.
pub const MAX_HEADER_LINE: usize = 4096;

/// Read one Content-Length-framed message from `reader`. Returns the
/// JSON body bytes — caller owns the allocation and must free.
///
/// `max_body_bytes` is a defensive cap to bound per-request memory.
/// Daemon-side: 1 MiB is generous (typical fetch params are <1 KB,
/// typical response JSON is <100 KB). Bigger payloads should be
/// streamed, which the v1 protocol doesn't support.
///
/// On any framing error the reader's stream state is left undefined
/// — the caller's contract is "discard the connection on error",
/// which the daemon and client both honor by closing the socket.
pub fn readFrame(
    reader: anytype,
    allocator: std.mem.Allocator,
    max_body_bytes: usize,
) ![]u8 {
    var content_length: ?usize = null;
    var line_buf: [MAX_HEADER_LINE]u8 = undefined;

    // Header lines until the blank line that terminates the header
    // block. Per LSP/MCP convention each header is `Name: value\r\n`
    // and the block ends with a bare `\r\n`.
    while (true) {
        const line_with_cr = reader.readUntilDelimiter(&line_buf, '\n') catch |err| switch (err) {
            error.EndOfStream => return FramingError.UnexpectedEof,
            error.StreamTooLong => return FramingError.HeaderTooLong,
            else => |e| return e,
        };
        // Reader includes the '\n' delimiter; strip CRLF to get the
        // bare header line. Matches src/net/http1.zig's pattern.
        const line = std.mem.trimEnd(u8, line_with_cr, "\r\n");

        if (line.len == 0) break; // blank line — end of headers

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return FramingError.InvalidHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch
                return FramingError.InvalidContentLength;
        }
        // Other headers (Content-Type, etc.) silently ignored.
    }

    const len = content_length orelse return FramingError.MissingContentLength;
    if (len > max_body_bytes) return FramingError.BodyTooLarge;

    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);

    // readNoEof reads exactly `len` bytes or returns EndOfStream. We
    // remap to a clearer error for the caller.
    reader.readNoEof(body) catch |err| switch (err) {
        error.EndOfStream => return FramingError.UnexpectedEof,
        else => |e| return e,
    };

    return body;
}

/// Write one Content-Length-framed message to `writer`. The body is
/// emitted verbatim — caller is responsible for ensuring it's valid
/// JSON. We never emit other headers (no Content-Type) so the
/// minimum-bytes-on-the-wire shape stays predictable.
pub fn writeFrame(writer: anytype, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

// ── Envelope parsing ────────────────────────────────────────────────────

/// Parsed view of a JSON-RPC 2.0 Request or Notification. Owns its
/// underlying JSON tree via `parsed`; call `deinit` to free.
///
/// Per JSON-RPC §4: a Request has an `id`, a Notification doesn't.
/// `id_value` is null when the message is a Notification.
///
/// `params_value` is null when params are absent. Per-method handlers
/// then drill into `params_value.?.object.get("...")` etc.
pub const Request = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Request) void {
        self.parsed.deinit();
    }

    /// Returns the `method` string. The slice is borrowed from the
    /// underlying JSON tree and is valid until `deinit`.
    pub fn method(self: *const Request) ?[]const u8 {
        const obj = self.parsed.value.object;
        const m = obj.get("method") orelse return null;
        return switch (m) {
            .string => |s| s,
            else => null,
        };
    }

    /// Returns the `id` field as a raw `std.json.Value`. JSON-RPC
    /// allows id to be a number, string, or null; `null` here means
    /// "no id field present" (i.e. Notification).
    pub fn id(self: *const Request) ?std.json.Value {
        return self.parsed.value.object.get("id");
    }

    /// Returns the `params` field as a raw `std.json.Value` or null
    /// if absent. Per-method handlers parse it further.
    pub fn params(self: *const Request) ?std.json.Value {
        return self.parsed.value.object.get("params");
    }

    pub fn isNotification(self: *const Request) bool {
        return self.id() == null;
    }
};

/// Parse a JSON body as a Request. The caller passes the body
/// bytes from `readFrame`; we wrap the std.json result so lifetime
/// is explicit.
pub fn parseRequest(allocator: std.mem.Allocator, body: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    errdefer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };

    // jsonrpc: "2.0" is required; we tolerate its absence rather than
    // hard-fail — some clients omit it. Accept the message and proceed.
    if (obj.get("jsonrpc")) |jr| switch (jr) {
        .string => |s| if (!std.mem.eql(u8, s, "2.0")) return error.InvalidRequest,
        else => return error.InvalidRequest,
    };

    if (obj.get("method") == null) return error.InvalidRequest;

    return Request{ .parsed = parsed };
}

// ── Envelope writing ────────────────────────────────────────────────────

/// Write a JSON-RPC success response to `writer`, framed for the
/// wire. `id_json` is the raw JSON of the original request's id —
/// passed back unchanged per JSON-RPC §5. `result_json` is the raw
/// JSON value of the result.
pub fn writeSuccess(
    writer: anytype,
    allocator: std.mem.Allocator,
    id_json: []const u8,
    result_json: []const u8,
) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try body.appendSlice(allocator, id_json);
    try body.appendSlice(allocator, ",\"result\":");
    try body.appendSlice(allocator, result_json);
    try body.append(allocator, '}');
    try writeFrame(writer, body.items);
}

/// Write a JSON-RPC error response to `writer`, framed.
pub fn writeError(
    writer: anytype,
    allocator: std.mem.Allocator,
    id_json: []const u8,
    code: ErrorCode,
    message: []const u8,
) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try body.appendSlice(allocator, id_json);
    try body.print(allocator, ",\"error\":{{\"code\":{d},\"message\":", .{@intFromEnum(code)});
    try writeJsonString(&body, allocator, message);
    try body.appendSlice(allocator, "}}");
    try writeFrame(writer, body.items);
}

/// Append `s` as a JSON-quoted string into `list`. Mirrors the
/// minimal escaper in `src/telemetry.zig` — we duplicate it here to
/// keep this module dependency-free from telemetry (telemetry imports
/// jsonrpc would create a cycle once daemon clients emit).
fn writeJsonString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try list.appendSlice(allocator, slice);
            },
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
}

/// Re-serialize a `std.json.Value` to its canonical text form so
/// daemon code can pass an id from the request straight to the
/// response without keeping the original bytes around. Caller owns
/// the returned slice.
pub fn idToJson(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    if (id == null) return allocator.dupe(u8, "null");
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(id.?, .{})});
}

// ── Tests ────────────────────────────────────────────────────────────────

// Test-only writer that owns a heap-resizable buffer and exposes the
// Zig 0.16 std.Io.Writer interface required by writeFrame. Replaces
// the old `ArrayList.writer(allocator)` shortcut that's gone in 0.16.
const TestWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestWriter) void {
        self.buf.deinit(self.allocator);
    }

    fn print(self: *TestWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.print(self.allocator, fmt, args);
    }

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }
};

// Test-only reader over a fixed byte slice. Exposes the readUntilDelimiter
// and readNoEof shape that readFrame's anytype expects, matching
// src/net/http1.zig:TestReader.
const TestReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn read(self: *TestReader, dest: []u8) error{}!usize {
        const remaining = self.data[self.pos..];
        const n = @min(dest.len, remaining.len);
        @memcpy(dest[0..n], remaining[0..n]);
        self.pos += n;
        return n;
    }

    fn readUntilDelimiter(self: *TestReader, out: []u8, delim: u8) ![]u8 {
        var len: usize = 0;
        while (len < out.len) {
            const n = try self.read(out[len .. len + 1]);
            if (n == 0) return error.EndOfStream;
            len += n;
            if (out[len - 1] == delim) return out[0..len];
        }
        return error.StreamTooLong;
    }

    fn readNoEof(self: *TestReader, dest: []u8) !void {
        var filled: usize = 0;
        while (filled < dest.len) {
            const n = try self.read(dest[filled..]);
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }
};

test "writeFrame produces Content-Length header + body" {
    var w: TestWriter = .{ .allocator = std.testing.allocator };
    defer w.deinit();
    try writeFrame(&w, "{\"hello\":\"world\"}");
    try std.testing.expectEqualStrings(
        "Content-Length: 17\r\n\r\n{\"hello\":\"world\"}",
        w.buf.items,
    );
}

test "readFrame round-trips with writeFrame" {
    var w: TestWriter = .{ .allocator = std.testing.allocator };
    defer w.deinit();
    const original = "{\"method\":\"ping\",\"id\":1,\"jsonrpc\":\"2.0\"}";
    try writeFrame(&w, original);

    var r = TestReader{ .data = w.buf.items };
    const body = try readFrame(&r, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(original, body);
}

test "readFrame ignores unknown headers (forward compat)" {
    const wire = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
        "Content-Length: 4\r\n" ++
        "X-Custom: yes\r\n" ++
        "\r\n" ++
        "noop";
    var r = TestReader{ .data = wire };
    const body = try readFrame(&r, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("noop", body);
}

test "readFrame errors on missing Content-Length" {
    const wire = "Content-Type: application/json\r\n\r\nbody";
    var r = TestReader{ .data = wire };
    try std.testing.expectError(
        FramingError.MissingContentLength,
        readFrame(&r, std.testing.allocator, 1 << 20),
    );
}

test "readFrame errors on body shorter than declared length" {
    const wire = "Content-Length: 100\r\n\r\nshort";
    var r = TestReader{ .data = wire };
    try std.testing.expectError(
        FramingError.UnexpectedEof,
        readFrame(&r, std.testing.allocator, 1 << 20),
    );
}

test "readFrame enforces max_body_bytes cap" {
    const wire = "Content-Length: 999999\r\n\r\n";
    var r = TestReader{ .data = wire };
    try std.testing.expectError(
        FramingError.BodyTooLarge,
        readFrame(&r, std.testing.allocator, 1024),
    );
}

test "readFrame errors on malformed Content-Length value" {
    const wire = "Content-Length: not-a-number\r\n\r\nbody";
    var r = TestReader{ .data = wire };
    try std.testing.expectError(
        FramingError.InvalidContentLength,
        readFrame(&r, std.testing.allocator, 1 << 20),
    );
}

test "readFrame errors on header without colon" {
    const wire = "ThisIsNotAHeader\r\n\r\nbody";
    var r = TestReader{ .data = wire };
    try std.testing.expectError(
        FramingError.InvalidHeader,
        readFrame(&r, std.testing.allocator, 1 << 20),
    );
}

test "parseRequest extracts method, id, params" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"https://example.com/\"}}";
    var req = try parseRequest(std.testing.allocator, body);
    defer req.deinit();

    try std.testing.expectEqualStrings("fetch", req.method().?);

    const id = req.id().?;
    try std.testing.expect(id == .integer);
    try std.testing.expectEqual(@as(i64, 42), id.integer);

    const params = req.params().?;
    try std.testing.expect(params == .object);
    const url = params.object.get("url").?;
    try std.testing.expectEqualStrings("https://example.com/", url.string);

    try std.testing.expect(!req.isNotification());
}

test "parseRequest detects Notification (no id)" {
    const body = "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\"}";
    var req = try parseRequest(std.testing.allocator, body);
    defer req.deinit();
    try std.testing.expect(req.isNotification());
    try std.testing.expectEqualStrings("shutdown", req.method().?);
}

test "parseRequest rejects body with no method" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    try std.testing.expectError(
        error.InvalidRequest,
        parseRequest(std.testing.allocator, body),
    );
}

test "parseRequest rejects non-2.0 jsonrpc version" {
    const body = "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}";
    try std.testing.expectError(
        error.InvalidRequest,
        parseRequest(std.testing.allocator, body),
    );
}

test "parseRequest tolerates omitted jsonrpc field" {
    // Some buggy clients omit the "jsonrpc":"2.0" tag. We accept
    // the message rather than hard-fail, consistent with what most
    // tolerant servers do.
    const body = "{\"id\":1,\"method\":\"ping\"}";
    var req = try parseRequest(std.testing.allocator, body);
    defer req.deinit();
    try std.testing.expectEqualStrings("ping", req.method().?);
}

test "writeSuccess produces a framed JSON-RPC response" {
    var w: TestWriter = .{ .allocator = std.testing.allocator };
    defer w.deinit();
    try writeSuccess(&w, std.testing.allocator, "42", "\"pong\"");

    try std.testing.expect(std.mem.startsWith(u8, w.buf.items, "Content-Length: "));
    try std.testing.expect(std.mem.endsWith(u8, w.buf.items, "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":\"pong\"}"));
}

test "writeError encodes code and message" {
    var w: TestWriter = .{ .allocator = std.testing.allocator };
    defer w.deinit();
    try writeError(&w, std.testing.allocator, "1", .method_not_found, "no such method");

    try std.testing.expect(std.mem.indexOf(u8, w.buf.items, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buf.items, "\"message\":\"no such method\"") != null);
}

test "writeError escapes special chars in message" {
    var w: TestWriter = .{ .allocator = std.testing.allocator };
    defer w.deinit();
    try writeError(&w, std.testing.allocator, "1", .internal_error, "oops \"quoted\"\nnewline");

    try std.testing.expect(std.mem.indexOf(u8, w.buf.items, "\\\"quoted\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buf.items, "\\n") != null);
}

test "idToJson serializes integer, string, and null ids" {
    const i = try idToJson(std.testing.allocator, .{ .integer = 42 });
    defer std.testing.allocator.free(i);
    try std.testing.expectEqualStrings("42", i);

    const s = try idToJson(std.testing.allocator, .{ .string = "abc" });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\"abc\"", s);

    const n = try idToJson(std.testing.allocator, null);
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("null", n);
}

test "round-trip: parseRequest output → writeSuccess → readable response" {
    // Simulates one full request/response cycle on a fixed-buffer
    // stream. Daemon-side parses a request, builds a response;
    // client-side reads the framed response back.
    const request_body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}";
    var req = try parseRequest(std.testing.allocator, request_body);
    defer req.deinit();
    try std.testing.expectEqualStrings("ping", req.method().?);

    const id_json = try idToJson(std.testing.allocator, req.id());
    defer std.testing.allocator.free(id_json);
    try std.testing.expectEqualStrings("7", id_json);

    var w: TestWriter = .{ .allocator = std.testing.allocator };
    defer w.deinit();
    try writeSuccess(&w, std.testing.allocator, id_json, "\"pong\"");

    var r = TestReader{ .data = w.buf.items };
    const resp_body = try readFrame(&r, std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(resp_body);

    var resp_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, resp_body, .{});
    defer resp_parsed.deinit();
    try std.testing.expectEqualStrings("pong", resp_parsed.value.object.get("result").?.string);
    try std.testing.expectEqual(@as(i64, 7), resp_parsed.value.object.get("id").?.integer);
}
