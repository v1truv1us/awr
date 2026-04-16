/// h2session.zig — HTTP/2 session layer for AWR.
///
/// STATUS: WIRED into the owned HTTPS fetch path for single-request H2 GETs.
/// Remaining gaps are verification depth, richer request headers, and any future
/// multi-stream/session reuse work.
///
/// Provides H2Session: a client-side HTTP/2 session that drives I/O
/// through caller-supplied send/recv callbacks and accumulates a full
/// response before returning it.
///
/// Phase 1 constraints:
///   - Single active stream per session.
///   - Synchronous I/O callbacks (libxev integration comes in Phase 2).
///   - TLS not wired in; caller must connect an already-negotiated stream.
///
/// Usage:
///   var sess = try H2Session.init(allocator, send_fn, recv_fn, ctx);
///   defer sess.deinit();
///   const sid = try sess.submitGet("GET", "https", "example.com", "/");
///   const resp = try sess.runUntilComplete(sid);
///   defer resp.deinit(allocator);
const std = @import("std");
const fingerprint = @import("fingerprint.zig");

const c = @cImport({
    @cInclude("h2_shim.h");
});

// ── Public response type ────────────────────────────────────────────────

pub const H2Response = struct {
    status: u16,
    body: []u8,
    headers: []u8, // raw name\0value\0 buffer — iterate with headerIterator()

    /// Free memory returned from awr_h2_get_response.
    pub fn deinit(self: *H2Response) void {
        if (self.body.len > 0) std.c.free(self.body.ptr);
        if (self.headers.len > 0) std.c.free(self.headers.ptr);
        self.body = &.{};
        self.headers = &.{};
    }

    /// Iterate over name/value header pairs.
    /// Usage:
    ///   var it = resp.headerIterator();
    ///   while (it.next()) |pair| { ... pair.name ... pair.value ... }
    pub fn headerIterator(self: *const H2Response) HeaderIterator {
        return HeaderIterator{ .buf = self.headers, .pos = 0 };
    }
};

pub const HeaderPair = struct { name: []const u8, value: []const u8 };

pub const HeaderIterator = struct {
    buf: []const u8,
    pos: usize,

    pub fn next(self: *HeaderIterator) ?HeaderPair {
        if (self.pos >= self.buf.len) return null;
        const name_start = self.pos;
        // find name NUL
        while (self.pos < self.buf.len and self.buf[self.pos] != 0) : (self.pos += 1) {}
        const name = self.buf[name_start..self.pos];
        if (self.pos >= self.buf.len) return null;
        self.pos += 1; // skip NUL
        const val_start = self.pos;
        // find value NUL
        while (self.pos < self.buf.len and self.buf[self.pos] != 0) : (self.pos += 1) {}
        const value = self.buf[val_start..self.pos];
        if (self.pos < self.buf.len) self.pos += 1; // skip NUL
        return HeaderPair{ .name = name, .value = value };
    }
};

// ── H2Session ──────────────────────────────────────────────────────────

pub const H2Error = error{
    SessionCreateFailed,
    SubmitFailed,
    IoError,
    StreamNotComplete,
    ResponseError,
};

