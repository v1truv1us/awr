/// iTerm2 inline-image encoder.
///
/// Per `spec/subspecs/rendering.md §3.1`. Wraps the original image
/// file bytes (PNG / JPEG / GIF / WebP) in an OSC-1337 sequence that
/// iTerm2 (and compatible terminals: WezTerm with `image_protocol =
/// "iTerm"`, mintty `--enable=imgs`) renders inline at the cursor.
///
/// Wire format:
///
///     ESC ] 1337 ; File = inline=1 ; width=COLS ; height=ROWS ;
///                          preserveAspectRatio=1 : <base64-data> BEL
///
/// Where `<base64-data>` is the **original encoded image bytes**
/// (PNG/JPEG/etc.), not raw RGBA. Unlike Kitty's protocol, iTerm
/// decodes inside the terminal — passing decoded RGBA back through a
/// re-encode step would burn CPU and risk lossy round-trips. The
/// pipeline therefore keeps both the network-fetched bytes (consumed
/// here) and the stb_image-decoded `Image` (consumed by Kitty / Sixel
/// / braille) alongside each other.
///
/// Width/height units: bare integers mean **terminal cells** (cells
/// columns / cells rows). Adding a `px` suffix would mean pixels; we
/// never want pixels because the layout reservation in `render.zig`
/// works in cells. Adding `preserveAspectRatio=1` is iTerm's default
/// but emitting it makes the wire format self-documenting.
///
/// Terminator: BEL (`\x07`) over ST (`\x1b\\`) — both are valid OSC
/// terminators per ANSI spec, but BEL is what iTerm's docs and every
/// example in the wild use. Older tmux versions can mangle ST.
const std = @import("std");

pub const ItermOptions = struct {
    /// Cell columns to occupy.
    cols: u32,
    /// Cell rows to occupy.
    rows: u32,
};

pub const ItermError = error{
    EmptyInput,
    InvalidGrid,
    OutOfMemory,
};

/// Encode `file_bytes` (the original PNG/JPEG/GIF/WebP wire bytes) into
/// an OSC-1337 inline-image sequence. Returns owned memory; caller frees.
pub fn encode(
    allocator: std.mem.Allocator,
    file_bytes: []const u8,
    opts: ItermOptions,
) ItermError![]u8 {
    if (file_bytes.len == 0) return ItermError.EmptyInput;
    if (opts.cols == 0 or opts.rows == 0) return ItermError.InvalidGrid;

    const Encoder = std.base64.standard.Encoder;
    const b64_size = Encoder.calcSize(file_bytes.len);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // Reserve up-front: prefix + headers + base64 + terminator.
    // Header is ~80 chars worst-case; terminator is 1.
    try list.ensureTotalCapacity(allocator, b64_size + 96);

    try list.appendSlice(allocator, "\x1b]1337;File=inline=1");
    var buf: [64]u8 = undefined;
    const dim_str = std.fmt.bufPrint(&buf, ";width={d};height={d};preserveAspectRatio=1:", .{ opts.cols, opts.rows }) catch unreachable;
    try list.appendSlice(allocator, dim_str);

    // Base64 directly into a stack buffer when small; allocate when
    // large. iTerm has no chunking limit so we always emit a single
    // OSC, but the staging buffer can't be 4 MiB on the stack — use
    // the allocator for any payload bigger than 8 KiB.
    if (b64_size <= 8 * 1024) {
        var stage: [8 * 1024 + 4]u8 = undefined;
        const enc = Encoder.encode(stage[0..b64_size], file_bytes);
        try list.appendSlice(allocator, enc);
    } else {
        const stage = try allocator.alloc(u8, b64_size);
        defer allocator.free(stage);
        const enc = Encoder.encode(stage, file_bytes);
        try list.appendSlice(allocator, enc);
    }

    try list.append(allocator, '\x07');
    return try list.toOwnedSlice(allocator);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "encode: rejects empty input" {
    try testing.expectError(ItermError.EmptyInput, encode(testing.allocator, "", .{ .cols = 1, .rows = 1 }));
}

test "encode: rejects 0 cols/rows" {
    try testing.expectError(ItermError.InvalidGrid, encode(testing.allocator, "abc", .{ .cols = 0, .rows = 1 }));
    try testing.expectError(ItermError.InvalidGrid, encode(testing.allocator, "abc", .{ .cols = 1, .rows = 0 }));
}

test "encode: golden bytes for 'PNG' magic + dims" {
    // Use four bytes ("PNG\x00") as a stand-in for image data — the
    // encoder treats the input opaquely; the terminal decodes.
    const out = try encode(testing.allocator, "PNG\x00", .{ .cols = 2, .rows = 1 });
    defer testing.allocator.free(out);

    // base64("PNG\x00") = "UE5HAA=="
    const expected = "\x1b]1337;File=inline=1;width=2;height=1;preserveAspectRatio=1:UE5HAA==\x07";
    try testing.expectEqualStrings(expected, out);
}

test "encode: cell dimensions stamp into the OSC verbatim (no px suffix)" {
    const out = try encode(testing.allocator, "x", .{ .cols = 80, .rows = 24 });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, ";width=80;") != null);
    try testing.expect(std.mem.indexOf(u8, out, ";height=24;") != null);
    // No "px" anywhere — bare integers are cell-units in iTerm's grammar.
    try testing.expect(std.mem.indexOf(u8, out, "px") == null);
}

test "encode: framing — starts with OSC opener, ends with BEL terminator" {
    const out = try encode(testing.allocator, "abc", .{ .cols = 1, .rows = 1 });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]1337;"));
    try testing.expectEqual(@as(u8, 0x07), out[out.len - 1]);
}

test "encode: round-trip — base64 between ':' and BEL decodes back to source" {
    const source = "the quick brown fox jumps over the lazy dog 0123456789";
    const out = try encode(testing.allocator, source, .{ .cols = 4, .rows = 2 });
    defer testing.allocator.free(out);

    const colon = std.mem.indexOfScalar(u8, out, ':') orelse return error.NoColon;
    const bel = out.len - 1; // BEL is always the final byte
    const b64 = out[colon + 1 .. bel];

    const Decoder = std.base64.standard.Decoder;
    const dec_size = try Decoder.calcSizeForSlice(b64);
    const decoded = try testing.allocator.alloc(u8, dec_size);
    defer testing.allocator.free(decoded);
    try Decoder.decode(decoded, b64);

    try testing.expectEqualStrings(source, decoded);
}

test "encode: large payload (>8 KiB) takes the heap-staging path" {
    const big = try testing.allocator.alloc(u8, 16 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 0xAB);

    const out = try encode(testing.allocator, big, .{ .cols = 10, .rows = 10 });
    defer testing.allocator.free(out);

    // Sanity: the payload should be base64-encoded (4/3 expansion).
    // Output = ~80 (framing) + ~21856 (b64 of 16384) ≈ 22 KiB.
    try testing.expect(out.len > 16 * 1024);
}
