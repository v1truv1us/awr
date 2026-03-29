/// ca_bundle.zig — Embedded Mozilla CA bundle for TLS verification.
///
/// Source: https://curl.se/ca/cacert.pem (Mozilla, public domain)
/// Update cadence: when BoringSSL or curl publishes a new snapshot.
const std = @import("std");

const tls_conn = @import("tls_conn.zig");

/// Embedded PEM bytes from the Mozilla CA bundle.
pub const pem_bytes = @embedFile("ca-bundle.pem");

/// Loads the embedded CA bundle into a TlsCtx.
pub fn load(ctx: *tls_conn.TlsCtx) tls_conn.TlsError!void {
    try ctx.loadCaBundle(pem_bytes);
}

test "embedded CA bundle is non-empty" {
    try std.testing.expect(pem_bytes.len > 0);
}

test "embedded CA bundle contains certificate marker" {
    try std.testing.expect(std.mem.indexOf(u8, pem_bytes, "-----BEGIN CERTIFICATE-----") != null);
}