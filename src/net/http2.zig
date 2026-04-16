/// http2.zig — HTTP/2 frame encoding for Chrome 132 fingerprint.
///
/// Implements frame-level encoding (SETTINGS, WINDOW_UPDATE, HEADERS)
/// without any C dependency. The nghttp2 integration will be layered on
/// top in a subsequent phase; this module lets us validate the byte output
/// independently.
///
/// All multi-byte integers are big-endian per RFC 7540 §4.1.
const std = @import("std");
const fp = @import("fingerprint.zig");

// ── Frame constants (RFC 7540) ─────────────────────────────────────────────

pub const FRAME_SETTINGS      : u8 = 0x4;
pub const FRAME_WINDOW_UPDATE : u8 = 0x8;
pub const FRAME_HEADERS       : u8 = 0x1;

pub const FLAG_NONE     : u8 = 0x0;
pub const FLAG_ACK      : u8 = 0x1;
pub const FLAG_END_HEADERS: u8 = 0x4;
pub const FLAG_END_STREAM : u8 = 0x1;

// ── Frame header ───────────────────────────────────────────────────────────

/// 9-byte HTTP/2 frame header (RFC 7540 §4.1).
pub const FrameHeader = struct {
    length: u24,     // payload length in bytes
    frame_type: u8,
    flags: u8,
    stream_id: u31,  // top bit reserved, always 0

    /// Serialize the 9-byte header into `out[0..9]`.
    pub fn encode(self: FrameHeader, out: *[9]u8) void {
        // Length: 3 bytes big-endian
        out[0] = @intCast((self.length >> 16) & 0xff);
        out[1] = @intCast((self.length >> 8) & 0xff);
        out[2] = @intCast(self.length & 0xff);
        out[3] = self.frame_type;
        out[4] = self.flags;
        // Stream ID: 4 bytes big-endian, top bit reserved = 0
        const sid: u32 = self.stream_id;
        out[5] = @intCast((sid >> 24) & 0x7f);
        out[6] = @intCast((sid >> 16) & 0xff);
        out[7] = @intCast((sid >> 8) & 0xff);
        out[8] = @intCast(sid & 0xff);
    }
};

// ── SETTINGS frame ─────────────────────────────────────────────────────────

pub const Setting = struct {
    id: u16,
    value: u32,
};

/// Encode a SETTINGS frame. Each setting is 6 bytes (2B id + 4B value).
/// `stream_id` must be 0 for connection-level SETTINGS.
pub fn encodeSettings(settings: []const Setting, writer: anytype) !void {
    const payload_len: u24 = @intCast(settings.len * 6);
    const header = FrameHeader{
        .length     = payload_len,
        .frame_type = FRAME_SETTINGS,
        .flags      = FLAG_NONE,
        .stream_id  = 0,
    };
    var hdr_buf: [9]u8 = undefined;
    header.encode(&hdr_buf);
    try writer.writeAll(&hdr_buf);

    for (settings) |s| {
        var pair: [6]u8 = undefined;
        pair[0] = @intCast((s.id >> 8) & 0xff);
        pair[1] = @intCast(s.id & 0xff);
        pair[2] = @intCast((s.value >> 24) & 0xff);
        pair[3] = @intCast((s.value >> 16) & 0xff);
        pair[4] = @intCast((s.value >> 8) & 0xff);
        pair[5] = @intCast(s.value & 0xff);
        try writer.writeAll(&pair);
    }
}

/// Chrome 132 SETTINGS: HEADER_TABLE_SIZE, MAX_CONCURRENT_STREAMS,
/// INITIAL_WINDOW_SIZE, MAX_HEADER_LIST_SIZE (exactly 4 settings, 24 bytes payload).
pub const chrome132_settings = [4]Setting{
    .{ .id = 0x0001, .value = fp.h2_header_table_size },      // 65536
    .{ .id = 0x0003, .value = fp.h2_max_concurrent_streams }, // 1000
    .{ .id = 0x0004, .value = fp.h2_initial_window_size },    // 6291456
    .{ .id = 0x0006, .value = fp.h2_max_header_list_size },   // 262144
};

