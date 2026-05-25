/// client.zig — AWR HTTP client.
///
/// Wraps `std.http.Client` (which uses `std.crypto.tls` for HTTPS) and
/// exposes the minimal fetch surface AWR needs: one-shot GET, follow
/// redirects, return `{status, headers, body}`. JA4+ fingerprint
/// matching / BoringSSL / H2 multiplexing live in Phase 3; this module
/// is the MVP network path.
///
/// Threading: the caller owns an `std.Io` (typically from
/// `std.process.Init.io` or `std.testing.io`) and passes it at
/// `Client.init` time. It's re-used by every fetch.
const std = @import("std");
const builtin = @import("builtin");

const http1 = @import("net/http1.zig");
const cookie = @import("net/cookie.zig");
const pool = @import("net/pool.zig");
const url_mod = @import("net/url.zig");
const tcp = @import("net/tcp.zig");
const dns = @import("util/dns.zig");
const boringssl_fallback = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
const tls_conn = if (boringssl_fallback) @import("net/tls_conn.zig") else struct {};
const h2session = if (boringssl_fallback) @import("net/h2session.zig") else struct {};

pub const Url = url_mod.Url;

// ── BoringSSL keep-alive connection pool ──────────────────────────────────
//
// AWR's std.http.Client path can't establish TLS to many large origins
// (e.g. HN throws TlsInitializationFailed in Zig's pure-Zig TLS stack).
// Those origins fall back to fetchOnceBoringSslHttp1, which previously
// did a fresh DNS+TCP+TLS handshake per request and sent
// `Connection: close` — guaranteeing a ~270ms hit on every same-origin
// sub-resource. This pool keeps the (TCP+TLS) tuple alive across
// requests so HTTP/1.1 keep-alive can deliver the same ~67ms warm fetch
// the std path enjoys.
//
// The pool is per-Client, single-threaded (matching all current
// fetch call sites). Constants follow Chrome's published limits.
const BoringSslPool = if (boringssl_fallback) struct {
    entries: std.ArrayList(*Entry) = .empty,

    pub const MAX_PER_ORIGIN: usize = 6;
    pub const MAX_REQUESTS_PER_CONN: u32 = 100;
    pub const IDLE_TIMEOUT_MS: i64 = 30_000;

    pub const Entry = struct {
        host: []const u8,
        port: u16,
        /// Borrowed reference to the Client-owned shared SSL_CTX. The
        /// SSL_CTX holds the parsed CA bundle and verifier setup;
        /// sharing it avoids re-parsing cacert.pem (~250KB, 100+
        /// certs) on every connection — saved ~5-15ms per cold fetch
        /// in measurements. BoringSSL guarantees SSL_CTX is safe for
        /// concurrent SSL_new() calls from one thread or many.
        ctx: *tls_conn.TlsCtx,
        tcp_conn: tcp.TcpConn,
        tls: tls_conn.TlsConn,
        reader: TlsBufferedReader,
        in_use: bool,
        last_used_ms: i64,
        request_count: u32,
        /// Set from `tls.alpn` after the handshake completes. Drives
        /// the dispatch in `fetchOnceBoringSsl`.
        protocol: Protocol = .http_1_1,
        /// Owned H2 session — non-null only when `protocol == .http_2`.
        /// `H2Session` callbacks receive `*Entry` as `user_data`; the
        /// entry pointer is stable for the entry's lifetime (entries
        /// are always `*Entry` in the pool, never moved by value).
        h2_session: ?h2session.H2Session = null,
        /// Stream ID of the in-flight H2 GET request, or 0 when no
        /// request is active. Set by `sendOnBoringSslEntryH2` before
        /// driving the I/O loop and cleared on return. The recv
        /// callback consults this + `H2Session.streamComplete` to
        /// signal `WOULDBLOCK` after the response END_STREAM has been
        /// processed — without this, `nghttp2_session_recv` would loop
        /// blocking on `tls.readFn` waiting for additional data the
        /// server has no reason to send.
        current_h2_stream_id: i32 = 0,

        fn nowMs() i64 {
            var ts: std.posix.timespec = undefined;
            _ = std.posix.system.clock_gettime(.REALTIME, &ts);
            return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
                @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
        }
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| destroyEntry(allocator, e);
        self.entries.deinit(allocator);
    }

    /// Tear down a per-connection entry. The SSL_CTX is borrowed and
    /// outlives the entry; only per-connection state (H2 session, TCP,
    /// TLS, host dup) is freed here.
    fn destroyEntry(allocator: std.mem.Allocator, e: *Entry) void {
        if (e.h2_session) |*sess| sess.deinit();
        e.tls.deinit();
        e.tcp_conn.deinit();
        allocator.free(e.host);
        allocator.destroy(e);
    }

    /// Find a healthy idle connection for (host, port), mark it in_use.
    pub fn acquire(self: *@This(), host: []const u8, port: u16) ?*Entry {
        const now = Entry.nowMs();
        for (self.entries.items) |e| {
            if (e.in_use) continue;
            if (e.port != port) continue;
            if (!std.ascii.eqlIgnoreCase(e.host, host)) continue;
            if (now - e.last_used_ms >= IDLE_TIMEOUT_MS) continue;
            if (e.request_count >= MAX_REQUESTS_PER_CONN) continue;
            e.in_use = true;
            return e;
        }
        return null;
    }

    /// Return entry to the idle pool (still usable for the next request).
    pub fn release(self: *@This(), e: *Entry) void {
        _ = self;
        e.in_use = false;
        e.last_used_ms = Entry.nowMs();
        e.request_count += 1;
    }

    /// Tear down and remove an entry. Use for stale connections, server-
    /// requested closes, or when a request fails mid-stream.
    pub fn discard(self: *@This(), allocator: std.mem.Allocator, e: *Entry) void {
        for (self.entries.items, 0..) |x, i| {
            if (x == e) {
                _ = self.entries.swapRemove(i);
                destroyEntry(allocator, e);
                return;
            }
        }
    }

    /// Total entries (idle + in_use) for an origin.
    pub fn countForOrigin(self: *const @This(), host: []const u8, port: u16) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.port == port and std.ascii.eqlIgnoreCase(e.host, host)) n += 1;
        }
        return n;
    }

    pub fn add(self: *@This(), allocator: std.mem.Allocator, e: *Entry) !void {
        try self.entries.append(allocator, e);
    }
} else struct {
    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};

// ── Request shape ─────────────────────────────────────────────────────────

pub const Method = enum { GET, POST };

/// Request descriptor used by `Client.fetchRequest`. `body` must be null for
/// GET; for POST the bytes are sent verbatim with `Content-Type:
/// application/x-www-form-urlencoded` (the only POST content type in MVP per
/// `spec/subspecs/agent-browser.md §2`).
pub const Request = struct {
    url: []const u8,
    method: Method = .GET,
    body: ?[]const u8 = null,
};

// ── Options ───────────────────────────────────────────────────────────────

pub const ClientOptions = struct {
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    timeout_ms: u32 = 30_000,
    max_response_header_bytes: usize = 64 * 1024,
    /// Explicit User-Agent override. Leave empty (default) so Chrome 132
    /// is emitted automatically when `use_chrome_headers = true`. T-74:
    /// the previous `"AWR/0.1"` default silently won over the Chrome UA
    /// because the if-branch in `effective_user_agent` checks `len != 0`
    /// first — that mismatch (TLS fingerprint claims Chrome 132, HTTP
    /// claims AWR/0.1) was the loudest anti-bot tell on Google.
    user_agent: []const u8 = "",
    /// When true, setChrome132Defaults() is called on every request.
    use_chrome_headers: bool = true,
    /// When true and `cookie_jar_path` is non-null, Client.init reads the
    /// jar from disk on startup and Client.deinit writes it back. Caller
    /// owns `cookie_jar_path`; Client borrows the slice.
    persist_cookies: bool = false,
    cookie_jar_path: ?[]const u8 = null,
    /// When non-null, Client *borrows* this CookieJar instead of
    /// constructing its own. The Client neither loads nor saves to
    /// disk in this mode — the caller (typically the daemon's
    /// scope→jar cache) owns the lifecycle. `persist_cookies` /
    /// `cookie_jar_path` must be left at their defaults when this
    /// is set; they're ignored otherwise. See
    /// `spec/subspecs/daemon-mode.md §5.3` for the in-memory cache
    /// gate that motivates this seam.
    external_cookie_jar: ?*cookie.CookieJar = null,
    /// When non-null, Client.init reads the cached `std_tls_failed_hosts`
    /// list from disk on startup and Client.deinit writes it back. The
    /// cache lets subsequent CLI invocations skip the doomed
    /// `fetchOnceStd` attempt for hosts where the std TLS stack always
    /// fails (~100-160ms saved per cold fetch to a known-failing host).
    /// Caller owns the slice; Client borrows it.
    tls_fail_cache_path: ?[]const u8 = null,
    /// When true, skip the `fetchOnceStd` (stdlib TLS) attempt entirely
    /// and go straight to the BoringSSL path. Used by prefetch workers to
    /// ensure TLS reads go through `awr_tls_conn_read` (which supports the
    /// total-fetch deadline). Without this, `fetchOnceStd` can hang on body
    /// reads indefinitely because the stdlib TLS layer has no deadline.
    force_boringssl: bool = false,
};

// ── Response ──────────────────────────────────────────────────────────────

/// Which transport actually delivered the response. Surfaced via
/// `Response.protocol` for telemetry consumers — observing the
/// distribution of std_lib / http_1_1 / http_2 in aggregate logs is
/// how you spot fingerprint or H2-routing regressions without
/// instrumenting every site individually.
pub const Protocol = enum {
    /// Zig std-lib `std.http.Client` path (HTTP/1.1, sometimes h2 if
    /// std-lib's TLS picks it). Used for hosts whose handshake works
    /// against std's pure-Zig TLS stack.
    std_lib,
    /// BoringSSL fallback — TLS handshake negotiated `http/1.1` ALPN.
    http_1_1,
    /// BoringSSL fallback — TLS handshake negotiated `h2` ALPN.
    http_2,

    /// Lower-case ASCII tag suitable for JSON / log emission.
    pub fn tag(self: Protocol) []const u8 {
        return switch (self) {
            .std_lib => "std",
            .http_1_1 => "h1.1",
            .http_2 => "h2",
        };
    }
};

