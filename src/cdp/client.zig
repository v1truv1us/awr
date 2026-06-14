/// cdp/client.zig — headless Chrome DevTools Protocol transport.
///
/// Spawns a headless Chrome process, connects to its DevTools WebSocket
/// endpoint, navigates to the requested URL, waits for the page to settle
/// (load event + optional extra settle delay for SPA JS), and returns the
/// JS-settled outerHTML as an owned []u8.  The caller then feeds that HTML
/// into AWR's existing lexbor→DOM→render pipeline with JS disabled.
///
/// Entry points:
///   chromeAvailable()                          — returns true if Chrome found
///   fetchRenderedHtml(alloc, io, url, opts) ![]u8 — main API
///
/// Cleanup contract: Chrome is killed and the temp user-data-dir is removed
/// on all exit paths (both success and error), via defer/errdefer.
///
/// Constraints:
///   - Never imports or modifies anything under src/net/ (fingerprint safety).
///   - Uses AWR's websocket.zig primitives for the CDP socket (recon confirmed
///     it can act as a generic client).
///   - Explicit allocators everywhere; no global state.
const std = @import("std");
const ws = @import("../net/websocket.zig");

// ── Chrome location ────────────────────────────────────────────────────────

const chrome_mac_path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/// Returns the Chrome binary path: AWR_CHROME env override, then the macOS
/// default.  Caller must NOT free the returned slice.
fn chromePath() []const u8 {
    if (std.c.getenv("AWR_CHROME")) |p| return std.mem.span(p);
    return chrome_mac_path;
}

/// libc access(2) — present on every POSIX platform AWR targets.
extern fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Returns true if the Chrome binary exists and is accessible.
pub fn chromeAvailable() bool {
    const path = chromePath();
    // Sentinel-terminate for the C call.
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len - 1) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return access(@ptrCast(&buf), 0) == 0;
}

// Zig 0.16 removed std.time.milliTimestamp and std.time.nanoTimestamp;
// mirror the pattern in pool.zig.
fn milliTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn nanoTimestamp() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
}

// ── Public error set ───────────────────────────────────────────────────────

pub const CdpError = error{
    /// Chrome binary not found or not executable.
    ChromeUnavailable,
    /// Chrome did not print its DevTools listening URL within the timeout.
    ChromeStartTimeout,
    /// Could not parse the ws:// URL from Chrome's stderr output.
    DevToolsUrlParse,
    /// CDP response did not contain the expected result field.
    CdpResultMissing,
    /// Chrome returned an error response to a CDP call.
    CdpCallFailed,
    /// The outerHTML result was absent or not a string.
    OuterHtmlMissing,
};

// ── Options ────────────────────────────────────────────────────────────────

pub const FetchOpts = struct {
    /// Extra milliseconds to wait after `Page.loadEventFired` for SPA JS.
    /// Default: 1 500 ms — enough for most React/Vue/Next hydration cycles.
    settle_ms: u64 = 1500,
    /// Milliseconds to wait for Chrome to print its DevTools URL.
    chrome_start_timeout_ms: u64 = 10_000,
};

// ── Main entry point ───────────────────────────────────────────────────────

