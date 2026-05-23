/// websocket.zig — RFC 6455 WebSocket frame codec and HTTP Upgrade handshake.
///
/// Pure-Zig; depends only on std. Works over any anytype reader/writer
/// that exposes readNoEof and writeAll methods. Higher-level callers supply
/// the connected transport: bridge.zig native callback uses TlsConn for wss://
/// and std.net.Stream for ws://; tests use in-process TestPipe or localhost threads.
///
/// Tier 3 — T3.D.2 WebSocket.
const std = @import("std");

/// macOS libc random — used instead of std.crypto.random (removed in Zig 0.16).
extern fn arc4random_buf(buf: [*]u8, nbytes: usize) void;

// ── Error set ─────────────────────────────────────────────────────────────

pub const WsError = error{
    /// Server did not return "101 Switching Protocols".
    HandshakeRejected,
    /// Sec-WebSocket-Accept doesn't match the expected value.
    HandshakeKeyMismatch,
    /// 101 response is missing required Upgrade or Connection headers.
    HandshakeProtocolError,
    /// Reserved bits (RSV1-3) non-zero with no extension negotiated.
    ProtocolError,
    /// Control frame (ping/pong/close) had FIN=0 — forbidden by RFC 6455.
    FragmentedControl,
    /// Payload length exceeds the 16 MiB sanity cap.
    PayloadTooLarge,
    /// Transport closed before the WebSocket handshake completed.
    ConnectionClosed,
    /// New data/binary frame arrived while a fragmented sequence is in progress.
    UnexpectedDataFrame,
};

// ── Opcode ─────────────────────────────────────────────────────────────────

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

// ── Frame ──────────────────────────────────────────────────────────────────

/// One WebSocket frame. `payload` is allocator-owned; free with `allocator.free(frame.payload)`.
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

// ── Session result ─────────────────────────────────────────────────────────

pub const WsMessage = struct {
    data: []u8,
    is_binary: bool,
};

/// All messages received until the server sent CLOSE (or an error occurred).
/// Call `deinit` to free all owned memory.
pub const WsSession = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(WsMessage),
    close_code: u16,
    close_reason: []u8,

    pub fn deinit(self: *WsSession) void {
        for (self.messages.items) |msg| self.allocator.free(msg.data);
        self.messages.deinit(self.allocator);
        self.allocator.free(self.close_reason);
    }
};

// ── RFC 6455 magic GUID ────────────────────────────────────────────────────

const ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ── Key helpers ────────────────────────────────────────────────────────────

/// Fill `out` (24 bytes) with a base64-encoded random 16-byte nonce.
/// This is the Sec-WebSocket-Key value sent in the upgrade request.
pub fn generateKey(out: *[24]u8) void {
    var raw: [16]u8 = undefined;
    arc4random_buf(&raw, raw.len);
    _ = std.base64.standard.Encoder.encode(out, &raw);
}

/// Compute the expected Sec-WebSocket-Accept for a given Sec-WebSocket-Key.
/// Returns a 28-byte base64 string; caller owns via `allocator`.
pub fn computeAccept(allocator: std.mem.Allocator, key_b64: []const u8) ![]u8 {
    // SHA-1(key || magic)
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key_b64);
    sha.update(ws_magic);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha.final(&digest);

    // base64(sha1_digest) → 28 bytes for a 20-byte digest
    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out;
}

// ── HTTP Upgrade handshake ─────────────────────────────────────────────────

/// Write the HTTP/1.1 Upgrade request to `writer`.
pub fn sendUpgradeRequest(
    writer: anytype,
    host: []const u8,
    path: []const u8,
    key_b64: []const u8,
) !void {
    var buf: [2048]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ path, host, key_b64 },
    );
    try writer.writeAll(req);
}

