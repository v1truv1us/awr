/// Phase 3 Step 1 — BoringSSL linkage smoke test.
/// Confirms vendored static libs resolve and C API is reachable. No network I/O.

const std = @import("std");

const tls_c = @cImport({
    @cInclude("tls_awr_shim.h");
});

test "BoringSSL shim allocates and frees ctx" {
    const ctx = tls_c.awr_tls_ctx_new();
    try std.testing.expect(ctx != null);
    tls_c.awr_tls_ctx_free(ctx);
}

test "BoringSSL shim exposes ALPS settings length" {
    try std.testing.expectEqual(@as(usize, 18), tls_c.awr_h2_alps_settings_len());
}

test "BoringSSL shim encodes ALPS settings payload" {
    var buf: [18]u8 = undefined;
    tls_c.awr_h2_alps_encode_settings(&buf);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[6]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[7]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[12]);
    try std.testing.expectEqual(@as(u8, 0x06), buf[13]);
}
