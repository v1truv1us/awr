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
const image_cache = @import("cache.zig");
const kitty = @import("kitty.zig");
const iterm = @import("iterm.zig");
const braille = @import("braille.zig");
const sixel = @import("sixel.zig");

/// T2.9: re-export so browser.zig can use `image_pipeline.Cache` without
/// a separate named module (avoids a decode.zig file-ownership conflict).
pub const Cache = image_cache.Cache;
pub const default_cache_cap_bytes = image_cache.default_cap_bytes;

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
    /// T2.9: cumulative wall-time budget for all image decodes on this
    /// page. Once the total time spent in decode.decode() exceeds this
    /// value, remaining images are counted as overflow_skipped rather
    /// than fetched. Does not apply to cache hits (no decode occurs).
    decode_budget_ms: u64 = 250,
    /// T2.9: palette size passed to the Sixel encoder. Smaller values
    /// trade color accuracy for output-byte size (useful on slow ttys).
    sixel_palette_size: u32 = 256,
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
/// `session_cache` is an optional cross-page decoded-image cache (T2.9).
/// On a cache hit the fetch + decode step is skipped; the cached RGBA
/// pixels are re-encoded directly. Pass null for one-shot CLI invocations
/// that have no session to attach state to.
pub fn build(
    allocator: std.mem.Allocator,
    page: *page_mod.Page,
    page_url: []const u8,
    proto: protocol.Protocol,
    opts: PipelineOptions,
    session_cache: ?*image_cache.Cache,
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

    // Viewport pixels for the `<picture>` / srcset picker. Per §5
    // fallback estimate: cell_pixel_width × cells.
    const viewport_w_px: u32 = opts.cell_pixel_width * opts.max_width_cells;

    // T2.9: tracks cumulative decode wall-time across all images this page.
    var budget_ms_used: u64 = 0;

    var fetched: u32 = 0;
    for (imgs) |img_elem| {
        const picked = pickSrc(allocator, img_elem, viewport_w_px) orelse continue;
        if (picked.len == 0) continue;
        if (fetched >= opts.max_images) {
            pl.overflow_skipped += 1;
            continue;
        }
        // The renderer's `renderImage` looks up bytes by the raw `src`
        // attribute. The pipeline may have *fetched* a higher-res
        // candidate from `<picture>` / `srcset` — those bytes still get
        // stored under the `src` value so the lookup hits. If the
        // image has no `src` (rare; some pages use `srcset` exclusively
        // on browsers that support it), fall back to the picked key —
        // renderImage's null-`src` path won't query, so this entry is
        // unreachable from rendering but the fetch warmth doesn't hurt.
        const lookup_key = img_elem.getAttribute("src") orelse picked;
        if (lookup_key.len == 0) continue;

        // Resolve relative URLs against the page URL for the *fetch*.
        const abs_url = page.resolveUrl(page_url, picked) catch {
            pl.failed += 1;
            continue;
        };
        defer allocator.free(abs_url);

        if (pl.bytes_by_url.contains(lookup_key)) continue;

        // T2.9: skip decode-bound images once the budget is exhausted.
        if (budget_ms_used >= opts.decode_budget_ms) {
            pl.overflow_skipped += 1;
            continue;
        }

        encodeOne(allocator, page, abs_url, lookup_key, proto, opts, &pl, session_cache, &budget_ms_used) catch {
            pl.failed += 1;
            continue;
        };
        fetched += 1;
    }

    // Step 10: CSS background-image resolve. Walk content-bearing
    // landmarks (`<header>`, `<section>`, `<figure>`) for inline
    // `style="background-image: url(...)"` (or shorthand `background:`).
    // Skipped + collapsed regions never get to render time so we don't
    // need to filter here — fetching them is harmless if they end up
    // not displayed. Same lookup as `<img>`: keyed by raw URL string.
    const bg_landmarks = try doc.querySelectorAll("header, section, figure", allocator);
    defer allocator.free(bg_landmarks);
    for (bg_landmarks) |lm| {
        const style = lm.getAttribute("style") orelse continue;
        const bg_url = extractBackgroundUrl(style) orelse continue;
        if (fetched >= opts.max_images) {
            pl.overflow_skipped += 1;
            continue;
        }
        const abs_url = page.resolveUrl(page_url, bg_url) catch {
            pl.failed += 1;
            continue;
        };
        defer allocator.free(abs_url);
        if (pl.bytes_by_url.contains(bg_url)) continue;

        if (budget_ms_used >= opts.decode_budget_ms) {
            pl.overflow_skipped += 1;
            continue;
        }

        encodeOne(allocator, page, abs_url, bg_url, proto, opts, &pl, session_cache, &budget_ms_used) catch {
            pl.failed += 1;
            continue;
        };
        fetched += 1;
    }

    return pl;
}

