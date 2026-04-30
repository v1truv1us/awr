/// Braille fallback downsampler — terminal image rendering of last resort.
///
/// Per `spec/subspecs/rendering.md §3.1`: when no graphics protocol is
/// available (Kitty / iTerm2 / Sixel all unavailable, or `--images=none`
/// degraded to braille on a basic terminal), images are downsampled into
/// a grid of Unicode braille glyphs (U+2800..U+28FF). Each glyph encodes
/// 8 dots arranged 2-wide × 4-tall, giving the highest spatial
/// resolution achievable in pure text — 8× more pixels per cell than
/// half-block ▀ would offer.
///
/// Pipeline (per output cell):
///
///   1. The source image is divided into `cols × rows` blocks, where
///      each block has size `⌊img.width / cols⌋ × ⌊img.height / rows⌋`.
///      Remaining pixels at the right/bottom edges are dropped — this is
///      consistent with Lanczos / nearest-neighbor reasonable defaults
///      for fallback rendering.
///
///   2. Each block is sub-divided into a 2×4 grid of sub-blocks, one
///      per braille dot. Each sub-block's mean luminance (BT.601:
///      0.299R + 0.587G + 0.114B, expressed as integer math
///      `(77R + 150G + 29B) >> 8`) is compared to `threshold`.
///
///   3. The 8 booleans pack into a u8 via the irregular Unicode braille
///      bit layout (see `dot_bit_at` below) and produce the codepoint
///      `U+2800 + bits`.
///
/// Color information is discarded — braille glyphs are monochrome by
/// construction. Callers may emit them with a foreground SGR if a
/// dominant color is desired, but that is out of scope here.
///
/// Bit ↔ dot layout (Unicode order, *not* row-major):
///
///       col0     col1
///       dot1=b0  dot4=b3   (sub-row 0)
///       dot2=b1  dot5=b4   (sub-row 1)
///       dot3=b2  dot6=b5   (sub-row 2)
///       dot7=b6  dot8=b7   (sub-row 3)
///
/// A naive `bit = sub_row*2 + sub_col` mapping is wrong — the bottom row
/// (dots 7,8) lives in bits 6,7 not bits 6,7 of the sub_row=3 quartet.
/// The lookup table `bit_for` enforces the correct mapping; tests cover
/// each of the 8 positions individually so a regression here is a
/// localized failure rather than "all images look rotated."
const std = @import("std");

const decode = @import("decode.zig");
const Image = decode.Image;

/// Default luminance threshold. Pixels with `Y >= threshold` light up
/// the corresponding braille dot. 128 is the midpoint of [0, 255] —
/// matches `chafa`'s default and works adequately for screenshots,
/// charts, and most photos. Override per-image when needed (dark-themed
/// content benefits from inverted thresholds via post-processing).
pub const default_threshold: u8 = 128;

pub const BrailleError = error{
    InvalidGridDimensions, // cols == 0 or rows == 0
    GridLargerThanImage, // cols > img.width or rows*4 > img.height
    OutOfMemory,
};

pub const Cell = struct {
    /// Codepoint in U+2800..U+28FF (256 patterns).
    codepoint: u21,
};

/// Bit position in a braille glyph for the dot at (sub_col, sub_row).
/// `sub_col` ∈ {0,1}, `sub_row` ∈ {0,1,2,3}. Returns the bit index
/// (0..7) inside the codepoint's low byte.
inline fn bit_for(sub_col: u8, sub_row: u8) u3 {
    // Hard-coded per Unicode braille spec. Comptime asserts on the
    // values would be redundant — calling code only feeds {0,1}×{0..3}.
    if (sub_col == 0) {
        return switch (sub_row) {
            0 => 0, // dot1
            1 => 1, // dot2
            2 => 2, // dot3
            3 => 6, // dot7
            else => unreachable,
        };
    } else {
        return switch (sub_row) {
            0 => 3, // dot4
            1 => 4, // dot5
            2 => 5, // dot6
            3 => 7, // dot8
            else => unreachable,
        };
    }
}

