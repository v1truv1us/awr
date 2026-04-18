/// url.zig — URL parser for http and https schemes.
///
/// Parses: scheme://host[:port]/path[?query]
/// Supported schemes: http (default port 80), https (default port 443)
/// Zero-allocation: all slices in the returned Url point into the original string.
const std = @import("std");

// ── Types ──────────────────────────────────────────────────────────────────

pub const Scheme = enum {
    http,
    https,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http  => 80,
            .https => 443,
        };
    }
};

pub const Url = struct {
    scheme: Scheme,
    host:   []const u8,  // slice into raw
    port:   u16,
    path:   []const u8,  // always starts with '/'
    query:  ?[]const u8, // null when no '?' present (does NOT include the '?')
    raw:    []const u8,  // original string

    /// Format "scheme://host:port". Caller owns the returned slice.
    pub fn origin(self: *const Url, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{
            @tagName(self.scheme), self.host, self.port,
        });
    }
};

pub const UrlError = error{
    MissingScheme,
    UnsupportedScheme,
    EmptyHost,
    InvalidPort,
};

// ── Parser ─────────────────────────────────────────────────────────────────

/// Parse a URL string. All slices in the returned Url point into `raw`.
/// No allocation is performed.
pub fn parse(raw: []const u8) UrlError!Url {
    // ── Scheme ───────────────────────────────────────────────────────────────
    const sep = std.mem.indexOf(u8, raw, "://") orelse return UrlError.MissingScheme;
    const scheme_str = raw[0..sep];
    const scheme: Scheme = blk: {
        if (std.ascii.eqlIgnoreCase(scheme_str, "https")) break :blk .https;
        if (std.ascii.eqlIgnoreCase(scheme_str, "http"))  break :blk .http;
        return UrlError.UnsupportedScheme;
    };

    // ── Authority + path ─────────────────────────────────────────────────────
    const after = raw[sep + 3 ..]; // skip "://"
    if (after.len == 0) return UrlError.EmptyHost;

    const slash          = std.mem.indexOfScalar(u8, after, '/');
    const authority      = if (slash) |s| after[0..s] else after;
    const path_and_query = if (slash) |s| after[s..] else "/";

    if (authority.len == 0) return UrlError.EmptyHost;

    // ── Host + optional port ─────────────────────────────────────────────────
    var host: []const u8 = authority;
    var port: u16 = scheme.defaultPort();

    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        const port_str = authority[colon + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch return UrlError.InvalidPort;
    }

    if (host.len == 0) return UrlError.EmptyHost;

    // ── Path + query ─────────────────────────────────────────────────────────
    var path: []const u8  = path_and_query;
    var query: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, path_and_query, '?')) |q| {
        path  = path_and_query[0..q];
        query = path_and_query[q + 1 ..];
    }

    return Url{
        .scheme = scheme,
        .host   = host,
        .port   = port,
        .path   = path,
        .query  = query,
        .raw    = raw,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "parse https URL with default port 443" {
    const url = try parse("https://example.com/path");
    try std.testing.expectEqual(Scheme.https, url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 443), url.port);
    try std.testing.expectEqualStrings("/path", url.path);
    try std.testing.expectEqual(@as(?[]const u8, null), url.query);
}

test "parse http URL with default port 80" {
    const url = try parse("http://example.com/");
    try std.testing.expectEqual(Scheme.http, url.scheme);
    try std.testing.expectEqual(@as(u16, 80), url.port);
}

test "parse URL with custom port" {
    const url = try parse("http://example.com:8080/api");
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 8080), url.port);
    try std.testing.expectEqualStrings("/api", url.path);
}

test "parse URL with path and query string" {
    const url = try parse("https://example.com/search?q=zig&page=1");
    try std.testing.expectEqualStrings("/search", url.path);
    try std.testing.expectEqualStrings("q=zig&page=1", url.query.?);
}

test "parse bare host with no path defaults to slash" {
    const url = try parse("http://example.com");
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqualStrings("/", url.path);
    try std.testing.expectEqual(@as(?[]const u8, null), url.query);
}

test "parse IPv4 literal host" {
    const url = try parse("http://127.0.0.1:8080/");
    try std.testing.expectEqualStrings("127.0.0.1", url.host);
    try std.testing.expectEqual(@as(u16, 8080), url.port);
}

test "Url.origin formats scheme://host:port" {
    const url = try parse("https://example.com:8443/path");
    const orig = try url.origin(std.testing.allocator);
    defer std.testing.allocator.free(orig);
    try std.testing.expectEqualStrings("https://example.com:8443", orig);
}

test "parse returns UnsupportedScheme for ftp" {
    try std.testing.expectError(UrlError.UnsupportedScheme, parse("ftp://example.com/"));
}

test "parse returns MissingScheme for bare host" {
    try std.testing.expectError(UrlError.MissingScheme, parse("example.com/path"));
}
