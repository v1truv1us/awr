/// Sixel graphics encoder.
///
/// Per `spec/subspecs/rendering.md §3.1`. Produces a complete DCS
/// sequence that, when written to a Sixel-capable terminal (foot,
/// mintty, contour, mlterm, recent xterm with `--enable-sixel-graphics`,
/// WezTerm with `enable_csi_u_key_encoding = true`), renders an
/// indexed-color version of an RGBA8 image at the cursor position.
///
/// Wire format:
///
///     ESC P q [color-defs] [bands] ESC \
///
/// Where:
///
///   • `[color-defs]` is a sequence of `#N;2;R;G;B` records — one per
///     palette entry, RGB each in 0–100 (Sixel's percentage scale).
///
///   • `[bands]` is one entry per group of 6 image rows. Each band is
///     a series of `#N <run>` substrings — color N selected, then
///     one sixel character (in 0x3F..0x7E, where bit-N indicates row-N
///     pixel-on for that color) per output column. `$` returns to the
///     start of the band so multiple colors can overlay; `-` advances
///     to the next 6-row band.
///
/// The implementation:
///
///   1. **Palette**: subsamples up to ~16 K pixels and median-cuts to
///      ≤ 256 colors. Subsampling keeps quantization tractable on 16 MP
///      images (the §3.1 decoded cap) while still giving a representative
///      palette; quality is indistinguishable from full-image median cut
///      for typical web content.
///
///   2. **Mapping**: every source pixel is matched to its nearest
///      palette entry via a linear scan in RGB Euclidean distance.
///      No LUT — simpler code; the linear scan is ≈ 256 ops per pixel,
///      well within budget for `awr render`'s one-shot usage.
///
///   3. **Emission**: one band at a time, six rows of indices in
///      parallel. For each color used in the band, the encoder emits a
///      run of sixel characters where each character's six bits mark
///      whether that pixel-row matches the active color. `$` between
///      colors lets a single band carry all the colors it uses without
///      buffering.
///
/// Memory: streaming output. The largest transient is the index buffer
/// (one u8 per source pixel = up to 16 MiB for a 16 MP image) plus the
/// output ArrayList. Palette + workspace are bounded at ≤ 64 KiB.
const std = @import("std");

const decode = @import("decode.zig");
const Image = decode.Image;

pub const max_palette_size: u32 = 256;
pub const palette_subsample_target: u32 = 16 * 1024;

pub const SixelOptions = struct {
    /// Maximum colors in the output palette. Capped at 256 by the
    /// protocol; smaller values trade quality for output size.
    palette_size: u32 = 256,
};

pub const SixelError = error{
    InvalidImage,
    InvalidPaletteSize,
    OutOfMemory,
};

/// Encode `img` into a complete Sixel byte stream. Owned memory;
/// caller frees.
pub fn encode(
    allocator: std.mem.Allocator,
    img: *const Image,
    opts: SixelOptions,
) SixelError![]u8 {
    if (img.width == 0 or img.height == 0) return SixelError.InvalidImage;
    if (img.pixels.len != @as(usize, img.width) * @as(usize, img.height) * 4) {
        return SixelError.InvalidImage;
    }
    if (opts.palette_size == 0 or opts.palette_size > max_palette_size) {
        return SixelError.InvalidPaletteSize;
    }

    // 1. Palette via subsampled median cut. The palette length may be
    // < palette_size when the image has fewer distinct colors than the
    // requested target (degenerate case: solid-color images).
    const palette = try buildPalette(allocator, img, opts.palette_size);
    defer allocator.free(palette);

    // 2. Map every pixel to its palette index.
    const indices = try mapToIndices(allocator, img, palette);
    defer allocator.free(indices);

    // 3. Emit DCS-framed Sixel bytes.
    return emitSixel(allocator, img.width, img.height, palette, indices);
}

const RGB = [3]u8;

// ── Palette construction (median cut) ─────────────────────────────────