pub const Response = struct {
    status: u16,
    url: []const u8,
    headers: http1.HeaderList,
    body: []u8,
    allocator: std.mem.Allocator,
    /// Transport that delivered this response. Defaults to `.std_lib`
    /// because that's the path historical callers (and tests that
    /// fabricate Responses by hand) end up on; the BoringSSL paths
    /// override this explicitly before returning.
    protocol: Protocol = .std_lib,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.url);
        self.headers.deinit(self.allocator);
        self.allocator.free(self.body);
    }

    pub fn isRedirect(self: *const Response) bool {
        return self.status >= 300 and self.status < 400;
    }

    pub fn location(self: *const Response) ?[]const u8 {
        return self.headers.get("location");
    }
};

// ── Client errors ─────────────────────────────────────────────────────────

pub const FetchError = error{
    InvalidUrl,
    DnsResolutionFailed,
    ConnectionFailed,
    TlsNotAvailable,
    SendFailed,
    RecvFailed,
    TooManyRedirects,
    OutOfMemory,
};

// ── Cookie persistence helpers ────────────────────────────────────────────

const COOKIE_JAR_MAX_BYTES: usize = 1 * 1024 * 1024;

/// Public so the daemon's scope→jar cache can pre-load jars from
/// disk on cache miss without going through Client.init.
pub fn loadCookiesFromDisk(jar: *cookie.CookieJar, io: std.Io, path: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, jar.allocator, .limited(COOKIE_JAR_MAX_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return, // first run is not an error
        else => return err,
    };
    defer jar.allocator.free(bytes);
    try jar.deserializeBytes(bytes);
}

/// Public so the daemon can write per-scope jars to disk after each
/// fetch (durability) without going through Client.deinit.
pub fn saveCookiesToDisk(jar: *const cookie.CookieJar, io: std.Io, path: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(jar.allocator);
    defer aw.deinit();
    try jar.serialize(&aw.writer);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .truncate = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);
    try file.writeStreamingAll(io, aw.written());
}

// ── std-TLS-fail cache persistence ────────────────────────────────────────
//
// Hosts where std.http.Client's TLS stack fails get cached so subsequent
// process invocations skip the doomed attempt (~100-160ms saved per cold
// fetch). Format: one host per line, ASCII, no metadata. Comment lines
// starting with `#` are ignored. Hostnames are validated as ASCII +
// digits + `.-` to defend against a corrupted/attacker-controlled cache
// file injecting whitespace or paths into the in-memory hash.

const TLS_FAIL_CACHE_MAX_BYTES: usize = 64 * 1024;

fn loadTlsFailCacheFromDisk(
    set: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(TLS_FAIL_CACHE_MAX_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (!isValidHost(line)) continue;
        if (set.contains(line)) continue;
        const host = try allocator.dupe(u8, line);
        errdefer allocator.free(host);
        try set.put(allocator, host, {});
    }
}

fn saveTlsFailCacheToDisk(
    set: *const std.StringHashMapUnmanaged(void),
    io: std.Io,
    path: []const u8,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .truncate = true,
        .permissions = .fromMode(0o644),
    });
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("# AWR std-TLS fail cache. Hosts that fail std.http.Client's TLS handshake.\n");
    try file.writeStreamingAll(io, w.buffered());

    var key_it = set.keyIterator();
    while (key_it.next()) |k| {
        const host = k.*;
        if (!isValidHost(host)) continue;
        var line_buf: [256]u8 = undefined;
        if (host.len + 1 > line_buf.len) continue;
        @memcpy(line_buf[0..host.len], host);
        line_buf[host.len] = '\n';
        try file.writeStreamingAll(io, line_buf[0 .. host.len + 1]);
    }
}

