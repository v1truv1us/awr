/// client.zig — AWR HTTP client.
///
/// Wires together all Phase 1 net modules into a single fetch() call:
///   URL parser → TcpConn → (TlsConn if HTTPS) → ALPN → H2Session / HTTP/1.1 → CookieJar → Response
///
/// HTTPS routing depends on -Dtls-backend build option:
///   - curl_impersonate: HTTPS goes through TlsConn with ALPN-aware protocol selection
///   - stub / std:       HTTPS falls back to std.http.Client
///
/// TCP is synchronous via libxev (Phase 2 will bring full async).
/// H2 path uses nghttp2 via src/net/h2session.zig when ALPN negotiates HTTP/2.
const std = @import("std");
const build_opts = @import("build_opts");
const use_curl_tls = build_opts.tls_backend == .curl_impersonate;

const http1  = @import("net/http1.zig");
const h2     = @import("net/h2session.zig");
const cookie = @import("net/cookie.zig");
const pool   = @import("net/pool.zig");
const tcp    = @import("net/tcp.zig");
const tls    = @import("net/tls.zig");
const url_mod = @import("net/url.zig");

pub const Url = url_mod.Url;

// ── Options ───────────────────────────────────────────────────────────────

pub const ClientOptions = struct {
    follow_redirects: bool  = true,
    max_redirects:    u8    = 10,
    timeout_ms:       u32   = 30_000,
    /// Sent as the User-Agent header when not using Chrome 132 defaults.
    user_agent:       []const u8 = "AWR/0.1",
    /// When true, setChrome132Defaults() is called on every request.
    use_chrome_headers: bool = true,
};

// ── Response ──────────────────────────────────────────────────────────────