/// ITU-R BT.601 luminance, integer-only. Matches a more expensive
/// floating-point `0.299R + 0.587G + 0.114B` to ±1.
inline fn luma(r: u8, g: u8, b: u8) u8 {
    const sum: u32 = @as(u32, r) * 77 + @as(u32, g) * 150 + @as(u32, b) * 29;
    return @intCast(sum >> 8);
}

/// Mean luminance of a sub-block of `img.pixels` (RGBA8, row-stride =
/// 4*img.width). Empty rectangle (w==0 or h==0) returns 0 — these
/// happen at the edge when a block is too small to subdivide further.
fn meanLuma(img: *const Image, x0: u32, y0: u32, w: u32, h: u32) u8 {
    if (w == 0 or h == 0) return 0;
    var sum: u64 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = ((y0 + y) * img.width + (x0 + x)) * 4;
            const r = img.pixels[px];
            const g = img.pixels[px + 1];
            const b = img.pixels[px + 2];
            sum += luma(r, g, b);
        }
    }
    const count: u64 = @as(u64, w) * @as(u64, h);
    return @intCast(sum / count);
}

/// Downsample `img` into a `cols × rows` grid of braille glyphs.
/// Returns row-major `Cell` slice of length `rows * cols`.
///
/// Returns `GridLargerThanImage` if the requested grid exceeds the
/// image's spatial budget — each cell needs at least 2 source pixels
/// wide and 4 tall to populate one braille dot per sub-block.
pub fn downsample(
    allocator: std.mem.Allocator,
    img: *const Image,
    cols: usize,
    rows: usize,
    threshold: u8,
) BrailleError![]Cell {
    if (cols == 0 or rows == 0) return BrailleError.InvalidGridDimensions;

    // Each cell is a (block_w × block_h) source rectangle. We then
    // chop that into 2×4 sub-blocks of size (sub_w × sub_h). If
    // `block_w < 2` or `block_h < 4`, sub-blocks would be empty — the
    // contract requires at least one sub-block pixel for every dot to
    // mean anything. Surface that as an explicit error rather than
    // silently rendering all-blank glyphs.
    const block_w: u32 = @intCast(img.width / cols);
    const block_h: u32 = @intCast(img.height / rows);
    if (block_w < 2 or block_h < 4) return BrailleError.GridLargerThanImage;

    const sub_w: u32 = block_w / 2;
    const sub_h: u32 = block_h / 4;

    const out = try allocator.alloc(Cell, rows * cols);
    errdefer allocator.free(out);

    var cy: usize = 0;
    while (cy < rows) : (cy += 1) {
        var cx: usize = 0;
        while (cx < cols) : (cx += 1) {
            const block_x0: u32 = @as(u32, @intCast(cx)) * block_w;
            const block_y0: u32 = @as(u32, @intCast(cy)) * block_h;

            var bits: u8 = 0;
            var sr: u8 = 0;
            while (sr < 4) : (sr += 1) {
                var sc: u8 = 0;
                while (sc < 2) : (sc += 1) {
                    const sub_x0 = block_x0 + @as(u32, sc) * sub_w;
                    const sub_y0 = block_y0 + @as(u32, sr) * sub_h;
                    const y = meanLuma(img, sub_x0, sub_y0, sub_w, sub_h);
                    if (y >= threshold) {
                        bits |= @as(u8, 1) << bit_for(sc, sr);
                    }
                }
            }

            out[cy * cols + cx] = .{ .codepoint = 0x2800 + @as(u21, bits) };
        }
    }
    return out;
}

/// Encode `cell.codepoint` into 3 UTF-8 bytes at `buf[0..3]`. Returns 3
/// on success. Panics if `buf.len < 3`. Always writes 3 bytes — every
/// braille codepoint U+2800..U+28FF is in the 3-byte UTF-8 plane.
pub fn encodeUtf8(cell: Cell, buf: []u8) usize {
    std.debug.assert(buf.len >= 3);
    const cp = cell.codepoint;
    buf[0] = 0xE0 | @as(u8, @intCast((cp >> 12) & 0x0F));
    buf[1] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F));
    buf[2] = 0x80 | @as(u8, @intCast(cp & 0x3F));
    return 3;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a synthetic Image with all pixels set to `(r, g, b, 255)`.