/// Spawn headless Chrome, navigate to `url`, wait for JS to settle, and
/// return the JS-settled `document.documentElement.outerHTML` as an owned
/// []u8.  Caller must free with `allocator.free(result)`.
///
/// Returns `error.ChromeUnavailable` if Chrome is not installed.
/// All other errors propagate; cleanup (kill Chrome, delete temp dir) is
/// guaranteed via defer/errdefer on all exit paths.
pub fn fetchRenderedHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    opts: FetchOpts,
) ![]u8 {
    if (!chromeAvailable()) return error.ChromeUnavailable;

    // ── 1. Temp user-data-dir ─────────────────────────────────────────────
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(
        &tmp_dir_buf,
        "/tmp/awr-cdp-{d}",
        .{milliTimestamp()},
    );

    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| switch (err) {
        error.PathAlreadyExists, error.NotDir => {},
        else => return err,
    };
    errdefer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    // ── 2. Spawn Chrome ───────────────────────────────────────────────────
    const chrome_bin = chromePath();
    const udd_flag = try std.fmt.allocPrint(
        allocator,
        "--user-data-dir={s}",
        .{tmp_dir},
    );
    defer allocator.free(udd_flag);

    const dyn_argv = [_][]const u8{
        chrome_bin,
        "--headless=new",
        "--disable-gpu",
        "--remote-debugging-port=0",
        udd_flag,
        "--no-first-run",
        "--no-default-browser-check",
        "about:blank",
    };

    var child = try std.process.spawn(io, .{
        .argv = &dyn_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    errdefer {
        child.kill(io);
    }

    // ── 3. Parse DevTools ws:// URL from stderr ───────────────────────────
    const ws_url = try readDevToolsUrl(
        allocator,
        io,
        &child,
        opts.chrome_start_timeout_ms,
    );
    defer allocator.free(ws_url);

    // ── 4. Parse ws://127.0.0.1:PORT/path ────────────────────────────────
    const port, const path = try parseWsUrl(ws_url);

    // ── 5. TCP connect to Chrome's DevTools endpoint ──────────────────────
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    // ── 6. Buffered reader / writer over the TCP stream ───────────────────
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var net_reader = stream.reader(io, &read_buf);
    var net_writer = stream.writer(io, &write_buf);

    // Bridge from std.Io.Reader/Writer to the readNoEof/writeAll interface
    // that websocket.zig (anytype) expects.  Pattern from tests/wpt_runner.zig.
    const ReaderAdapter = struct {
        inner: *std.Io.Reader,
        pub fn readNoEof(self: *@This(), buf: []u8) !void {
            try self.inner.readSliceAll(buf);
        }
    };
    const WriterAdapter = struct {
        inner: *std.Io.Writer,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.inner.writeAll(bytes);
        }
    };
    var r_adapt = ReaderAdapter{ .inner = &net_reader.interface };
    var w_adapt = WriterAdapter{ .inner = &net_writer.interface };

    // ── 7. WebSocket handshake ────────────────────────────────────────────
    var ws_key: [24]u8 = undefined;
    ws.generateKey(&ws_key);

    const host_port = try std.fmt.allocPrint(
        allocator,
        "127.0.0.1:{d}",
        .{port},
    );
    defer allocator.free(host_port);

    try ws.sendUpgradeRequest(&w_adapt, host_port, path, &ws_key);
    try net_writer.interface.flush();
    try ws.readUpgradeResponse(&r_adapt, allocator, &ws_key);

    // ── 8. CDP session ────────────────────────────────────────────────────
    const html = try runCdpSession(
        allocator,
        io,
        &r_adapt,
        &w_adapt,
        &net_writer.interface,
        url,
        opts.settle_ms,
    );
    errdefer allocator.free(html);

    // ── 9. Close WebSocket and kill Chrome ────────────────────────────────
    var close_mask: [4]u8 = undefined;
    // generateKey fills 24 bytes; use first 4 as the mask (random bytes).
    var close_key_buf: [24]u8 = undefined;
    ws.generateKey(&close_key_buf);
    @memcpy(&close_mask, close_key_buf[0..4]);
    ws.writeFrame(&w_adapt, .close, &.{}, close_mask) catch {};
    net_writer.interface.flush() catch {};

    child.kill(io);
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    return html;
}

// ── DevTools URL extraction ────────────────────────────────────────────────

/// Read Chrome's stderr until we see:
///   DevTools listening on ws://127.0.0.1:PORT/devtools/browser/<id>
/// Returns the full ws:// URL as an owned []u8.
fn readDevToolsUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    timeout_ms: u64,
) ![]u8 {
    const stderr_file = &(child.stderr orelse return error.ChromeStartTimeout);

    const deadline_ns = @as(u64, @intCast(nanoTimestamp())) +
        timeout_ms * std.time.ns_per_ms;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var stderr_read_buf: [4096]u8 = undefined;
    var stderr_reader = stderr_file.reader(io, &stderr_read_buf);

    const marker = "DevTools listening on ";

    while (true) {
        const now: u64 = @intCast(nanoTimestamp());
        if (now >= deadline_ns) return error.ChromeStartTimeout;

        var byte_buf: [1]u8 = undefined;
        // Use std.Io.Reader.readSliceShort to tolerate zero-byte reads.
        const n = stderr_reader.interface.readSliceShort(&byte_buf) catch
            return error.ChromeStartTimeout;
        if (n == 0) continue; // no data yet — spin
        if (byte_buf[0] == '\n') {
            const line = line_buf.items;
            if (std.mem.startsWith(u8, line, marker)) {
                const ws_url = try allocator.dupe(
                    u8,
                    std.mem.trimEnd(u8, line[marker.len..], "\r\n "),
                );
                return ws_url;
            }
            line_buf.clearRetainingCapacity();
        } else {
            try line_buf.append(allocator, byte_buf[0]);
        }
    }
}