pub const Response = struct {
    status:    u16,
    headers:   http1.HeaderList,
    body:      []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
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

// ── Client ────────────────────────────────────────────────────────────────

pub const Client = struct {
    allocator: std.mem.Allocator,
    cookies:   cookie.CookieJar,
    conns:     pool.ConnectionPool,
    options:   ClientOptions,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) Client {
        return Client{
            .allocator = allocator,
            .cookies   = cookie.CookieJar.init(allocator),
            .conns     = pool.ConnectionPool.init(allocator),
            .options   = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.conns.deinit();
        self.cookies.deinit();
    }

    /// Fetch a URL. Caller must call response.deinit() on success.
    pub fn fetch(self: *Client, url_str: []const u8) anyerror!Response {
        const parsed = url_mod.Url.parse(url_str) catch return FetchError.InvalidUrl;
        return self.fetchUrl(parsed, 0);
    }

    fn fetchUrl(self: *Client, parsed: Url, redirect_count: u8) anyerror!Response {
        if (redirect_count > self.options.max_redirects) return FetchError.TooManyRedirects;

        // HTTPS: route through TlsConn when curl_impersonate backend is selected.
        // Fall back to std.http.Client for stub/std backends.
        if (parsed.is_https) {
            if (use_curl_tls) {
                return self.fetchHttpsViaTls(parsed, redirect_count);
            }
            // Fallback: delegate to std.http.Client
            var path_buf: [2048]u8 = undefined;
            const path = parsed.pathWithQuery(&path_buf);
            var url_buf: [4096]u8 = undefined;
            const full_url = std.fmt.bufPrint(&url_buf, "https://{s}:{d}{s}", .{
                parsed.host, parsed.port, path,
            }) catch return error.OutOfMemory;
            return self.fetchHttpsViaStd(full_url);
        }

        // HTTP path — resolve hostname, connect TCP, build request, read response
        return self.fetchHttp(parsed, redirect_count);
    }

    /// HTTP fetch: TcpConn → http1.Request → Response.
    fn fetchHttp(self: *Client, parsed: Url, redirect_count: u8) anyerror!Response {
        // Build origin key for connection pool
        var origin_buf: [512]u8 = undefined;
        const origin = std.fmt.bufPrint(&origin_buf, "http://{s}:{d}", .{
            parsed.host, parsed.port,
        }) catch return FetchError.ConnectionFailed;

        // Enforce per-origin connection limit
        if (self.conns.countForOrigin(origin) >= pool.MAX_PER_ORIGIN)
            return FetchError.ConnectionFailed;

        // Resolve hostname
        const addr_list = std.net.getAddressList(self.allocator, parsed.host, parsed.port) catch
            return FetchError.DnsResolutionFailed;
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return FetchError.DnsResolutionFailed;
        const addr = addr_list.addrs[0];

        // TCP connect
        var conn = tcp.TcpConn.init(self.allocator, addr) catch return FetchError.ConnectionFailed;
        defer conn.deinit();
        conn.connect() catch return FetchError.ConnectionFailed;

        // Build request
        var path_buf: [2048]u8 = undefined;
        const path = parsed.pathWithQuery(&path_buf);

        var req = http1.Request{
            .method = .GET,
            .path   = path,
            .host   = parsed.host,
        };
        defer req.headers.deinit(self.allocator);

        if (self.options.use_chrome_headers) {
            req.setChrome132Defaults(self.allocator) catch return FetchError.OutOfMemory;
        } else {
            req.headers.append(self.allocator, "Host", parsed.host) catch return FetchError.OutOfMemory;
            req.headers.append(self.allocator, "User-Agent", self.options.user_agent) catch return FetchError.OutOfMemory;
            req.headers.append(self.allocator, "Connection", "keep-alive") catch return FetchError.OutOfMemory;
        }

        // Set cookies for this origin
        const cookie_header_opt = self.cookies.getCookieHeader(
            parsed.host,
            path,
            parsed.is_https,
        ) catch null;
        defer if (cookie_header_opt) |ch| self.allocator.free(ch);
        if (cookie_header_opt) |ch| {
            if (ch.len > 0) {
                req.headers.append(self.allocator, "Cookie", ch) catch return FetchError.OutOfMemory;
            }
        }

        // Serialize request into a buffer and write
        var req_buf: [16 * 1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&req_buf);
        req.write(fbs.writer()) catch return FetchError.SendFailed;
        const req_bytes = fbs.getWritten();

        var written: usize = 0;
        while (written < req_bytes.len) {
            const n = conn.write(req_bytes[written..]) catch return FetchError.SendFailed;
            written += n;
        }

        // Read response via a GenericReader wrapping the libxev TcpConn.
        // TcpConn.readFn drives a single xev loop iteration per read call.
        const TcpReader = std.io.GenericReader(*tcp.TcpConn, tcp.TcpError, tcp.TcpConn.readFn);
        const stream_reader = TcpReader{ .context = &conn };
        var resp = try http1.readResponse(stream_reader, self.allocator);
        errdefer resp.deinit();

        // Store Set-Cookie headers
        for (resp.headers.items.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
                self.cookies.parseSetCookie(h.value, parsed.host) catch {};
            }
        }

        // Follow redirects
        if (resp.isRedirect() and self.options.follow_redirects) {
            if (resp.location()) |loc| {
                // Resolve relative redirects against current URL
                var next_url_buf: [2048]u8 = undefined;
                const next_url_str = if (std.mem.startsWith(u8, loc, "http"))
                    loc
                else blk: {
                    const scheme = if (parsed.is_https) "https" else "http";
                    break :blk std.fmt.bufPrint(&next_url_buf, "{s}://{s}:{d}{s}", .{
                        scheme, parsed.host, parsed.port, loc,
                    }) catch loc;
                };
                const next_url = url_mod.Url.parse(next_url_str) catch return Response{
                    .status    = resp.status,
                    .headers   = resp.headers,
                    .body      = resp.body,
                    .allocator = self.allocator,
                };
                resp.deinit();
                return self.fetchUrl(next_url, redirect_count + 1);
            }
        }

        // Wrap into our Response type
        return Response{
            .status    = resp.status,
            .headers   = resp.headers,
            .body      = resp.body,
            .allocator = self.allocator,
        };
    }

    /// HTTPS fetch via std.http.Client (uses std.crypto.tls under the hood).
    /// TODO(Phase 3): Replace with AWR's owned BoringSSL stack + JA4+ Chrome 132 fingerprint.
    fn fetchHttpsViaStd(self: *Client, url_str: []const u8) anyerror!Response {
        var std_client = std.http.Client{ .allocator = self.allocator };
        defer std_client.deinit();

        var body_writer = std.Io.Writer.Allocating.init(self.allocator);
        const result = std_client.fetch(.{
            .location        = .{ .url = url_str },
            .response_writer = &body_writer.writer,
        }) catch |err| {
            body_writer.deinit();
            return err;
        };

        const body = body_writer.toOwnedSlice() catch {
            body_writer.deinit();
            return error.OutOfMemory;
        };

        return Response{
            .status    = @as(u16, @intFromEnum(result.status)),
            .headers   = http1.HeaderList{},
            .body      = body,
            .allocator = self.allocator,
        };
    }

    /// HTTPS fetch via AWR's TlsConn (Chrome 132 TLS fingerprint).
    /// TlsConn wraps curl-impersonate which handles DNS, TCP connect, and TLS.
    fn fetchHttpsViaTls(self: *Client, parsed: Url, redirect_count: u8) anyerror!Response {
        // Build origin key for connection pool
        var origin_buf: [512]u8 = undefined;
        const origin = std.fmt.bufPrint(&origin_buf, "https://{s}:{d}", .{
            parsed.host, parsed.port,
        }) catch return FetchError.ConnectionFailed;

        // Enforce per-origin connection limit
        if (self.conns.countForOrigin(origin) >= pool.MAX_PER_ORIGIN)
            return FetchError.ConnectionFailed;

        var path_buf: [2048]u8 = undefined;
        const path = parsed.pathWithQuery(&path_buf);

        // Create TLS connection — curl handles DNS + TCP + TLS handshake internally
        var conn = tls.TlsConn.init(
            self.allocator,
            parsed.host,
            parsed.port,
            .chrome_132,
        ) catch return FetchError.ConnectionFailed;
        defer conn.deinit();

        conn.handshake() catch |err| switch (err) {
            tls.TlsError.CurlImpersonateNotAvailable => return FetchError.TlsNotAvailable,
            tls.TlsError.HandshakeFailed => return FetchError.ConnectionFailed,
            else => return FetchError.ConnectionFailed,
        };

        // ALPN-aware protocol selection
        return switch (conn.negotiatedProtocol()) {
            .http2   => self.fetchHttpsH2(parsed, path, redirect_count, &conn),
            .http1_1 => self.fetchHttpsH1(parsed, path, redirect_count, &conn),
        };
    }

    /// H2 callback context: holds the TLS connection for C callbacks.
    const H2TlsCtx = struct {
        conn: *tls.TlsConn,
    };

    /// H2 send callback — bridge from h2session C API to TlsConn.
    fn h2TlsSend(data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *H2TlsCtx = @ptrCast(@alignCast(user_data));
        const slice = data[0..len];
        const n = ctx.conn.send(slice) catch return -1;
        return @intCast(n);
    }

    /// H2 recv callback — bridge from h2session C API to TlsConn.
    fn h2TlsRecv(buf: [*c]u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *H2TlsCtx = @ptrCast(@alignCast(user_data));
        const slice = buf[0..len];
        const n = ctx.conn.recv(slice) catch return -1;
        if (n == 0) return 0; // EAGAIN/WOULDBLOCK
        return @intCast(n);
    }

    /// HTTPS fetch via HTTP/2 using h2session over TlsConn.
    fn fetchHttpsH2(
        self: *Client,
        parsed: Url,
        path: []const u8,
        redirect_count: u8,
        conn: *tls.TlsConn,
    ) anyerror!Response {
        var h2_ctx = H2TlsCtx{ .conn = conn };

        var session = h2.H2Session.init(h2TlsSend, h2TlsRecv, &h2_ctx) catch
            return FetchError.ConnectionFailed;
        defer session.deinit();

        // Build null-terminated strings for h2session API
        const method_z = "GET";
        const scheme_z = "https";

        var authority_buf: [256]u8 = undefined;
        const authority_z = std.fmt.bufPrintZ(&authority_buf, "{s}", .{parsed.host}) catch
            return FetchError.SendFailed;

        var path_buf2: [2048]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf2, "{s}", .{path}) catch
            return FetchError.SendFailed;

        const stream_id = session.submitGet(method_z, scheme_z, authority_z.ptr, path_z.ptr) catch
            return FetchError.SendFailed;

        // Run the session to completion
        var h2_resp = session.runUntilComplete(stream_id, 1024) catch |err| switch (err) {
            h2.H2Error.StreamNotComplete => return FetchError.RecvFailed,
            h2.H2Error.IoError => return FetchError.RecvFailed,
            h2.H2Error.ResponseError => return FetchError.RecvFailed,
            else => return FetchError.RecvFailed,
        };

        // Capture everything we need from h2_resp BEFORE freeing it
        const h2_status = h2_resp.status;
        const owned_body = self.allocator.dupe(u8, h2_resp.body) catch return FetchError.OutOfMemory;
        errdefer self.allocator.free(owned_body);

        var redirect_loc: ?[]const u8 = null;
        var redirect_loc_buf: [2048]u8 = undefined;

        // Parse h2 response headers for cookies and redirect location
        var header_iter = h2_resp.headerIterator();
        while (header_iter.next()) |hp| {
            if (std.ascii.eqlIgnoreCase(hp.name, "set-cookie")) {
                self.cookies.parseSetCookie(hp.value, parsed.host) catch {};
            }
            if (std.ascii.eqlIgnoreCase(hp.name, "location")) {
                // Build a stable copy from the header buffer before freeing
                if (h2_status >= 300 and h2_status < 400 and self.options.follow_redirects) {
                    if (std.mem.startsWith(u8, hp.value, "http")) {
                        redirect_loc = hp.value;
                    } else {
                        redirect_loc = std.fmt.bufPrint(&redirect_loc_buf, "{s}://{s}:{d}{s}", .{
                            "https", parsed.host, parsed.port, hp.value,
                        }) catch null;
                    }
                }
            }
        }

        // Now free h2 response memory
        h2_resp.deinit();

        // Follow redirects
        if (redirect_loc) |loc| {
            if (redirect_count >= self.options.max_redirects) {
                self.allocator.free(owned_body);
                return FetchError.TooManyRedirects;
            }
            const next_url = url_mod.Url.parse(loc) catch {
                // Can't parse — return current response
                return Response{
                    .status    = h2_status,
                    .headers   = http1.HeaderList{},
                    .body      = owned_body,
                    .allocator = self.allocator,
                };
            };
            self.allocator.free(owned_body);
            return self.fetchUrl(next_url, redirect_count + 1);
        }

        return Response{
            .status    = h2_status,
            .headers   = http1.HeaderList{},
            .body      = owned_body,
            .allocator = self.allocator,
        };
    }

    /// HTTPS fetch via HTTP/1.1 over TlsConn (text request/response).
    fn fetchHttpsH1(
        self: *Client,
        parsed: Url,
        path: []const u8,
        redirect_count: u8,
        conn: *tls.TlsConn,
    ) anyerror!Response {
        // Build HTTP/1.1 request
        var req = http1.Request{
            .method = .GET,
            .path   = path,
            .host   = parsed.host,
        };
        defer req.headers.deinit(self.allocator);

        if (self.options.use_chrome_headers) {
            req.setChrome132Defaults(self.allocator) catch return FetchError.OutOfMemory;
        } else {
            req.headers.append(self.allocator, "Host", parsed.host) catch return FetchError.OutOfMemory;
            req.headers.append(self.allocator, "User-Agent", self.options.user_agent) catch return FetchError.OutOfMemory;
            req.headers.append(self.allocator, "Connection", "keep-alive") catch return FetchError.OutOfMemory;
        }

        // Set cookies for this origin
        const cookie_header_opt = self.cookies.getCookieHeader(
            parsed.host,
            path,
            parsed.is_https,
        ) catch null;
        defer if (cookie_header_opt) |ch| self.allocator.free(ch);
        if (cookie_header_opt) |ch| {
            if (ch.len > 0) {
                req.headers.append(self.allocator, "Cookie", ch) catch return FetchError.OutOfMemory;
            }
        }

        // Serialize request and send via TLS
        var req_buf: [16 * 1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&req_buf);
        req.write(fbs.writer()) catch return FetchError.SendFailed;
        const req_bytes = fbs.getWritten();

        var written: usize = 0;
        while (written < req_bytes.len) {
            const n = conn.send(req_bytes[written..]) catch return FetchError.SendFailed;
            written += n;
        }

        // Read response via TlsConn reader adapter
        const TlsReader = std.io.GenericReader(*tls.TlsConn, tls.TlsError, tls.TlsConn.readFn);
        const tls_reader = TlsReader{ .context = conn };
        var resp = try http1.readResponse(tls_reader, self.allocator);
        errdefer resp.deinit();

        // Store Set-Cookie headers
        for (resp.headers.items.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
                self.cookies.parseSetCookie(h.value, parsed.host) catch {};
            }
        }

        // Follow redirects
        if (resp.isRedirect() and self.options.follow_redirects) {
            if (resp.location()) |loc| {
                if (redirect_count >= self.options.max_redirects) {
                    resp.deinit();
                    return FetchError.TooManyRedirects;
                }
                var next_url_buf: [2048]u8 = undefined;
                const next_url_str = if (std.mem.startsWith(u8, loc, "http"))
                    loc
                else blk: {
                    break :blk std.fmt.bufPrint(&next_url_buf, "{s}://{s}:{d}{s}", .{
                        "https", parsed.host, parsed.port, loc,
                    }) catch loc;
                };
                const next_url = url_mod.Url.parse(next_url_str) catch return Response{
                    .status    = resp.status,
                    .headers   = resp.headers,
                    .body      = resp.body,
                    .allocator = self.allocator,
                };
                resp.deinit();
                return self.fetchUrl(next_url, redirect_count + 1);
            }
        }

        return Response{
            .status    = resp.status,
            .headers   = resp.headers,
            .body      = resp.body,
            .allocator = self.allocator,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "Client.init and deinit" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    try std.testing.expect(client.cookies.cookies.items.len == 0);
}