/// Read the server's 101 response and validate it.
/// Checks status 101, Upgrade/Connection headers, and Sec-WebSocket-Accept.
pub fn readUpgradeResponse(
    reader: anytype,
    allocator: std.mem.Allocator,
    key_b64: []const u8,
) !void {
    // Read byte-by-byte until \r\n\r\n (header terminator).
    // 4 KiB is more than enough for any realistic WebSocket 101 response.
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        var rb: [1]u8 = undefined;
        try reader.readNoEof(&rb);
        buf[len] = rb[0];
        len += 1;
        if (len >= 4 and
            buf[len - 4] == '\r' and buf[len - 3] == '\n' and
            buf[len - 2] == '\r' and buf[len - 1] == '\n') break;
    }
    const response = buf[0..len];

    // Status line must contain "101".
    const status_end = std.mem.indexOf(u8, response, "\r\n") orelse return error.HandshakeRejected;
    const status_line = response[0..status_end];
    if (std.mem.indexOf(u8, status_line, "101") == null) return error.HandshakeRejected;

    // Parse headers that follow the status line.
    var got_upgrade = false;
    var got_connection = false;
    var accept_value: ?[]const u8 = null;

    var lines = std.mem.splitSequence(u8, response[status_end + 2 ..], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            if (std.ascii.eqlIgnoreCase(value, "websocket")) got_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |tok| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, tok, " \t"), "upgrade")) {
                    got_connection = true;
                    break;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            accept_value = value;
        }
    }

    if (!got_upgrade or !got_connection) return error.HandshakeProtocolError;

    const accept = accept_value orelse return error.HandshakeKeyMismatch;
    const expected = try computeAccept(allocator, key_b64);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, accept, expected)) return error.HandshakeKeyMismatch;
}

// ── Frame I/O ──────────────────────────────────────────────────────────────

/// Maximum payload size accepted in a single frame (16 MiB sanity cap).
const max_payload_len: u64 = 16 * 1024 * 1024;

/// Read one WebSocket frame. `frame.payload` is allocated from `allocator`; caller frees.
pub fn readFrame(reader: anytype, allocator: std.mem.Allocator) !Frame {
    // Byte 0: FIN | RSV1 | RSV2 | RSV3 | opcode(4)
    var b0b: [1]u8 = undefined;
    try reader.readNoEof(&b0b);
    const b0 = b0b[0];
    const fin = (b0 & 0x80) != 0;
    const rsv = b0 & 0x70;
    // No extensions negotiated — any non-zero RSV is a protocol error.
    if (rsv != 0) return error.ProtocolError;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));

    // Byte 1: MASK | payload_len(7)
    var b1b: [1]u8 = undefined;
    try reader.readNoEof(&b1b);
    const b1 = b1b[0];
    const server_masked = (b1 & 0x80) != 0;
    const len7: u8 = b1 & 0x7F;

    // Extended payload length (RFC 6455 §5.2).
    const payload_len: u64 = switch (len7) {
        126 => blk: {
            var ext: [2]u8 = undefined;
            try reader.readNoEof(&ext);
            break :blk std.mem.readInt(u16, &ext, .big);
        },
        127 => blk: {
            var ext: [8]u8 = undefined;
            try reader.readNoEof(&ext);
            break :blk std.mem.readInt(u64, &ext, .big);
        },
        else => @intCast(len7),
    };

    if (payload_len > max_payload_len) return error.PayloadTooLarge;

    // Masking key (server→client frames SHOULD NOT be masked, but handle it anyway).
    var mask_key: [4]u8 = undefined;
    if (server_masked) try reader.readNoEof(&mask_key);

    const payload = try allocator.alloc(u8, @intCast(payload_len));
    errdefer allocator.free(payload);
    try reader.readNoEof(payload);
    if (server_masked) maskPayload(payload, mask_key, 0);

    // Control frames (opcode high bit set) must not be fragmented (RFC 6455 §5.5).
    if ((@intFromEnum(opcode) & 0x8) != 0 and !fin) return error.FragmentedControl;

    return Frame{ .fin = fin, .opcode = opcode, .payload = payload };
}

