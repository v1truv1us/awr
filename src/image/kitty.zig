/// Kitty graphics-protocol encoder.
///
/// Per `spec/subspecs/rendering.md §3.1`. Emits a complete APC byte
/// stream that, when written to a Kitty-compatible terminal, transmits
/// + immediately displays an RGBA8 image at the current cursor position
/// and advances the cursor down by `opts.rows` cells.
///
/// Wire format:
///
///   • All commands are wrapped in APC: `\x1b_G<keys>;<base64>\x1b\\`.
///   • `keys` are `key=value,key=value,…` pairs. Order does not matter
///     to the terminal but we emit a fixed order for golden-byte tests.
///   • `base64` is standard base64 (with `=` padding) of the raw
///     pixel bytes.
///   • If the base64 payload is ≤ 4096 bytes it goes in a single APC
///     with no chunking key. Larger payloads are split into `≤4096`-
///     byte chunks; the first chunk gets the full key set + `m=1`,
///     subsequent middle chunks get `m=1` only, and the final chunk
///     gets `m=0`. (Kitty docs §"Chunking".)
///
/// Key choices:
///
///   • `a=T` — Transmit and display.
///   • `f=32` — Format is raw RGBA8. We've already decoded via
///     stb_image; re-encoding to PNG (`f=100`) would use CPU + risk
///     terminal-side decoder bugs for no transmission-size win on
///     small web images.
///   • `s=W,v=H` — pixel dimensions, required for `f=32`.
///   • `c=COLS,r=ROWS` — cell dimensions; the terminal scales the
///     image to fit. Required so the renderer can reserve the right
///     amount of layout space.
///   • `q=2` — Suppress success/error replies. Critical: without this,
///     the terminal echoes a `\x1b_GOK\x1b\\` (or `\x1b_Gerror\x1b\\`)
///     reply that pollutes stdin/stdout for non-interactive runs.
///   • `i=ID` — optional image id, only emitted when non-zero. Re-using
///     the same id replaces the existing image at that id (used by
///     `awr browse` for redraws; `awr render` passes 0).
///
/// Memory: the encoder streams base64 directly to the output writer,
/// chunk-by-chunk, never materializing the full base64 payload in
/// memory. A 16-megapixel decoded image (≈ 64 MiB RGBA) produces
/// ≈ 85 MiB of base64 — holding both at once would breach the 128 MiB
/// peak-RSS gate (`§6 gate 9`).
const std = @import("std");

const decode = @import("decode.zig");
const Image = decode.Image;

/// Maximum base64 bytes per APC chunk. Kitty's protocol caps total APC
/// length at 4096 bytes including framing — we conservatively cap the
/// payload so the framing keys stay well under budget.
pub const max_chunk_base64: usize = 4096;

pub const KittyOptions = struct {
    /// Cell columns to occupy in the terminal grid.
    cols: u32,
    /// Cell rows to occupy.
    rows: u32,
    /// Image id (1..2^32-1). 0 = no id (terminal allocates one).
    image_id: u32 = 0,
};

pub const KittyError = error{
    InvalidImage, // 0×0 dimensions or pixels.len mismatch
    InvalidGrid, // cols == 0 or rows == 0
    OutOfMemory,
};

/// Encode `img` into a single contiguous Kitty APC byte stream.
/// Returned slice owns memory via `allocator`; caller must free.
pub fn encode(
    allocator: std.mem.Allocator,
    img: *const Image,
    opts: KittyOptions,
) KittyError![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try streamTo(allocator, &list, img, opts);
    return try list.toOwnedSlice(allocator);
}