/// Extract the URL from a CSS `background-image` (or `background`
/// shorthand) declaration in an inline `style="..."` attribute.
///
/// Returns the URL string borrowed from `style` (caller must dupe if
/// it wants ownership). Returns null on:
///
///   • No `background` / `background-image` property in `style`.
///   • Property value contains a `gradient(`, `image-set(`, or other
///     non-url image function (out of §3.1 scope).
///   • No `url(...)` token in the property value.
///
/// Tolerates single-quoted, double-quoted, and unquoted URL values;
/// leading/trailing whitespace inside `url(...)` is stripped.
pub fn extractBackgroundUrl(style: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < style.len) {
        const bg = indexOfICase(style, idx, "background") orelse return null;
        var probe = bg + "background".len;
        // Either "-image" or directly ":" should follow.
        if (probe + 6 <= style.len and std.ascii.eqlIgnoreCase(style[probe .. probe + 6], "-image")) {
            probe += 6;
        }
        probe = skipAsciiWs(style, probe);
        if (probe >= style.len or style[probe] != ':') {
            // Not a background property — could be `background-color`,
            // `background-position`, etc. Advance and try again.
            idx = bg + 1;
            continue;
        }
        probe += 1;
        // Property value runs until `;` or end-of-string.
        const end = std.mem.indexOfScalarPos(u8, style, probe, ';') orelse style.len;
        const value = style[probe..end];

        // Reject non-url image functions.
        if (indexOfICase(value, 0, "gradient") != null) return null;
        if (indexOfICase(value, 0, "image-set") != null) return null;

        const url_kw = indexOfICase(value, 0, "url(") orelse return null;
        const url_start = url_kw + 4;
        const url_close = std.mem.indexOfScalarPos(u8, value, url_start, ')') orelse return null;
        const inner = std.mem.trim(u8, value[url_start..url_close], " \t\"'");
        if (inner.len == 0) return null;
        return inner;
    }
    return null;
}

