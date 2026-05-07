/// telemetry.zig — Per-session structured metrics emission.
///
/// AWR is a CLI process that runs once per agent fetch. Heavy
/// observability SDKs (sentry-native, OpenTelemetry C++) are
/// out-of-character for a Zig CLI runtime — they're megabytes of
/// dependencies for a few KB of useful data per invocation. Instead
/// AWR emits one JSON Lines record at the end of each session,
/// to stderr or a configured file. That format ingests cleanly into
/// Sentry, Datadog, Loki, or `jq` / `grep` / `awk` pipelines without
/// linking against any of them.
///
/// Opt-in via env var:
///
///   AWR_TELEMETRY=1            → emit to stderr (also accepts "stderr")
///   AWR_TELEMETRY=/path/log    → append one JSON object per line
///   (unset)                    → no output, near-zero overhead
///
/// Schema is versioned via the `v` field. Stable contract for a
/// minor version bump; breaking changes increment the major.
///
/// What's recorded today (v1):
///   - URL, response status, body sizes
///   - Top-level phase timings (page_init, navigate_fetch,
///     process_html, json_emit)
///   - Sub-phase timings inside process_html (js_reset, parse,
///     bridge, prefetch, scripts, drain_*, extract)
///   - External-script-fetch aggregates (count + total ms)
///
/// What's NOT recorded yet (TODO for a v2):
///   - Per-host TLS protocol (h1.1 vs h2) — needed to spot
///     fingerprint regressions in aggregate logs
///   - Fatal-error context — currently `std.process.fatal` kills
///     the process before telemetry emits; needs a thin wrapper
///     that emits-then-dies
///   - Memory peak / RSS — `getrusage` integration
const std = @import("std");