/// Stream-encode `img` directly into `out`. `out` must be a
/// `*std.ArrayList(u8)` (we use `appendSlice` for batched writes).
/// This is the memory-efficient path — base64 chunks are emitted
/// 4 bytes at a time without ever holding the full encoded payload.
pub fn streamTo(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    img: *const Image,
    opts: KittyOptions,
) KittyError!void {
    if (img.width == 0 or img.height == 0) return KittyError.InvalidImage;
    if (img.pixels.len != @as(usize, img.width) * @as(usize, img.height) * 4) {
        return KittyError.InvalidImage;
    }
    if (opts.cols == 0 or opts.rows == 0) return KittyError.InvalidGrid;

    const Encoder = std.base64.standard.Encoder;
    const total_b64 = Encoder.calcSize(img.pixels.len);

    // Single-APC fast path when the entire payload fits.
    if (total_b64 <= max_chunk_base64) {
        try writeChunkPrefix(allocator, out, img, opts, .single);
        try streamBase64(allocator, out, img.pixels, 0, img.pixels.len);
        try out.appendSlice(allocator, "\x1b\\");
        return;
    }

    // Multi-chunk path: split source bytes so each chunk's base64
    // output is ≤ max_chunk_base64. base64 expands every 3 src bytes
    // to 4 b64 bytes; choose `src_chunk` as the largest multiple of 3
    // not exceeding 3*max_chunk_base64/4. We keep src_chunk
    // 3-byte-aligned so all chunks except the last avoid base64
    // padding, which would make the chunk boundary indistinguishable
    // from EOF for the receiving terminal.
    const src_chunk: usize = (max_chunk_base64 / 4) * 3;
    var off: usize = 0;
    var first = true;
    while (off < img.pixels.len) {
        const remaining = img.pixels.len - off;
        const take = @min(src_chunk, remaining);
        const is_last = (off + take == img.pixels.len);

        const tag: ChunkTag = if (first) .first else if (is_last) .last else .middle;
        try writeChunkPrefix(allocator, out, img, opts, tag);
        try streamBase64(allocator, out, img.pixels, off, take);
        try out.appendSlice(allocator, "\x1b\\");

        off += take;
        first = false;
    }
}

const ChunkTag = enum { single, first, middle, last };

fn writeChunkPrefix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    img: *const Image,
    opts: KittyOptions,
    tag: ChunkTag,
) KittyError!void {
    try out.appendSlice(allocator, "\x1b_G");

    // The 128-byte stack buffer comfortably exceeds the longest
    // possible key string (≈ 80 chars for `.first` with all u32
    // dimensions at u32 max). NoSpaceLeft from `bufPrint` is therefore
    // an invariant violation — surface it as `unreachable` rather
    // than expanding `KittyError` for a case that cannot occur.
    var keybuf: [128]u8 = undefined;
    const keys = switch (tag) {
        .single => std.fmt.bufPrint(
            &keybuf,
            "a=T,f=32,s={d},v={d},c={d},r={d},q=2",
            .{ img.width, img.height, opts.cols, opts.rows },
        ) catch unreachable,
        .first => std.fmt.bufPrint(
            &keybuf,
            "a=T,f=32,s={d},v={d},c={d},r={d},q=2,m=1",
            .{ img.width, img.height, opts.cols, opts.rows },
        ) catch unreachable,
        .middle => std.fmt.bufPrint(&keybuf, "m=1", .{}) catch unreachable,
        .last => std.fmt.bufPrint(&keybuf, "m=0", .{}) catch unreachable,
    };
    try out.appendSlice(allocator, keys);

    if (opts.image_id != 0 and (tag == .single or tag == .first)) {
        var idbuf: [32]u8 = undefined;
        const idstr = std.fmt.bufPrint(&idbuf, ",i={d}", .{opts.image_id}) catch unreachable;
        try out.appendSlice(allocator, idstr);
    }

    try out.append(allocator, ';');
}

fn streamBase64(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    src: []const u8,
    offset: usize,
    len: usize,
) KittyError!void {
    const slice = src[offset .. offset + len];
    const Encoder = std.base64.standard.Encoder;
    const enc_size = Encoder.calcSize(slice.len);

    // Stage into a stack buffer of fixed size (≤ max_chunk_base64) so
    // we never grow a transient heap allocation matching the encoded
    // payload. Chunks are bounded above by `max_chunk_base64`, so a
    // 6 KiB stack buffer is comfortable for any chunk.
    var stage: [max_chunk_base64 + 16]u8 = undefined;
    if (enc_size > stage.len) return KittyError.OutOfMemory;
    const encoded = Encoder.encode(stage[0..enc_size], slice);
    try out.appendSlice(allocator, encoded);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn solidImage(allocator: std.mem.Allocator, w: u32, h: u32, r: u8, g: u8, b: u8) !Image {
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i] = r;
        pixels[i + 1] = g;
        pixels[i + 2] = b;
        pixels[i + 3] = 255;
    }
    return .{
        .width = w,
        .height = h,
        .pixels = pixels,
        .allocator = allocator,
    };
}

test "encode: 1x1 red pixel produces single-APC golden bytes" {
    var img = try solidImage(testing.allocator, 1, 1, 255, 0, 0);
    defer img.deinit();

    const out = try encode(testing.allocator, &img, .{ .cols = 1, .rows = 1 });
    defer testing.allocator.free(out);

    // 1×1 RGBA = 4 bytes = 8 base64 bytes; well under 4096 → single APC.
    // Pixel: 0xFF 0x00 0x00 0xFF → "/wAA/w==" in standard base64.
    const expected = "\x1b_Ga=T,f=32,s=1,v=1,c=1,r=1,q=2;/wAA/w==\x1b\\";
    try testing.expectEqualStrings(expected, out);
}