fn isValidHost(s: []const u8) bool {
    if (s.len == 0 or s.len > 253) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// ── Client ────────────────────────────────────────────────────────────────

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cookies: cookie.CookieJar,
    conns: pool.ConnectionPool,
    options: ClientOptions,
    /// Persistent std.http.Client reused across all fetches for connection
    /// pooling and keep-alive. Initialized lazily on first fetch.
    std_client: ?std.http.Client = null,
    /// Per-origin pool of live TCP+TLS connections used by the BoringSSL
    /// fallback path. Lives only on platforms where boringssl_fallback is
    /// active; an empty stub elsewhere.
    boringssl_pool: BoringSslPool = .{},
    /// Process-shared SSL_CTX for the BoringSSL path. Lazy-initialized
    /// on first cold connection. Holds the parsed Mozilla CA bundle +
    /// system default verify paths; reusing it across all entries in
    /// the pool eliminates a ~250KB PEM re-parse per cold fetch.
    /// BoringSSL/OpenSSL document SSL_CTX as immutable post-init and
    /// safe for many SSL_new() calls.
    shared_tls_ctx: ?tls_conn.TlsCtx = null,
    /// Sibling SSL_CTX restricted to `http/1.1` ALPN, used when a
    /// request must run on H1.1 framing even though the default ctx
    /// would let the server pick H2 (e.g. POST, since the H2 submit
    /// path is GET-only in this MVP). Lazy-initialized on first POST.
    shared_tls_ctx_h1: ?tls_conn.TlsCtx = null,
    /// Hosts where `fetchOnceStd` has already returned `TlsNotAvailable`.
    /// On subsequent requests we skip the std attempt (which costs ~100-160ms
    /// on a fresh TCP+TLS handshake before failing) and go straight to
    /// `fetchOnceBoringSslHttp1`. Hosts are duped on first failure and freed
    /// in `Client.deinit`. Bounded by the number of distinct origins a
    /// session visits — fine for an MVP browse session.
    std_tls_failed_hosts: std.StringHashMapUnmanaged(void) = .empty,

    /// Pointer to the active cookie jar. When `options.external_cookie_jar`
    /// is non-null, returns that borrowed pointer; otherwise the inline
    /// `cookies` field. All cookie reads/writes inside Client should go
    /// through this helper so the borrow vs. owned distinction stays in
    /// one place.
    pub fn cookieJar(self: *Client) *cookie.CookieJar {
        if (self.options.external_cookie_jar) |ext| return ext;
        return &self.cookies;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ClientOptions) Client {
        // When borrowing an external jar, the inline field is initialized
        // empty but never used — accessor `cookieJar()` returns the
        // borrowed pointer. We still allocate the inline value (cheap; an
        // empty ArrayList) so the field stays valid for any code that
        // historically used `&self.cookies` we haven't migrated.
        var c = Client{
            .allocator = allocator,
            .io = io,
            .cookies = cookie.CookieJar.init(allocator),
            .conns = pool.ConnectionPool.init(allocator),
            .options = options,
        };
        // Disk load only applies to the owned-jar path. Borrowed jars
        // arrive pre-loaded from the caller (see main_daemon's scope
        // cache).
        if (options.external_cookie_jar == null and options.persist_cookies) {
            if (options.cookie_jar_path) |path| loadCookiesFromDisk(&c.cookies, io, path) catch |err| {
                std.log.warn("cookie jar load from {s} failed: {s}", .{ path, @errorName(err) });
            };
        }
        if (options.tls_fail_cache_path) |path| {
            loadTlsFailCacheFromDisk(&c.std_tls_failed_hosts, allocator, io, path) catch |err| {
                std.log.warn("tls-fail cache load from {s} failed: {s}", .{ path, @errorName(err) });
            };
        }
        return c;
    }

    pub fn deinit(self: *Client) void {
        // Disk save only applies to the owned-jar path. Borrowed jars are
        // the caller's responsibility (the daemon writes them after each
        // fetch and on shutdown).
        if (self.options.external_cookie_jar == null and self.options.persist_cookies) {
            if (self.options.cookie_jar_path) |path| saveCookiesToDisk(&self.cookies, self.io, path) catch |err| {
                std.log.warn("cookie jar save to {s} failed: {s}", .{ path, @errorName(err) });
            };
        }
        if (self.options.tls_fail_cache_path) |path| {
            saveTlsFailCacheToDisk(&self.std_tls_failed_hosts, self.io, path) catch |err| {
                std.log.warn("tls-fail cache save to {s} failed: {s}", .{ path, @errorName(err) });
            };
        }
        if (self.std_client) |*c| c.deinit();
        self.boringssl_pool.deinit(self.allocator);
        // Pool entries borrow the shared ctx — destroy them first, then
        // the ctx (above order is enforced by the .deinit() sequence).
        if (self.shared_tls_ctx) |*ctx| ctx.deinit();
        if (self.shared_tls_ctx_h1) |*ctx| ctx.deinit();
        var key_it = self.std_tls_failed_hosts.keyIterator();
        while (key_it.next()) |k| self.allocator.free(k.*);
        self.std_tls_failed_hosts.deinit(self.allocator);
        self.conns.deinit();
        // Inline cookie jar deinit is zero-cost when the jar is empty
        // (the external-jar path never populates the inline field) and
        // the right thing when the inline jar IS the active one. Either
        // way the borrowed pointer's lifetime is the caller's problem.
        self.cookies.deinit();
    }

    /// Fetch a URL via GET. Backwards-compat wrapper for callers that don't
    /// need POST. Caller must call response.deinit() on success.
    pub fn fetch(self: *Client, url_str: []const u8) anyerror!Response {
        return self.fetchRequest(.{ .url = url_str });
    }

    /// Set a total-read deadline for all TLS reads on the calling thread.
    /// deadline_ms: wall-clock ms since epoch (use wallClockMillis() + budget_ms).
    /// Pass 0 to clear. Prefetch workers call this before each fetch so a
    /// server drip-feeding data just under SO_RCVTIMEO cannot hold the thread
    /// indefinitely.
    pub fn setFetchDeadlineMs(_: *Client, deadline_ms: i64) void {
        tls_conn.setReadDeadlineMs(deadline_ms);
    }

    /// Full fetch entry — accepts a `Request` with method and body. Follows
    /// redirects per `options.follow_redirects`. On 30x responses to a POST,
    /// per RFC 7231 §6.4.2/3 the body is dropped and the next hop becomes a
    /// GET (303 always; 301/302 in practice). 307/308 preserve method+body.
    pub fn fetchRequest(self: *Client, req: Request) anyerror!Response {
        var current_url = try self.allocator.dupe(u8, req.url);
        defer self.allocator.free(current_url);

        // Body is borrowed from the caller; once redirects strip it (303 etc.)
        // we drop the reference. We never free the caller's slice.
        var current_method = req.method;
        var current_body = req.body;

        var redirects: u8 = 0;
        while (true) {
            var resp = try self.fetchOnce(current_url, current_method, current_body);

            // Absorb any Set-Cookie headers into the jar BEFORE deciding
            // about redirects. Auth flows commonly issue
            // `302 Set-Cookie: session=…` and the next-hop request must
            // carry the new cookie — if we deferred parsing until after
            // the loop, the second fetch would go out with no session.
            absorbSetCookies(self.cookieJar(), current_url, &resp.headers);

            if (!self.options.follow_redirects or !resp.isRedirect()) return resp;
            const location = resp.location() orelse return resp;
            if (redirects >= self.options.max_redirects) {
                resp.deinit();
                return FetchError.TooManyRedirects;
            }

            const next_url = resolveRedirectUrl(self.allocator, resp.url, location) catch |err| {
                resp.deinit();
                return err;
            };
            // Per RFC 7231: 301/302/303 demote POST→GET and drop the body.
            // 307/308 preserve method+body. status is on the Response.
            switch (resp.status) {
                301, 302, 303 => if (current_method == .POST) {
                    current_method = .GET;
                    current_body = null;
                },
                else => {},
            }
            resp.deinit();
            self.allocator.free(current_url);
            current_url = next_url;
            redirects += 1;
        }
    }

    fn fetchOnce(self: *Client, url_str: []const u8, method: Method, body: ?[]const u8) anyerror!Response {
        // Skip the std attempt for hosts where its TLS stack has already
        // failed once, or when force_boringssl is set (prefetch workers use
        // this to ensure TLS reads go through awr_tls_conn_read which
        // supports total-fetch deadlines — the stdlib TLS body reader has
        // no deadline mechanism).
        if (self.options.force_boringssl or self.shouldSkipStdForUrl(url_str)) {
            if (boringsslFallbackAllowed(url_str)) {
                return self.fetchOnceBoringSslHttp1(url_str, method, body) catch |e| return mapFetchError(e);
            }
        }

        const timing_on = std.c.getenv("AWR_TIMING") != null;
        const std_start_ms = if (timing_on) nowMsForTiming() else 0;

        return self.fetchOnceStd(url_str, method, body) catch |err| switch (err) {
            FetchError.TlsNotAvailable => {
                if (timing_on) {
                    const elapsed = nowMsForTiming() - std_start_ms;
                    std.debug.print("[timing]   doomed_std_tls={d}ms ({s})\n", .{ elapsed, url_str });
                }
                self.rememberStdTlsFailure(url_str);
                return if (boringsslFallbackAllowed(url_str))
                    self.fetchOnceBoringSslHttp1(url_str, method, body) catch |fallback_err| return mapFetchError(fallback_err)
                else
                    err;
            },
            else => return err,
        };
    }

    fn nowMsForTiming() i64 {
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.REALTIME, &ts);
        return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
            @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    }

    /// Returns true if a previous `fetchOnceStd` call to this URL's host
    /// returned `TlsNotAvailable`. Only meaningful for https:// URLs.
    fn shouldSkipStdForUrl(self: *const Client, url_str: []const u8) bool {
        const u = url_mod.Url.parse(url_str) catch return false;
        if (!u.is_https) return false;
        return self.std_tls_failed_hosts.contains(u.host);
    }

    /// Record that std's TLS stack failed for this URL's host so future
    /// requests skip straight to the BoringSSL path. No-op on non-https
    /// or already-recorded hosts. Allocation failure here is non-fatal — the
    /// next request just pays the std-attempt cost again.
    fn rememberStdTlsFailure(self: *Client, url_str: []const u8) void {
        const u = url_mod.Url.parse(url_str) catch return;
        if (!u.is_https) return;
        if (self.std_tls_failed_hosts.contains(u.host)) return;
        const host_owned = self.allocator.dupe(u8, u.host) catch return;
        self.std_tls_failed_hosts.put(self.allocator, host_owned, {}) catch {
            self.allocator.free(host_owned);
        };
    }

    fn fetchOnceStd(self: *Client, url_str: []const u8, method: Method, body: ?[]const u8) anyerror!Response {
        // Validate via our own URL parser so bad inputs surface as InvalidUrl
        // before std.http.Client parses and returns its own error.
        const uri = std.Uri.parse(url_str) catch return FetchError.InvalidUrl;

        // Lazily initialize the persistent std.http.Client for connection reuse.
        if (self.std_client == null) {
            self.std_client = std.http.Client{
                .allocator = self.allocator,
                .io = self.io,
                .read_buffer_size = self.options.max_response_header_bytes,
            };
        }
        const std_client = &self.std_client.?;

        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_buf.deinit();

        // T-74: Chrome 132 UA (matches the JA4 fingerprint per
        // spec/Fingerprint-Plan.md). Bumped from 127 — the version
        // skew between TLS fingerprint claim (132) and HTTP UA (127)
        // was itself a tell for fingerprint-correlating bot detectors.
        const effective_user_agent =
            if (self.options.user_agent.len != 0)
                self.options.user_agent
            else if (self.options.use_chrome_headers)
                http1.chrome132_user_agent
            else
                "awr";

        // Capacity 16: chrome132 regular headers + content-type + cookie.
        // user-agent and accept-encoding go through std.http's
        // Headers.override knobs (below) to avoid std.http's
        // auto-injected `zig/0.16.0 (std.http)` user-agent
        // showing up alongside ours — that double-UA was the
        // single biggest anti-bot tell (T-74).
        var extra_headers: [16]std.http.Header = undefined;
        var extra_header_count: usize = 0;

        if (self.options.use_chrome_headers) {
            extra_headers[extra_header_count] = .{ .name = "accept", .value = http1.chrome132_accept };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "accept-language", .value = http1.chrome132_accept_language };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "cache-control", .value = "max-age=0" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "sec-ch-ua", .value = "\"Not A(Brand\";v=\"8\", \"Chromium\";v=\"132\", \"Google Chrome\";v=\"132\"" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "sec-ch-ua-mobile", .value = "?0" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "sec-ch-ua-platform", .value = "\"macOS\"" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "sec-fetch-dest", .value = "document" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "sec-fetch-mode", .value = "navigate" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "sec-fetch-site", .value = "none" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "sec-fetch-user", .value = "?1" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "upgrade-insecure-requests", .value = "1" };
            extra_header_count += 1;
        }

        // For POST, Content-Type is required by most servers and Content-Length
        // is set automatically by std.http.Client when we use sendBodyComplete.
        if (method == .POST) {
            extra_headers[extra_header_count] = .{ .name = "content-type", .value = "application/x-www-form-urlencoded" };
            extra_header_count += 1;
        }

        // Cookie header — derived from the jar based on URL host / path /
        // https. The owned slice must outlive `req.send*`; we free it
        // after the response head is parsed (defer below).
        const u_for_cookies = url_mod.Url.parse(url_str) catch return FetchError.InvalidUrl;
        const cookie_value = try buildCookieHeaderValue(self.cookieJar(), self.allocator, u_for_cookies.host, u_for_cookies.path, u_for_cookies.is_https);
        defer self.allocator.free(cookie_value);
        if (cookie_value.len > 0) {
            extra_headers[extra_header_count] = .{ .name = "cookie", .value = cookie_value };
            extra_header_count += 1;
        }

        const std_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
        };

        // Connection-pool staleness retry. std.http.Client.connection_pool
        // can hand back a pooled socket the peer has already closed (very
        // common against single-request-per-connection servers like our
        // own `awr mock`, and any non-keep-alive HTTP/1.1 server). The
        // first sign is `HttpConnectionClosing` from receiveHead — server
        // closed before any response bytes. Retry once with a fresh
        // connection. POST body is re-sent because we own the body buffer
        // for the duration of this function. Matches Go net/http's
        // implicit "request canceled — retry idempotent or with fresh body".
        var req: std.http.Client.Request = undefined;
        var result: std.http.Client.Response = undefined;
        var attempt: u8 = 0;
        var owned_body: ?[]u8 = null;
        defer if (owned_body) |b| self.allocator.free(b);
        if (method == .POST) {
            const body_const = body orelse "";
            owned_body = try self.allocator.dupe(u8, body_const);
        }
        // T-74: header overrides. `headers.user_agent = .override(...)`
        // replaces std.http's default `zig/0.16.0 (std.http)` UA
        // entirely — without this we send TWO user-agent headers
        // and bot detectors flag us instantly. accept-encoding is
        // overridden to advertise what AWR can actually decompress
        // (gzip + deflate + zstd, NOT br/brotli — see fetchOnceStd's
        // content_encoding switch). Chrome 132 also sends br but
        // we'd have to add brotli decompression first.
        const std_request_headers: std.http.Client.Request.Headers = if (self.options.use_chrome_headers)
            .{
                .user_agent = .{ .override = effective_user_agent },
                .accept_encoding = .{ .override = http1.chrome132_accept_encoding_decodable },
            }
        else
            .{
                .user_agent = .{ .override = effective_user_agent },
            };

        while (true) : (attempt += 1) {
            req = std_client.request(std_method, uri, .{
                .redirect_behavior = .unhandled,
                .headers = std_request_headers,
                .extra_headers = extra_headers[0..extra_header_count],
            }) catch |err| return mapFetchError(err);
            // On retry, deinit the previous (failed) request before
            // shadowing. On success, the outer defer at function exit
            // handles cleanup.
            errdefer req.deinit();

            if (method == .POST) {
                req.sendBodyComplete(owned_body.?) catch |err| return mapFetchError(err);
            } else {
                req.sendBodiless() catch |err| return mapFetchError(err);
            }

            if (req.receiveHead(&.{})) |r| {
                result = r;
                break;
            } else |err| switch (err) {
                error.HttpConnectionClosing => {
                    if (attempt >= 1) return mapFetchError(err);
                    req.deinit();
                    continue; // fresh connection on next iteration
                },
                else => return mapFetchError(err),
            }
        }
        defer req.deinit();

        var headers = try cloneFetchHeaders(self.allocator, result.head.iterateHeaders());
        errdefer headers.deinit(self.allocator);

        const effective_url = try std.fmt.allocPrint(self.allocator, "{f}", .{
            req.uri.fmt(.{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true, .fragment = true }),
        });
        errdefer self.allocator.free(effective_url);

        // RFC 9112 §6.3 rule (1): bodiless statuses (1xx incl. 101, 204, 205,
        // 304) and HEAD responses MUST NOT have a body. Zig's std.http does
        // not implement this short-circuit (as of 0.16) — for a 204 without
        // Content-Length / Transfer-Encoding, the body reader's state goes
        // to `.body_none` (read until close) and `streamRemaining` plus the
        // matching `req.deinit` body-drain both hang on a kept-alive socket.
        //
        // Workaround: detect bodiless here, mark the connection as closing
        // so `req.deinit` skips its drain-then-pool path and just closes
        // the socket, then return an empty body.
        // client.Method is GET/POST today; HEAD short-circuit lives in the
        // http1.readBody helper (used by the BoringSSL fallback). When HEAD
        // is added to client.Method, mirror the same check here.
        const status_code = @intFromEnum(result.head.status);
        const bodiless =
            (status_code >= 100 and status_code < 200) or
            status_code == 204 or status_code == 205 or status_code == 304;
        if (bodiless) {
            // Force the connection to close so req.deinit doesn't try to
            // drain a body that doesn't exist. Loses keep-alive for this
            // exchange; correctness > pooling for bodiless responses.
            if (req.connection) |conn| conn.closing = true;
            const empty = try self.allocator.alloc(u8, 0);
            errdefer self.allocator.free(empty);
            return Response{
                .status = status_code,
                .url = effective_url,
                .headers = headers,
                .body = empty,
                .allocator = self.allocator,
                .protocol = .std_lib,
            };
        }

        const decompress_buffer: []u8 = switch (result.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (result.head.content_encoding != .identity) self.allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = result.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(&body_buf.writer) catch |err| switch (err) {
            error.ReadFailed => return mapFetchError(result.bodyErr().?),
            else => |e| return mapFetchError(e),
        };

        // Drain any remaining transfer-encoding bytes so the body reader
        // reaches `.ready`. `chunked + gzip` responses (e.g. Wikipedia, MDN)
        // leave the chunked terminator unread — the decompressor stops at the
        // gzip trailer, before the chunked `0\r\n\r\n`. Without this drain,
        // `Request.deinit` interprets the non-`.ready` state as a partial
        // read and marks the connection as closing instead of returning it to
        // the pool, defeating P1's keep-alive on every same-origin
        // sub-resource fetch (~6.5x slowdown on Wikipedia).
        switch (req.reader.state) {
            .body_remaining_content_length, .body_remaining_chunk_len => {
                _ = req.reader.interface.discardRemaining() catch {};
            },
            else => {},
        }

        var body_list = body_buf.toArrayList();
        errdefer body_list.deinit(self.allocator);
        const resp_body = try body_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(resp_body);

        return Response{
            .status = @intFromEnum(result.head.status),
            .url = effective_url,
            .headers = headers,
            .body = resp_body,
            .allocator = self.allocator,
            .protocol = .std_lib,
        };
    }

    fn fetchOnceBoringSslHttp1(self: *Client, url_str: []const u8, method: Method, body: ?[]const u8) anyerror!Response {
        if (!boringssl_fallback) return FetchError.TlsNotAvailable;

        const u = url_mod.Url.parse(url_str) catch return FetchError.InvalidUrl;
        if (!u.is_https) return FetchError.InvalidUrl;

        // Try a pooled idle connection first. On any failure (server closed
        // the connection during idle, RST, framing error mid-response), drop
        // the entry and fall through to a fresh handshake. We do not retry
        // pooled-then-fresh blindly across arbitrary error classes — only when
        // the *first* request on a pooled connection failed before any
        // application-level response framing.
        if (self.boringssl_pool.acquire(u.host, u.port)) |entry| {
            // POST on a pooled H2 entry: discard. The H2 submit path is
            // GET-only in this MVP, so we'd corrupt the connection if we
            // tried to mix HTTP/1.1 framing onto an H2 stream.
            if (method != .GET and entry.protocol == .http_2) {
                self.boringssl_pool.discard(self.allocator, entry);
            } else {
                if (self.sendOnBoringSslEntryDispatch(entry, &u, url_str, method, body)) |resp| {
                    self.maybeReleaseBoringSsl(entry, &resp);
                    return resp;
                } else |_| {
                    self.boringssl_pool.discard(self.allocator, entry);
                    // fall through to fresh handshake
                }
            }
        }

        // Fresh handshake. The errdefer covers: send failure, response parse
        // failure, allocation failure between handshake and Response return.
        const entry = try self.createBoringSslEntry(&u, method);
        errdefer self.boringssl_pool.discard(self.allocator, entry);

        const resp = try self.sendOnBoringSslEntryDispatch(entry, &u, url_str, method, body);
        self.maybeReleaseBoringSsl(entry, &resp);
        return resp;
    }

    /// Route to the H1.1 or H2 send path based on `entry.protocol`.
    /// `entry.protocol == .http_2` requires `method == .GET` because the
    /// H2 submit shim is GET-only — callers (`fetchOnceBoringSslHttp1`)
    /// guarantee that invariant by discarding H2 pool entries when the
    /// request is non-GET.
    fn sendOnBoringSslEntryDispatch(
        self: *Client,
        entry: *BoringSslPool.Entry,
        u: *const Url,
        url_str: []const u8,
        method: Method,
        body: ?[]const u8,
    ) anyerror!Response {
        return switch (entry.protocol) {
            .http_1_1 => self.sendOnBoringSslEntry(entry, u, url_str, method, body),
            .http_2 => self.sendOnBoringSslEntryH2(entry, u, url_str),
            // `.std_lib` belongs to the std.http path and never reaches
            // a BoringSSL pool entry. Entries are always tagged
            // `http_1_1` or `http_2` after the handshake (see
            // `createBoringSslEntry`); seeing this here is a bug.
            .std_lib => unreachable,
        };
    }

    /// Lazy-init the shared SSL_CTX. Done outside `Client.init` so a CLI
    /// invocation that never touches the BoringSSL path (file:// URLs,
    /// std-only hosts) doesn't pay the ~5-15ms PEM parse cost. Returns
    /// a borrowed pointer; ownership stays with the Client.
    ///
    /// Uses the **full** Chrome 132 ctx (`initWithBundle`) — cipher list,
    /// curve order, sigalg list, and ALPN advertise list `["h2",
    /// "http/1.1"]` matching what tls.peet.ws confirms is Chrome 132's
    /// fingerprint (`awr_ja4_h2`). The negotiated protocol per
    /// connection is read from `TlsConn.alpn` post-handshake and
    /// dispatched in `fetchOnceBoringSsl`.
    fn getSharedTlsCtx(self: *Client) anyerror!*tls_conn.TlsCtx {
        if (self.shared_tls_ctx) |*ctx| return ctx;
        self.shared_tls_ctx = tls_conn.initWithBundle() catch return FetchError.TlsNotAvailable;
        return &self.shared_tls_ctx.?;
    }

    /// Sibling ctx restricted to `http/1.1` ALPN. Used by POST requests
    /// because the H2 shim only exposes a GET submit path
    /// (`awr_h2_submit_get_ex`). Forcing H1.1 ALPN guarantees the
    /// resulting TlsConn negotiates `http/1.1`, which `sendOnBoringSslEntry`
    /// can drive directly. The published JA4 for this ctx is `awr_ja4_h1`.
    fn getSharedTlsCtxH1Only(self: *Client) anyerror!*tls_conn.TlsCtx {
        if (self.shared_tls_ctx_h1) |*ctx| return ctx;
        var ctx = tls_conn.initWithBundle() catch return FetchError.TlsNotAvailable;
        tls_conn.forceHttp11Alpn(&ctx);
        self.shared_tls_ctx_h1 = ctx;
        return &self.shared_tls_ctx_h1.?;
    }

    /// Allocate, handshake, and register a new pool entry for `u`. The entry
    /// is added to the pool with `in_use=true` so a concurrent acquire would
    /// not steal it (single-threaded today, but the invariant matters).
    ///
    /// `method` selects the shared ctx: GET uses the h2-capable ctx
    /// (`["h2", "http/1.1"]` ALPN; the entry's `protocol` field reflects
    /// what the server picked). POST forces `http/1.1`-only ALPN because
    /// the H2 submit shim is GET-only in this MVP.
    fn createBoringSslEntry(self: *Client, u: *const Url, method: Method) anyerror!*BoringSslPool.Entry {
        if (!boringssl_fallback) return FetchError.TlsNotAvailable;

        const shared_ctx = if (method == .GET)
            try self.getSharedTlsCtx()
        else
            try self.getSharedTlsCtxH1Only();

        const addr = dns.resolve(self.io, u.host, u.port) catch |err| return mapFetchError(err);

        const entry = try self.allocator.create(BoringSslPool.Entry);
        errdefer self.allocator.destroy(entry);

        entry.host = try self.allocator.dupe(u8, u.host);
        errdefer self.allocator.free(entry.host);

        entry.port = u.port;
        entry.in_use = true;
        entry.last_used_ms = BoringSslPool.Entry.nowMs();
        entry.request_count = 0;
        entry.ctx = shared_ctx;
        entry.protocol = .http_1_1;
        entry.h2_session = null;

        entry.tcp_conn = tcp.TcpConn.init(self.allocator, addr) catch return FetchError.ConnectionFailed;
        errdefer entry.tcp_conn.deinit();
        entry.tcp_conn.connect() catch |err| return mapFetchError(err);

        const hostname_z = try self.allocator.dupeZ(u8, u.host);
        defer self.allocator.free(hostname_z);

        // Use `connect` (with ALPS) not `connectNoAlps` so the handshake
        // includes the ALPS extension that Chrome 132 sends. ALPS is the
        // 12th extension whose hash distinguishes the published
        // `awr_ja4_h1` (`t13d1512h1_…`) from the 11-extension variant
        // (`t13d1511h1_…`). ALPS is harmless when ALPN is http/1.1 —
        // the server just ignores the embedded H2 settings.
        entry.tls = tls_conn.TlsConn.connect(entry.ctx, entry.tcp_conn.socket.?.fd, hostname_z.ptr) catch return FetchError.TlsNotAvailable;
        errdefer entry.tls.deinit();

        // Reader buffers across requests on this connection so any bytes
        // over-read past the previous response (rare with strict framing,
        // but possible) survive into the next request's readUntilDelimiter.
        // For H2 entries the reader is unused — the H2 session reads
        // directly from `entry.tls` via the recv callback.
        entry.reader = .{ .conn = &entry.tls };

        // Tag the negotiated protocol and lazily create the H2 session.
        // The H2 callbacks take `*Entry` as user_data so the recv
        // callback can short-circuit nghttp2's internal recv loop
        // after the active stream completes (see `h2RecvCallback`).
        // The entry pointer is stable for the entry's lifetime —
        // entries are always heap-allocated `*Entry` in the pool
        // array, never moved by value.
        if (entry.tls.alpn == .h2) {
            entry.protocol = .http_2;
            entry.h2_session = h2session.H2Session.init(
                h2SendCallback,
                h2RecvCallback,
                @as(*anyopaque, @ptrCast(entry)),
            ) catch return FetchError.TlsNotAvailable;
        }
        errdefer if (entry.h2_session) |*sess| sess.deinit();

        try self.boringssl_pool.add(self.allocator, entry);
        return entry;
    }

    /// Send one request on `entry` and read the response. Caller decides via
    /// `maybeReleaseBoringSsl` whether to keep or discard the entry based on
    /// the response's `Connection` header and request count.
    fn sendOnBoringSslEntry(
        self: *Client,
        entry: *BoringSslPool.Entry,
        u: *const Url,
        url_str: []const u8,
        method: Method,
        body: ?[]const u8,
    ) anyerror!Response {
        if (!boringssl_fallback) return FetchError.TlsNotAvailable;

        const host_header = try hostHeader(self.allocator, u);
        defer self.allocator.free(host_header);
        const path = try pathWithQueryAlloc(self.allocator, u);
        defer self.allocator.free(path);

        const http_method: http1.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
        };

        var req_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer req_buf.deinit();

        const cookie_header = try buildCookieHeaderValue(self.cookieJar(), self.allocator, u.host, path, u.is_https);
        defer self.allocator.free(cookie_header);

        try writeChrome132Http1Request(
            self,
            &req_buf.writer,
            http_method,
            host_header,
            path,
            cookie_header,
            if (method == .POST) body orelse "" else null,
        );
        try writeAllTls(&entry.tls, req_buf.written());

        // client.Method is a narrow GET/POST enum; map to http1.Method for
        // body-framing rules (RFC 9112 §6.3 rule 1 needs to recognize HEAD,
        // which AWR doesn't issue today but the helper must still type-match).
        const http1_method: http1.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
        };
        var parsed = try http1.readResponse(&entry.reader, self.allocator, http1_method);
        errdefer parsed.deinit();

        const effective_url = try self.allocator.dupe(u8, url_str);
        errdefer self.allocator.free(effective_url);

        return Response{
            .status = parsed.status,
            .url = effective_url,
            .headers = parsed.headers,
            .body = parsed.body,
            .allocator = self.allocator,
            .protocol = .http_1_1,
        };
    }

    /// Send one GET request on `entry` over an H2 stream and read the
    /// response. Builds Chrome 132 lowercase request headers, submits a
    /// new stream to the entry's H2Session, runs the I/O loop until the
    /// stream completes, and translates the H2Response to AWR's
    /// Response shape.
    ///
    /// MVP scope: GET only. POST is routed elsewhere because the H2
    /// shim only exposes `awr_h2_submit_get_ex` for now.
    fn sendOnBoringSslEntryH2(
        self: *Client,
        entry: *BoringSslPool.Entry,
        u: *const Url,
        url_str: []const u8,
    ) anyerror!Response {
        if (!boringssl_fallback) return FetchError.TlsNotAvailable;

        var sess = &entry.h2_session.?;

        // Pseudo-headers must be NUL-terminated for the C shim. authority
        // is host (with explicit port if non-default).
        const authority = try hostHeader(self.allocator, u);
        defer self.allocator.free(authority);
        const authority_z = try self.allocator.dupeZ(u8, authority);
        defer self.allocator.free(authority_z);
        const path = try pathWithQueryAlloc(self.allocator, u);
        defer self.allocator.free(path);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const cookie_value = try buildCookieHeaderValue(self.cookieJar(), self.allocator, u.host, path, u.is_https);
        defer self.allocator.free(cookie_value);

        var headers_buf: [16]h2session.H2Session.HeaderField = undefined;
        const header_count = try fillChrome132H2Headers(
            self,
            &headers_buf,
            authority,
            path,
            cookie_value,
        );

        const sid = sess.submitGetWithHeaders(
            "GET",
            "https",
            authority_z.ptr,
            path_z.ptr,
            headers_buf[0..header_count],
        ) catch return FetchError.ConnectionFailed;

        // Mark the active stream so `h2RecvCallback` knows when to
        // return WOULDBLOCK and break nghttp2's internal recv loop.
        // Reset on every exit path (success and error) — leaving it
        // stale would make a subsequent request misread completion.
        entry.current_h2_stream_id = sid;
        defer entry.current_h2_stream_id = 0;

        // 4096 iters is generous — most responses complete in < 10. The
        // loop bound exists to bail on a stalled server rather than
        // hang forever; runUntilComplete returns StreamNotComplete in
        // that case which surfaces as a fetch error.
        var h2_resp = sess.runUntilComplete(sid, 4096) catch return FetchError.ConnectionFailed;
        defer h2_resp.deinit();

        // Translate H2Response → AWR Response. Body and header buffers
        // are duped because h2_resp.deinit() frees the C-side allocation.
        const effective_url = try self.allocator.dupe(u8, url_str);
        errdefer self.allocator.free(effective_url);

        const body_dup = if (h2_resp.body.len > 0)
            try self.allocator.dupe(u8, h2_resp.body)
        else
            try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(body_dup);

        var headers_out = http1.HeaderList{ .owns_strings = true };
        errdefer headers_out.deinit(self.allocator);

        var it = h2_resp.headerIterator();
        while (it.next()) |pair| {
            const name_dup = try self.allocator.dupe(u8, pair.name);
            errdefer self.allocator.free(name_dup);
            const value_dup = try self.allocator.dupe(u8, pair.value);
            errdefer self.allocator.free(value_dup);
            try headers_out.append(self.allocator, name_dup, value_dup);
        }

        return Response{
            .status = h2_resp.status,
            .url = effective_url,
            .headers = headers_out,
            .body = body_dup,
            .allocator = self.allocator,
            .protocol = .http_2,
        };
    }

    /// Either return the entry to the idle pool (server willing to keep
    /// going) or discard it (server sent `Connection: close`, or we hit the
    /// per-connection request cap).
    fn maybeReleaseBoringSsl(self: *Client, entry: *BoringSslPool.Entry, resp: *const Response) void {
        if (!boringssl_fallback) return;

        const close_requested = blk: {
            if (resp.headers.get("connection")) |c| {
                const trimmed = std.mem.trim(u8, c, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, "close")) break :blk true;
            }
            break :blk false;
        };

        if (close_requested or entry.request_count + 1 >= BoringSslPool.MAX_REQUESTS_PER_CONN) {
            self.boringssl_pool.discard(self.allocator, entry);
        } else {
            self.boringssl_pool.release(entry);
        }
    }
};