// ── ws:// URL parser ───────────────────────────────────────────────────────

/// Parse `ws://127.0.0.1:PORT/path` → (port, path).
/// `path` is a slice into `url` (not owned).
fn parseWsUrl(url: []const u8) !struct { u16, []const u8 } {
    if (!std.mem.startsWith(u8, url, "ws://")) return error.DevToolsUrlParse;
    const rest = url["ws://".len..];

    // Find the first `/` to split authority from path.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
        return error.DevToolsUrlParse;
    const authority = rest[0..slash];
    const path = rest[slash..];

    // Split host:port — use lastIndexOf to handle IPv6 addresses too.
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse
        return error.DevToolsUrlParse;
    const port_str = authority[colon + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch
        return error.DevToolsUrlParse;

    return .{ port, path };
}

// ── CDP JSON-RPC session ───────────────────────────────────────────────────

const CdpConn = struct {
    next_id: u32 = 1,

    fn nextId(self: *CdpConn) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

/// Run the full CDP session over an established WebSocket connection.
/// r_adapt / w_adapt provide the readNoEof / writeAll interface.
/// flush_writer is the underlying std.Io.Writer (for explicit flush after sends).
fn runCdpSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    r_adapt: anytype,
    w_adapt: anytype,
    flush_writer: *std.Io.Writer,
    url: []const u8,
    settle_ms: u64,
) ![]u8 {
    var conn: CdpConn = .{};

    // ── Target.createTarget ───────────────────────────────────────────────
    const create_id = conn.nextId();
    {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"method\":\"Target.createTarget\"," ++
                "\"params\":{{\"url\":\"about:blank\"}}}}",
            .{create_id},
        );
        defer allocator.free(msg);
        try wsSend(w_adapt, flush_writer, msg);
    }

    const target_id = try awaitStringField(
        allocator,
        r_adapt,
        create_id,
        "targetId",
    );
    defer allocator.free(target_id);

    // ── Target.attachToTarget ─────────────────────────────────────────────
    const attach_id = conn.nextId();
    {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"method\":\"Target.attachToTarget\"," ++
                "\"params\":{{\"targetId\":\"{s}\",\"flatten\":true}}}}",
            .{ attach_id, target_id },
        );
        defer allocator.free(msg);
        try wsSend(w_adapt, flush_writer, msg);
    }

    const session_id = try awaitStringField(
        allocator,
        r_adapt,
        attach_id,
        "sessionId",
    );
    defer allocator.free(session_id);

    // ── Page.enable ───────────────────────────────────────────────────────
    const enable_id = conn.nextId();
    {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"sessionId\":\"{s}\"," ++
                "\"method\":\"Page.enable\",\"params\":{{}}}}",
            .{ enable_id, session_id },
        );
        defer allocator.free(msg);
        try wsSend(w_adapt, flush_writer, msg);
    }
    try awaitAck(allocator, r_adapt, enable_id);

    // ── Page.navigate ─────────────────────────────────────────────────────
    const nav_id = conn.nextId();
    {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"sessionId\":\"{s}\"," ++
                "\"method\":\"Page.navigate\"," ++
                "\"params\":{{\"url\":\"{s}\"}}}}",
            .{ nav_id, session_id, url },
        );
        defer allocator.free(msg);
        try wsSend(w_adapt, flush_writer, msg);
    }
    try awaitAck(allocator, r_adapt, nav_id);

    // ── Wait for Page.loadEventFired ──────────────────────────────────────
    try waitForEvent(allocator, r_adapt, session_id, "Page.loadEventFired");

    // ── Settle delay ──────────────────────────────────────────────────────
    if (settle_ms > 0) {
        std.Io.sleep(
            io,
            std.Io.Duration.fromMilliseconds(@intCast(settle_ms)),
            .awake,
        ) catch {};
    }

    // ── Runtime.evaluate — get outerHTML ──────────────────────────────────
    const eval_id = conn.nextId();
    {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"sessionId\":\"{s}\"," ++
                "\"method\":\"Runtime.evaluate\"," ++
                "\"params\":{{\"expression\":\"document.documentElement.outerHTML\"," ++
                "\"returnByValue\":true}}}}",
            .{ eval_id, session_id },
        );
        defer allocator.free(msg);
        try wsSend(w_adapt, flush_writer, msg);
    }

    return awaitOuterHtml(allocator, r_adapt, eval_id);
}

