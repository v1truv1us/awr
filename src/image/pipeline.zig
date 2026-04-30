/// Image pipeline — fetches, decodes, and encodes every `<img>` on a
/// page into the protocol bytes that `render.zig` will splice into
/// the output. This is the glue between `Page` (network + DOM) and
/// `RenderOptions.image_lookup` (the renderer's contract).
///
/// Per `spec/subspecs/rendering.md §3.1`. Honors:
///
///   • The 32-images-per-page hard cap (surplus images render as
///     text alt-refs).
///   • The 4 MiB-encoded / 16 MP-decoded per-image caps enforced by
///     `src/image/decode.zig`.
///   • The 32 MiB resident-bytes cache cap (we don't use the cache
///     here for `awr render` — it's one-shot — but the per-image caps
///     keep memory bounded regardless).
///   • The terminal cell-pixel ratio (defaults: 7 px wide × 14 px
///     tall per cell, the §5 estimate when `CSI 14 t` / `OSC 1337
///     ReportCellSize` probe fails or isn't run).
///
/// Fingerprint discipline (`spec/MVP.md §3`): image fetches go
/// through the same `Client.fetchRequest` that page navigation uses,
/// with no per-request header tweaks. JA4 + HTTP/2 SETTINGS stay
/// identical to the navigating fetch — verified by `test-tls` and
/// `test-h2` after every encoder lands.
const std = @import("std");

const page_mod = @import("page");
const decode = @import("decode.zig");
const protocol = @import("image_protocol");
const kitty = @import("kitty.zig");
const iterm = @import("iterm.zig");
const braille = @import("braille.zig");
const sixel = @import("sixel.zig");

pub const PipelineOptions = struct {
    /// Hard cap on images fetched per page. §3.1.
    max_images: u32 = 32,
    /// Render width in cells; image cell-cols are clamped to fit.
    max_width_cells: u32 = 80,
    /// Default cell-pixel sizes. Match §5's fallback estimate.
    cell_pixel_width: u32 = 7,
    cell_pixel_height: u32 = 14,
    /// Minimum cell dimensions for any rendered image. Prevents
    /// favicon-sized icons from collapsing to a single dot of garble.
    min_cols: u32 = 4,
    min_rows: u32 = 2,
};

pub const PipelineError = error{
    UnsupportedProtocol, // reserved for future protocols (none today)
    OutOfMemory,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    /// Owns both keys (URL strings) and values (encoded protocol bytes).
    bytes_by_url: std.StringHashMap([]u8),
    /// Count of `<img>` elements that were skipped because of the
    /// per-page max_images cap. Surfaced for status reporting.
    overflow_skipped: u32 = 0,
    /// Count of fetch / decode failures. Doesn't abort the pipeline —
    /// failed images fall through to the alt-ref text path.
    failed: u32 = 0,

    pub fn deinit(self: *Pipeline) void {
        var it = self.bytes_by_url.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.bytes_by_url.deinit();
        self.* = undefined;
    }

    /// Construct a non-owning lookup compatible with
    /// `RenderOptions.image_lookup`. The returned struct borrows
    /// `self`; lifetime is the Pipeline's.
    pub fn lookup(self: *const Pipeline) page_mod.ImageLookup {
        return .{ .ctx = self, .getFn = getFn };
    }

    fn getFn(ctx: *const anyopaque, url: []const u8) ?[]const u8 {
        const self: *const Pipeline = @ptrCast(@alignCast(ctx));
        if (self.bytes_by_url.get(url)) |bytes| return bytes;
        return null;
    }
};

/// Walk the page's DOM, collect every `<img src>`, fetch + decode +
/// encode each, and return a populated Pipeline.
///
/// `proto` must be one of the encoded variants (`.kitty`, `.iterm`,
/// `.braille`). For `.none` callers should skip building a pipeline at
/// all — there's nothing to do. `.sixel` returns
/// `error.UnsupportedProtocol` until Step 7 lands the encoder; main.zig
/// catches and falls back to text alt-refs.
pub fn build(
    allocator: std.mem.Allocator,
    page: *page_mod.Page,
    page_url: []const u8,
    proto: protocol.Protocol,
    opts: PipelineOptions,
) !Pipeline {
    if (proto == .none) {
        return .{
            .allocator = allocator,
            .bytes_by_url = std.StringHashMap([]u8).init(allocator),
        };
    }

    const doc = page.current_doc orelse return .{
        .allocator = allocator,
        .bytes_by_url = std.StringHashMap([]u8).init(allocator),
    };

    var pl: Pipeline = .{
        .allocator = allocator,
        .bytes_by_url = std.StringHashMap([]u8).init(allocator),
    };
    errdefer pl.deinit();

    const imgs = try doc.querySelectorAll("img", allocator);
    defer allocator.free(imgs);

    var fetched: u32 = 0;
    for (imgs) |img_elem| {
        const src = img_elem.getAttribute("src") orelse continue;
        if (src.len == 0) continue;
        if (fetched >= opts.max_images) {
            pl.overflow_skipped += 1;
            continue;
        }
        // Resolve relative URLs against the page URL.
        const abs_url = page.resolveUrl(page_url, src) catch {
            pl.failed += 1;
            continue;
        };
        defer allocator.free(abs_url);

        // Skip URLs we've already encoded (avoids fetching the same
        // hero image twice on pages that use it in multiple <img>).
        if (pl.bytes_by_url.contains(abs_url)) continue;

        encodeOne(allocator, page, abs_url, proto, opts, &pl) catch {
            pl.failed += 1;
            continue;
        };
        fetched += 1;
    }

    return pl;
}