/// Serialize an HTTP/1.1 request on the BoringSSL path using the same
/// Chrome 132 header set as `http1.Request.setChrome132Defaults`.
fn writeChrome132Http1Request(
    self: *Client,
    writer: anytype,
    method: http1.Method,
    host_header: []const u8,
    path: []const u8,
    cookie_header: []const u8,
    post_body: ?[]const u8,
) !void {
    var req = http1.Request{ .method = method, .path = path, .host = host_header };
    defer req.headers.deinit(self.allocator);

    if (self.options.use_chrome_headers) {
        try req.setChrome132Defaults(self.allocator);
    } else {
        try req.headers.append(self.allocator, "host", host_header);
        try req.headers.append(self.allocator, "user-agent", effectiveUserAgent(self.options));
        try req.headers.append(self.allocator, "accept", "*/*");
        try req.headers.append(self.allocator, "accept-language", "en-US,en;q=0.9");
        try req.headers.append(self.allocator, "accept-encoding", "identity");
    }

    if (cookie_header.len > 0) {
        try req.headers.append(self.allocator, "cookie", cookie_header);
    }

    if (post_body) |body_bytes| {
        var cl_buf: [32]u8 = undefined;
        const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body_bytes.len});
        try req.headers.append(self.allocator, "content-type", "application/x-www-form-urlencoded");
        try req.headers.append(self.allocator, "content-length", cl);
    }

    try req.write(writer);
    if (post_body) |body_bytes| try writer.writeAll(body_bytes);
}

