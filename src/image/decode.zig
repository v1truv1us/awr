/// Image decoder — thin Zig wrapper around vendored stb_image.
///
/// Mirrors `spec/subspecs/rendering.md §3.1`: decodes PNG / JPEG / GIF
/// (first frame) / WebP-still bytes into an RGBA8 buffer with width and
/// height. Enforces the per-image safety caps so that one hostile or
/// pathological image cannot OOM the cache:
///
///   max_encoded_bytes  = 4  MiB  — refuses encoded payloads larger than this
///                                  (the network layer should also cap, but we
///                                  defend in depth here).
///   max_decoded_pixels = 16 MP   — refuses images whose w*h would expand to
///                                  more than 16 megapixels of decoded RGBA
///                                  (≈ 64 MiB at 4 bytes/pixel).
///
/// Returned `Image` owns its `pixels` slice via the caller-supplied allocator.
/// Callers must `image.deinit()` to release. stb_image's own malloc'd buffer
/// is freed before this function returns; nothing C-allocated escapes the
/// boundary.
const std = @import("std");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const max_encoded_bytes: usize = 4 * 1024 * 1024;
pub const max_decoded_pixels: u64 = 16 * 1024 * 1024;

pub const ImageError = error{
    OversizeEncoded,
    OversizeDecoded,
    InvalidImage,
    UnsupportedFormat,
    OutOfMemory,
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA8, len = 4 * width * height
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Decode an encoded image (PNG / JPEG / GIF first-frame / WebP-still) from
/// a byte slice into an RGBA8 buffer. The returned `Image` owns memory
/// allocated through `allocator`; stb_image's internal allocations are
/// always released before this function returns.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ImageError!Image {
    if (bytes.len == 0) return ImageError.InvalidImage;
    if (bytes.len > max_encoded_bytes) return ImageError.OversizeEncoded;

    // Pre-flight: ask stb_image for the dimensions without decoding so we
    // can reject oversized images before allocating gigabytes of RGBA.
    var info_w: c_int = 0;
    var info_h: c_int = 0;
    var info_comp: c_int = 0;
    const info_ok = c.stbi_info_from_memory(
        bytes.ptr,
        @intCast(bytes.len),
        &info_w,
        &info_h,
        &info_comp,
    );
    if (info_ok == 0) return ImageError.UnsupportedFormat;
    if (info_w <= 0 or info_h <= 0) return ImageError.InvalidImage;

    const width: u64 = @intCast(info_w);
    const height: u64 = @intCast(info_h);
    if (width * height > max_decoded_pixels) return ImageError.OversizeDecoded;

    var x: c_int = 0;
    var y: c_int = 0;
    var channels: c_int = 0;
    const decoded_ptr = c.stbi_load_from_memory(
        bytes.ptr,
        @intCast(bytes.len),
        &x,
        &y,
        &channels,
        4, // force RGBA8 output
    );
    if (decoded_ptr == null) return ImageError.InvalidImage;
    defer c.stbi_image_free(decoded_ptr);

    if (x <= 0 or y <= 0) return ImageError.InvalidImage;
    const out_w: u32 = @intCast(x);
    const out_h: u32 = @intCast(y);
    const byte_count: usize = @as(usize, out_w) * @as(usize, out_h) * 4;

    const pixels = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(pixels);

    // Copy stb_image's output into our Zig-owned buffer so the caller never
    // sees C-allocated memory. Cheap; the alternative is overriding
    // STBI_MALLOC globally, which would touch every translation unit.
    @memcpy(pixels, decoded_ptr[0..byte_count]);

    return .{
        .width = out_w,
        .height = out_h,
        .pixels = pixels,
        .allocator = allocator,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────
// Decoder smoke fixtures live alongside this file because Zig restricts
// @embedFile to the module's package path. The encoder *integration*
// golden-byte fixtures (tests/image_fixtures/) referenced in
// `spec/subspecs/rendering.md §3.3` are a separate set used by per-protocol
// snapshot tests in `tests/image_*.zig` — those land with each encoder.
// Fixtures here are generated reproducibly via `python3` PNG-chunk
// synthesis (see commit message for the script) and checked into git so
// tests are deterministic and offline.

const red_1x1_png = @embedFile("test_fixtures/red_1x1.png");
const pattern_4x4_png = @embedFile("test_fixtures/pattern_4x4.png");

test "decode 1x1 red PNG → RGBA8" {
    var img = try decode(std.testing.allocator, red_1x1_png);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    try std.testing.expectEqual(@as(usize, 4), img.pixels.len);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[0]); // R
    try std.testing.expectEqual(@as(u8, 0), img.pixels[1]); // G
    try std.testing.expectEqual(@as(u8, 0), img.pixels[2]); // B
    try std.testing.expectEqual(@as(u8, 255), img.pixels[3]); // A (forced)
}

test "decode 4x4 pattern PNG preserves per-row colors" {
    var img = try decode(std.testing.allocator, pattern_4x4_png);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
    try std.testing.expectEqual(@as(usize, 64), img.pixels.len);

    // Row 0 = red
    try std.testing.expectEqual(@as(u8, 255), img.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[2]);
    // Row 1 = green (offset = 1 * 4 * 4 = 16)
    try std.testing.expectEqual(@as(u8, 0), img.pixels[16]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[17]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[18]);
    // Row 2 = blue (offset = 32)
    try std.testing.expectEqual(@as(u8, 0), img.pixels[32]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[33]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[34]);
    // Row 3 = white (offset = 48)
    try std.testing.expectEqual(@as(u8, 255), img.pixels[48]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[49]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[50]);
}

test "decode rejects empty input" {
    try std.testing.expectError(ImageError.InvalidImage, decode(std.testing.allocator, ""));
}

test "decode rejects garbage bytes" {
    const garbage = "this is not an image file";
    try std.testing.expectError(ImageError.UnsupportedFormat, decode(std.testing.allocator, garbage));
}

test "decode rejects encoded payload over max_encoded_bytes" {
    const oversized = try std.testing.allocator.alloc(u8, max_encoded_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(ImageError.OversizeEncoded, decode(std.testing.allocator, oversized));
}
