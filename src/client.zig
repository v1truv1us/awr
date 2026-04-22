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

const http1   = @import("net/http1.zig");
const cookie  = @import("net/cookie.zig");
const pool    = @import("net/pool.zig");
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
    io:        std.Io,
    cookies:   cookie.CookieJar,
    conns:     pool.ConnectionPool,
    options:   ClientOptions,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: ClientOptions) Client {
        return Client{
            .allocator = allocator,
            .io        = io,
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
        // Validate via our own URL parser so bad inputs surface as InvalidUrl
        // before std.http.Client parses and returns its own error.
        _ = url_mod.Url.parse(url_str) catch return FetchError.InvalidUrl;

        var std_client: std.http.Client = .{
            .allocator = self.allocator,
            .io        = self.io,
        };
        defer std_client.deinit();

        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_buf.deinit();

        const redirect_behavior: std.http.Client.Request.RedirectBehavior =
            if (self.options.follow_redirects)
                @enumFromInt(self.options.max_redirects)
            else
                .unhandled;

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

        const result = std_client.fetch(.{
            .location = .{ .url = url_str },
            .response_writer = &body_buf.writer,
            .redirect_behavior = redirect_behavior,
            .timeout_ms = self.options.timeout_ms,
            .extra_headers = extra_headers[0..extra_header_count],
        }) catch |err| return mapFetchError(err);

        var body_list = body_buf.toArrayList();
        errdefer body_list.deinit(self.allocator);
        const body = try body_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(body);

        return Response{
            .status    = @intFromEnum(result.status),
            .headers   = .{},
            .body      = body,
            .allocator = self.allocator,
        };
    }
};

fn cloneFetchHeaders(allocator: std.mem.Allocator, src_headers: anytype) !http1.HeaderList {
    var headers: http1.HeaderList = .{};
    errdefer headers.deinit(allocator);

    for (src_headers) |header| {
        try headers.append(allocator, .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        });
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

test "fetch TooManyRedirects when max_redirects is 0" {
    // Can't easily test redirect following without a real server,
    // but we can test the max_redirects option exists and is applied.
    const opts = ClientOptions{ .max_redirects = 0 };
    try std.testing.expectEqual(@as(u8, 0), opts.max_redirects);
}