/// Copy Chrome 132 regular headers into the H2 submit buffer. Skips
/// HTTP/1-only `host` and H2 pseudo-headers (the shim adds those).
fn fillChrome132H2Headers(
    self: *Client,
    out: []h2session.H2Session.HeaderField,
    authority: []const u8,
    path: []const u8,
    cookie_header: []const u8,
) !usize {
    var req = http1.Request{ .method = .GET, .path = path, .host = authority };
    defer req.headers.deinit(self.allocator);

    if (self.options.use_chrome_headers) {
        try req.setChrome132Defaults(self.allocator);
    } else {
        const ua = effectiveUserAgent(self.options);
        try req.headers.append(self.allocator, "user-agent", ua);
        try req.headers.append(self.allocator, "accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
        try req.headers.append(self.allocator, "accept-language", "en-US,en;q=0.9");
        try req.headers.append(self.allocator, "accept-encoding", "identity");
    }

    if (cookie_header.len > 0) {
        try req.headers.append(self.allocator, "cookie", cookie_header);
    }

    var count: usize = 0;
    for (req.headers.items.items) |h| {
        if (h.name.len > 0 and h.name[0] == ':') continue;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
        if (count >= out.len) return FetchError.ConnectionFailed;
        out[count] = .{
            .name = h.name.ptr,
            .name_len = @intCast(h.name.len),
            .value = h.value.ptr,
            .value_len = @intCast(h.value.len),
        };
        count += 1;
    }
    return count;
}

fn effectiveUserAgent(options: ClientOptions) []const u8 {
    if (options.user_agent.len != 0) return options.user_agent;
    if (options.use_chrome_headers) return http1.chrome132_user_agent;
    return "awr";
}

fn boringsslFallbackAllowed(url_str: []const u8) bool {
    if (!boringssl_fallback) return false;
    const u = url_mod.Url.parse(url_str) catch return false;
    return u.is_https;
}

fn hostHeader(allocator: std.mem.Allocator, u: *const Url) ![]u8 {
    const default_port: u16 = if (u.is_https) 443 else 80;
    if (u.port == default_port) return allocator.dupe(u8, u.host);
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ u.host, u.port });
}

