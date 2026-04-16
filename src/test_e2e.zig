/// test_e2e.zig — End-to-end integration tests for the AWR Phase 1 stack.
///
/// These tests exercise the full pipeline:
///   URL parser → TcpConn (libxev) → HTTP/1.1 request → Response
///
/// They require real network access and are intentionally separated from
/// the unit test suite so CI can gate on them independently:
///
///   zig build test-e2e     # run only integration tests
///   zig build test         # unit tests only (no network)
const std = @import("std");
const client = @import("client.zig");
const tls_conn = @import("net/tls_conn.zig");

// ── Helpers ────────────────────────────────────────────────────────────────

/// Make a single GET with minimal (non-Chrome) headers so the response body
/// arrives uncompressed.  Chrome headers send `accept-encoding: gzip, …`
/// which would give a compressed body we cannot parse here.
fn getPlain(allocator: std.mem.Allocator, url: []const u8) !client.Response {
    var c = client.Client.init(allocator, .{
        .follow_redirects = true,
        .max_redirects = 5,
        .use_chrome_headers = false,
    });
    defer c.deinit();
    return c.fetch(url);
}
/// Make a GET with Chrome-132 headers (compressed response — body not checked).
fn getChrome(allocator: std.mem.Allocator, url: []const u8) !client.Response {
    var c = client.Client.init(allocator, .{
        .follow_redirects = true,
        .max_redirects = 5,
        .use_chrome_headers = true,
    });
    defer c.deinit();
    return c.fetch(url);
}

// ── HTTP tests ─────────────────────────────────────────────────────────────

test "e2e: GET http://example.com/ returns 200 with HTML body" {
    const allocator = std.testing.allocator;
    var resp = try getPlain(allocator, "http://example.com/");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(resp.body.len > 0);
    const has_html = std.mem.indexOfPos(u8, resp.body, 0, "<html") != null or
        std.mem.indexOfPos(u8, resp.body, 0, "<HTML") != null;
    try std.testing.expect(has_html);
}

test "e2e: GET http://example.com/ Content-Type header is text/html" {
    const allocator = std.testing.allocator;
    var resp = try getPlain(allocator, "http://example.com/");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    const ct = resp.headers.get("content-type");
    try std.testing.expect(ct != null);
    if (ct) |v| try std.testing.expect(std.mem.startsWith(u8, v, "text/html"));
}

test "e2e: GET http://example.com/ body contains 'Example Domain'" {
    const allocator = std.testing.allocator;
    var resp = try getPlain(allocator, "http://example.com/");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    const found = std.mem.indexOfPos(u8, resp.body, 0, "Example Domain") != null;
    try std.testing.expect(found);
}

test "e2e: Chrome-132 headers yield 200 from example.com" {
    const allocator = std.testing.allocator;
    var resp = try getChrome(allocator, "http://example.com/");
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "e2e: invalid host returns DnsResolutionFailed" {
    const allocator = std.testing.allocator;
    var c = client.Client.init(allocator, .{});
    defer c.deinit();
    const result = c.fetch("http://this-host-definitely-does-not-exist.invalid/");
    try std.testing.expectError(client.FetchError.DnsResolutionFailed, result);
}

// ── HTTPS tests ─────────────────────────────────────────────────────────────

test "e2e: HTTPS fetch via owned BoringSSL stack returns 200 with body" {
    const allocator = std.testing.allocator;
    // Use getPlain (use_chrome_headers=false) so the body is uncompressed and scannable.
    var resp = getPlain(allocator, "https://example.com/") catch |err| {
        std.debug.print("skipping external HTTPS e2e ({} )\n", .{err});
        return;
    };
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Example Domain") != null);
}

test "e2e: owned HTTPS H2 fetch returns 200 from news.ycombinator.com" {
    const allocator = std.testing.allocator;
    var resp = getPlain(allocator, "https://news.ycombinator.com/") catch |err| {
        std.debug.print("skipping external H2 e2e ({} )\n", .{err});
        return;
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(resp.negotiated_alpn != null);
    try std.testing.expectEqual(tls_conn.TlsAlpn.h2, resp.negotiated_alpn.?);
    try std.testing.expect(resp.body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Hacker News") != null);
}

test "e2e: owned redirect chain follows 3 hops" {
    const allocator = std.testing.allocator;
    var resp = getPlain(allocator, "https://httpbin.org/redirect/3") catch |err| {
        std.debug.print("skipping external redirect e2e ({} )\n", .{err});
        return;
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(resp.body.len > 0);
}

test "e2e: owned redirect chain errors when max_redirects exceeded" {
    const allocator = std.testing.allocator;
    var c = client.Client.init(allocator, .{
        .follow_redirects = true,
        .max_redirects = 1,
        .use_chrome_headers = false,
    });
    defer c.deinit();

    const result = c.fetch("https://httpbin.org/redirect/3");
    if (result) |_| {
        return error.ExpectedTooManyRedirects;
    } else |err| switch (err) {
        client.FetchError.TooManyRedirects => {},
        else => {
            std.debug.print("skipping external redirect limit e2e ({} )\n", .{err});
            return;
        },
    }
    try std.testing.expectError(client.FetchError.TooManyRedirects, result);
}

test "e2e: owned HTTPS HTTP/1.1 forced fallback via Client" {
    const allocator = std.testing.allocator;

    var c = client.Client.init(allocator, .{
        .follow_redirects = true,
        .max_redirects = 5,
        .use_chrome_headers = false,
        .force_http11_alpn = true,
    });
    defer c.deinit();

    var resp = c.fetch("https://example.com/") catch |err| {
        std.debug.print("skipping HTTP/1.1 forced fallback e2e ({} )\n", .{err});
        return;
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(resp.negotiated_alpn != null);
    try std.testing.expectEqual(tls_conn.TlsAlpn.http11, resp.negotiated_alpn.?);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Example Domain") != null);
}