fn buildPalette(allocator: std.mem.Allocator, img: *const Image, target: u32) SixelError![]RGB {
    const total: usize = @as(usize, img.width) * @as(usize, img.height);
    // Subsample stride: aim for ≤ palette_subsample_target samples.
    const stride: usize = @max(@as(usize, 1), total / palette_subsample_target);

    const sample_count = (total + stride - 1) / stride;
    const samples = try allocator.alloc(RGB, sample_count);
    defer allocator.free(samples);

    var i: usize = 0;
    var s: usize = 0;
    while (i < total and s < sample_count) : (i += stride) {
        const px = i * 4;
        samples[s] = .{ img.pixels[px], img.pixels[px + 1], img.pixels[px + 2] };
        s += 1;
    }
    const used_samples = samples[0..s];

    return medianCut(allocator, used_samples, target);
}

const Bucket = struct {
    /// Slice into the workspace array; mutable subslice for in-place sort.
    pixels: []RGB,
};

fn medianCut(allocator: std.mem.Allocator, samples: []RGB, target: u32) SixelError![]RGB {
    var buckets: std.ArrayList(Bucket) = .empty;
    defer buckets.deinit(allocator);
    try buckets.append(allocator, .{ .pixels = samples });

    while (buckets.items.len < target) {
        // Pick the bucket with the widest single-channel range.
        var best: usize = 0;
        var best_range: u32 = 0;
        for (buckets.items, 0..) |b, idx| {
            if (b.pixels.len < 2) continue;
            const r = channelRange(b.pixels).range;
            if (r > best_range) {
                best_range = r;
                best = idx;
            }
        }
        if (best_range == 0) break;

        // Sort that bucket's pixels by its widest channel.
        const ch = channelRange(buckets.items[best].pixels).channel;
        std.sort.pdq(RGB, buckets.items[best].pixels, ch, sortByChannelLessThan);

        const mid = buckets.items[best].pixels.len / 2;
        const left = buckets.items[best].pixels[0..mid];
        const right = buckets.items[best].pixels[mid..];

        buckets.items[best] = .{ .pixels = left };
        try buckets.append(allocator, .{ .pixels = right });
    }

    // Mean per bucket → palette.
    const palette = try allocator.alloc(RGB, buckets.items.len);
    for (buckets.items, 0..) |b, idx| {
        palette[idx] = bucketMean(b.pixels);
    }
    return palette;
}

const ChannelRange = struct {
    channel: u2, // 0=R, 1=G, 2=B
    range: u32,
};

fn channelRange(pixels: []const RGB) ChannelRange {
    var min: [3]u8 = .{ 255, 255, 255 };
    var max: [3]u8 = .{ 0, 0, 0 };
    for (pixels) |p| {
        for (0..3) |c| {
            if (p[c] < min[c]) min[c] = p[c];
            if (p[c] > max[c]) max[c] = p[c];
        }
    }
    var widest: u2 = 0;
    var widest_w: u32 = 0;
    for (0..3) |c| {
        const w: u32 = @as(u32, max[c]) - @as(u32, min[c]);
        if (w > widest_w) {
            widest_w = w;
            widest = @intCast(c);
        }
    }
    return .{ .channel = widest, .range = widest_w };
}

fn sortByChannelLessThan(channel: u2, a: RGB, b: RGB) bool {
    return a[channel] < b[channel];
}

fn bucketMean(pixels: []const RGB) RGB {
    var sum: [3]u32 = .{ 0, 0, 0 };
    for (pixels) |p| {
        sum[0] += p[0];
        sum[1] += p[1];
        sum[2] += p[2];
    }
    const n: u32 = @intCast(pixels.len);
    return .{
        @intCast(sum[0] / n),
        @intCast(sum[1] / n),
        @intCast(sum[2] / n),
    };
}

// ── Per-pixel index assignment ───────────────────────────────────────

fn mapToIndices(allocator: std.mem.Allocator, img: *const Image, palette: []const RGB) SixelError![]u8 {
    const total: usize = @as(usize, img.width) * @as(usize, img.height);
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const px = i * 4;
        const pixel: RGB = .{ img.pixels[px], img.pixels[px + 1], img.pixels[px + 2] };
        out[i] = nearestIndex(palette, pixel);
    }
    return out;
}

fn nearestIndex(palette: []const RGB, pixel: RGB) u8 {
    var best: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    for (palette, 0..) |p, idx| {
        const dr: i32 = @as(i32, p[0]) - @as(i32, pixel[0]);
        const dg: i32 = @as(i32, p[1]) - @as(i32, pixel[1]);
        const db: i32 = @as(i32, p[2]) - @as(i32, pixel[2]);
        const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (dist < best_dist) {
            best_dist = dist;
            best = @intCast(idx);
            if (dist == 0) break;
        }
    }
    return best;
}