/// Caller owns memory; image deinit() releases.
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

/// Build an Image where one specific pixel is white and the rest are
/// black. Used to verify that a single bright pixel at sub-block (sc, sr)
/// only sets bit `bit_for(sc, sr)`.
fn singlePixelImage(allocator: std.mem.Allocator, w: u32, h: u32, hot_x: u32, hot_y: u32) !Image {
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    @memset(pixels, 0);
    const px = (hot_y * w + hot_x) * 4;
    pixels[px] = 255;
    pixels[px + 1] = 255;
    pixels[px + 2] = 255;
    pixels[px + 3] = 255;
    return .{
        .width = w,
        .height = h,
        .pixels = pixels,
        .allocator = allocator,
    };
}

test "downsample: 0 cols or rows is rejected" {
    var img = try solidImage(testing.allocator, 2, 4, 255, 255, 255);
    defer img.deinit();
    try testing.expectError(
        BrailleError.InvalidGridDimensions,
        downsample(testing.allocator, &img, 0, 1, 128),
    );
    try testing.expectError(
        BrailleError.InvalidGridDimensions,
        downsample(testing.allocator, &img, 1, 0, 128),
    );
}

test "downsample: image too small for grid is rejected" {
    var img = try solidImage(testing.allocator, 2, 3, 255, 255, 255);
    defer img.deinit();
    // 2×3 → block_h = 3 < 4 (one row needs 4 sub-rows of pixels).
    try testing.expectError(
        BrailleError.GridLargerThanImage,
        downsample(testing.allocator, &img, 1, 1, 128),
    );
}

test "downsample: all-white 2×4 → fully populated U+28FF" {
    var img = try solidImage(testing.allocator, 2, 4, 255, 255, 255);
    defer img.deinit();
    const cells = try downsample(testing.allocator, &img, 1, 1, 128);
    defer testing.allocator.free(cells);
    try testing.expectEqual(@as(usize, 1), cells.len);
    try testing.expectEqual(@as(u21, 0x28FF), cells[0].codepoint);
}

test "downsample: all-black 2×4 → empty U+2800" {
    var img = try solidImage(testing.allocator, 2, 4, 0, 0, 0);
    defer img.deinit();
    const cells = try downsample(testing.allocator, &img, 1, 1, 128);
    defer testing.allocator.free(cells);
    try testing.expectEqual(@as(u21, 0x2800), cells[0].codepoint);
}

test "downsample: threshold=0 lights every dot regardless of pixel value" {
    var img = try solidImage(testing.allocator, 2, 4, 1, 1, 1); // luma ~1
    defer img.deinit();
    const cells = try downsample(testing.allocator, &img, 1, 1, 0);
    defer testing.allocator.free(cells);
    try testing.expectEqual(@as(u21, 0x28FF), cells[0].codepoint);
}

test "downsample: threshold=255 dark-only suppresses all dots" {
    var img = try solidImage(testing.allocator, 2, 4, 254, 254, 254); // luma ~254
    defer img.deinit();
    const cells = try downsample(testing.allocator, &img, 1, 1, 255);
    defer testing.allocator.free(cells);
    try testing.expectEqual(@as(u21, 0x2800), cells[0].codepoint);
}

test "downsample: each dot position maps to its expected bit (Unicode order)" {
    // For each sub-block position (sc, sr) ∈ {0,1} × {0..3}, place
    // exactly one bright pixel inside that sub-block of a 2×4 image
    // and verify only the matching bit is set.
    const cases = [_]struct {
        sc: u8,
        sr: u8,
        expected_bit: u3,
    }{
        .{ .sc = 0, .sr = 0, .expected_bit = 0 },
        .{ .sc = 0, .sr = 1, .expected_bit = 1 },
        .{ .sc = 0, .sr = 2, .expected_bit = 2 },
        .{ .sc = 0, .sr = 3, .expected_bit = 6 },
        .{ .sc = 1, .sr = 0, .expected_bit = 3 },
        .{ .sc = 1, .sr = 1, .expected_bit = 4 },
        .{ .sc = 1, .sr = 2, .expected_bit = 5 },
        .{ .sc = 1, .sr = 3, .expected_bit = 7 },
    };
    for (cases) |k| {
        var img = try singlePixelImage(testing.allocator, 2, 4, k.sc, k.sr);
        defer img.deinit();
        const cells = try downsample(testing.allocator, &img, 1, 1, 128);
        defer testing.allocator.free(cells);
        const expected: u21 = 0x2800 + (@as(u21, 1) << k.expected_bit);
        try testing.expectEqual(expected, cells[0].codepoint);
    }
}