// ── WINDOW_UPDATE frame ────────────────────────────────────────────────────

/// Encode a WINDOW_UPDATE frame.
/// For connection-level: stream_id = 0, increment = 15663105.
pub fn encodeWindowUpdate(stream_id: u31, increment: u31, writer: anytype) !void {
    const header = FrameHeader{
        .length     = 4,
        .frame_type = FRAME_WINDOW_UPDATE,
        .flags      = FLAG_NONE,
        .stream_id  = stream_id,
    };
    var hdr_buf: [9]u8 = undefined;
    header.encode(&hdr_buf);
    try writer.writeAll(&hdr_buf);

    // Window size increment: 4 bytes, top bit reserved = 0
    var payload: [4]u8 = undefined;
    const inc: u32 = increment;
    payload[0] = @intCast((inc >> 24) & 0x7f);
    payload[1] = @intCast((inc >> 16) & 0xff);
    payload[2] = @intCast((inc >> 8) & 0xff);
    payload[3] = @intCast(inc & 0xff);
    try writer.writeAll(&payload);
}

// ── Pseudo-header ordering ─────────────────────────────────────────────────

/// Verify that a slice of header names begins with Chrome 132 pseudo-header order.
/// Used for testing / assertion purposes.
pub fn hasChromeH2PseudoOrder(header_names: []const []const u8) bool {
    if (header_names.len < 4) return false;
    return std.mem.eql(u8, header_names[0], ":method") and
           std.mem.eql(u8, header_names[1], ":authority") and
           std.mem.eql(u8, header_names[2], ":scheme") and
           std.mem.eql(u8, header_names[3], ":path");
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "SETTINGS frame header has correct type byte" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeSettings(&chrome132_settings, &fbs);
    const written = fbs.buffered();
    // Byte 3 = frame type
    try std.testing.expectEqual(@as(u8, FRAME_SETTINGS), written[3]);
}

test "SETTINGS frame stream_id is 0" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeSettings(&chrome132_settings, &fbs);
    const written = fbs.buffered();
    // Bytes 5-8 = stream_id (must be 0)
    try std.testing.expectEqual(@as(u8, 0), written[5]);
    try std.testing.expectEqual(@as(u8, 0), written[6]);
    try std.testing.expectEqual(@as(u8, 0), written[7]);
    try std.testing.expectEqual(@as(u8, 0), written[8]);
}

test "SETTINGS frame payload length is 4 * 6 = 24 bytes" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeSettings(&chrome132_settings, &fbs);
    const written = fbs.buffered();
    // Bytes 0-2 = length (big-endian u24)
    const length: u32 = (@as(u32, written[0]) << 16) |
                        (@as(u32, written[1]) << 8) |
                        @as(u32, written[2]);
    try std.testing.expectEqual(@as(u32, 24), length);
    // Total frame = 9 header + 24 payload = 33
    try std.testing.expectEqual(@as(usize, 33), written.len);
}

test "SETTINGS frame encodes HEADER_TABLE_SIZE = 65536" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeSettings(&chrome132_settings, &fbs);
    const written = fbs.buffered();
    // First setting starts at byte 9: id=0x0001, value=65536 (0x00010000)
    const payload = written[9..];
    try std.testing.expectEqual(@as(u8, 0x00), payload[0]); // id high
    try std.testing.expectEqual(@as(u8, 0x01), payload[1]); // id low
    try std.testing.expectEqual(@as(u8, 0x00), payload[2]); // value byte 3
    try std.testing.expectEqual(@as(u8, 0x01), payload[3]); // value byte 2 (65536 = 0x00010000)
    try std.testing.expectEqual(@as(u8, 0x00), payload[4]); // value byte 1
    try std.testing.expectEqual(@as(u8, 0x00), payload[5]); // value byte 0
}

test "SETTINGS frame encodes MAX_CONCURRENT_STREAMS = 1000" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeSettings(&chrome132_settings, &fbs);
    const written = fbs.buffered();
    const payload = written[9..]; // skip 9-byte frame header
    // Second setting at offset 6: id=0x0003, value=1000 (0x000003E8)
    try std.testing.expectEqual(@as(u8, 0x00), payload[6]);
    try std.testing.expectEqual(@as(u8, 0x03), payload[7]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[8]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[9]);
    try std.testing.expectEqual(@as(u8, 0x03), payload[10]);
    try std.testing.expectEqual(@as(u8, 0xe8), payload[11]);
}