// ── DCS / band emission ───────────────────────────────────────────────

fn emitSixel(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    palette: []const RGB,
    indices: []const u8,
) SixelError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\x1bPq");

    // Palette definitions: `#N;2;R;G;B` per entry, R/G/B as 0-100.
    var idxbuf: [32]u8 = undefined;
    for (palette, 0..) |p, idx| {
        const r = pctOf(p[0]);
        const g = pctOf(p[1]);
        const b = pctOf(p[2]);
        const def = std.fmt.bufPrint(&idxbuf, "#{d};2;{d};{d};{d}", .{ idx, r, g, b }) catch unreachable;
        try out.appendSlice(allocator, def);
    }

    // Band emission: 6 rows at a time. For each band, each color used
    // emits a run of sixel chars; `$` between colors keeps cursor at
    // band start; `-` advances to next band.
    var band_top: u32 = 0;
    while (band_top < height) : (band_top += 6) {
        const band_h: u32 = @min(@as(u32, 6), height - band_top);

        // Determine which palette indices are used in this band.
        var used: [max_palette_size]bool = .{false} ** max_palette_size;
        var any_used = false;
        var r: u32 = 0;
        while (r < band_h) : (r += 1) {
            const row = band_top + r;
            var c: u32 = 0;
            while (c < width) : (c += 1) {
                used[indices[row * width + c]] = true;
                any_used = true;
            }
        }
        if (!any_used) {
            try out.append(allocator, '-');
            continue;
        }

        var first_color = true;
        for (palette, 0..) |_, p_idx| {
            if (!used[p_idx]) continue;
            if (!first_color) try out.append(allocator, '$');
            first_color = false;

            const sel = std.fmt.bufPrint(&idxbuf, "#{d}", .{p_idx}) catch unreachable;
            try out.appendSlice(allocator, sel);

            try emitBandRowForColor(allocator, &out, indices, width, band_top, band_h, @intCast(p_idx));
        }
        // Last band gets no trailing `-`; subsequent bands need it.
        if (band_top + 6 < height) try out.append(allocator, '-');
    }

    try out.appendSlice(allocator, "\x1b\\");
    return try out.toOwnedSlice(allocator);
}

fn emitBandRowForColor(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indices: []const u8,
    width: u32,
    band_top: u32,
    band_h: u32,
    color: u8,
) SixelError!void {
    // Run-length-encode columns of the same sixel value to keep the
    // output compact. A "sixel" is one byte in 0x3F..0x7E; bit-N (0..5)
    // means row-N of the band (above) is the active color.
    var c: u32 = 0;
    var run_char: u8 = 0;
    var run_len: u32 = 0;
    while (c < width) : (c += 1) {
        var bits: u8 = 0;
        var rr: u32 = 0;
        while (rr < band_h) : (rr += 1) {
            const idx = indices[(band_top + rr) * width + c];
            if (idx == color) bits |= @as(u8, 1) << @intCast(rr);
        }
        const sx: u8 = 0x3F + bits;
        if (run_len == 0) {
            run_char = sx;
            run_len = 1;
        } else if (sx == run_char) {
            run_len += 1;
        } else {
            try flushRun(allocator, out, run_char, run_len);
            run_char = sx;
            run_len = 1;
        }
    }
    if (run_len > 0) try flushRun(allocator, out, run_char, run_len);
}

fn flushRun(allocator: std.mem.Allocator, out: *std.ArrayList(u8), char: u8, len: u32) SixelError!void {
    if (len >= 3) {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "!{d}", .{len}) catch unreachable;
        try out.appendSlice(allocator, s);
        try out.append(allocator, char);
    } else {
        var i: u32 = 0;
        while (i < len) : (i += 1) try out.append(allocator, char);
    }
}

