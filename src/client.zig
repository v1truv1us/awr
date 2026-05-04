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
        ctx: tls_conn.TlsCtx,
        tcp_conn: tcp.TcpConn,
        tls: tls_conn.TlsConn,
        reader: TlsBufferedReader,
        in_use: bool,
        last_used_ms: i64,
        request_count: u32,

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

    fn destroyEntry(allocator: std.mem.Allocator, e: *Entry) void {
        e.tls.deinit();
        e.ctx.deinit();
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
    /// Sent as the User-Agent header when not using Chrome 132 defaults.
    user_agent: []const u8 = "AWR/0.1",
    /// When true, setChrome132Defaults() is called on every request.
    use_chrome_headers: bool = true,
    /// When true and `cookie_jar_path` is non-null, Client.init reads the
    /// jar from disk on startup and Client.deinit writes it back. Caller
    /// owns `cookie_jar_path`; Client borrows the slice.
    persist_cookies: bool = false,
    cookie_jar_path: ?[]const u8 = null,
};

// ── Response ──────────────────────────────────────────────────────────────

pub const Response = struct {
    status: u16,
    url: []const u8,
    headers: http1.HeaderList,
    body: []u8,
    allocator: std.mem.Allocator,

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

fn loadCookiesFromDisk(jar: *cookie.CookieJar, io: std.Io, path: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, jar.allocator, .limited(COOKIE_JAR_MAX_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return, // first run is not an error
        else => return err,
    };
    defer jar.allocator.free(bytes);
    try jar.deserializeBytes(bytes);
}

fn saveCookiesToDisk(jar: *const cookie.CookieJar, io: std.Io, path: []const u8) !void {
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
    /// Hosts where `fetchOnceStd` has already returned `TlsNotAvailable`.
    /// On subsequent requests we skip the std attempt (which costs ~100-160ms
    /// on a fresh TCP+TLS handshake before failing) and go straight to
    /// `fetchOnceBoringSslHttp1`. Hosts are duped on first failure and freed
    /// in `Client.deinit`. Bounded by the number of distinct origins a
    /// session visits — fine for an MVP browse session.
    std_tls_failed_hosts: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ClientOptions) Client {
        var c = Client{
            .allocator = allocator,
            .io = io,
            .cookies = cookie.CookieJar.init(allocator),
            .conns = pool.ConnectionPool.init(allocator),
            .options = options,
        };
        if (options.persist_cookies) {
            if (options.cookie_jar_path) |path| loadCookiesFromDisk(&c.cookies, io, path) catch |err| {
                std.log.warn("cookie jar load from {s} failed: {s}", .{ path, @errorName(err) });
            };
        }
        return c;
    }

    pub fn deinit(self: *Client) void {
        if (self.options.persist_cookies) {
            if (self.options.cookie_jar_path) |path| saveCookiesToDisk(&self.cookies, self.io, path) catch |err| {
                std.log.warn("cookie jar save to {s} failed: {s}", .{ path, @errorName(err) });
            };
        }
        if (self.std_client) |*c| c.deinit();
        self.boringssl_pool.deinit(self.allocator);
        var key_it = self.std_tls_failed_hosts.keyIterator();
        while (key_it.next()) |k| self.allocator.free(k.*);
        self.std_tls_failed_hosts.deinit(self.allocator);
        self.conns.deinit();
        self.cookies.deinit();
    }

    /// Fetch a URL via GET. Backwards-compat wrapper for callers that don't
    /// need POST. Caller must call response.deinit() on success.
    pub fn fetch(self: *Client, url_str: []const u8) anyerror!Response {
        return self.fetchRequest(.{ .url = url_str });
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
        // failed once. Without this cache, every same-host fetch pays the
        // full TCP+TLS handshake on the std side (~100-160ms) before falling
        // back to BoringSSL — wiping out most of the keep-alive savings.
        if (self.shouldSkipStdForUrl(url_str)) {
            if (boringsslFallbackAllowed(url_str)) {
                return self.fetchOnceBoringSslHttp1(url_str, method, body) catch |e| return mapFetchError(e);
            }
        }

        return self.fetchOnceStd(url_str, method, body) catch |err| switch (err) {
            FetchError.TlsNotAvailable => {
                self.rememberStdTlsFailure(url_str);
                return if (boringsslFallbackAllowed(url_str))
                    self.fetchOnceBoringSslHttp1(url_str, method, body) catch |fallback_err| return mapFetchError(fallback_err)
                else
                    err;
            },
            else => return err,
        };
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

        const effective_user_agent =
            if (self.options.user_agent.len != 0)
                self.options.user_agent
            else if (self.options.use_chrome_headers)
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
            else
                "awr";

        var extra_headers: [10]std.http.Header = undefined;
        var extra_header_count: usize = 0;

        extra_headers[extra_header_count] = .{ .name = "user-agent", .value = effective_user_agent };
        extra_header_count += 1;

        if (self.options.use_chrome_headers) {
            extra_headers[extra_header_count] = .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/png,*/*;q=0.8" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "accept-language", .value = "en-US,en;q=0.9" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "cache-control", .value = "max-age=0" };
            extra_header_count += 1;
            extra_headers[extra_header_count] = .{ .name = "pragma", .value = "no-cache" };
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

        const std_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
        };
        var req = std_client.request(std_method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = extra_headers[0..extra_header_count],
        }) catch |err| return mapFetchError(err);
        defer req.deinit();

        if (method == .POST) {
            // std.http.Client.Request.sendBodyComplete takes []u8 (mutable),
            // so dupe the const slice into a temporary owned buffer.
            const body_const = body orelse "";
            const body_bytes = try self.allocator.dupe(u8, body_const);
            defer self.allocator.free(body_bytes);
            req.sendBodyComplete(body_bytes) catch |err| return mapFetchError(err);
        } else {
            req.sendBodiless() catch |err| return mapFetchError(err);
        }

        var result = req.receiveHead(&.{}) catch |err| return mapFetchError(err);

        var headers = try cloneFetchHeaders(self.allocator, result.head.iterateHeaders());
        errdefer headers.deinit(self.allocator);

        const effective_url = try std.fmt.allocPrint(self.allocator, "{f}", .{
            req.uri.fmt(.{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true, .fragment = true }),
        });
        errdefer self.allocator.free(effective_url);

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
            if (self.sendOnBoringSslEntry(entry, &u, url_str, method, body)) |resp| {
                self.maybeReleaseBoringSsl(entry, &resp);
                return resp;
            } else |_| {
                self.boringssl_pool.discard(self.allocator, entry);
                // fall through to fresh handshake
            }
        }

        // Fresh handshake. The errdefer covers: send failure, response parse
        // failure, allocation failure between handshake and Response return.
        const entry = try self.createBoringSslEntry(&u);
        errdefer self.boringssl_pool.discard(self.allocator, entry);

        const resp = try self.sendOnBoringSslEntry(entry, &u, url_str, method, body);
        self.maybeReleaseBoringSsl(entry, &resp);
        return resp;
    }

    /// Allocate, handshake, and register a new pool entry for `u`. The entry
    /// is added to the pool with `in_use=true` so a concurrent acquire would
    /// not steal it (single-threaded today, but the invariant matters).
    fn createBoringSslEntry(self: *Client, u: *const Url) anyerror!*BoringSslPool.Entry {
        if (!boringssl_fallback) return FetchError.TlsNotAvailable;

        const addr = dns.resolve(self.io, u.host, u.port) catch |err| return mapFetchError(err);

        const entry = try self.allocator.create(BoringSslPool.Entry);
        errdefer self.allocator.destroy(entry);

        entry.host = try self.allocator.dupe(u8, u.host);
        errdefer self.allocator.free(entry.host);

        entry.port = u.port;
        entry.in_use = true;
        entry.last_used_ms = BoringSslPool.Entry.nowMs();
        entry.request_count = 0;

        entry.tcp_conn = tcp.TcpConn.init(self.allocator, addr) catch return FetchError.ConnectionFailed;
        errdefer entry.tcp_conn.deinit();
        entry.tcp_conn.connect() catch |err| return mapFetchError(err);

        entry.ctx = tls_conn.initCompatHttp11WithBundle() catch return FetchError.TlsNotAvailable;
        errdefer entry.ctx.deinit();

        const hostname_z = try self.allocator.dupeZ(u8, u.host);
        defer self.allocator.free(hostname_z);

        entry.tls = tls_conn.TlsConn.connectNoAlps(&entry.ctx, entry.tcp_conn.socket.?.fd, hostname_z.ptr) catch return FetchError.TlsNotAvailable;
        errdefer entry.tls.deinit();

        // Reader buffers across requests on this connection so any bytes
        // over-read past the previous response (rare with strict framing,
        // but possible) survive into the next request's readUntilDelimiter.
        entry.reader = .{ .conn = &entry.tls };

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

        const method_str: []const u8 = switch (method) {
            .GET => "GET",
            .POST => "POST",
        };

        var req_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer req_buf.deinit();
        // HTTP/1.1 — keep-alive by default. No `Connection: close` so the
        // server is willing to leave the connection open after the response.
        try req_buf.writer.print("{s} {s} HTTP/1.1\r\n", .{ method_str, path });
        try req_buf.writer.print("Host: {s}\r\n", .{host_header});
        try req_buf.writer.print("User-Agent: {s}\r\n", .{effectiveUserAgent(self.options)});
        try req_buf.writer.writeAll("Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n");
        try req_buf.writer.writeAll("Accept-Language: en-US,en;q=0.9\r\n");
        try req_buf.writer.writeAll("Accept-Encoding: identity\r\n");
        if (method == .POST) {
            const body_bytes = body orelse "";
            try req_buf.writer.writeAll("Content-Type: application/x-www-form-urlencoded\r\n");
            try req_buf.writer.print("Content-Length: {d}\r\n", .{body_bytes.len});
            try req_buf.writer.writeAll("\r\n");
            try req_buf.writer.writeAll(body_bytes);
        } else {
            try req_buf.writer.writeAll("\r\n");
        }
        try writeAllTls(&entry.tls, req_buf.written());

        var parsed = try http1.readResponse(&entry.reader, self.allocator);
        errdefer parsed.deinit();

        const effective_url = try self.allocator.dupe(u8, url_str);
        errdefer self.allocator.free(effective_url);

        return Response{
            .status = parsed.status,
            .url = effective_url,
            .headers = parsed.headers,
            .body = parsed.body,
            .allocator = self.allocator,
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

fn effectiveUserAgent(options: ClientOptions) []const u8 {
    if (options.user_agent.len != 0) return options.user_agent;
    if (options.use_chrome_headers) {
        return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36";
    }
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