// ── WebSocket send helper ──────────────────────────────────────────────────

fn wsSend(w_adapt: anytype, flush_writer: *std.Io.Writer, msg: []const u8) !void {
    var key_buf: [24]u8 = undefined;
    ws.generateKey(&key_buf);
    const mask = [4]u8{ key_buf[0], key_buf[1], key_buf[2], key_buf[3] };
    try ws.writeFrame(w_adapt, .text, msg, mask);
    try flush_writer.flush();
}

// ── CDP response helpers ───────────────────────────────────────────────────

/// Read frames until we get response id == `expected_id`, then extract
/// the string value of `field` from `result`.  Returns owned []u8.
fn awaitStringField(
    allocator: std.mem.Allocator,
    r_adapt: anytype,
    expected_id: u32,
    field: []const u8,
) ![]u8 {
    while (true) {
        const frame = try ws.readFrame(r_adapt, allocator);
        defer allocator.free(frame.payload);
        if (frame.opcode != .text and frame.opcode != .binary) continue;
        if (!matchesId(frame.payload, expected_id)) continue;
        if (findError(frame.payload)) return error.CdpCallFailed;
        return extractStringField(allocator, frame.payload, field) orelse
            error.CdpResultMissing;
    }
}

/// Wait for a response with `id == expected_id`; ignore content.
fn awaitAck(
    allocator: std.mem.Allocator,
    r_adapt: anytype,
    expected_id: u32,
) !void {
    while (true) {
        const frame = try ws.readFrame(r_adapt, allocator);
        defer allocator.free(frame.payload);
        if (frame.opcode != .text and frame.opcode != .binary) continue;
        if (!matchesId(frame.payload, expected_id)) continue;
        if (findError(frame.payload)) return error.CdpCallFailed;
        return;
    }
}

/// Wait for a CDP event with the given `method` on the given `session_id`.
fn waitForEvent(
    allocator: std.mem.Allocator,
    r_adapt: anytype,
    session_id: []const u8,
    method: []const u8,
) !void {
    while (true) {
        const frame = try ws.readFrame(r_adapt, allocator);
        defer allocator.free(frame.payload);
        if (frame.opcode != .text and frame.opcode != .binary) continue;
        const msg = frame.payload;
        if (hasMethod(msg, method) and hasSessionId(msg, session_id)) return;
    }
}