fn indexOfICase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or start >= haystack.len) return null;
    if (haystack.len < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn skipAsciiWs(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return i;
}

fn encodeOne(
    allocator: std.mem.Allocator,
    page: *page_mod.Page,
    abs_url: []const u8,
    raw_key: []const u8,
    proto: protocol.Protocol,
    opts: PipelineOptions,
    pl: *Pipeline,
    session_cache: ?*image_cache.Cache,
    budget_ms_used: *u64,
) !void {
    // Only http(s) image URLs go through the network. Skip data:, mailto:,
    // file:, etc. — supporting them is out of scope for the MVP.
    if (!(std.mem.startsWith(u8, abs_url, "http://") or std.mem.startsWith(u8, abs_url, "https://"))) {
        return;
    }

    // T2.9: check session cache for a previously-decoded image.
    // iTerm2 encoding uses the raw compressed bytes rather than RGBA
    // pixels, so cache hits can only serve kitty / braille / sixel.
    const cache_eligible = proto != .iterm;
    if (cache_eligible) {
        if (session_cache) |sc| {
            if (sc.get(abs_url)) |cached_img| {
                const dims = estimateCellDims(cached_img.width, cached_img.height, opts);
                const encoded: []u8 = switch (proto) {
                    .kitty => try kitty.encode(allocator, cached_img, .{ .cols = dims.cols, .rows = dims.rows }),
                    .braille => try encodeBraille(allocator, cached_img, dims.cols, dims.rows),
                    .sixel => try sixel.encode(allocator, cached_img, .{ .palette_size = opts.sixel_palette_size }),
                    .none, .iterm => unreachable,
                };
                errdefer allocator.free(encoded);
                const url_owned = try allocator.dupe(u8, raw_key);
                errdefer allocator.free(url_owned);
                try pl.bytes_by_url.put(url_owned, encoded);
                return;
            }
        }
    }

    var resp = page.client.fetch(abs_url) catch return error.FetchFailed;
    defer resp.deinit();
    if (resp.status < 200 or resp.status >= 300) return error.NonOkStatus;
    if (resp.body.len == 0) return error.EmptyBody;

    // T2.9: time the decode call and accumulate into the caller's budget.
    const t0 = milliTimestamp();
    var img = decode.decode(allocator, resp.body) catch return error.DecodeFailed;
    const t1 = milliTimestamp();
    const elapsed: u64 = if (t1 > t0) @intCast(t1 - t0) else 0;
    budget_ms_used.* +|= elapsed;
    defer img.deinit();

    const dims = estimateCellDims(img.width, img.height, opts);

    // T2.9: store a clone in the session cache so the next rerender (or
    // back-navigation) skips the fetch+decode path. Best-effort: if the
    // clone allocation fails or the cache rejects it (oversize), we
    // continue with the local `img` and the miss is silent.
    if (cache_eligible) {
        if (session_cache) |sc| {
            if (allocator.dupe(u8, img.pixels)) |px| {
                const clone: decode.Image = .{
                    .width = img.width,
                    .height = img.height,
                    .pixels = px,
                    .allocator = allocator,
                };
                sc.put(abs_url, clone) catch {};
            } else |_| {}
        }
    }

    const encoded: []u8 = switch (proto) {
        .kitty => try kitty.encode(allocator, &img, .{ .cols = dims.cols, .rows = dims.rows }),
        .iterm => try iterm.encode(allocator, resp.body, .{ .cols = dims.cols, .rows = dims.rows }),
        .braille => try encodeBraille(allocator, &img, dims.cols, dims.rows),
        .sixel => try sixel.encode(allocator, &img, .{ .palette_size = opts.sixel_palette_size }),
        .none => unreachable,
    };
    errdefer allocator.free(encoded);

    const url_owned = try allocator.dupe(u8, raw_key);
    errdefer allocator.free(url_owned);

    try pl.bytes_by_url.put(url_owned, encoded);
}

// Zig 0.16 removed std.time.milliTimestamp; mirror the pattern in pool.zig.
fn milliTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
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

// ── `<picture>` / srcset picker ───────────────────────────────────────
//
// Per `spec/subspecs/rendering.md §3.1`. Pre-fetch URL selection:
//
//   1. If `img.parent` is `<picture>`, scan the picture's `<source>`
//      children. For each, evaluate the `media` query against the
//      viewport-px estimate. The first matching `<source>` contributes
//      its `srcset` (or `src`) to the picker.
//
//   2. If `<img>` has its own `srcset`, parse `Nw` candidates and pick
//      the smallest width ≥ viewport. Fall back to the largest if
//      none qualify (matches Chrome's behavior on too-small viewports).
//
//   3. Otherwise the `src` attribute.
//
// Media features other than `min-width` and `max-width` evaluate to
// false, per the spec. `screen` and `all` keywords are accepted at the
// top level; `print` rejects.

fn pickSrc(allocator: std.mem.Allocator, img: *page_mod.Element, viewport_w_px: u32) ?[]const u8 {
    if (img.parent) |parent| {
        if (std.ascii.eqlIgnoreCase(parent.tag, "picture")) {
            if (pickFromPicture(allocator, parent, viewport_w_px)) |url| return url;
        }
    }
    if (img.getAttribute("srcset")) |sset| {
        if (pickFromSrcset(sset, viewport_w_px)) |url| return url;
    }
    return img.getAttribute("src");
}

fn pickFromPicture(
    allocator: std.mem.Allocator,
    picture: *const page_mod.Element,
    viewport_w_px: u32,
) ?[]const u8 {
    const sources = picture.querySelectorAll("source", allocator) catch return null;
    defer allocator.free(sources);
    for (sources) |s| {
        const media = s.getAttribute("media") orelse "";
        if (!evalMedia(media, viewport_w_px)) continue;
        if (s.getAttribute("srcset")) |sset| {
            if (pickFromSrcset(sset, viewport_w_px)) |url| return url;
        }
        if (s.getAttribute("src")) |src| return src;
    }
    return null;
}

fn pickFromSrcset(sset: []const u8, viewport_w_px: u32) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_w: u32 = 0;
    var fallback: ?[]const u8 = null;
    var fallback_w: u32 = 0;

    var iter = std.mem.splitScalar(u8, sset, ',');
    while (iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\n\r");
        if (trimmed.len == 0) continue;
        const space = std.mem.indexOfAny(u8, trimmed, " \t") orelse continue;
        const url = trimmed[0..space];
        const desc = std.mem.trim(u8, trimmed[space..], " \t");
        if (desc.len < 2) continue;
        if (desc[desc.len - 1] != 'w') continue; // ignore Nx (DPR) descriptors
        const w_str = std.mem.trim(u8, desc[0 .. desc.len - 1], " \t");
        const w = std.fmt.parseInt(u32, w_str, 10) catch continue;

        if (w > fallback_w) {
            fallback_w = w;
            fallback = url;
        }
        if (w >= viewport_w_px) {
            if (best == null or w < best_w) {
                best_w = w;
                best = url;
            }
        }
    }
    return best orelse fallback;
}