/// Write one WebSocket frame with client-side masking (RFC 6455 §5.3).
/// `mask_key` should be 4 cryptographically random bytes.
pub fn writeFrame(
    writer: anytype,
    opcode: Opcode,
    payload: []const u8,
    mask_key: [4]u8,
) !void {
    // Byte 0: FIN=1 (no fragmentation for client frames here), opcode.
    try writer.writeAll(&[_]u8{0x80 | @as(u8, @intFromEnum(opcode))});

    // Byte 1: MASK=1 (client MUST mask), payload length.
    const len = payload.len;
    if (len < 126) {
        try writer.writeAll(&[_]u8{0x80 | @as(u8, @intCast(len))});
    } else if (len <= 0xFFFF) {
        try writer.writeAll(&[_]u8{0x80 | 126});
        var ext: [2]u8 = undefined;
        std.mem.writeInt(u16, &ext, @intCast(len), .big);
        try writer.writeAll(&ext);
    } else {
        try writer.writeAll(&[_]u8{0x80 | 127});
        var ext: [8]u8 = undefined;
        std.mem.writeInt(u64, &ext, @intCast(len), .big);
        try writer.writeAll(&ext);
    }
    try writer.writeAll(&mask_key);

    // Write masked payload in 4 KiB chunks to stay off the stack for large payloads.
    var chunk: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < len) {
        const end = @min(offset + chunk.len, len);
        const n = end - offset;
        @memcpy(chunk[0..n], payload[offset..end]);
        maskPayload(chunk[0..n], mask_key, offset);
        try writer.writeAll(chunk[0..n]);
        offset = end;
    }
}

/// XOR-mask `payload` in-place. `key_offset` is the byte index into the stream
/// at which `payload[0]` starts — used for chunked writes to maintain key rotation.
pub fn maskPayload(payload: []u8, key: [4]u8, key_offset: usize) void {
    for (payload, 0..) |*b, i| b.* ^= key[(key_offset + i) % 4];
}

// ── High-level session ─────────────────────────────────────────────────────