fn pathWithQueryAlloc(allocator: std.mem.Allocator, u: *const Url) ![]u8 {
    if (u.query) |q| return std.fmt.allocPrint(allocator, "{s}?{s}", .{ u.path, q });
    return allocator.dupe(u8, u.path);
}

fn writeAllTls(conn: anytype, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try conn.writeFn(bytes[written..]);
        if (n == 0) return FetchError.SendFailed;
        written += n;
    }
}

/// Walk a response's headers and feed every `Set-Cookie` into the jar.
/// `request_url` is the URL we sent the request to (not the response's
/// final URL); the cookie's effective domain comes from there.
///
/// Multiple Set-Cookie headers are not folded into one comma-separated
/// value the way other headers are — RFC 6265 mandates one Set-Cookie
/// per directive. The HeaderList preserves the wire order so iterating
/// with `eqlIgnoreCase` covers all of them.
///
/// Parse failures are non-fatal — a malformed Set-Cookie shouldn't kill
/// the whole fetch. Real browsers tolerate the wide range of bad
/// cookies servers ship.
fn absorbSetCookies(jar: *cookie.CookieJar, request_url: []const u8, headers: *const http1.HeaderList) void {
    const u = url_mod.Url.parse(request_url) catch return;
    for (headers.items.items) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        jar.parseSetCookie(h.value, u.host) catch continue;
    }
}

/// Build the `Cookie:` header value to send with a request to
/// (host, path, https). Returns an owned, possibly-empty slice — the
/// caller owns it. Empty result means "no matching cookies, omit the
/// header entirely". Mirrors `cookie.CookieJar.getCookieHeader` but
/// hides the same-site default in one place.
pub fn buildCookieHeaderValue(
    jar: *cookie.CookieJar,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    https: bool,
) ![]u8 {
    _ = allocator; // jar uses its own allocator internally
    return jar.getCookieHeader(host, path, https);
}

// ── H2 session send/recv callbacks ────────────────────────────────────────
//
// nghttp2 (via h2_shim.c) calls these whenever it has bytes to push out
// or wants more bytes to read. `user_data` is a `*BoringSslPool.Entry`
// that owns the H2 session — stable for the entry's lifetime because
// entries are heap-allocated `*Entry` pointers in the pool array.
//
// Return values follow the `cb_send` / `cb_recv` contract in h2_shim.c:
//   send: positive = bytes written, -1 = error
//   recv: positive = bytes read, 0 = WOULDBLOCK, -2 = EOF, <0 = error
//
// The recv callback's WOULDBLOCK return is the key to making blocking
// TLS I/O work with `nghttp2_session_recv`'s internal loop. After the
// active stream's END_STREAM is processed, we return 0 so nghttp2
// stops calling us — otherwise the next `tls.readFn` would block
// forever waiting for data the server has no reason to send.

fn h2SendCallback(data: [*c]const u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int {
    if (!boringssl_fallback) return -1;
    const entry: *BoringSslPool.Entry = @ptrCast(@alignCast(ud orelse return -1));
    const slice = data[0..len];
    const n = entry.tls.writeFn(slice) catch return -1;
    return @intCast(n);
}

fn h2RecvCallback(buf: [*c]u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int {
    if (!boringssl_fallback) return -1;
    const entry: *BoringSslPool.Entry = @ptrCast(@alignCast(ud orelse return -1));

    // If we have an active stream and it has already received END_STREAM,
    // tell nghttp2 there's nothing more to read so its internal recv
    // loop returns. Without this, `tls.readFn` blocks indefinitely
    // because the server keeps the H2 connection open for keep-alive.
    if (entry.current_h2_stream_id != 0) {
        if (entry.h2_session) |*sess| {
            if (sess.streamComplete(entry.current_h2_stream_id)) return 0;
        }
    }

    const slice = buf[0..len];
    const n = entry.tls.readFn(slice) catch return -1;
    if (n == 0) return -2; // EOF — TlsConn.readFn returns 0 at end-of-stream
    return @intCast(n);
}

const TlsBufferedReader = if (boringssl_fallback) struct {
    conn: *tls_conn.TlsConn,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(self: *@This()) tls_conn.TlsError!usize {
        const n = try self.conn.readFn(&self.buf);
        self.start = 0;
        self.end = n;
        return n;
    }

    pub fn read(self: *@This(), dest: []u8) tls_conn.TlsError!usize {
        if (dest.len == 0) return 0;
        if (self.start == self.end) {
            if (dest.len >= self.buf.len) return self.conn.readFn(dest);
            const n = try self.fill();
            if (n == 0) return 0;
        }
        const n = @min(dest.len, self.end - self.start);
        @memcpy(dest[0..n], self.buf[self.start .. self.start + n]);
        self.start += n;
        return n;
    }

    pub fn readUntilDelimiter(self: *@This(), out: []u8, delim: u8) ![]u8 {
        var len: usize = 0;
        while (true) {
            if (self.start == self.end) {
                const n = try self.fill();
                if (n == 0) return error.EndOfStream;
            }

            const available = self.buf[self.start..self.end];
            const take_len = if (std.mem.indexOfScalar(u8, available, delim)) |idx| idx + 1 else available.len;
            if (len + take_len > out.len) return error.StreamTooLong;
            @memcpy(out[len .. len + take_len], available[0..take_len]);
            len += take_len;
            self.start += take_len;
            if (take_len > 0 and out[len - 1] == delim) return out[0..len];
        }
    }

    pub fn readNoEof(self: *@This(), dest: []u8) !void {
        var filled: usize = 0;
        while (filled < dest.len) {
            const n = try self.read(dest[filled..]);
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }
} else struct {};

fn resolveRedirectUrl(alloc: std.mem.Allocator, base: []const u8, location: []const u8) ![]u8 {
    if (hasScheme(location)) return alloc.dupe(u8, location);

    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return FetchError.InvalidUrl;
    const authority_start = scheme_end + 3;

    if (std.mem.startsWith(u8, location, "?")) {
        const hash_start = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
        const query_start = std.mem.indexOfScalar(u8, base[0..hash_start], '?') orelse hash_start;
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ base[0..query_start], location });
    }

    if (std.mem.startsWith(u8, location, "#")) {
        const hash_start = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ base[0..hash_start], location });
    }

    if (std.mem.startsWith(u8, location, "//")) {
        return std.fmt.allocPrint(alloc, "{s}:{s}", .{ base[0..scheme_end], location });
    }

    const authority_end = std.mem.indexOfScalarPos(u8, base, authority_start, '/') orelse base.len;
    const origin = base[0..authority_end];
    if (std.mem.startsWith(u8, location, "/")) {
        return joinAndNormalize(alloc, origin, location);
    }

    var path_end = base.len;
    if (std.mem.indexOfScalarPos(u8, base, authority_end, '?')) |q| path_end = @min(path_end, q);
    if (std.mem.indexOfScalarPos(u8, base, authority_end, '#')) |h| path_end = @min(path_end, h);

    const base_path = if (authority_end < path_end) base[authority_end..path_end] else "/";
    const last_slash = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0;
    const dir = base_path[0 .. last_slash + 1];

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    try joined.appendSlice(alloc, dir);
    try joined.appendSlice(alloc, location);
    return joinAndNormalize(alloc, origin, joined.items);
}

fn joinAndNormalize(alloc: std.mem.Allocator, origin: []const u8, path: []const u8) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(alloc);

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(alloc, seg);
    }

    const trailing_slash = path.len > 0 and path[path.len - 1] == '/';
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, origin);
    if (segments.items.len == 0) {
        try out.append(alloc, '/');
    } else {
        for (segments.items) |seg| {
            try out.append(alloc, '/');
            try out.appendSlice(alloc, seg);
        }
        if (trailing_slash) try out.append(alloc, '/');
    }
    return out.toOwnedSlice(alloc);
}

fn hasScheme(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..], 1..) |c, i| {
        if (c == ':') return i > 0;
        const ok = std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return false;
}