pub const H2Session = struct {
    sess: *c.awr_h2_session_t,

    pub const HeaderField = c.awr_h2_header_t;

    pub fn init(
        send_cb: c.awr_h2_send_cb,
        recv_cb: c.awr_h2_recv_cb,
        user_data: ?*anyopaque,
    ) H2Error!H2Session {
        const s = c.awr_h2_session_new(send_cb, recv_cb, user_data) orelse return H2Error.SessionCreateFailed;
        return H2Session{ .sess = s };
    }

    pub fn deinit(self: *H2Session) void {
        c.awr_h2_session_free(self.sess);
    }

    /// Queue a GET request. Returns the nghttp2 stream_id.
    pub fn submitGet(
        self: *H2Session,
        method: [*:0]const u8,
        scheme: [*:0]const u8,
        authority: [*:0]const u8,
        path: [*:0]const u8,
    ) H2Error!i32 {
        return self.submitGetWithHeaders(method, scheme, authority, path, &.{});
    }

    pub fn submitGetWithHeaders(
        self: *H2Session,
        method: [*:0]const u8,
        scheme: [*:0]const u8,
        authority: [*:0]const u8,
        path: [*:0]const u8,
        headers: []const HeaderField,
    ) H2Error!i32 {
        const header_ptr = if (headers.len == 0) null else headers.ptr;
        const sid = c.awr_h2_submit_get_ex(self.sess, method, scheme, authority, path, header_ptr, headers.len);
        if (sid < 0) return H2Error.SubmitFailed;
        return sid;
    }

    /// Drive one send+recv cycle. Returns true when the stream is complete.
    pub fn run(self: *H2Session, stream_id: i32) H2Error!bool {
        const rc = c.awr_h2_session_run(self.sess);
        if (rc != 0) return H2Error.IoError;
        return c.awr_h2_stream_complete(self.sess, stream_id) != 0;
    }

    /// Spin the I/O loop up to `max_iters` times until `stream_id` completes.
    /// Returns H2Error.StreamNotComplete if the limit is reached.
    pub fn runUntilComplete(self: *H2Session, stream_id: i32, max_iters: u32) H2Error!H2Response {
        var i: u32 = 0;
        while (i < max_iters) : (i += 1) {
            if (try self.run(stream_id)) break;
        } else return H2Error.StreamNotComplete;

        var raw: c.awr_h2_response_t = undefined;
        if (c.awr_h2_get_response(self.sess, stream_id, &raw) != 0)
            return H2Error.ResponseError;

        return H2Response{
            .status = raw.status,
            .body = if (raw.body != null) raw.body[0..raw.body_len] else &.{},
            .headers = if (raw.headers_buf != null)
                @as([*]u8, @ptrCast(raw.headers_buf))[0..raw.headers_buf_len]
            else
                &.{},
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "HeaderIterator parses name/value pairs" {
    // Simulate the flat name\0value\0 buffer layout
    const buf = "content-type\x00text/html\x00content-length\x0042\x00";
    const response = H2Response{
        .status = 200,
        .body = &.{},
        .headers = @constCast(buf[0..buf.len]),
    };
    var it = response.headerIterator();

    const p1 = it.next() orelse return error.MissingPair;
    try std.testing.expectEqualStrings("content-type", p1.name);
    try std.testing.expectEqualStrings("text/html", p1.value);

    const p2 = it.next() orelse return error.MissingPair;
    try std.testing.expectEqualStrings("content-length", p2.name);
    try std.testing.expectEqualStrings("42", p2.value);

    try std.testing.expect(it.next() == null);
}

test "HeaderIterator returns null on empty buffer" {
    const response = H2Response{ .status = 200, .body = &.{}, .headers = &.{} };
    var it = response.headerIterator();
    try std.testing.expect(it.next() == null);
}

// Minimal no-op I/O callbacks used by unit tests that don't exercise the wire.
fn noop_send(_: [*c]const u8, _: usize, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}
fn noop_recv(_: [*c]u8, _: usize, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

const CaptureCtx = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *CaptureCtx, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    fn send(data: [*c]const u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *@This() = @ptrCast(@alignCast(ud.?));
        ctx.bytes.appendSlice(std.testing.allocator, data[0..len]) catch return -1;
        return @intCast(len);
    }

    fn recv(_: [*c]u8, _: usize, _: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }
};

const Frame = struct {
    length: usize,
    frame_type: u8,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
    next_offset: usize,
};

fn parseFrame(bytes: []const u8, offset: usize) !Frame {
    if (bytes.len < offset + 9) return error.TruncatedFrameHeader;
    const length = (@as(usize, bytes[offset]) << 16) |
        (@as(usize, bytes[offset + 1]) << 8) |
        @as(usize, bytes[offset + 2]);
    const end = offset + 9 + length;
    if (bytes.len < end) return error.TruncatedFramePayload;

    const stream_id = std.mem.readInt(u32, bytes[offset + 5 .. offset + 9][0..4], .big) & 0x7fffffff;
    return .{
        .length = length,
        .frame_type = bytes[offset + 3],
        .flags = bytes[offset + 4],
        .stream_id = stream_id,
        .payload = bytes[offset + 9 .. end],
        .next_offset = end,
    };
}

test "H2Session.init and deinit succeed with no-op callbacks" {
    var sess = try H2Session.init(noop_send, noop_recv, null);
    defer sess.deinit();
    // If we reach here without error the session was created successfully.
}

test "H2Session.submitGet returns a positive stream_id" {
    var sess = try H2Session.init(noop_send, noop_recv, null);
    defer sess.deinit();
    const sid = try sess.submitGet("GET", "https", "example.com", "/");
    // nghttp2 assigns odd stream IDs starting at 1.
    try std.testing.expect(sid > 0);
    try std.testing.expect(@rem(sid, 2) == 1);
}

test "first run sends client preface, Chrome-like SETTINGS, and connection WINDOW_UPDATE" {
    var capture = CaptureCtx{};
    defer capture.deinit(std.testing.allocator);

    var sess = try H2Session.init(CaptureCtx.send, CaptureCtx.recv, &capture);
    defer sess.deinit();

    try std.testing.expect(!(try sess.run(1)));

    const bytes = capture.bytes.items;
    const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    try std.testing.expect(bytes.len >= preface.len + 9);
    try std.testing.expectEqualStrings(preface, bytes[0..preface.len]);

    const settings = try parseFrame(bytes, preface.len);
    try std.testing.expectEqual(@as(u8, 0x4), settings.frame_type);
    try std.testing.expectEqual(@as(u8, 0x0), settings.flags);
    try std.testing.expectEqual(@as(u32, 0), settings.stream_id);
    try std.testing.expectEqual(@as(usize, 24), settings.length);

    try std.testing.expectEqual(@as(u16, 0x1), std.mem.readInt(u16, settings.payload[0..2], .big));
    try std.testing.expectEqual(fingerprint.h2_header_table_size, std.mem.readInt(u32, settings.payload[2..6], .big));
    try std.testing.expectEqual(@as(u16, 0x3), std.mem.readInt(u16, settings.payload[6..8], .big));
    try std.testing.expectEqual(fingerprint.h2_max_concurrent_streams, std.mem.readInt(u32, settings.payload[8..12], .big));
    try std.testing.expectEqual(@as(u16, 0x4), std.mem.readInt(u16, settings.payload[12..14], .big));
    try std.testing.expectEqual(fingerprint.h2_initial_window_size, std.mem.readInt(u32, settings.payload[14..18], .big));
    try std.testing.expectEqual(@as(u16, 0x6), std.mem.readInt(u16, settings.payload[18..20], .big));
    try std.testing.expectEqual(fingerprint.h2_max_header_list_size, std.mem.readInt(u32, settings.payload[20..24], .big));

    const window_update = try parseFrame(bytes, settings.next_offset);
    try std.testing.expectEqual(@as(u8, 0x8), window_update.frame_type);
    try std.testing.expectEqual(@as(u32, 0), window_update.stream_id);
    try std.testing.expectEqual(@as(usize, 4), window_update.length);
    try std.testing.expectEqual(
        fingerprint.h2_connection_window_increment,
        std.mem.readInt(u32, window_update.payload[0..4], .big) & 0x7fffffff,
    );
}

test "h2 shim keeps Chrome pseudo-header order" {
    try std.testing.expectEqual(@as(c_int, 1), c.awr_h2_pseudo_header_order_ok());
}