fn evalMedia(query: []const u8, viewport_w_px: u32) bool {
    const trimmed = std.mem.trim(u8, query, " \t");
    if (trimmed.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "screen")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "print")) return false;

    var rest: []const u8 = trimmed;
    var loop_guard: u32 = 0;
    while (rest.len > 0) : (loop_guard += 1) {
        if (loop_guard > 16) return false; // pathological-input guard
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len == 0) break;

        // Strip leading "screen" or "screen and ".
        if (std.ascii.startsWithIgnoreCase(rest, "screen")) {
            rest = std.mem.trim(u8, rest[6..], " \t");
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(rest, "and")) {
            rest = std.mem.trim(u8, rest[3..], " \t");
            continue;
        }
        if (rest[0] == '(') {
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return false;
            const inner = rest[1..close];
            if (!evalFeature(inner, viewport_w_px)) return false;
            rest = rest[close + 1 ..];
            continue;
        }
        // Unrecognized token — per §3.1, only min/max-width supported.
        return false;
    }
    return true;
}

fn evalFeature(feature: []const u8, viewport_w_px: u32) bool {
    const colon = std.mem.indexOfScalar(u8, feature, ':') orelse return false;
    const name = std.mem.trim(u8, feature[0..colon], " \t");
    const value = std.mem.trim(u8, feature[colon + 1 ..], " \t");

    var num_str = value;
    if (std.ascii.endsWithIgnoreCase(num_str, "px")) {
        num_str = std.mem.trim(u8, num_str[0 .. num_str.len - 2], " \t");
    }
    const n = std.fmt.parseInt(u32, num_str, 10) catch return false;

    if (std.ascii.eqlIgnoreCase(name, "min-width")) return viewport_w_px >= n;
    if (std.ascii.eqlIgnoreCase(name, "max-width")) return viewport_w_px <= n;
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "PipelineOptions: T2.9 fields have correct defaults" {
    const opts: PipelineOptions = .{};
    try testing.expectEqual(@as(u64, 250), opts.decode_budget_ms);
    try testing.expectEqual(@as(u32, 256), opts.sixel_palette_size);
}

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

test "pickFromSrcset: smallest width >= viewport" {
    const sset = "small.jpg 200w, mid.jpg 400w, big.jpg 800w";
    try testing.expectEqualStrings("mid.jpg", pickFromSrcset(sset, 350).?);
    try testing.expectEqualStrings("mid.jpg", pickFromSrcset(sset, 400).?);
    try testing.expectEqualStrings("big.jpg", pickFromSrcset(sset, 600).?);
    try testing.expectEqualStrings("small.jpg", pickFromSrcset(sset, 100).?);
}

test "pickFromSrcset: largest as fallback when none qualify" {
    const sset = "small.jpg 200w, mid.jpg 400w";
    try testing.expectEqualStrings("mid.jpg", pickFromSrcset(sset, 9999).?);
}

test "pickFromSrcset: ignores Nx (DPR) descriptors" {
    const sset = "high.jpg 2x, normal.jpg 1x";
    try testing.expect(pickFromSrcset(sset, 100) == null);
}

test "pickFromSrcset: empty input → null" {
    try testing.expect(pickFromSrcset("", 100) == null);
    try testing.expect(pickFromSrcset(" ,, ", 100) == null);
}

test "pickFromSrcset: tolerates extra whitespace" {
    const sset = "  url-a.jpg   400w ,  url-b.jpg   800w  ";
    try testing.expectEqualStrings("url-a.jpg", pickFromSrcset(sset, 300).?);
    try testing.expectEqualStrings("url-b.jpg", pickFromSrcset(sset, 500).?);
}

test "evalMedia: empty / all / screen → true" {
    try testing.expect(evalMedia("", 100));
    try testing.expect(evalMedia("all", 100));
    try testing.expect(evalMedia("screen", 100));
    try testing.expect(evalMedia("  all  ", 100));
}

test "evalMedia: print → false" {
    try testing.expect(!evalMedia("print", 100));
}

test "evalMedia: min-width matches when viewport >= value" {
    try testing.expect(evalMedia("(min-width: 768px)", 800));
    try testing.expect(evalMedia("(min-width: 768px)", 768));
    try testing.expect(!evalMedia("(min-width: 768px)", 700));
}

test "evalMedia: max-width matches when viewport <= value" {
    try testing.expect(evalMedia("(max-width: 1024px)", 800));
    try testing.expect(evalMedia("(max-width: 1024px)", 1024));
    try testing.expect(!evalMedia("(max-width: 1024px)", 1200));
}

test "evalMedia: min and max chained with 'and'" {
    try testing.expect(evalMedia("(min-width: 600px) and (max-width: 1024px)", 800));
    try testing.expect(!evalMedia("(min-width: 600px) and (max-width: 1024px)", 500));
    try testing.expect(!evalMedia("(min-width: 600px) and (max-width: 1024px)", 1200));
}

test "evalMedia: 'screen and (min-width: ...)' is honored" {
    try testing.expect(evalMedia("screen and (min-width: 600px)", 800));
    try testing.expect(!evalMedia("screen and (min-width: 600px)", 400));
}

test "evalMedia: unsupported features evaluate to false" {
    // Per §3.1: features other than min-width / max-width → false.
    try testing.expect(!evalMedia("(orientation: portrait)", 800));
    try testing.expect(!evalMedia("(prefers-color-scheme: dark)", 800));
    try testing.expect(!evalMedia("(hover: hover)", 800));
}

test "extractBackgroundUrl: background-image with double-quoted url" {
    const url = extractBackgroundUrl("background-image: url(\"hero.jpg\")").?;
    try testing.expectEqualStrings("hero.jpg", url);
}

test "extractBackgroundUrl: background-image with single-quoted url" {
    const url = extractBackgroundUrl("background-image: url('photo.png');").?;
    try testing.expectEqualStrings("photo.png", url);
}

test "extractBackgroundUrl: background-image with unquoted url" {
    const url = extractBackgroundUrl("background-image: url(/static/hero.jpg)").?;
    try testing.expectEqualStrings("/static/hero.jpg", url);
}

test "extractBackgroundUrl: background shorthand with extras" {
    const url = extractBackgroundUrl("background: url('bg.png') no-repeat center center").?;
    try testing.expectEqualStrings("bg.png", url);
}

test "extractBackgroundUrl: case-insensitive property name" {
    const url = extractBackgroundUrl("BACKGROUND-IMAGE: URL('foo.jpg')").?;
    try testing.expectEqualStrings("foo.jpg", url);
}

test "extractBackgroundUrl: rejects gradients" {
    try testing.expect(extractBackgroundUrl("background: linear-gradient(red, blue)") == null);
    try testing.expect(extractBackgroundUrl("background-image: radial-gradient(circle, red, blue)") == null);
    try testing.expect(extractBackgroundUrl("background: linear-gradient(red, blue), url(fallback.jpg)") == null);
}

test "extractBackgroundUrl: rejects image-set" {
    try testing.expect(extractBackgroundUrl("background-image: image-set(url('1x.jpg') 1x, url('2x.jpg') 2x)") == null);
}

test "extractBackgroundUrl: empty / no background → null" {
    try testing.expect(extractBackgroundUrl("") == null);
    try testing.expect(extractBackgroundUrl("color: red; padding: 1em") == null);
    try testing.expect(extractBackgroundUrl("background-color: blue") == null);
    try testing.expect(extractBackgroundUrl("background-position: center") == null);
}

test "extractBackgroundUrl: property after another declaration" {
    const url = extractBackgroundUrl("color: red; background-image: url('after.png');").?;
    try testing.expectEqualStrings("after.png", url);
}

test "extractBackgroundUrl: empty url() returns null" {
    try testing.expect(extractBackgroundUrl("background: url()") == null);
    try testing.expect(extractBackgroundUrl("background: url('')") == null);
}