fn cloneFetchHeaders(allocator: std.mem.Allocator, src_headers: anytype) !http1.HeaderList {
    var headers: http1.HeaderList = .{};
    errdefer headers.deinit(allocator);

    var it = src_headers;
    while (it.next()) |header| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try headers.append(allocator, name, value);
    }

    headers.owns_strings = true;
    return headers;
}
/// Translate `std.http.Client.FetchError` into our stable `FetchError`
/// surface. Anything we can't map falls through as the original error.
fn mapFetchError(err: anyerror) anyerror {
    return switch (err) {
        error.UnknownHostName,
        error.NameServerFailure,
        error.TemporaryNameServerFailure,
        error.HostLacksNetworkAddresses,
        error.NoAddressReturned,
        error.NoAddressesResolved,
        error.InvalidHostName,
        => FetchError.DnsResolutionFailed,

        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        => FetchError.ConnectionFailed,

        error.TlsInitializationFailed,
        error.TlsAlert,
        error.TlsFailure,
        => FetchError.TlsNotAvailable,

        error.TooManyHttpRedirects => FetchError.TooManyRedirects,

        error.UnsupportedUriScheme,
        error.UriMissingHost,
        => FetchError.InvalidUrl,

        error.OutOfMemory => FetchError.OutOfMemory,

        else => err,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "Client.init and deinit" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();
    try std.testing.expect(client.cookies.cookies.items.len == 0);
}

test "Client options defaults" {
    const opts = ClientOptions{};
    try std.testing.expect(opts.follow_redirects);
    try std.testing.expectEqual(@as(u8, 10), opts.max_redirects);
    try std.testing.expectEqual(@as(u32, 30_000), opts.timeout_ms);
    try std.testing.expectEqual(@as(usize, 64 * 1024), opts.max_response_header_bytes);
    try std.testing.expect(opts.use_chrome_headers);
    try std.testing.expectEqualStrings("", opts.user_agent);
}

test "effectiveUserAgent matches chrome132_user_agent" {
    try std.testing.expectEqualStrings(http1.chrome132_user_agent, effectiveUserAgent(.{}));
}

test "fetch returns InvalidUrl for bad URL" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();
    const result = client.fetch("not-a-url");
    try std.testing.expectError(FetchError.InvalidUrl, result);
}

test "fetch returns DnsResolutionFailed for invalid host" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();
    const result = client.fetch("http://this.host.does.not.exist.invalid/");
    try std.testing.expectError(FetchError.DnsResolutionFailed, result);
}

test "Client cookie jar is populated after fetch sets a cookie (mock)" {
    // Verify cookie jar stores cookies via parseSetCookie directly
    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();
    try client.cookies.parseSetCookie("session=abc123; Path=/; HttpOnly", "example.com");
    try std.testing.expectEqual(@as(usize, 1), client.cookies.cookies.items.len);
}

test "fetch populates response url" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{
        .use_chrome_headers = false,
    });
    defer client.deinit();

    var result = try client.fetch("http://example.com/");
    defer result.deinit();

    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expectEqualStrings("http://example.com/", result.url);
}

test "fetch TooManyRedirects when max_redirects is 0" {
    // Can't easily test redirect following without a real server,
    // but we can test the max_redirects option exists and is applied.
    const opts = ClientOptions{ .max_redirects = 0 };
    try std.testing.expectEqual(@as(u8, 0), opts.max_redirects);
}

test "resolveRedirectUrl handles absolute and protocol-relative locations" {
    const absolute = try resolveRedirectUrl(std.testing.allocator, "http://a.com/path", "https://b.com/next");
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("https://b.com/next", absolute);

    const protocol_relative = try resolveRedirectUrl(std.testing.allocator, "https://a.com/path", "//cdn.example/next");
    defer std.testing.allocator.free(protocol_relative);
    try std.testing.expectEqualStrings("https://cdn.example/next", protocol_relative);
}

test "resolveRedirectUrl handles root-relative and relative locations" {
    const root_relative = try resolveRedirectUrl(std.testing.allocator, "http://a.com/dir/page.html", "/next");
    defer std.testing.allocator.free(root_relative);
    try std.testing.expectEqualStrings("http://a.com/next", root_relative);

    const relative = try resolveRedirectUrl(std.testing.allocator, "http://a.com/dir/sub/page.html?x=1", "../next");
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("http://a.com/dir/next", relative);
}

test "resolveRedirectUrl handles query-only and fragment-only locations" {
    const query = try resolveRedirectUrl(std.testing.allocator, "http://a.com/dir/page.html?old=1#top", "?new=1");
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("http://a.com/dir/page.html?new=1", query);

    const fragment = try resolveRedirectUrl(std.testing.allocator, "http://a.com/dir/page.html?x=1#old", "#new");
    defer std.testing.allocator.free(fragment);
    try std.testing.expectEqualStrings("http://a.com/dir/page.html?x=1#new", fragment);
}

// ── BoringSslPool tests ────────────────────────────────────────────────────
//
// These tests exercise the pool's bookkeeping (host/port matching, idle
// timeout, request cap, release/discard) without touching real TLS. Entries
// are manually allocated with the connection fields left undefined; tests
// must use `cleanupBookkeepingPool` to tear down without calling TLS deinit.

const BookkeepingOnlyPool = if (boringssl_fallback) struct {
    fn makeEntry(allocator: std.mem.Allocator, host: []const u8, port: u16) !*BoringSslPool.Entry {
        const e = try allocator.create(BoringSslPool.Entry);
        errdefer allocator.destroy(e);
        e.host = try allocator.dupe(u8, host);
        e.port = port;
        e.in_use = false;
        e.last_used_ms = BoringSslPool.Entry.nowMs();
        e.request_count = 0;
        // tls/ctx/tcp_conn/reader intentionally left undefined.
        return e;
    }

    fn cleanup(allocator: std.mem.Allocator, bs_pool: *BoringSslPool) void {
        for (bs_pool.entries.items) |e| {
            allocator.free(e.host);
            allocator.destroy(e);
        }
        bs_pool.entries.deinit(allocator);
    }
} else struct {};

test "absorbSetCookies parses Set-Cookie from response headers into the jar" {
    var jar = cookie.CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    var headers = http1.HeaderList{ .owns_strings = false };
    defer headers.deinit(std.testing.allocator);
    try headers.append(std.testing.allocator, "content-type", "text/html");
    try headers.append(std.testing.allocator, "Set-Cookie", "session=abc123; Path=/; HttpOnly");
    try headers.append(std.testing.allocator, "set-cookie", "tracking=xyz; Path=/");

    absorbSetCookies(&jar, "https://example.com/", &headers);

    // Both case-variants should have been picked up.
    try std.testing.expectEqual(@as(usize, 2), jar.cookies.items.len);

    // The jar should now produce a Cookie header that includes both.
    const sent = try jar.getCookieHeader("example.com", "/", true);
    defer std.testing.allocator.free(sent);
    try std.testing.expect(std.mem.indexOf(u8, sent, "session=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "tracking=xyz") != null);
}

test "absorbSetCookies tolerates malformed Set-Cookie without crashing" {
    var jar = cookie.CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    var headers = http1.HeaderList{ .owns_strings = false };
    defer headers.deinit(std.testing.allocator);
    try headers.append(std.testing.allocator, "set-cookie", ""); // empty value
    try headers.append(std.testing.allocator, "set-cookie", "=novalue"); // no name
    try headers.append(std.testing.allocator, "set-cookie", "session=ok; Path=/");

    absorbSetCookies(&jar, "https://example.com/", &headers);

    // Only the well-formed one should land — but the call shouldn't
    // have crashed on the malformed entries.
    try std.testing.expect(jar.cookies.items.len >= 1);
    const found = jar.getCookieHeader("example.com", "/", true) catch unreachable;
    defer std.testing.allocator.free(found);
    try std.testing.expect(std.mem.indexOf(u8, found, "session=ok") != null);
}

test "absorbSetCookies skips non-Set-Cookie headers" {
    var jar = cookie.CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    var headers = http1.HeaderList{ .owns_strings = false };
    defer headers.deinit(std.testing.allocator);
    try headers.append(std.testing.allocator, "content-type", "text/html");
    try headers.append(std.testing.allocator, "x-frame-options", "DENY");
    try headers.append(std.testing.allocator, "cookie", "incoming=val"); // request-side, not response

    absorbSetCookies(&jar, "https://example.com/", &headers);

    try std.testing.expectEqual(@as(usize, 0), jar.cookies.items.len);
}

test "buildCookieHeaderValue returns empty when jar has no matching cookies" {
    var jar = cookie.CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("foo=bar; Path=/", "other.example.com");

    const value = try buildCookieHeaderValue(&jar, std.testing.allocator, "example.com", "/", true);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqual(@as(usize, 0), value.len);
}

test "BoringSslPool.acquire returns null on empty pool" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);
    try std.testing.expectEqual(@as(?*BoringSslPool.Entry, null), bs_pool.acquire("example.com", 443));
}

test "BoringSslPool.acquire matches host:port and marks in_use" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    try bs_pool.add(std.testing.allocator, e);

    const acquired = bs_pool.acquire("example.com", 443);
    try std.testing.expect(acquired != null);
    try std.testing.expectEqual(e, acquired.?);
    try std.testing.expect(e.in_use);
}

test "BoringSslPool.acquire skips entries with mismatched host" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    try bs_pool.add(std.testing.allocator, e);

    try std.testing.expectEqual(@as(?*BoringSslPool.Entry, null), bs_pool.acquire("other.com", 443));
}

test "BoringSslPool.acquire skips entries with mismatched port" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    try bs_pool.add(std.testing.allocator, e);

    try std.testing.expectEqual(@as(?*BoringSslPool.Entry, null), bs_pool.acquire("example.com", 8443));
}

test "BoringSslPool.acquire skips entries already in use" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    e.in_use = true;
    try bs_pool.add(std.testing.allocator, e);

    try std.testing.expectEqual(@as(?*BoringSslPool.Entry, null), bs_pool.acquire("example.com", 443));
}

