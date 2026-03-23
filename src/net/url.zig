/// url.zig — URL parser for AWR.
///
/// Parses scheme://host[:port]/path[?query] into a Url struct.
/// Supports http (default port 80) and https (default port 443).
const std = @import("std");

pub const ParseError = error{
    MissingScheme,
    UnsupportedScheme,
    MissingHost,
    InvalidPort,
};

pub const Url = struct {
    /// "http" or "https"
    scheme: []const u8,
    /// Hostname, e.g. "example.com"
    host: []const u8,
    /// Port number (default: 80 for http, 443 for https)
    port: u16,
    /// Path including leading slash, e.g. "/" or "/path/to/page"
    path: []const u8,
    /// Query string without leading '?', or null if absent
    query: ?[]const u8,
    /// True when scheme == "https"
    is_https: bool,

    /// Parse a URL string. All returned slices point into `input` — no allocation.
    pub fn parse(input: []const u8) ParseError!Url {
        var rest = input;

        // Scheme
        const scheme_end = std.mem.indexOf(u8, rest, "://") orelse return ParseError.MissingScheme;
        const scheme = rest[0..scheme_end];
        rest = rest[scheme_end + 3 ..];

        const is_https = blk: {
            if (std.ascii.eqlIgnoreCase(scheme, "https")) break :blk true;
            if (std.ascii.eqlIgnoreCase(scheme, "http"))  break :blk false;
            return ParseError.UnsupportedScheme;
        };
        const default_port: u16 = if (is_https) 443 else 80;

        if (rest.len == 0) return ParseError.MissingHost;

        // Split authority from path
        const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..path_start];
        rest = rest[path_start..];
        if (rest.len == 0) rest = "/";

        if (authority.len == 0) return ParseError.MissingHost;

        // Split host from port
        var host: []const u8 = authority;
        var port: u16 = default_port;

        // Handle IPv6 addresses like [::1]:8080
        if (authority[0] == '[') {
            const bracket_end = std.mem.indexOfScalar(u8, authority, ']') orelse return ParseError.MissingHost;
            host = authority[1..bracket_end];
            const after_bracket = authority[bracket_end + 1 ..];
            if (after_bracket.len > 1 and after_bracket[0] == ':') {
                port = std.fmt.parseInt(u16, after_bracket[1..], 10) catch return ParseError.InvalidPort;
            }
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return ParseError.InvalidPort;
        }

        if (host.len == 0) return ParseError.MissingHost;

        // Split path from query
        var path = rest;
        var query: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
            path  = rest[0..q];
            query = rest[q + 1 ..];
        }

        return Url{
            .scheme   = scheme,
            .host     = host,
            .port     = port,
            .path     = path,
            .query    = query,
            .is_https = is_https,
        };
    }

    /// Returns "host:port" as a stack-allocated buffer (used as pool key).
    /// Caller must provide a buffer of at least host.len + 7 bytes.
    pub fn origin(self: *const Url, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ self.host, self.port }) catch buf[0..0];
    }

    /// Full path including query string, e.g. "/search?q=zig"
    pub fn pathWithQuery(self: *const Url, buf: []u8) []const u8 {
        if (self.query) |q| {
            return std.fmt.bufPrint(buf, "{s}?{s}", .{ self.path, q }) catch self.path;
        }
        return self.path;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "parse https://example.com/" {
    const u = try Url.parse("https://example.com/");
    try std.testing.expectEqualStrings("https", u.scheme);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/", u.path);
    try std.testing.expect(u.query == null);
    try std.testing.expect(u.is_https);
}

test "parse http://example.com" {
    const u = try Url.parse("http://example.com");
    try std.testing.expectEqualStrings("http", u.scheme);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 80), u.port);
    try std.testing.expectEqualStrings("/", u.path);
    try std.testing.expect(!u.is_https);
}

test "parse https with custom port" {
    const u = try Url.parse("https://api.example.com:8443/v1/data");
    try std.testing.expectEqualStrings("api.example.com", u.host);
    try std.testing.expectEqual(@as(u16, 8443), u.port);
    try std.testing.expectEqualStrings("/v1/data", u.path);
}

test "parse http with custom port" {
    const u = try Url.parse("http://localhost:3000/api");
    try std.testing.expectEqualStrings("localhost", u.host);
    try std.testing.expectEqual(@as(u16, 3000), u.port);
    try std.testing.expectEqualStrings("/api", u.path);
}

test "parse URL with query string" {
    const u = try Url.parse("https://search.example.com/search?q=zig+lang&page=2");
    try std.testing.expectEqualStrings("/search", u.path);
    try std.testing.expectEqualStrings("q=zig+lang&page=2", u.query.?);
}

test "parse bare host defaults to root path" {
    const u = try Url.parse("http://example.com");
    try std.testing.expectEqualStrings("/", u.path);
    try std.testing.expectEqual(@as(u16, 80), u.port);
}

test "parse IPv4 address" {
    const u = try Url.parse("http://127.0.0.1:8080/ping");
    try std.testing.expectEqualStrings("127.0.0.1", u.host);
    try std.testing.expectEqual(@as(u16, 8080), u.port);
}

test "origin returns host:port" {
    const u = try Url.parse("https://example.com/");
    var buf: [64]u8 = undefined;
    const o = u.origin(&buf);
    try std.testing.expectEqualStrings("example.com:443", o);
}

test "pathWithQuery includes query" {
    const u = try Url.parse("https://example.com/search?q=test");
    var buf: [128]u8 = undefined;
    const pq = u.pathWithQuery(&buf);
    try std.testing.expectEqualStrings("/search?q=test", pq);
}

test "error on missing scheme" {
    try std.testing.expectError(ParseError.MissingScheme, Url.parse("example.com/path"));
}

test "error on unsupported scheme" {
    try std.testing.expectError(ParseError.UnsupportedScheme, Url.parse("ftp://example.com"));
}
