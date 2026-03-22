/// fingerprint.zig — JA4+ constants and Chrome 132 TLS/H2 fingerprint values.
///
/// This module contains ONLY constants and pure functions — no I/O, no
/// allocations. It is the single source of truth for the Chrome 132 fingerprint
/// that AWR must reproduce on the wire.
const std = @import("std");

// ── GREASE ────────────────────────────────────────────────────────────────

/// All 16 valid GREASE values per RFC 8701 §3.1.
/// Pattern: 0x?A?A where both bytes are equal and the low nibble is 0xA.
pub const grease_values = [16]u16{
    0x0a0a, 0x1a1a, 0x2a2a, 0x3a3a,
    0x4a4a, 0x5a5a, 0x6a6a, 0x7a7a,
    0x8a8a, 0x9a9a, 0xaaaa, 0xbaba,
    0xcaca, 0xdada, 0xeaea, 0xfafa,
};

/// Returns true when `v` is a valid GREASE value (RFC 8701 §3.1).
/// GREASE values follow the pattern 0x?A?A — both bytes equal, low nibble = A.
pub fn isGrease(v: u16) bool {
    const lo: u8 = @truncate(v & 0xff);
    const hi: u8 = @truncate((v >> 8) & 0xff);
    return lo == hi and (lo & 0x0f) == 0x0a;
}

// ── Chrome 132 cipher suites ───────────────────────────────────────────────

/// Chrome 132 cipher suites (16 non-GREASE entries, order-sensitive).
/// Position 0 in the ClientHello is a GREASE value chosen per-session;
/// these 16 follow immediately after. See Phase1-Networking-TLS.md §Cipher Suites.
pub const chrome132_ciphers = [16]u16{
    0x1301, // TLS_AES_128_GCM_SHA256
    0x1302, // TLS_AES_256_GCM_SHA384
    0x1303, // TLS_CHACHA20_POLY1305_SHA256
    0xc02b, // TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    0xc02f, // TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    0xc02c, // TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    0xc030, // TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    0xcca9, // TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
    0xcca8, // TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
    0xc013, // TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA
    0xc014, // TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
    0x009c, // TLS_RSA_WITH_AES_128_GCM_SHA256
    0x009d, // TLS_RSA_WITH_AES_256_GCM_SHA384
    0x002f, // TLS_RSA_WITH_AES_128_CBC_SHA
    0x0035, // TLS_RSA_WITH_AES_256_CBC_SHA
    0x000a, // TLS_RSA_WITH_3DES_EDE_CBC_SHA
};

// ── HTTP/2 SETTINGS (Chrome 132) ──────────────────────────────────────────

pub const h2_header_table_size: u32      = 65536;
pub const h2_max_concurrent_streams: u32 = 1000;
pub const h2_initial_window_size: u32    = 6291456;
pub const h2_max_header_list_size: u32   = 262144;

/// Connection-level WINDOW_UPDATE increment Chrome 132 sends after SETTINGS.
pub const h2_connection_window_increment: u32 = 15663105;

// ── HTTP/2 pseudo-header order ─────────────────────────────────────────────

pub const h2_pseudo_header_order = [4][]const u8{
    ":method",
    ":authority",
    ":scheme",
    ":path",
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "Chrome 132 cipher suite list has exactly 16 entries" {
    try std.testing.expectEqual(@as(usize, 16), chrome132_ciphers.len);
}

test "Chrome 132 cipher suites match spec values exactly" {
    const expected = [16]u16{
        0x1301, 0x1302, 0x1303, 0xc02b,
        0xc02f, 0xc02c, 0xc030, 0xcca9,
        0xcca8, 0xc013, 0xc014, 0x009c,
        0x009d, 0x002f, 0x0035, 0x000a,
    };
    for (expected, chrome132_ciphers) |exp, got| {
        try std.testing.expectEqual(exp, got);
    }
}

test "GREASE values list has exactly 16 entries" {
    try std.testing.expectEqual(@as(usize, 16), grease_values.len);
}

test "all GREASE values follow 0x?A?A pattern" {
    for (grease_values) |v| {
        try std.testing.expect(isGrease(v));
    }
}

test "isGrease returns true for 0x0a0a" {
    try std.testing.expect(isGrease(0x0a0a));
}

test "isGrease returns false for non-GREASE cipher 0x1301" {
    try std.testing.expect(!isGrease(0x1301));
}

test "isGrease returns false for 0x0000" {
    try std.testing.expect(!isGrease(0x0000));
}

test "isGrease returns false for 0x0a0b (bytes differ)" {
    try std.testing.expect(!isGrease(0x0a0b));
}

test "H2 SETTINGS values match Chrome 132 spec" {
    try std.testing.expectEqual(@as(u32, 65536),   h2_header_table_size);
    try std.testing.expectEqual(@as(u32, 1000),    h2_max_concurrent_streams);
    try std.testing.expectEqual(@as(u32, 6291456), h2_initial_window_size);
    try std.testing.expectEqual(@as(u32, 262144),  h2_max_header_list_size);
}

test "H2 connection window update value is 15663105" {
    try std.testing.expectEqual(@as(u32, 15663105), h2_connection_window_increment);
}

test "H2 pseudo-header order is :method :authority :scheme :path" {
    try std.testing.expectEqualStrings(":method",    h2_pseudo_header_order[0]);
    try std.testing.expectEqualStrings(":authority", h2_pseudo_header_order[1]);
    try std.testing.expectEqualStrings(":scheme",    h2_pseudo_header_order[2]);
    try std.testing.expectEqualStrings(":path",      h2_pseudo_header_order[3]);
}