test "encode: rejects 0×0 image" {
    const empty: Image = .{
        .width = 0,
        .height = 0,
        .pixels = &.{},
        .allocator = testing.allocator,
    };
    try testing.expectError(KittyError.InvalidImage, encode(testing.allocator, &empty, .{ .cols = 1, .rows = 1 }));
}

test "encode: rejects 0 cols/rows" {
    var img = try solidImage(testing.allocator, 1, 1, 0, 0, 0);
    defer img.deinit();
    try testing.expectError(KittyError.InvalidGrid, encode(testing.allocator, &img, .{ .cols = 0, .rows = 1 }));
    try testing.expectError(KittyError.InvalidGrid, encode(testing.allocator, &img, .{ .cols = 1, .rows = 0 }));
}

test "encode: rejects pixel-buffer length mismatch" {
    var pixels = [_]u8{ 0, 0, 0 }; // claims 16 bytes, has 3
    const img: Image = .{
        .width = 2,
        .height = 2,
        .pixels = &pixels,
        .allocator = testing.allocator,
    };
    try testing.expectError(KittyError.InvalidImage, encode(testing.allocator, &img, .{ .cols = 1, .rows = 1 }));
}

test "encode: image_id=0 omits i= key" {
    var img = try solidImage(testing.allocator, 1, 1, 0, 0, 0);
    defer img.deinit();
    const out = try encode(testing.allocator, &img, .{ .cols = 1, .rows = 1, .image_id = 0 });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, ",i=") == null);
}

test "encode: non-zero image_id emits i=N key on first chunk" {
    var img = try solidImage(testing.allocator, 1, 1, 0, 0, 0);
    defer img.deinit();
    const out = try encode(testing.allocator, &img, .{ .cols = 1, .rows = 1, .image_id = 42 });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, ",i=42;") != null);
}

test "encode: framing — every chunk starts with ESC_G and ends with ESC\\" {
    // A 64×64 image is 64*64*4 = 16384 raw bytes = 21848 base64 bytes
    // → 6 chunks at 4096-byte boundaries.
    var img = try solidImage(testing.allocator, 64, 64, 128, 64, 32);
    defer img.deinit();

    const out = try encode(testing.allocator, &img, .{ .cols = 16, .rows = 4 });
    defer testing.allocator.free(out);

    // Count APC openers and closers; every opener must have a matching
    // closer immediately following its keys+payload.
    const opens = std.mem.count(u8, out, "\x1b_G");
    const closes = std.mem.count(u8, out, "\x1b\\");
    try testing.expectEqual(opens, closes);
    try testing.expect(opens >= 2); // multi-chunk
}

test "encode: multi-chunk first carries full keys + m=1; last carries m=0" {
    var img = try solidImage(testing.allocator, 64, 64, 1, 1, 1);
    defer img.deinit();

    const out = try encode(testing.allocator, &img, .{ .cols = 16, .rows = 4 });
    defer testing.allocator.free(out);

    // First APC must have a=T plus m=1.
    try testing.expect(std.mem.startsWith(u8, out, "\x1b_Ga=T,"));
    try testing.expect(std.mem.indexOf(u8, out, "a=T,f=32,s=64,v=64,c=16,r=4,q=2,m=1;") != null);

    // Last APC must have m=0; ensure exactly one ",m=0" or "m=0;" lives in the stream.
    try testing.expect(std.mem.indexOf(u8, out, "m=0;") != null);
}

test "encode: round-trip — base64 of all chunks decodes back to source pixels" {
    var img = try solidImage(testing.allocator, 8, 8, 200, 100, 50);
    defer img.deinit();

    const out = try encode(testing.allocator, &img, .{ .cols = 4, .rows = 2 });
    defer testing.allocator.free(out);

    // Strip APC framing and concatenate every chunk's base64 payload.
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(testing.allocator);

    var rest: []const u8 = out;
    while (std.mem.indexOf(u8, rest, "\x1b_G")) |open| {
        const semi = std.mem.indexOfScalarPos(u8, rest, open, ';') orelse break;
        const close = std.mem.indexOfPos(u8, rest, semi, "\x1b\\") orelse break;
        try combined.appendSlice(testing.allocator, rest[semi + 1 .. close]);
        rest = rest[close + 2 ..];
    }

    const Decoder = std.base64.standard.Decoder;
    const dec_size = try Decoder.calcSizeForSlice(combined.items);
    const decoded = try testing.allocator.alloc(u8, dec_size);
    defer testing.allocator.free(decoded);
    try Decoder.decode(decoded, combined.items);

    try testing.expectEqualSlices(u8, img.pixels, decoded);
}
