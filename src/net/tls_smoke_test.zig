/// Phase 3 Step 1 — BoringSSL linkage smoke test.
/// Confirms vendored static libs resolve and C API is reachable. No network I/O.

const std = @import("std");

const ssl_c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/crypto.h");
});

test "BoringSSL SSL_CTX_new and free do not crash" {
    const method = ssl_c.TLS_client_method();
    try std.testing.expect(method != null);
    const ctx = ssl_c.SSL_CTX_new(method);
    try std.testing.expect(ctx != null);
    ssl_c.SSL_CTX_free(ctx);
}

test "BoringSSL SSL_new and free do not crash" {
    const method = ssl_c.TLS_client_method();
    const ctx = ssl_c.SSL_CTX_new(method);
    defer ssl_c.SSL_CTX_free(ctx);
    const ssl = ssl_c.SSL_new(ctx);
    try std.testing.expect(ssl != null);
    ssl_c.SSL_free(ssl);
}

test "BoringSSL version string contains BoringSSL" {
    // OpenSSL_version(OPENSSL_VERSION) returns "BoringSSL" for BoringSSL,
    // confirming we linked the vendored lib rather than system OpenSSL.
    const ver_str = ssl_c.OpenSSL_version(ssl_c.OPENSSL_VERSION);
    try std.testing.expect(ver_str != null);
    const s = std.mem.span(ver_str);
    try std.testing.expect(std.mem.indexOf(u8, s, "BoringSSL") != null);
}