/// Run a complete WebSocket session over already-connected `reader`/`writer`.
///
/// 1. Sends the HTTP Upgrade request using `host` and `path`.
/// 2. Validates the 101 response (Sec-WebSocket-Accept checked).
/// 3. Sends each string in `pending_sends` as a text frame.
/// 4. Reads frames until a CLOSE frame or transport error.
///    - ping → pong echo (RFC 6455 §5.5.3).
///    - Fragmented messages reassembled before dispatch.
/// 5. Returns all received messages plus the close code/reason.
///
/// Caller owns the returned `WsSession`; call `session.deinit()` to free.
pub fn runSession(
    reader: anytype,
    writer: anytype,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    pending_sends: []const []const u8,
) !WsSession {
    // Generate a unique key for this handshake.
    var key_buf: [24]u8 = undefined;
    generateKey(&key_buf);
    const key_b64: []const u8 = &key_buf;

    try sendUpgradeRequest(writer, host, path, key_b64);
    try readUpgradeResponse(reader, allocator, key_b64);

    // Send any messages that were buffered before the connection opened.
    for (pending_sends) |msg| {
        var mask: [4]u8 = undefined;
        arc4random_buf(&mask, mask.len);
        try writeFrame(writer, .text, msg, mask);
    }

    // Receive frames until CLOSE.
    var messages: std.ArrayList(WsMessage) = .empty;
    errdefer {
        for (messages.items) |msg| allocator.free(msg.data);
        messages.deinit(allocator);
    }

    // Fragment reassembly state.
    var frag_buf: std.ArrayList(u8) = .empty;
    var frag_is_binary = false;
    defer frag_buf.deinit(allocator);

    var close_code: u16 = 1000;
    var close_reason: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(close_reason);

    while (true) {
        const frame = try readFrame(reader, allocator);
        defer allocator.free(frame.payload);

        switch (frame.opcode) {
            .text, .binary => {
                if (!frame.fin) {
                    // First fragment of a fragmented message.
                    if (frag_buf.items.len > 0) return error.UnexpectedDataFrame;
                    frag_is_binary = frame.opcode == .binary;
                    try frag_buf.appendSlice(allocator, frame.payload);
                } else {
                    // Unfragmented message (the common case).
                    if (frag_buf.items.len > 0) return error.UnexpectedDataFrame;
                    try messages.append(allocator, .{
                        .data = try allocator.dupe(u8, frame.payload),
                        .is_binary = frame.opcode == .binary,
                    });
                }
            },
            .continuation => {
                try frag_buf.appendSlice(allocator, frame.payload);
                if (frame.fin) {
                    const data = try allocator.dupe(u8, frag_buf.items);
                    try messages.append(allocator, .{ .data = data, .is_binary = frag_is_binary });
                    frag_buf.clearRetainingCapacity();
                    frag_is_binary = false;
                }
            },
            .ping => {
                // RFC 6455 §5.5.3: must respond with a pong carrying the same payload.
                var mask: [4]u8 = undefined;
                arc4random_buf(&mask, mask.len);
                try writeFrame(writer, .pong, frame.payload, mask);
            },
            .pong => {
                // Unsolicited pong — ignore per spec.
            },
            .close => {
                // Parse close code and reason from payload (RFC 6455 §5.5.1).
                if (frame.payload.len >= 2) {
                    close_code = std.mem.readInt(u16, frame.payload[0..2], .big);
                    if (frame.payload.len > 2) {
                        allocator.free(close_reason);
                        close_reason = try allocator.dupe(u8, frame.payload[2..]);
                    }
                }
                // Echo a CLOSE frame to acknowledge.
                var mask: [4]u8 = undefined;
                arc4random_buf(&mask, mask.len);
                writeFrame(writer, .close, &.{}, mask) catch {};
                break;
            },
            _ => return error.ProtocolError,
        }
    }

    return WsSession{
        .allocator = allocator,
        .messages = messages,
        .close_code = close_code,
        .close_reason = close_reason,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

/// In-memory pipe used by tests in place of std.io.fixedBufferStream (removed in Zig 0.16).
/// Acts as both writer (append) and reader (sequential consume) on a shared buffer.
const TestPipe = struct {
    data: [4096]u8 = .{0} ** 4096,
    write_pos: usize = 0,
    read_pos: usize = 0,

    pub fn writeAll(self: *TestPipe, bytes: []const u8) !void {
        @memcpy(self.data[self.write_pos..][0..bytes.len], bytes);
        self.write_pos += bytes.len;
    }

    pub fn readNoEof(self: *TestPipe, dest: []u8) !void {
        if (dest.len == 0) return;
        if (self.read_pos + dest.len > self.write_pos) return error.EndOfStream;
        @memcpy(dest, self.data[self.read_pos..][0..dest.len]);
        self.read_pos += dest.len;
    }

    /// Reset read cursor to start — mirrors fbs.pos = 0 in old tests.
    pub fn resetRead(self: *TestPipe) void {
        self.read_pos = 0;
    }

    /// Slice of bytes written so far.
    pub fn getWritten(self: *const TestPipe) []const u8 {
        return self.data[0..self.write_pos];
    }

    /// Pre-load bytes so the pipe can be used as a reader immediately.
    pub fn fill(self: *TestPipe, bytes: []const u8) void {
        @memcpy(self.data[0..bytes.len], bytes);
        self.write_pos = bytes.len;
        self.read_pos = 0;
    }
};

test "computeAccept — RFC 6455 §1.3 example vector" {
    // The spec gives this exact example:
    // key = "dGhlIHNhbXBsZSBub25jZQ==" → accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const accept = try computeAccept(std.testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer std.testing.allocator.free(accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "generateKey — produces a 24-byte base64 string" {
    var key: [24]u8 = undefined;
    generateKey(&key);
    // All characters should be valid base64 (A-Z a-z 0-9 + / =).
    for (key) |b| {
        const ok = (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or b == '+' or b == '/' or b == '=';
        try std.testing.expect(ok);
    }
}

test "maskPayload — XOR round-trip" {
    var data = [_]u8{ 0x48, 0x65, 0x6C, 0x6C, 0x6F }; // "Hello"
    const key = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
    maskPayload(&data, key, 0);
    maskPayload(&data, key, 0); // second pass restores original
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x48, 0x65, 0x6C, 0x6C, 0x6F }, &data);
}

test "writeFrame + readFrame — text roundtrip (short payload)" {
    const allocator = std.testing.allocator;
    var pipe: TestPipe = .{};

    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    try writeFrame(&pipe, .text, "Hello", mask);

    pipe.resetRead();
    const frame = try readFrame(&pipe, allocator);
    defer allocator.free(frame.payload);

    try std.testing.expect(frame.fin);
    try std.testing.expect(frame.opcode == .text);
    try std.testing.expectEqualStrings("Hello", frame.payload);
}

test "writeFrame + readFrame — binary with 126-byte extended length" {
    const allocator = std.testing.allocator;
    var pipe: TestPipe = .{};

    // Exactly 200 bytes triggers the 126 extended-length path.
    var payload: [200]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 256);

    const mask = [4]u8{ 0xAB, 0xCD, 0xEF, 0x01 };
    try writeFrame(&pipe, .binary, &payload, mask);

    pipe.resetRead();
    const frame = try readFrame(&pipe, allocator);
    defer allocator.free(frame.payload);

    try std.testing.expect(frame.opcode == .binary);
    try std.testing.expectEqual(@as(usize, 200), frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, frame.payload);
}