test "downsample: 4×4 image into 2×1 grid produces 2 cells" {
    // Left half white, right half black → left cell U+28FF, right U+2800.
    var img = try solidImage(testing.allocator, 4, 4, 0, 0, 0);
    defer img.deinit();
    // Paint left half white.
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 2) : (x += 1) {
            const px = (y * 4 + x) * 4;
            img.pixels[px] = 255;
            img.pixels[px + 1] = 255;
            img.pixels[px + 2] = 255;
        }
    }
    const cells = try downsample(testing.allocator, &img, 2, 1, 128);
    defer testing.allocator.free(cells);
    try testing.expectEqual(@as(usize, 2), cells.len);
    try testing.expectEqual(@as(u21, 0x28FF), cells[0].codepoint);
    try testing.expectEqual(@as(u21, 0x2800), cells[1].codepoint);
}

test "downsample: odd source dimensions floor-divide cleanly" {
    // 5×9 → 1×1 grid: block_w=5, block_h=9, sub_w=2, sub_h=2.
    // Trailing pixels (col 4 of width 5; row 8 of height 9) are dropped.
    var img = try solidImage(testing.allocator, 5, 9, 255, 255, 255);
    defer img.deinit();
    const cells = try downsample(testing.allocator, &img, 1, 1, 128);
    defer testing.allocator.free(cells);
    try testing.expectEqual(@as(u21, 0x28FF), cells[0].codepoint);
}

test "luma: BT.601 weights match reference values within ±1" {
    // Reference: 0.299*255 + 0.587*0   + 0.114*0   ≈ 76 (red)
    //            0.299*0   + 0.587*255 + 0.114*0   ≈ 150 (green)
    //            0.299*0   + 0.587*0   + 0.114*255 ≈ 29 (blue)
    //            0.299*255 + 0.587*255 + 0.114*255 = 255 (white)
    try testing.expectApproxEqAbs(@as(f32, 76), @as(f32, @floatFromInt(luma(255, 0, 0))), 1.5);
    try testing.expectApproxEqAbs(@as(f32, 150), @as(f32, @floatFromInt(luma(0, 255, 0))), 1.5);
    try testing.expectApproxEqAbs(@as(f32, 29), @as(f32, @floatFromInt(luma(0, 0, 255))), 1.5);
    try testing.expectApproxEqAbs(@as(f32, 255), @as(f32, @floatFromInt(luma(255, 255, 255))), 1.5);
    try testing.expectEqual(@as(u8, 0), luma(0, 0, 0));
}

test "encodeUtf8: U+2800 → 0xE2 0xA0 0x80" {
    var buf: [3]u8 = undefined;
    const n = encodeUtf8(.{ .codepoint = 0x2800 }, &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &.{ 0xE2, 0xA0, 0x80 }, &buf);
}

test "encodeUtf8: U+28FF → 0xE2 0xA3 0xBF" {
    var buf: [3]u8 = undefined;
    _ = encodeUtf8(.{ .codepoint = 0x28FF }, &buf);
    try testing.expectEqualSlices(u8, &.{ 0xE2, 0xA3, 0xBF }, &buf);
}

test "encodeUtf8: round-trips through std.unicode for 16 sample codepoints" {
    var i: u21 = 0;
    while (i < 256) : (i += 17) {
        var buf: [3]u8 = undefined;
        _ = encodeUtf8(.{ .codepoint = 0x2800 + i }, &buf);
        const decoded = try std.unicode.utf8Decode(&buf);
        try testing.expectEqual(@as(u21, 0x2800 + i), decoded);
    }
}