/// Per-session record. Initialized at process start, populated as
/// phases complete, emitted as one JSON line at the end. All `_ms`
/// fields use `-1` for "not measured" so the JSON stays compact and
/// downstream queries can filter cleanly.
pub const SessionMetrics = struct {
    /// Wall-clock time the metric collection started, in epoch
    /// milliseconds. Used to anchor the record on a timeline; not
    /// the same as any of the phase start times.
    started_at_ms: i64 = 0,
    /// Target URL, borrowed from the caller. Lifetime must outlive
    /// the call to `emit`. Typically the CLI argv[1] is the URL,
    /// which lives in the process arena.
    url: ?[]const u8 = null,
    /// HTTP status code from the final response (after redirects).
    status: ?u16 = null,
    /// Bytes in the response body delivered to the page pipeline
    /// (post-decompression, post-redirect-follow).
    body_bytes: usize = 0,
    /// Bytes in the JSON envelope that AWR emits to stdout. Smaller
    /// than `body_bytes` because the envelope's `body_text` field
    /// is plain text, not raw HTML.
    envelope_bytes: usize = 0,

    // ── Top-level phase timings (main.zig owns these) ────────────────────
    /// Time from process start through `Page.init`.
    page_init_ms: i64 = -1,
    /// Time from `client.fetch` start through response body received.
    navigate_fetch_ms: i64 = -1,
    /// Time spent inside `Page.processHtml` (parse → JS → drain → extract).
    process_html_ms: i64 = -1,
    /// Time spent serializing the JSON envelope and writing it to stdout.
    json_emit_ms: i64 = -1,

    // ── Sub-phase timings (page.zig TimingProbe owns these) ──────────────
    js_reset_ms: i64 = -1,
    parse_ms: i64 = -1,
    bridge_ms: i64 = -1,
    prefetch_ms: i64 = -1,
    scripts_ms: i64 = -1,
    drain_interactive_ms: i64 = -1,
    drain_load_ms: i64 = -1,
    extract_ms: i64 = -1,

    // ── External-fetch aggregates (page.zig populates) ───────────────────
    /// Number of external `<script src>` resources fetched (cache-
    /// hit or miss) during script execution.
    ext_fetch_count: u32 = 0,
    /// Total ms spent on external script fetches (sum across the
    /// sequential or worker-prefetched path).
    ext_fetch_total_ms: i64 = 0,
    /// Total bytes fetched across all external scripts.
    ext_fetch_bytes: usize = 0,

    /// Transport that delivered the main page response — short
    /// lower-case tag like `"std"`, `"h1.1"`, or `"h2"`. Borrowed
    /// from a `static` string literal, so no allocator concerns.
    /// Aggregating this in production logs is how you spot
    /// fingerprint or H2-routing regressions: if a host that should
    /// be on h2 suddenly reports h1.1, something changed upstream
    /// (or in our ctx / pool wiring). null when not measured.
    protocol_main: ?[]const u8 = null,

    /// Initialize with the current wall-clock time.
    pub fn init() SessionMetrics {
        return .{ .started_at_ms = wallClockMs() };
    }

    /// Set a sub-phase ms field by name. Used by `TimingProbe.mark`
    /// so it doesn't have to know the field layout. Unknown names
    /// are silently ignored (forward compat: the probe can mark
    /// phases that telemetry doesn't track yet).
    pub fn setSubPhase(self: *SessionMetrics, name: []const u8, ms: i64) void {
        if (std.mem.eql(u8, name, "js_reset")) self.js_reset_ms = ms;
        if (std.mem.eql(u8, name, "parse")) self.parse_ms = ms;
        if (std.mem.eql(u8, name, "bridge")) self.bridge_ms = ms;
        if (std.mem.eql(u8, name, "prefetch")) self.prefetch_ms = ms;
        if (std.mem.eql(u8, name, "scripts")) self.scripts_ms = ms;
        if (std.mem.eql(u8, name, "drain_interactive")) self.drain_interactive_ms = ms;
        if (std.mem.eql(u8, name, "drain_load")) self.drain_load_ms = ms;
        if (std.mem.eql(u8, name, "extract")) self.extract_ms = ms;
    }

    /// Aggregate one external-script fetch result.
    pub fn recordExtFetch(self: *SessionMetrics, ms: i64, bytes: usize) void {
        self.ext_fetch_count += 1;
        self.ext_fetch_total_ms += ms;
        self.ext_fetch_bytes += bytes;
    }

    /// Serialize as a single line of JSON to `writer`. Emits a
    /// trailing newline so successive emits to the same file form
    /// proper JSON Lines.
    pub fn writeJson(self: *const SessionMetrics, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"v\":1,\"ts_ms\":");
        try writer.print("{d}", .{self.started_at_ms});

        if (self.url) |u| {
            try writer.writeAll(",\"url\":");
            try writeJsonString(writer, u);
        }
        if (self.status) |s| try writer.print(",\"status\":{d}", .{s});
        try writer.print(",\"body_bytes\":{d}", .{self.body_bytes});
        try writer.print(",\"envelope_bytes\":{d}", .{self.envelope_bytes});

        // Top-level phase timings
        try writeMs(writer, "page_init_ms", self.page_init_ms);
        try writeMs(writer, "navigate_fetch_ms", self.navigate_fetch_ms);
        try writeMs(writer, "process_html_ms", self.process_html_ms);
        try writeMs(writer, "json_emit_ms", self.json_emit_ms);

        // Sub-phase timings
        try writeMs(writer, "js_reset_ms", self.js_reset_ms);
        try writeMs(writer, "parse_ms", self.parse_ms);
        try writeMs(writer, "bridge_ms", self.bridge_ms);
        try writeMs(writer, "prefetch_ms", self.prefetch_ms);
        try writeMs(writer, "scripts_ms", self.scripts_ms);
        try writeMs(writer, "drain_interactive_ms", self.drain_interactive_ms);
        try writeMs(writer, "drain_load_ms", self.drain_load_ms);
        try writeMs(writer, "extract_ms", self.extract_ms);

        // External-fetch aggregates (always emitted, even when zero,
        // because absence is meaningful: zero ext fetches = no script
        // resources on the page).
        try writer.print(",\"ext_fetch_count\":{d}", .{self.ext_fetch_count});
        try writer.print(",\"ext_fetch_total_ms\":{d}", .{self.ext_fetch_total_ms});
        try writer.print(",\"ext_fetch_bytes\":{d}", .{self.ext_fetch_bytes});

        if (self.protocol_main) |p| {
            try writer.writeAll(",\"protocol_main\":");
            try writeJsonString(writer, p);
        }

        try writer.writeAll("}\n");
    }
};

fn writeMs(writer: *std.Io.Writer, name: []const u8, value: i64) !void {
    if (value < 0) return; // -1 means not-measured; omit from output
    try writer.print(",\"{s}\":{d}", .{ name, value });
}

/// Minimal JSON string escaper. Mirrors `writeJsonStr` in main.zig
/// but lives here to keep telemetry self-contained. Escapes the four
/// JSON-specials plus control chars; a URL contains none of those in
/// practice but we belt-and-suspender.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // Control chars (0x00-0x1f) other than the named ones above.
            // The named ones must be matched first because Zig's switch
            // doesn't allow overlapping ranges with explicit values.
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn wallClockMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Resolve `AWR_TELEMETRY` to a destination. Returns `.none` if the
/// env var is unset or empty. The returned `Dest.file_path`, when
/// present, is duped from the env value and owned by the caller —
/// pass it to `allocator.free` after the final `emit` call.
pub const Dest = union(enum) {
    none,
    stderr,
    file_path: []u8,

    pub fn deinit(self: *Dest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .file_path => |p| allocator.free(p),
            else => {},
        }
        self.* = .none;
    }
};

pub fn resolveDest(allocator: std.mem.Allocator) !Dest {
    if (!@hasDecl(std.c, "getenv")) return .none;
    const raw = std.c.getenv("AWR_TELEMETRY") orelse return .none;
    const value = std.mem.sliceTo(raw, 0);
    if (value.len == 0) return .none;
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "stderr")) return .stderr;
    return Dest{ .file_path = try allocator.dupe(u8, value) };
}