inline fn pctOf(v: u8) u32 {
    // Round-half-up: (v * 100 + 127) / 255 → 0..100.
    return (@as(u32, v) * 100 + 127) / 255;
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

test "encode: rejects 0×0 image" {
    const img: Image = .{ .width = 0, .height = 0, .pixels = &.{}, .allocator = testing.allocator };
    try testing.expectError(SixelError.InvalidImage, encode(testing.allocator, &img, .{}));
}

test "encode: rejects 0 palette_size" {
    var img = try solidImage(testing.allocator, 1, 1, 0, 0, 0);
    defer img.deinit();
    try testing.expectError(SixelError.InvalidPaletteSize, encode(testing.allocator, &img, .{ .palette_size = 0 }));
}

test "encode: rejects palette_size > 256" {
    var img = try solidImage(testing.allocator, 1, 1, 0, 0, 0);
    defer img.deinit();
    try testing.expectError(SixelError.InvalidPaletteSize, encode(testing.allocator, &img, .{ .palette_size = 300 }));
}

test "encode: framing — starts with ESC P q, ends with ESC \\\\" {
    var img = try solidImage(testing.allocator, 4, 6, 200, 100, 50);
    defer img.deinit();
    const out = try encode(testing.allocator, &img, .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "\x1bPq"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
}

test "encode: solid-color image yields a single palette entry" {
    var img = try solidImage(testing.allocator, 6, 6, 255, 0, 0);
    defer img.deinit();
    const out = try encode(testing.allocator, &img, .{});
    defer testing.allocator.free(out);
    // Exactly one `#N;2;R;G;B` color def → one '#' followed by `;2;`.
    const def_count = std.mem.count(u8, out, ";2;");
    try testing.expectEqual(@as(usize, 1), def_count);
}

test "encode: palette uses 0-100 percent units" {
    // Pure white → R=G=B=100 in palette spec.
    var img = try solidImage(testing.allocator, 2, 6, 255, 255, 255);
    defer img.deinit();
    const out = try encode(testing.allocator, &img, .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "#0;2;100;100;100") != null);
}

test "encode: every band-separator '-' is followed by data, not the terminator" {
    // 12-row image → 2 bands → 1 separator. Verify the separator is
    // followed by sixel data, not by ESC\\.
    var img = try solidImage(testing.allocator, 4, 12, 100, 100, 100);
    defer img.deinit();
    const out = try encode(testing.allocator, &img, .{});
    defer testing.allocator.free(out);
    // Find the (single) '-' separator. It should NOT be at len-2 (right before ESC\\).
    // Search for "-\x1b\\" — should not appear.
    try testing.expect(std.mem.indexOf(u8, out, "-\x1b\\") == null);
}

test "encode: median cut produces ≤ palette_size colors" {
    const allocator = testing.allocator;
    // 4×6 image with a 4×4 gradient stamped in the top rows (16 distinct
    // RGB combinations); bottom 2 rows stay black. Image must be ≥ 6
    // rows tall to satisfy the one-band minimum.
    var img6 = try solidImage(allocator, 4, 6, 0, 0, 0);
    defer img6.deinit();
    var yy: u32 = 0;
    while (yy < 4) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < 4) : (xx += 1) {
            const px = (yy * 4 + xx) * 4;
            img6.pixels[px] = @intCast(xx * 64);
            img6.pixels[px + 1] = @intCast(yy * 64);
            img6.pixels[px + 2] = 0;
            img6.pixels[px + 3] = 255;
        }
    }

    const out = try encode(allocator, &img6, .{ .palette_size = 8 });
    defer allocator.free(out);

    const def_count = std.mem.count(u8, out, ";2;");
    try testing.expect(def_count <= 8);
    try testing.expect(def_count >= 2);
}

test "encode: pctOf rounds correctly at boundary values" {
    try testing.expectEqual(@as(u32, 0), pctOf(0));
    try testing.expectEqual(@as(u32, 100), pctOf(255));
    try testing.expectEqual(@as(u32, 50), pctOf(127)); // (127*100 + 127) / 255 = 50.99... → 50
    try testing.expectEqual(@as(u32, 50), pctOf(128)); // (128*100 + 127) / 255 = 51.39... → 51
}

test "encode: small image full round-trip without error" {
    var img = try solidImage(testing.allocator, 8, 12, 200, 100, 50);
    defer img.deinit();
    const out = try encode(testing.allocator, &img, .{});
    defer testing.allocator.free(out);
    // Must contain at least one band separator (12 rows = 2 bands).
    const sep_count = std.mem.count(u8, out, "-");
    try testing.expect(sep_count >= 1);
    // RLE-compressed solid image is small (~30 bytes); just verify
    // it's well-formed and has both bands.
    try testing.expect(out.len > 16);
    try testing.expect(std.mem.startsWith(u8, out, "\x1bPq"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
}