fn encodeOne(
    allocator: std.mem.Allocator,
    page: *page_mod.Page,
    abs_url: []const u8,
    proto: protocol.Protocol,
    opts: PipelineOptions,
    pl: *Pipeline,
) !void {
    // Only http(s) image URLs go through the network. Skip data:, mailto:,
    // file:, etc. — supporting them is out of scope for the MVP.
    if (!(std.mem.startsWith(u8, abs_url, "http://") or std.mem.startsWith(u8, abs_url, "https://"))) {
        return;
    }

    var resp = page.client.fetch(abs_url) catch return error.FetchFailed;
    defer resp.deinit();
    if (resp.status < 200 or resp.status >= 300) return error.NonOkStatus;
    if (resp.body.len == 0) return error.EmptyBody;

    var img = decode.decode(allocator, resp.body) catch return error.DecodeFailed;
    defer img.deinit();

    const dims = estimateCellDims(img.width, img.height, opts);

    const encoded: []u8 = switch (proto) {
        .kitty => try kitty.encode(allocator, &img, .{ .cols = dims.cols, .rows = dims.rows }),
        .iterm => try iterm.encode(allocator, resp.body, .{ .cols = dims.cols, .rows = dims.rows }),
        .braille => try encodeBraille(allocator, &img, dims.cols, dims.rows),
        .sixel => try sixel.encode(allocator, &img, .{}),
        .none => unreachable,
    };
    errdefer allocator.free(encoded);

    const url_owned = try allocator.dupe(u8, abs_url);
    errdefer allocator.free(url_owned);

    try pl.bytes_by_url.put(url_owned, encoded);
}

const CellDims = struct { cols: u32, rows: u32 };

/// Pick a cell-size for a decoded image: scale aspect-preserving so
/// the image fills up to `max_width_cells` and stays at least
/// `min_cols × min_rows` (so a 16×16 favicon still reads as recognizable
/// shape, not a single corrupted glyph).
fn estimateCellDims(img_w: u32, img_h: u32, opts: PipelineOptions) CellDims {
    if (img_w == 0 or img_h == 0) return .{ .cols = opts.min_cols, .rows = opts.min_rows };

    // "Natural" cell size = pixel size / cell-pixel size.
    const nat_cols = @max(@as(u32, 1), img_w / opts.cell_pixel_width);
    const nat_rows = @max(@as(u32, 1), img_h / opts.cell_pixel_height);

    var cols = nat_cols;
    var rows = nat_rows;

    // Clamp to the render-width budget.
    if (cols > opts.max_width_cells) {
        // Scale rows down by the same ratio so aspect is preserved.
        // Use 64-bit arithmetic to avoid u32 overflow on large images.
        const scaled_rows: u64 = @as(u64, rows) * @as(u64, opts.max_width_cells) / @as(u64, cols);
        rows = @intCast(@max(@as(u64, 1), scaled_rows));
        cols = opts.max_width_cells;
    }

    // Floor at min cell sizes so tiny icons stay readable.
    cols = @max(cols, opts.min_cols);
    rows = @max(rows, opts.min_rows);

    return .{ .cols = cols, .rows = rows };
}

/// UTF-8 encode a braille downsample into the wire bytes a terminal
/// would render: row-by-row, glyphs separated by `\n`.
///
/// Returned slice is owned by the caller. Always 3 UTF-8 bytes per
/// glyph + 1 newline per row except the last.
fn encodeBraille(allocator: std.mem.Allocator, img: *const decode.Image, cols: u32, rows: u32) ![]u8 {
    const cells = try braille.downsample(allocator, img, cols, rows, braille.default_threshold);
    defer allocator.free(cells);

    // 3 bytes per cell + (rows - 1) inter-row newlines.
    const total = @as(usize, cols) * @as(usize, rows) * 3 + @as(usize, rows) - 1;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    var off: usize = 0;
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const cell = cells[r * cols + c];
            const n = braille.encodeUtf8(cell, out[off..]);
            off += n;
        }
        if (r + 1 < rows) {
            out[off] = '\n';
            off += 1;
        }
    }
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "estimateCellDims: scales aspect-preserving when wider than budget" {
    const dims = estimateCellDims(1000, 500, .{ .max_width_cells = 80 });
    // 1000/7 = 142 → exceeds 80 → clamp to 80; rows = 35 * (80/142) ≈ 19
    try testing.expectEqual(@as(u32, 80), dims.cols);
    try testing.expectEqual(@as(u32, 19), dims.rows);
}

test "estimateCellDims: tiny icon clamps up to min dimensions" {
    const dims = estimateCellDims(8, 8, .{});
    // 8/7 = 1; 8/14 = 0; floored at min_cols=4, min_rows=2.
    try testing.expectEqual(@as(u32, 4), dims.cols);
    try testing.expectEqual(@as(u32, 2), dims.rows);
}

test "estimateCellDims: zero-dimension image falls to mins" {
    const dims = estimateCellDims(0, 0, .{});
    try testing.expectEqual(@as(u32, 4), dims.cols);
    try testing.expectEqual(@as(u32, 2), dims.rows);
}

test "estimateCellDims: medium image uses natural dimensions" {
    const dims = estimateCellDims(280, 280, .{ .max_width_cells = 80 });
    // 280/7 = 40 (fits in 80); 280/14 = 20.
    try testing.expectEqual(@as(u32, 40), dims.cols);
    try testing.expectEqual(@as(u32, 20), dims.rows);
}
