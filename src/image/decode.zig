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

    // T4: reject SVG / XML markup up front. stb_image is raster-only and its
    // TGA sniffer has no magic number, so we don't want to depend on the
    // accident that markup happens to fail TGA header validation — detect it
    // explicitly so an `<img src="...svg">` reliably degrades to the alt-text
    // fallback (a clean UnsupportedFormat → pipeline miss) instead of risking a
    // degenerate 1×1 emit. Sniffing the precise `<svg` / `<?xml` signatures
    // (not any leading `<`) avoids false-rejecting a valid TGA whose first byte
    // is an ID-field length of 0x3c.
    if (looksLikeSvg(bytes)) return ImageError.UnsupportedFormat;

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

/// True when `bytes` is SVG / XML markup rather than a raster image. Skips an
/// optional UTF-8 BOM and leading ASCII whitespace, then matches the `<svg`
/// or `<?xml` signature case-insensitively. Deliberately narrow: a bare
/// leading `<` is not enough (a valid TGA may start with id-length 0x3c), but
/// `<svg` / `<?xml` cannot be a raster header.
fn looksLikeSvg(bytes: []const u8) bool {
    var b = bytes;
    if (b.len >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF) b = b[3..]; // UTF-8 BOM
    var i: usize = 0;
    while (i < b.len and (b[i] == ' ' or b[i] == '\t' or b[i] == '\n' or b[i] == '\r')) : (i += 1) {}
    const rest = b[i..];
    return std.ascii.startsWithIgnoreCase(rest, "<svg") or
        std.ascii.startsWithIgnoreCase(rest, "<?xml");
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

test "decode rejects SVG → UnsupportedFormat (no degenerate 1x1 emit)" {
    // T4: stb_image is raster-only and its TGA sniffer has no magic number,
    // so XML/SVG text can false-positive into a degenerate tiny image. Sniff
    // SVG explicitly so the pipeline gets a clean miss and falls back to
    // alt-text instead of emitting a 1×1 blob. Covers both the bare `<svg>`
    // root and the `<?xml …?>`-prefixed form (HN's y18.svg uses the latter).
    const svg_bare =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\">" ++
        "<path d=\"M0 0h18v18H0z\" fill=\"#ff6600\"/></svg>";
    try std.testing.expectError(ImageError.UnsupportedFormat, decode(std.testing.allocator, svg_bare));

    const svg_xml_prefixed =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!-- HN logo -->\n" ++
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\">" ++
        "<circle cx=\"12\" cy=\"12\" r=\"10\"/></svg>";
    try std.testing.expectError(ImageError.UnsupportedFormat, decode(std.testing.allocator, svg_xml_prefixed));

    // Leading whitespace before the root (common in served SVGs) must still
    // be recognized.
    const svg_leading_ws = "  \n\t<svg viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>";
    try std.testing.expectError(ImageError.UnsupportedFormat, decode(std.testing.allocator, svg_leading_ws));

    // UTF-8 BOM before the root must still be recognized.
    const svg_bom = "\xEF\xBB\xBF<svg></svg>";
    try std.testing.expectError(ImageError.UnsupportedFormat, decode(std.testing.allocator, svg_bom));
}

test "looksLikeSvg: precise — does not false-match a TGA-style 0x3c header" {
    // A valid uncompressed TGA may begin with id-length 0x3c ('<') followed by
    // colormap-type 0x00; the sniff must not treat that as SVG. (We assert on
    // looksLikeSvg directly because such bytes are not a *decodable* image, so
    // decode() would still error later via stb_image — this isolates the sniff.)
    const tga_like = [_]u8{ 0x3c, 0x00, 0x02, 0x00 } ++ [_]u8{0} ** 14;
    try std.testing.expect(!looksLikeSvg(&tga_like));
    // Sanity: real SVG/XML signatures match (case-insensitively).
    try std.testing.expect(looksLikeSvg("<svg/>"));
    try std.testing.expect(looksLikeSvg("<?XML version=\"1.0\"?>"));
    // Non-SVG markup is not SVG-sniffed (stb_image's own validation rejects it
    // separately — the sniff only claims the SVG/XML signatures).
    try std.testing.expect(!looksLikeSvg("<html><body></body></html>"));
}
