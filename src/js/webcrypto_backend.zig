/// webcrypto_backend.zig — BoringSSL-backed WebCrypto implementation.
/// T-93 / Tier 3 starter slice. Provides `engine.CryptoBackend`
/// function pointers wired from BoringSSL's `RAND_bytes` and the
/// SHA convenience functions.
///
/// Kept separate from `engine.zig` so the standalone `js_test` target
/// (which doesn't link BoringSSL) compiles without pulling in the
/// crypto C deps. Page imports this and calls
/// `engine.JsEngine.setCryptoBackend(backend)` post-init.
const std = @import("std");
const engine = @import("engine.zig");

const c = @cImport({
    @cInclude("openssl/rand.h");
    @cInclude("openssl/sha.h");
});

/// Fill `out` with cryptographically-secure random bytes via BoringSSL's
/// `RAND_bytes`. Returns true on success. RAND_bytes can fail when the
/// PRNG hasn't been seeded — vanishingly unlikely on macOS/Linux but
/// we surface it as `false` rather than panic.
fn randBytes(out: []u8) bool {
    if (out.len == 0) return true;
    // RAND_bytes returns 1 on success, 0 on failure.
    return c.RAND_bytes(out.ptr, out.len) == 1;
}

/// Compute a digest into `out`. Caller must size `out` to match the
/// algorithm (20/32/48/64 bytes). The BoringSSL convenience functions
/// (`SHA256`, etc.) operate as `SHA256(data, len, out)` — single-shot,
/// no streaming, no allocation. Perfect for our use case.
fn digest(algo: engine.DigestAlgo, data: []const u8, out: []u8) bool {
    // BoringSSL's convenience APIs never fail at the SHA-* level
    // (allocation-free, no key dependence). Returning true unconditionally
    // is correct.
    const data_ptr: [*c]const u8 = if (data.len == 0) null else data.ptr;
    const out_ptr: [*c]u8 = out.ptr;
    switch (algo) {
        .sha1 => {
            std.debug.assert(out.len >= 20);
            _ = c.SHA1(data_ptr, data.len, out_ptr);
        },
        .sha256 => {
            std.debug.assert(out.len >= 32);
            _ = c.SHA256(data_ptr, data.len, out_ptr);
        },
        .sha384 => {
            std.debug.assert(out.len >= 48);
            _ = c.SHA384(data_ptr, data.len, out_ptr);
        },
        .sha512 => {
            std.debug.assert(out.len >= 64);
            _ = c.SHA512(data_ptr, data.len, out_ptr);
        },
    }
    return true;
}

/// The CryptoBackend instance Page wires into the JS engine via
/// `JsEngine.setCryptoBackend(backend)`. Function pointers are
/// resolved at module load — no init step required.
pub const backend: engine.CryptoBackend = .{
    .rand_bytes = randBytes,
    .digest = digest,
};

// ── Tests ──────────────────────────────────────────────────────────

test "randBytes fills the slice (smoke test: non-trivial entropy)" {
    var buf: [32]u8 = undefined;
    @memset(&buf, 0);
    try std.testing.expect(randBytes(&buf));
    // Probability of all 32 bytes being zero from a healthy CSPRNG is
    // 2^-256. If this fires we have bigger problems.
    var all_zero = true;
    for (buf) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}

test "randBytes accepts zero-length input" {
    var buf: [0]u8 = undefined;
    try std.testing.expect(randBytes(&buf));
}

test "digest SHA-256 of empty input matches the spec vector" {
    var out: [32]u8 = undefined;
    try std.testing.expect(digest(.sha256, "", &out));
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "digest SHA-256 of \"abc\" matches the spec vector" {
    var out: [32]u8 = undefined;
    try std.testing.expect(digest(.sha256, "abc", &out));
    // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "digest SHA-1 of \"abc\" matches the spec vector" {
    var out: [20]u8 = undefined;
    try std.testing.expect(digest(.sha1, "abc", &out));
    // SHA-1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
    const expected = [_]u8{
        0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
        0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "digest SHA-512 of \"abc\" matches the spec vector" {
    var out: [64]u8 = undefined;
    try std.testing.expect(digest(.sha512, "abc", &out));
    // SHA-512("abc") = ddaf35a193617aba...
    const expected = [_]u8{
        0xdd, 0xaf, 0x35, 0xa1, 0x93, 0x61, 0x7a, 0xba,
        0xcc, 0x41, 0x73, 0x49, 0xae, 0x20, 0x41, 0x31,
        0x12, 0xe6, 0xfa, 0x4e, 0x89, 0xa9, 0x7e, 0xa2,
        0x0a, 0x9e, 0xee, 0xe6, 0x4b, 0x55, 0xd3, 0x9a,
        0x21, 0x92, 0x99, 0x2a, 0x27, 0x4f, 0xc1, 0xa8,
        0x36, 0xba, 0x3c, 0x23, 0xa3, 0xfe, 0xeb, 0xbd,
        0x45, 0x4d, 0x44, 0x23, 0x64, 0x3c, 0xe8, 0x0e,
        0x2a, 0x9a, 0xc9, 0x4f, 0xa5, 0x4c, 0xa4, 0x9f,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}