/// Emit `metrics` to whatever destination `AWR_TELEMETRY` resolves
/// to. Allocation failures, file-open failures, and write errors are
/// silently swallowed — telemetry must never break the foreground
/// fetch. Callers can inspect `resolveDest` directly if they need to
/// know whether emission was attempted.
pub fn emit(metrics: *const SessionMetrics, allocator: std.mem.Allocator, io: std.Io) void {
    var dest = resolveDest(allocator) catch return;
    defer dest.deinit(allocator);

    switch (dest) {
        .none => return,
        .stderr => emitToStderr(metrics, io) catch {},
        .file_path => |path| emitToFile(metrics, io, path) catch {},
    }
}

fn emitToStderr(metrics: *const SessionMetrics, io: std.Io) !void {
    var stderr = std.Io.File.stderr();
    var buffer: [2048]u8 = undefined;
    var fw = stderr.writer(io, &buffer);
    try metrics.writeJson(&fw.interface);
    try fw.interface.flush();
}

fn emitToFile(metrics: *const SessionMetrics, io: std.Io, path: []const u8) !void {
    // Best-effort directory create — telemetry shouldn't add new
    // failure modes to the fetch path.
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    // Build the JSON line in a heap buffer first, then append at the
    // current end-of-file via writePositionalAll. This is the JSON
    // Lines append model on Zig 0.16, which doesn't expose POSIX
    // O_APPEND directly through std.Io.File.
    var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer line.deinit();
    try metrics.writeJson(&line.writer);

    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
    defer file.close(io);
    const offset = file.length(io) catch 0;
    try file.writePositionalAll(io, line.written(), offset);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "SessionMetrics.init records wall-clock time" {
    const m = SessionMetrics.init();
    try std.testing.expect(m.started_at_ms > 0);
    try std.testing.expectEqual(@as(i64, -1), m.page_init_ms);
}

test "SessionMetrics.setSubPhase sets known fields, ignores unknown" {
    var m = SessionMetrics.init();
    m.setSubPhase("parse", 17);
    try std.testing.expectEqual(@as(i64, 17), m.parse_ms);
    m.setSubPhase("not_a_phase", 99);
    // No assertion; just verifying it doesn't crash. Unknown phases
    // are silently ignored so TimingProbe can mark new phases without
    // requiring a sync update here.
    try std.testing.expect(true);
}

test "SessionMetrics.recordExtFetch aggregates count, ms, bytes" {
    var m = SessionMetrics.init();
    m.recordExtFetch(50, 1024);
    m.recordExtFetch(30, 2048);
    try std.testing.expectEqual(@as(u32, 2), m.ext_fetch_count);
    try std.testing.expectEqual(@as(i64, 80), m.ext_fetch_total_ms);
    try std.testing.expectEqual(@as(usize, 3072), m.ext_fetch_bytes);
}

test "SessionMetrics.writeJson emits valid one-line JSON" {
    var m = SessionMetrics.init();
    m.url = "https://example.com/";
    m.status = 200;
    m.body_bytes = 1234;
    m.envelope_bytes = 567;
    m.page_init_ms = 2;
    m.navigate_fetch_ms = 89;
    m.parse_ms = 4;
    m.recordExtFetch(50, 1024);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try m.writeJson(&buf.writer);

    const out = buf.written();
    // One trailing newline — the JSON Lines contract.
    try std.testing.expect(out.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
    // Single line: no embedded newlines.
    const body = out[0 .. out.len - 1];
    try std.testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);

    // Schema-version field must be present and equal 1.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"v\":1") != null);
    // Spot-check a few fields are emitted.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"url\":\"https://example.com/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"body_bytes\":1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"page_init_ms\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parse_ms\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ext_fetch_count\":1") != null);
    // Unset phases (-1) are omitted from output.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"bridge_ms\"") == null);
}

test "SessionMetrics.writeJson includes protocol_main when set" {
    var m = SessionMetrics.init();
    m.url = "https://example.com/";
    m.status = 200;
    m.protocol_main = "h2";

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try m.writeJson(&buf.writer);

    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"protocol_main\":\"h2\"") != null);
}

test "SessionMetrics.writeJson omits protocol_main when null" {
    var m = SessionMetrics.init();
    m.url = "https://example.com/";

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try m.writeJson(&buf.writer);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "protocol_main") == null);
}

test "SessionMetrics.writeJson escapes JSON-special chars in url" {
    var m = SessionMetrics.init();
    m.url = "https://example.com/\"quoted\"\\path\nnewline";

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try m.writeJson(&buf.writer);

    const out = buf.written();
    // \" sequence must be escaped, not bare quote
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"quoted\\\"") != null);
    // \\ and \n likewise
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\\path") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
}