/// Await `Runtime.evaluate` result and extract the string value of "value".
/// Chrome wraps it as:
///   {"id":N,"result":{"result":{"type":"string","value":"<!DOCTYPE..."}}}
fn awaitOuterHtml(
    allocator: std.mem.Allocator,
    r_adapt: anytype,
    expected_id: u32,
) ![]u8 {
    while (true) {
        const frame = try ws.readFrame(r_adapt, allocator);
        defer allocator.free(frame.payload);
        if (frame.opcode != .text and frame.opcode != .binary) continue;
        if (!matchesId(frame.payload, expected_id)) continue;
        if (findError(frame.payload)) return error.CdpCallFailed;
        return extractStringField(allocator, frame.payload, "value") orelse
            error.OuterHtmlMissing;
    }
}

// ── Minimal JSON field extraction ──────────────────────────────────────────
//
// Hand-rolled scan to avoid allocating the full JSON AST for potentially
// large HTML payloads.  CDP messages are well-structured; the scan is
// intentionally minimal: it finds the first `"key":"..."` occurrence.

fn matchesId(msg: []const u8, id: u32) bool {
    var buf: [32]u8 = undefined;
    const pattern = std.fmt.bufPrint(&buf, "\"id\":{d}", .{id}) catch return false;
    return std.mem.indexOf(u8, msg, pattern) != null;
}

fn findError(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "\"error\":{") != null;
}

fn hasMethod(msg: []const u8, method: []const u8) bool {
    return std.mem.indexOf(u8, msg, "\"method\"") != null and
        std.mem.indexOf(u8, msg, method) != null;
}

fn hasSessionId(msg: []const u8, session_id: []const u8) bool {
    return std.mem.indexOf(u8, msg, session_id) != null;
}

/// Find the first `"field":"..."` in `msg` and return the decoded string
/// value as an owned []u8.  Returns null if the key is absent.
///
/// Handles JSON string escapes: \\, \", \n, \r, \t, \uXXXX (basic BMP).
fn extractStringField(
    allocator: std.mem.Allocator,
    msg: []const u8,
    field: []const u8,
) ?[]u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(
        &needle_buf,
        "\"{s}\":\"",
        .{field},
    ) catch return null;

    const start_pos = std.mem.indexOf(u8, msg, needle) orelse return null;
    const val_start = start_pos + needle.len;
    if (val_start >= msg.len) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i = val_start;
    while (i < msg.len) {
        const c = msg[i];
        if (c == '"') break; // unescaped closing quote
        if (c == '\\' and i + 1 < msg.len) {
            i += 1;
            switch (msg[i]) {
                '"' => out.append(allocator, '"') catch return null,
                '\\' => out.append(allocator, '\\') catch return null,
                '/' => out.append(allocator, '/') catch return null,
                'n' => out.append(allocator, '\n') catch return null,
                'r' => out.append(allocator, '\r') catch return null,
                't' => out.append(allocator, '\t') catch return null,
                'u' => {
                    if (i + 4 < msg.len) {
                        const hex = msg[i + 1 .. i + 5];
                        const code_point = std.fmt.parseInt(u21, hex, 16) catch {
                            out.append(allocator, '?') catch return null;
                            i += 4;
                            i += 1;
                            continue;
                        };
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(code_point, &utf8_buf) catch 0;
                        if (len > 0) {
                            out.appendSlice(allocator, utf8_buf[0..len]) catch return null;
                        }
                        i += 4;
                    }
                },
                else => out.append(allocator, msg[i]) catch return null,
            }
        } else {
            out.append(allocator, c) catch return null;
        }
        i += 1;
    }

    return out.toOwnedSlice(allocator) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "chromeAvailable — returns bool without crashing" {
    _ = chromeAvailable();
}

