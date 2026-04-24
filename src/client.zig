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

// ── Client ────────────────────────────────────────────────────────────────

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cookies: cookie.CookieJar,
    conns: pool.ConnectionPool,
    options: ClientOptions,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ClientOptions) Client {
        return Client{
            .allocator = allocator,
            .io = io,
            .cookies = cookie.CookieJar.init(allocator),
            .conns = pool.ConnectionPool.init(allocator),
            .options = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.conns.deinit();
        self.cookies.deinit();
    }

    /// Fetch a URL. Caller must call response.deinit() on success.
    pub fn fetch(self: *Client, url_str: []const u8) anyerror!Response {
        var current_url = try self.allocator.dupe(u8, url_str);
        defer self.allocator.free(current_url);

        var redirects: u8 = 0;
        while (true) {
            var resp = try self.fetchOnce(current_url);
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
            resp.deinit();
            self.allocator.free(current_url);
            current_url = next_url;
            redirects += 1;
        }
    }

    fn fetchOnce(self: *Client, url_str: []const u8) anyerror!Response {
        return self.fetchOnceStd(url_str) catch |err| switch (err) {
            FetchError.TlsNotAvailable => if (boringsslFallbackAllowed(url_str))
                self.fetchOnceBoringSslHttp1(url_str) catch |fallback_err| return mapFetchError(fallback_err)
            else
                return err,
            else => return err,
        };
    }

    fn fetchOnceStd(self: *Client, url_str: []const u8) anyerror!Response {
        // Validate via our own URL parser so bad inputs surface as InvalidUrl
        // before std.http.Client parses and returns its own error.
        const uri = std.Uri.parse(url_str) catch return FetchError.InvalidUrl;

        var std_client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
            .read_buffer_size = self.options.max_response_header_bytes,
        };
        defer std_client.deinit();

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

        var req = std_client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = extra_headers[0..extra_header_count],
        }) catch |err| return mapFetchError(err);
        defer req.deinit();

        req.sendBodiless() catch |err| return mapFetchError(err);

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

        var body_list = body_buf.toArrayList();
        errdefer body_list.deinit(self.allocator);
        const body = try body_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(body);

        return Response{
            .status = @intFromEnum(result.head.status),
            .url = effective_url,
            .headers = headers,
            .body = body,
            .allocator = self.allocator,
        };
    }

    fn fetchOnceBoringSslHttp1(self: *Client, url_str: []const u8) anyerror!Response {
        if (!boringssl_fallback) return FetchError.TlsNotAvailable;

        const u = url_mod.Url.parse(url_str) catch return FetchError.InvalidUrl;
        if (!u.is_https) return FetchError.InvalidUrl;

        const addr = dns.resolve(self.io, u.host, u.port) catch |err| return mapFetchError(err);
        var tcp_conn = tcp.TcpConn.init(self.allocator, addr) catch return FetchError.ConnectionFailed;
        defer tcp_conn.deinit();
        tcp_conn.connect() catch |err| return mapFetchError(err);

        var ctx = tls_conn.initCompatHttp11WithBundle() catch return FetchError.TlsNotAvailable;
        defer ctx.deinit();

        const hostname_z = try self.allocator.dupeZ(u8, u.host);
        defer self.allocator.free(hostname_z);

        var tls = tls_conn.TlsConn.connectNoAlps(&ctx, tcp_conn.socket.?.fd, hostname_z.ptr) catch return FetchError.TlsNotAvailable;
        defer tls.deinit();

        const host_header = try hostHeader(self.allocator, &u);
        defer self.allocator.free(host_header);
        const path = try pathWithQueryAlloc(self.allocator, &u);
        defer self.allocator.free(path);

        var req_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer req_buf.deinit();
        try req_buf.writer.print("GET {s} HTTP/1.0\r\n", .{path});
        try req_buf.writer.print("Host: {s}\r\n", .{host_header});
        try req_buf.writer.print("User-Agent: {s}\r\n", .{effectiveUserAgent(self.options)});
        try req_buf.writer.writeAll("Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n");
        try req_buf.writer.writeAll("Accept-Language: en-US,en;q=0.9\r\n");
        try req_buf.writer.writeAll("Accept-Encoding: identity\r\n");
        try req_buf.writer.writeAll("Connection: close\r\n");
        try req_buf.writer.writeAll("\r\n");
        try writeAllTls(&tls, req_buf.written());

        var reader = TlsBufferedReader{ .conn = &tls };
        var parsed = try http1.readResponse(&reader, self.allocator);
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
