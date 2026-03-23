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
///
/// Phase 1 constraints reflected here:
///   - HTTPS is stubbed; only http:// URLs work end-to-end.
///   - example.com returns 200 for plain HTTP.
///   - Redirects to https:// are caught as TlsNotAvailable (expected in Phase 1).
const std    = @import("std");
const client = @import("client.zig");

// ── Helpers ────────────────────────────────────────────────────────────────

/// Make a single GET with minimal (non-Chrome) headers so the response body
/// arrives uncompressed.  Phase 1 has no decompression; Chrome headers send
/// `accept-encoding: gzip, deflate, br, zstd` which would give us a
/// compressed body we cannot parse.  A separate test verifies Chrome headers
/// produce a 200 without inspecting the compressed body.
fn getPlain(allocator: std.mem.Allocator, url: []const u8) !client.Response {
    var c = client.Client.init(allocator, .{
        .follow_redirects   = true,
        .max_redirects      = 5,
        .use_chrome_headers = false,  // no accept-encoding → uncompressed body
    });
    defer c.deinit();
    return c.fetch(url);
}

/// Make a GET with Chrome-132 headers (compressed response — body not checked).
fn getChrome(allocator: std.mem.Allocator, url: []const u8) !client.Response {
    var c = client.Client.init(allocator, .{
        .follow_redirects   = true,
        .max_redirects      = 5,
        .use_chrome_headers = true,
    });
    defer c.deinit();
    return c.fetch(url);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "e2e: GET http://example.com/ returns 200 with HTML body" {
    const allocator = std.testing.allocator;
    // Plain headers → no accept-encoding → uncompressed body we can inspect.
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
    // Verifies Chrome fingerprint headers are accepted; body may be compressed.
    const allocator = std.testing.allocator;
    var resp = try getChrome(allocator, "http://example.com/");
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "e2e: HTTPS fetch succeeds via std.crypto.tls (Phase 1)" {
    const allocator = std.testing.allocator;
    var c = client.Client.init(allocator, .{});
    defer c.deinit();
    var resp = try c.fetch("https://example.com/");
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Example Domain") != null);
}

test "e2e: invalid host returns DnsResolutionFailed" {
    const allocator = std.testing.allocator;
    var c = client.Client.init(allocator, .{});
    defer c.deinit();
    const result = c.fetch("http://this-host-definitely-does-not-exist.invalid/");
    try std.testing.expectError(client.FetchError.DnsResolutionFailed, result);
}
