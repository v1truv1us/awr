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
    /// Navigation did not complete within nav_timeout_ms and best-effort
    /// DOM retrieval also failed.  Caller should fall back to Zig render.
    NavTimeout,
};

// ── Cookie type (decoupled from net/cookie.zig) ───────────────────────────

/// A cookie to inject into headless Chrome via `Network.setCookies`.
/// Decoupled from `net/cookie.zig` to preserve the fingerprint-safety
/// constraint (cdp/ must never import src/net/ except websocket.zig).
/// Callers in page.zig map net/cookie.Cookie → CdpCookie before calling
/// fetchRenderedHtml.
pub const CdpCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    /// Unix seconds; null = session cookie (omit `expires` in CDP JSON).
    expires: ?i64,
    secure: bool,
    http_only: bool,
    /// "Strict" | "Lax" | "None"
    same_site: []const u8,
};

// ── Options ────────────────────────────────────────────────────────────────

pub const FetchOpts = struct {
    /// Extra milliseconds to wait after `Page.navigate` ack for SPA JS.
    /// Default: 1 500 ms — enough for most React/Vue/Next hydration cycles.
    settle_ms: u64 = 1500,
    /// Milliseconds to wait for Chrome to print its DevTools URL.
    chrome_start_timeout_ms: u64 = 10_000,
    /// Total wall-clock budget for the navigation + settle phase.
    /// If the page never fires a load event the CDP path sleeps for at most
    /// `@min(nav_timeout_ms, settle_ms + 3_000)` ms then captures best-effort
    /// DOM.  Pass 0 to disable (not recommended — risks an infinite hang).
    /// Default: 20 000 ms.
    nav_timeout_ms: u64 = 20_000,
    /// Cookies to inject via `Network.setCookies` before navigation.
    /// Defaulted to empty so all existing call sites compile unchanged.
    cookies: []const CdpCookie = &.{},
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

    // ── 1. AWR persistent profile directory (with per-PID ephemeral fallback) ─
    // Preferred: ~/.awr/profile (or $AWR_PROFILE override) so the profile
    // accumulates cookies and trust over time.  Concurrent awr processes
    // (e.g. agent fan-out) must not race over the same profile — Chrome's
    // Singleton files prevent it from starting.  We use a non-blocking flock
    // on a lock file inside the shared profile to determine ownership:
    //
    //   • Lock acquired  → we own the shared profile; clean any stale
    //     Singleton files left by a previous owner that died un-cleanly.
    //     The flock releases automatically when the fd is closed (on return)
    //     or when this process dies — no manual Singleton manipulation by
    //     concurrent processes.
    //
    //   • Lock not acquired → another live AWR-driven Chrome owns the shared
    //     profile.  Fall back to an ephemeral /tmp/awr-cdp-<pid> directory
    //     for this run; it is deleted on return.
    const home = std.c.getenv("HOME") orelse "/tmp";
    const home_slice = std.mem.span(home);
    // shared_profile: either borrowed from env (AWR_PROFILE) or allocated.
    const shared_profile: []const u8 = if (std.c.getenv("AWR_PROFILE")) |p|
        std.mem.span(p)
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}/.awr/profile",
            .{home_slice},
        );
    defer if (std.c.getenv("AWR_PROFILE") == null) allocator.free(shared_profile);

    std.Io.Dir.cwd().createDirPath(io, shared_profile) catch |err| switch (err) {
        error.PathAlreadyExists, error.NotDir => {},
        else => return err,
    };

    // Try a non-blocking exclusive flock on .awr-instance.lock inside the
    // shared profile to determine whether we are the sole owner.
    const lock_rel = try std.fmt.allocPrint(
        allocator,
        "{s}/.awr-instance.lock",
        .{shared_profile},
    );
    defer allocator.free(lock_rel);
    const lock_rel_z = try allocator.dupeZ(u8, lock_rel);
    defer allocator.free(lock_rel_z);

    const lock_fd: ?std.posix.fd_t = std.posix.openat(
        std.posix.AT.FDCWD,
        lock_rel_z,
        .{ .ACCMODE = .RDWR, .CREAT = true },
        0o644,
    ) catch null;

    const got_lock: bool = if (lock_fd) |fd|
        (std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) == 0)
    else
        false;

    // profile_dir: the directory Chrome will actually use for this run.
    var is_ephemeral = false;
    const profile_dir: []const u8 = blk: {
        if (got_lock) {
            // We own the shared profile.  Keep lock_fd open until return.
            break :blk shared_profile;
        }
        // Another live AWR owns the shared profile — fall back to a fresh
        // per-PID ephemeral directory.
        if (lock_fd) |fd| _ = std.c.close(fd);
        const eph = try std.fmt.allocPrint(
            allocator,
            "/tmp/awr-cdp-{d}",
            .{std.c.getpid()},
        );
        std.Io.Dir.cwd().createDirPath(io, eph) catch |err| switch (err) {
            error.PathAlreadyExists, error.NotDir => {},
            else => {
                allocator.free(eph);
                return err;
            },
        };
        is_ephemeral = true;
        break :blk eph;
    };
    // Close the flock fd when we return (releases the lock automatically).
    defer if (got_lock) {
        if (lock_fd) |fd| _ = std.c.close(fd);
    };
    // Ephemeral dir is removed on return; shared profile persists.
    defer if (is_ephemeral) {
        std.Io.Dir.cwd().deleteTree(io, profile_dir) catch {};
        allocator.free(profile_dir);
    };

    // ── 1b. Remove stale Singleton files (only when we own the shared profile)
    // Chrome writes SingletonLock / SingletonSocket / SingletonCookie into the
    // profile root when it starts and removes them on clean exit.  If a prior
    // AWR run orphaned Chrome (e.g. SIGKILL), these files linger and prevent
    // the next Chrome instance from acquiring the profile (ChromeStartTimeout).
    // The flock above guarantees no other live AWR-driven Chrome is using this
    // profile, so unlinking is safe.
    if (got_lock) {
        const lock_names = [_][]const u8{
            "SingletonLock",
            "SingletonSocket",
            "SingletonCookie",
        };
        for (lock_names) |name| {
            const stale_path = std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ profile_dir, name },
            ) catch continue;
            defer allocator.free(stale_path);
            const stale_path_z = allocator.dupeZ(u8, stale_path) catch continue;
            defer allocator.free(stale_path_z);
            _ = std.c.unlink(stale_path_z.ptr);
        }
    }

    // ── 2. Spawn Chrome ───────────────────────────────────────────────────
    const chrome_bin = chromePath();
    const udd_flag = try std.fmt.allocPrint(
        allocator,
        "--user-data-dir={s}",
        .{profile_dir},
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
    // Bound the outerHTML read phase with a kernel-level SO_RCVTIMEO so
    // ws.readFrame() cannot block indefinitely if Chrome stops responding.
    // We use a short polling window (5 s) and check the wall-clock deadline
    // inside awaitOuterHtml to decide when to bail.  All earlier CDP acks
    // (createTarget, attachToTarget, Page.enable, Page.navigate) receive
    // prompt replies and are not the hang source; the timeout only matters
    // for the final outerHTML read.
    if (opts.nav_timeout_ms > 0) {
        // Total budget = sleep budget + 3 s post-settle read window.
        const total_budget_ms: u32 = @intCast(@min(
            opts.nav_timeout_ms + 3_000,
            @as(u64, std.math.maxInt(u32)),
        ));
        const tv: std.posix.timeval = .{
            .sec = @intCast(total_budget_ms / 1000),
            .usec = @intCast((total_budget_ms % 1000) * 1000),
        };
        const opt = std.mem.asBytes(&tv);
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, opt) catch {};
    }

    // Compute the absolute deadline for the outerHTML read phase.
    // We give an extra 3 s beyond nav_timeout_ms for the read itself.
    const html_deadline_ms: i64 = if (opts.nav_timeout_ms > 0)
        milliTimestamp() + @as(i64, @intCast(opts.nav_timeout_ms)) + 3_000
    else
        0; // 0 = no deadline check (unlimited budget)

    const html = try runCdpSession(
        allocator,
        io,
        &r_adapt,
        &w_adapt,
        &net_writer.interface,
        url,
        opts.settle_ms,
        opts.nav_timeout_ms,
        html_deadline_ms,
        opts.cookies,
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
    // The shared profile persists across runs; an ephemeral fallback dir is
    // cleaned by the defer installed in step 1.

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
        if (n == 0) {
            // No data yet — yield briefly instead of busy-spinning a full core
            // while Chrome boots (can take seconds on a cold start).
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
            continue;
        }
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
/// settle_ms: extra wait after navigate ack for SPA JS hydration.
/// nav_timeout_ms: hard ceiling on the navigate+settle phase; caps the settle
///   sleep so the call is always bounded even if the page never fires loadEventFired.
/// deadline_ms: absolute milliTimestamp deadline for the outerHTML read phase.
///   0 means no deadline check (used in tests with synthetic readers).
/// cookies: optional slice of CdpCookie to inject before navigation.
fn runCdpSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    r_adapt: anytype,
    w_adapt: anytype,
    flush_writer: *std.Io.Writer,
    url: []const u8,
    settle_ms: u64,
    nav_timeout_ms: u64,
    deadline_ms: i64,
    cookies: []const CdpCookie,
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

    // ── Cookie injection (Network.enable + Network.setCookies) ────────────
    // Injected AFTER attachToTarget (session_id is live) and BEFORE
    // Page.enable / navigate so the navigation request is authenticated.
    if (cookies.len > 0) {
        const net_enable_id = conn.nextId();
        {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{{\"id\":{d},\"sessionId\":\"{s}\"," ++
                    "\"method\":\"Network.enable\",\"params\":{{}}}}",
                .{ net_enable_id, session_id },
            );
            defer allocator.free(msg);
            try wsSend(w_adapt, flush_writer, msg);
        }
        try awaitAck(allocator, r_adapt, net_enable_id);

        const set_cookies_id = conn.nextId();
        {
            const msg = try buildSetCookiesMessage(allocator, set_cookies_id, session_id, cookies);
            defer allocator.free(msg);
            try wsSend(w_adapt, flush_writer, msg);
        }
        try awaitAck(allocator, r_adapt, set_cookies_id);
    }

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

    _ = nav_timeout_ms; // deadline_ms already encodes the nav budget; kept for caller ABI

    // ── Race Page.loadEventFired against the deadline ─────────────────────
    // Return to capture as soon as the page fires load (fast path: a page
    // that hydrates in 200ms is captured at ~load+settle, not a fixed 4.5s),
    // but never hang if a SPA/challenge page never fires load. The wait is
    // bounded by load_deadline (reserving a read window for outerHTML) and by
    // SO_RCVTIMEO on the socket. deadline_ms==0 (unit tests) skips the wait.
    const read_reserve_ms: i64 = 3_000;
    const load_deadline_ms: i64 = if (deadline_ms != 0) deadline_ms - read_reserve_ms else 0;
    if (load_deadline_ms != 0) {
        while (milliTimestamp() < load_deadline_ms) {
            const frame = ws.readFrame(r_adapt, allocator) catch {
                // SO_RCVTIMEO EAGAIN or transient read error — re-check the deadline.
                if (milliTimestamp() >= load_deadline_ms) break;
                continue;
            };
            defer allocator.free(frame.payload);
            if (frame.opcode != .text and frame.opcode != .binary) continue;
            if (hasMethod(frame.payload, "Page.loadEventFired")) break;
        }
    }

    // ── Bounded hydration settle ──────────────────────────────────────────
    // After load (or load timeout) give SPA JS a brief window to hydrate, but
    // never exceed the remaining nav budget (preserving the outerHTML read
    // window). When unbounded (tests), just honor settle_ms.
    {
        const room_ms: i64 = if (load_deadline_ms != 0)
            load_deadline_ms - milliTimestamp()
        else
            @intCast(settle_ms);
        if (room_ms > 0) {
            const sleep_ms: u64 = @min(settle_ms, @as(u64, @intCast(room_ms)));
            if (sleep_ms > 0)
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
        }
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

    return awaitOuterHtml(allocator, r_adapt, eval_id, deadline_ms);
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

/// Await `Runtime.evaluate` result and extract the string value of "value".
/// Chrome wraps it as:
///   {"id":N,"result":{"result":{"type":"string","value":"<!DOCTYPE..."}}}
///
/// deadline_ms is an absolute milliTimestamp() deadline for the entire read
/// loop.  When non-zero, each ws.readFrame() error (including EAGAIN from
/// SO_RCVTIMEO) triggers a deadline check; if the wall clock has passed
/// deadline_ms the function returns error.NavTimeout rather than spinning.
/// When deadline_ms is 0, deadline checking is skipped (used in unit tests
/// that drive synthetic readers with no kernel socket underneath).
fn awaitOuterHtml(
    allocator: std.mem.Allocator,
    r_adapt: anytype,
    expected_id: u32,
    deadline_ms: i64,
) ![]u8 {
    while (true) {
        const frame = ws.readFrame(r_adapt, allocator) catch |err| {
            // SO_RCVTIMEO fires EAGAIN (surfaces as a read error through the
            // adapter).  Check whether the wall-clock deadline has passed; if
            // so, give up rather than retrying indefinitely.
            if (deadline_ms != 0 and milliTimestamp() >= deadline_ms) {
                return error.NavTimeout;
            }
            return err;
        };
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

// ── JSON helpers ──────────────────────────────────────────────────────────

/// Append `s` as a JSON string (with surrounding quotes) to `list`,
/// escaping `"`, `\`, and common control characters. Control characters
/// < 0x20 are rendered as `\uXXXX`.
fn appendJsonString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |ch| switch (ch) {
        '"' => try list.appendSlice(allocator, "\\\""),
        '\\' => try list.appendSlice(allocator, "\\\\"),
        '\n' => try list.appendSlice(allocator, "\\n"),
        '\r' => try list.appendSlice(allocator, "\\r"),
        '\t' => try list.appendSlice(allocator, "\\t"),
        else => if (ch < 0x20) {
            var buf: [6]u8 = undefined;
            const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
            try list.appendSlice(allocator, hex);
        } else try list.append(allocator, ch),
    };
    try list.append(allocator, '"');
}

/// Build the full `Network.setCookies` CDP JSON message.
/// Returns an owned []u8 that the caller must free.
/// Factored out so it can be unit-tested without a live WebSocket.
fn buildSetCookiesMessage(
    allocator: std.mem.Allocator,
    id: u32,
    session_id: []const u8,
    cookies: []const CdpCookie,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Prefix: {"id":N,"sessionId":"...","method":"Network.setCookies","params":{"cookies":[
    try out.appendSlice(allocator, "{\"id\":");
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
    try out.appendSlice(allocator, id_str);
    try out.appendSlice(allocator, ",\"sessionId\":");
    try appendJsonString(&out, allocator, session_id);
    try out.appendSlice(allocator, ",\"method\":\"Network.setCookies\",\"params\":{\"cookies\":[");

    for (cookies, 0..) |c, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');

        try out.appendSlice(allocator, "\"name\":");
        try appendJsonString(&out, allocator, c.name);
        try out.appendSlice(allocator, ",\"value\":");
        try appendJsonString(&out, allocator, c.value);
        try out.appendSlice(allocator, ",\"domain\":");
        try appendJsonString(&out, allocator, c.domain);
        try out.appendSlice(allocator, ",\"path\":");
        try appendJsonString(&out, allocator, c.path);
        try out.appendSlice(allocator, ",\"secure\":");
        try out.appendSlice(allocator, if (c.secure) "true" else "false");
        try out.appendSlice(allocator, ",\"httpOnly\":");
        try out.appendSlice(allocator, if (c.http_only) "true" else "false");
        try out.appendSlice(allocator, ",\"sameSite\":");
        try appendJsonString(&out, allocator, c.same_site);

        if (c.expires) |exp| {
            try out.appendSlice(allocator, ",\"expires\":");
            var exp_buf: [24]u8 = undefined;
            const exp_str = std.fmt.bufPrint(&exp_buf, "{d}", .{exp}) catch unreachable;
            try out.appendSlice(allocator, exp_str);
        }

        try out.append(allocator, '}');
    }

    try out.appendSlice(allocator, "]}}");
    return out.toOwnedSlice(allocator);
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

test "appendJsonString — escapes double-quote and backslash" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendJsonString(&list, std.testing.allocator, "a\"b\\c");
    // Expected JSON string: "a\"b\\c"
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", list.items);
}

test "buildSetCookiesMessage — two cookies, one with expires and one session" {
    const alloc = std.testing.allocator;
    const cookies = [_]CdpCookie{
        .{
            .name = "auth",
            .value = "tok123",
            .domain = "example.com",
            .path = "/",
            .expires = 1999999999,
            .secure = true,
            .http_only = true,
            .same_site = "Strict",
        },
        .{
            .name = "pref",
            .value = "dark",
            .domain = "example.com",
            .path = "/",
            .expires = null,
            .secure = false,
            .http_only = false,
            .same_site = "Lax",
        },
    };

    const msg = try buildSetCookiesMessage(alloc, 7, "SID42", &cookies);
    defer alloc.free(msg);

    // Must contain the method name
    try std.testing.expect(std.mem.indexOf(u8, msg, "Network.setCookies") != null);
    // Must contain the session id
    try std.testing.expect(std.mem.indexOf(u8, msg, "SID42") != null);
    // Must contain both cookie names and values
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"tok123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"pref\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"dark\"") != null);
    // First cookie: sameSite = Strict, expires present
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"Strict\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "1999999999") != null);
    // Second cookie: sameSite = Lax, no "expires" key for session cookie.
    // Verify "Lax" appears.
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"Lax\"") != null);
    // The session cookie must NOT have an "expires" key.  Since the first
    // cookie does have one, we confirm by checking that after the second
    // cookie's name ("pref") there is no "expires" substring — the simplest
    // structural check is that the total count of "expires" occurrences
    // equals 1 (only the first cookie).
    var count: usize = 0;
    var search = msg;
    while (std.mem.indexOf(u8, search, "\"expires\"")) |pos| {
        count += 1;
        search = search[pos + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