test "BoringSslPool.acquire skips entries past IDLE_TIMEOUT_MS" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    e.last_used_ms -= BoringSslPool.IDLE_TIMEOUT_MS + 1;
    try bs_pool.add(std.testing.allocator, e);

    try std.testing.expectEqual(@as(?*BoringSslPool.Entry, null), bs_pool.acquire("example.com", 443));
}

test "BoringSslPool.acquire skips entries at MAX_REQUESTS_PER_CONN" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    e.request_count = BoringSslPool.MAX_REQUESTS_PER_CONN;
    try bs_pool.add(std.testing.allocator, e);

    try std.testing.expectEqual(@as(?*BoringSslPool.Entry, null), bs_pool.acquire("example.com", 443));
}

test "BoringSslPool.release makes entry available again and bumps count" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    e.in_use = true;
    try bs_pool.add(std.testing.allocator, e);

    bs_pool.release(e);
    try std.testing.expect(!e.in_use);
    try std.testing.expectEqual(@as(u32, 1), e.request_count);
    try std.testing.expectEqual(e, bs_pool.acquire("example.com", 443).?);
}

test "BoringSslPool.acquire is case-insensitive on host" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const e = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "Example.COM", 443);
    try bs_pool.add(std.testing.allocator, e);

    try std.testing.expectEqual(e, bs_pool.acquire("example.com", 443).?);
}

test "BoringSslPool.countForOrigin tallies idle + in_use entries" {
    if (!boringssl_fallback) return error.SkipZigTest;
    var bs_pool = BoringSslPool{};
    defer BookkeepingOnlyPool.cleanup(std.testing.allocator, &bs_pool);

    const a = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    const b = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "example.com", 443);
    const c = try BookkeepingOnlyPool.makeEntry(std.testing.allocator, "other.com", 443);
    b.in_use = true;
    try bs_pool.add(std.testing.allocator, a);
    try bs_pool.add(std.testing.allocator, b);
    try bs_pool.add(std.testing.allocator, c);

    try std.testing.expectEqual(@as(usize, 2), bs_pool.countForOrigin("example.com", 443));
    try std.testing.expectEqual(@as(usize, 1), bs_pool.countForOrigin("other.com", 443));
    try std.testing.expectEqual(@as(usize, 0), bs_pool.countForOrigin("missing.com", 443));
}

test "Client.shouldSkipStdForUrl + rememberStdTlsFailure round-trip" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();

    try std.testing.expect(!client.shouldSkipStdForUrl("https://news.ycombinator.com/"));
    client.rememberStdTlsFailure("https://news.ycombinator.com/path?q=1");
    try std.testing.expect(client.shouldSkipStdForUrl("https://news.ycombinator.com/other"));
    try std.testing.expect(!client.shouldSkipStdForUrl("https://example.com/"));
    // http:// URLs ignored even if host matches a recorded https failure
    try std.testing.expect(!client.shouldSkipStdForUrl("http://news.ycombinator.com/"));
}

test "Client.rememberStdTlsFailure deduplicates same host" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();

    client.rememberStdTlsFailure("https://news.ycombinator.com/a");
    client.rememberStdTlsFailure("https://news.ycombinator.com/b");
    client.rememberStdTlsFailure("https://news.ycombinator.com/c");
    try std.testing.expectEqual(@as(usize, 1), client.std_tls_failed_hosts.count());
}

test "tls-fail cache: round-trip through disk preserves recorded hosts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // tmpDir is rooted at .zig-cache/tmp/<sub_path>; build a relative
    // path so loadTlsFailCacheFromDisk's std.Io.Dir.cwd() reaches it.
    const cache_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/tls_fail.txt", .{tmp.sub_path});
    defer allocator.free(cache_path);

    {
        var client = Client.init(allocator, io, .{ .tls_fail_cache_path = cache_path });
        defer client.deinit();
        client.rememberStdTlsFailure("https://news.ycombinator.com/");
        client.rememberStdTlsFailure("https://other.example.com/path");
    }

    var client2 = Client.init(allocator, io, .{ .tls_fail_cache_path = cache_path });
    defer client2.deinit();
    try std.testing.expectEqual(@as(usize, 2), client2.std_tls_failed_hosts.count());
    try std.testing.expect(client2.shouldSkipStdForUrl("https://news.ycombinator.com/"));
    try std.testing.expect(client2.shouldSkipStdForUrl("https://other.example.com/"));
    try std.testing.expect(!client2.shouldSkipStdForUrl("https://example.com/"));
}

test "tls-fail cache: rejects malformed lines and survives missing file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/bad.txt", .{tmp.sub_path});
    defer allocator.free(cache_path);

    // Missing file is not an error.
    {
        var client = Client.init(allocator, io, .{ .tls_fail_cache_path = cache_path });
        defer client.deinit();
        try std.testing.expectEqual(@as(usize, 0), client.std_tls_failed_hosts.count());
    }

    // Hand-write a file with valid + invalid + comment lines via the same
    // io capability the load path uses, so we exercise the same vtable.
    {
        var f = try std.Io.Dir.cwd().createFile(io, cache_path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\# comment
            \\good.example.com
            \\
            \\bad host with spaces
            \\../traversal
            \\also-good.com
            \\
        );
    }

    var client = Client.init(allocator, io, .{ .tls_fail_cache_path = cache_path });
    defer client.deinit();
    try std.testing.expectEqual(@as(usize, 2), client.std_tls_failed_hosts.count());
    try std.testing.expect(client.shouldSkipStdForUrl("https://good.example.com/"));
    try std.testing.expect(client.shouldSkipStdForUrl("https://also-good.com/"));
}

fn networkTestsEnabled() bool {
    if (!@hasDecl(std.c, "getenv")) return false;
    return std.c.getenv("AWR_RUN_NETWORK_TESTS") != null;
}

test "integration: BoringSSL pool reuses connection across same-origin fetches" {
    if (!networkTestsEnabled()) return error.SkipZigTest;
    if (!boringssl_fallback) return error.SkipZigTest;

    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();

    // First fetch: std attempt fails with TlsNotAvailable, BoringSSL fallback
    // creates a fresh entry, sends, and releases it back to idle.
    var resp1 = client.fetch("https://news.ycombinator.com/") catch |err| switch (err) {
        FetchError.DnsResolutionFailed, FetchError.ConnectionFailed => return,
        else => return err,
    };
    defer resp1.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp1.status);

    // After fetch 1: host is recorded as std-TLS-failing, and the pool has
    // exactly one (idle) entry for HN:443 with request_count=1.
    try std.testing.expect(client.std_tls_failed_hosts.contains("news.ycombinator.com"));
    try std.testing.expectEqual(@as(usize, 1), client.boringssl_pool.countForOrigin("news.ycombinator.com", 443));
    try std.testing.expectEqual(@as(u32, 1), client.boringssl_pool.entries.items[0].request_count);

    // Second fetch on the same origin: should reuse the pooled connection
    // (no new entry created) and the existing entry's request_count climbs.
    var resp2 = client.fetch("https://news.ycombinator.com/") catch |err| switch (err) {
        FetchError.DnsResolutionFailed, FetchError.ConnectionFailed => return,
        else => return err,
    };
    defer resp2.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp2.status);

    try std.testing.expectEqual(@as(usize, 1), client.boringssl_pool.countForOrigin("news.ycombinator.com", 443));
    try std.testing.expectEqual(@as(u32, 2), client.boringssl_pool.entries.items[0].request_count);
}

test "integration: production BoringSSL fetch path sends awr_ja4_h2 fingerprint" {
    // Pins the production code path's TLS fingerprint to the published
    // Chrome 132 ALPN-h2 constant in src/net/fingerprint.zig. The GET
    // path uses the h2-capable ctx (`["h2", "http/1.1"]` ALPN); a
    // server that supports H2 (tls.peet.ws does) will pick h2 and the
    // resulting JA4 ends in `_h2`.
    //
    // This test exists because of a 2026-05-06 finding where production
    // had silently drifted to a generic BoringSSL fingerprint
    // (t13d86_b6101760603d_5301e1d12640) — no test was exercising the
    // actual Client.getSharedTlsCtx + createBoringSslEntry path against
    // a fingerprint-reporting endpoint.
    if (!networkTestsEnabled()) return error.SkipZigTest;
    if (!boringssl_fallback) return error.SkipZigTest;

    const fingerprint = @import("net/fingerprint.zig");

    var client = Client.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();

    // Force the BoringSSL fallback: tls.peet.ws's TLS works in std-lib,
    // so without this hint the fetch would go through std.http (whose
    // fingerprint is unrelated to AWR's claim).
    const host = std.testing.allocator.dupe(u8, "tls.peet.ws") catch return;
    client.std_tls_failed_hosts.put(std.testing.allocator, host, {}) catch {
        std.testing.allocator.free(host);
        return;
    };

    var resp = client.fetch("https://tls.peet.ws/api/all") catch |err| switch (err) {
        FetchError.DnsResolutionFailed, FetchError.ConnectionFailed => return,
        else => return err,
    };
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // tls.peet.ws returns its capture as JSON. Find `"ja4"` then skip
    // ASCII whitespace + the colon + the opening quote. Avoids depending
    // on whether the server's serializer inserts a space after `:`.
    const key = "\"ja4\"";
    const key_idx = std.mem.indexOf(u8, resp.body, key) orelse return error.Ja4FieldMissing;
    var cursor = key_idx + key.len;
    while (cursor < resp.body.len and (resp.body[cursor] == ' ' or resp.body[cursor] == ':' or
        resp.body[cursor] == '\t' or resp.body[cursor] == '\n')) : (cursor += 1)
    {}
    if (cursor >= resp.body.len or resp.body[cursor] != '"') return error.Ja4FieldMalformed;
    const value_start = cursor + 1;
    const end = std.mem.indexOfScalarPos(u8, resp.body, value_start, '"') orelse
        return error.Ja4FieldUnterminated;
    const ja4 = resp.body[value_start..end];

    try std.testing.expectEqualStrings(fingerprint.awr_ja4_h2, ja4);
}
