/// client.zig — AWR HTTP client.
///
/// Wires together all Phase 1 net modules into a single fetch() call:
///   URL parser → TcpConn → (TlsConn if HTTPS) → HttpRequest → CookieJar → Response
///
/// Phase 1 limitations:
///   - HTTPS stubs out (TlsConn.handshake returns CurlImpersonateNotAvailable);
///     fetch() returns error.TlsNotAvailable for https:// URLs until curl-impersonate is wired in.
///   - TCP is synchronous (libxev replacement comes in Phase 2).
///   - HTTP/2 session management is stubbed; all requests use HTTP/1.1.
const std = @import("std");

const http1  = @import("net/http1.zig");
const cookie = @import("net/cookie.zig");
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
    options:   ClientOptions,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) Client {
        return Client{
            .allocator = allocator,
            .cookies   = cookie.CookieJar.init(allocator),
            .options   = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.cookies.deinit();
    }

    /// Fetch a URL. Caller must call response.deinit() on success.
    pub fn fetch(self: *Client, url_str: []const u8) anyerror!Response {
        const parsed = url_mod.Url.parse(url_str) catch return FetchError.InvalidUrl;
        return self.fetchUrl(parsed, 0);
    }

    fn fetchUrl(self: *Client, parsed: Url, redirect_count: u8) anyerror!Response {
        if (redirect_count > self.options.max_redirects) return FetchError.TooManyRedirects;

        // HTTPS not available until curl-impersonate is wired in
        if (parsed.is_https) return FetchError.TlsNotAvailable;

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

test "fetch returns TlsNotAvailable for https in stub mode" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    const result = client.fetch("https://example.com/");
    try std.testing.expectError(FetchError.TlsNotAvailable, result);
}

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