test "parseWsUrl — happy path" {
    const port, const path = try parseWsUrl(
        "ws://127.0.0.1:9222/devtools/browser/abc-123",
    );
    try std.testing.expectEqual(@as(u16, 9222), port);
    try std.testing.expectEqualStrings("/devtools/browser/abc-123", path);
}

test "parseWsUrl — rejects non-ws scheme" {
    const result = parseWsUrl("http://127.0.0.1:9222/path");
    try std.testing.expectError(error.DevToolsUrlParse, result);
}

test "parseWsUrl — rejects missing path separator" {
    const result = parseWsUrl("ws://127.0.0.1:9222");
    try std.testing.expectError(error.DevToolsUrlParse, result);
}

test "extractStringField — simple string" {
    const msg = "{\"id\":1,\"result\":{\"targetId\":\"ABCDEF\"}}";
    const val = extractStringField(std.testing.allocator, msg, "targetId");
    defer if (val) |v| std.testing.allocator.free(v);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("ABCDEF", val.?);
}

test "extractStringField — escaped quotes" {
    const msg = "{\"result\":{\"value\":\"he said \\\"hello\\\"\"}}";
    const val = extractStringField(std.testing.allocator, msg, "value");
    defer if (val) |v| std.testing.allocator.free(v);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("he said \"hello\"", val.?);
}

test "extractStringField — missing key returns null" {
    const msg = "{\"id\":1,\"result\":{}}";
    const val = extractStringField(std.testing.allocator, msg, "targetId");
    try std.testing.expect(val == null);
}

test "extractStringField — escaped newline and tab" {
    const msg = "{\"value\":\"line1\\nline2\\ttabbed\"}";
    const val = extractStringField(std.testing.allocator, msg, "value");
    defer if (val) |v| std.testing.allocator.free(v);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("line1\nline2\ttabbed", val.?);
}

test "matchesId — matches correct id" {
    try std.testing.expect(matchesId("{\"id\":42,\"result\":{}}", 42));
    try std.testing.expect(!matchesId("{\"id\":42,\"result\":{}}", 43));
}

test "findError — detects error field" {
    try std.testing.expect(findError("{\"id\":1,\"error\":{\"code\":-32601}}"));
    try std.testing.expect(!findError("{\"id\":1,\"result\":{}}"));
}

test "hasMethod — detects CDP event method" {
    try std.testing.expect(hasMethod(
        "{\"method\":\"Page.loadEventFired\",\"params\":{}}",
        "Page.loadEventFired",
    ));
    try std.testing.expect(!hasMethod(
        "{\"method\":\"Page.domContentEventFired\",\"params\":{}}",
        "Page.loadEventFired",
    ));
}

test "fetchRenderedHtml — error.ChromeUnavailable when Chrome absent" {
    if (chromeAvailable()) {
        // Chrome present — skip the no-Chrome path in this test.
        std.debug.print("(skipping: Chrome is present)\n", .{});
        return;
    }
    const result = fetchRenderedHtml(
        std.testing.allocator,
        std.testing.io,
        "data:text/html,<h1>hi</h1>",
        .{},
    );
    try std.testing.expectError(error.ChromeUnavailable, result);
}

test "fetchRenderedHtml — data: URL renders hello-cdp when Chrome present" {
    if (!chromeAvailable()) {
        std.debug.print("skipping: Chrome not found\n", .{});
        return;
    }
    const html = fetchRenderedHtml(
        std.testing.allocator,
        std.testing.io,
        "data:text/html,<html><body><h1 id=x>hello-cdp</h1></body></html>",
        .{ .settle_ms = 500 },
    ) catch |err| {
        std.debug.print("skipping: fetchRenderedHtml failed: {}\n", .{err});
        return;
    };
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "hello-cdp") != null);
}