test "SETTINGS frame encodes INITIAL_WINDOW_SIZE = 6291456" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeSettings(&chrome132_settings, &fbs);
    const written = fbs.buffered();
    const payload = written[9..];
    // Third setting at offset 12: id=0x0004, value=6291456 (0x00600000)
    try std.testing.expectEqual(@as(u8, 0x00), payload[12]);
    try std.testing.expectEqual(@as(u8, 0x04), payload[13]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[14]);
    try std.testing.expectEqual(@as(u8, 0x60), payload[15]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[16]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[17]);
}

test "SETTINGS frame encodes MAX_HEADER_LIST_SIZE = 262144" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeSettings(&chrome132_settings, &fbs);
    const written = fbs.buffered();
    const payload = written[9..];
    // Fourth setting at offset 18: id=0x0006, value=262144 (0x00040000)
    try std.testing.expectEqual(@as(u8, 0x00), payload[18]);
    try std.testing.expectEqual(@as(u8, 0x06), payload[19]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[20]);
    try std.testing.expectEqual(@as(u8, 0x04), payload[21]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[22]);
    try std.testing.expectEqual(@as(u8, 0x00), payload[23]);
}

test "WINDOW_UPDATE frame has correct type byte" {
    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeWindowUpdate(0, fp.h2_connection_window_increment, &fbs);
    const written = fbs.buffered();
    try std.testing.expectEqual(@as(u8, FRAME_WINDOW_UPDATE), written[3]);
}

test "WINDOW_UPDATE frame length is 4" {
    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeWindowUpdate(0, fp.h2_connection_window_increment, &fbs);
    const written = fbs.buffered();
    const length: u32 = (@as(u32, written[0]) << 16) |
                        (@as(u32, written[1]) << 8) |
                        @as(u32, written[2]);
    try std.testing.expectEqual(@as(u32, 4), length);
    try std.testing.expectEqual(@as(usize, 13), written.len); // 9 + 4
}

test "WINDOW_UPDATE frame encodes increment 15663105" {
    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeWindowUpdate(0, @intCast(fp.h2_connection_window_increment), &fbs);
    const written = fbs.buffered();
    // Increment at bytes 9-12: 15663105 = 0x00EF0001
    try std.testing.expectEqual(@as(u8, 0x00), written[9]);
    try std.testing.expectEqual(@as(u8, 0xef), written[10]);
    try std.testing.expectEqual(@as(u8, 0x00), written[11]);
    try std.testing.expectEqual(@as(u8, 0x01), written[12]);
}

test "WINDOW_UPDATE stream_id is 0 for connection-level" {
    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try encodeWindowUpdate(0, 100, &fbs);
    const written = fbs.buffered();
    try std.testing.expectEqual(@as(u8, 0), written[5]);
    try std.testing.expectEqual(@as(u8, 0), written[6]);
    try std.testing.expectEqual(@as(u8, 0), written[7]);
    try std.testing.expectEqual(@as(u8, 0), written[8]);
}

test "hasChromeH2PseudoOrder returns true for correct order" {
    const names = [_][]const u8{ ":method", ":authority", ":scheme", ":path", "accept" };
    try std.testing.expect(hasChromeH2PseudoOrder(&names));
}

test "hasChromeH2PseudoOrder returns false for wrong order" {
    const names = [_][]const u8{ ":path", ":method", ":authority", ":scheme" };
    try std.testing.expect(!hasChromeH2PseudoOrder(&names));
}

test "hasChromeH2PseudoOrder returns false for too-short list" {
    const names = [_][]const u8{ ":method", ":authority" };
    try std.testing.expect(!hasChromeH2PseudoOrder(&names));
}

test "chrome132_settings has exactly 4 entries" {
    try std.testing.expectEqual(@as(usize, 4), chrome132_settings.len);
}