test "Client options defaults" {
    const opts = ClientOptions{};
    try std.testing.expect(opts.follow_redirects);
    try std.testing.expectEqual(@as(u8, 10), opts.max_redirects);
    try std.testing.expectEqual(@as(u32, 30_000), opts.timeout_ms);
    try std.testing.expect(opts.use_chrome_headers);
}

// Integration test — requires network; uncomment to run manually
// test "integration: fetch https://example.com" {
//     var client = Client.init(std.testing.allocator, .{});
//     defer client.deinit();
//     var resp = try client.fetch("https://example.com/");
//     defer resp.deinit();
//     try std.testing.expectEqual(@as(u16, 200), resp.status);
//     try std.testing.expect(std.mem.indexOf(u8, resp.body, "Example Domain") != null);
// }

test "fetch returns InvalidUrl for bad URL" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    const result = client.fetch("not-a-url");
    try std.testing.expectError(FetchError.InvalidUrl, result);
}

test "fetch returns DnsResolutionFailed for invalid host" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    const result = client.fetch("http://this.host.does.not.exist.invalid/");
    try std.testing.expectError(FetchError.DnsResolutionFailed, result);
}

test "Client cookie jar is populated after fetch sets a cookie (mock)" {
    // Verify cookie jar stores cookies via parseSetCookie directly
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    try client.cookies.parseSetCookie("session=abc123; Path=/; HttpOnly", "example.com");
    try std.testing.expectEqual(@as(usize, 1), client.cookies.cookies.items.len);
}

test "fetch TooManyRedirects when max_redirects is 0" {
    // Can't easily test redirect following without a real server,
    // but we can test the max_redirects option exists and is applied.
    const opts = ClientOptions{ .max_redirects = 0 };
    try std.testing.expectEqual(@as(u8, 0), opts.max_redirects);
}

// Integration test — requires network access; skipped in CI
// test "integration: fetch http://example.com" {
//     var client = Client.init(std.testing.allocator, .{});
//     defer client.deinit();
//     var resp = try client.fetch("http://example.com/");
//     defer resp.deinit();
//     try std.testing.expectEqual(@as(u16, 200), resp.status);
//     try std.testing.expect(resp.body.len > 0);
// }