test "writeFrame + readFrame — ping and pong opcodes" {
    const allocator = std.testing.allocator;
    var pipe: TestPipe = .{};

    const mask = [4]u8{ 0x00, 0x00, 0x00, 0x00 };
    try writeFrame(&pipe, .ping, "ping-data", mask);

    pipe.resetRead();
    const frame = try readFrame(&pipe, allocator);
    defer allocator.free(frame.payload);

    try std.testing.expect(frame.opcode == .ping);
    try std.testing.expect(frame.fin);
    try std.testing.expectEqualStrings("ping-data", frame.payload);
}

test "writeFrame + readFrame — close opcode with code+reason" {
    const allocator = std.testing.allocator;
    var pipe: TestPipe = .{};

    // Construct a close payload: u16 big-endian code + reason text.
    var close_payload: [5]u8 = undefined;
    std.mem.writeInt(u16, close_payload[0..2], 1000, .big);
    @memcpy(close_payload[2..5], "bye");

    const mask = [4]u8{ 0x00, 0x00, 0x00, 0x00 };
    try writeFrame(&pipe, .close, &close_payload, mask);

    pipe.resetRead();
    const frame = try readFrame(&pipe, allocator);
    defer allocator.free(frame.payload);

    try std.testing.expect(frame.opcode == .close);
    try std.testing.expectEqual(@as(usize, 5), frame.payload.len);
    const code = std.mem.readInt(u16, frame.payload[0..2], .big);
    try std.testing.expectEqual(@as(u16, 1000), code);
    try std.testing.expectEqualStrings("bye", frame.payload[2..5]);
}

test "sendUpgradeRequest — writes correct HTTP headers" {
    var pipe: TestPipe = .{};
    try sendUpgradeRequest(&pipe, "echo.example.com", "/ws", "dGhlIHNhbXBsZSBub25jZQ==");
    const written = pipe.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "GET /ws HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Sec-WebSocket-Version: 13\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "readUpgradeResponse — accepts a valid 101 response" {
    const response =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    var pipe: TestPipe = .{};
    pipe.fill(response);
    // The spec key that produces the above accept value:
    try readUpgradeResponse(&pipe, std.testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
}

test "readUpgradeResponse — rejects non-101 response" {
    const response =
        "HTTP/1.1 400 Bad Request\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    var pipe: TestPipe = .{};
    pipe.fill(response);
    const result = readUpgradeResponse(&pipe, std.testing.allocator, "any");
    try std.testing.expectError(error.HandshakeRejected, result);
}

test "readUpgradeResponse — rejects mismatched accept key" {
    const response =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAAA\r\n" ++
        "\r\n";
    var pipe: TestPipe = .{};
    pipe.fill(response);
    const result = readUpgradeResponse(&pipe, std.testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectError(error.HandshakeKeyMismatch, result);
}
