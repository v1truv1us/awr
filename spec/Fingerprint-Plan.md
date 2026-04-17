# AWR Phase 3 Plan — TLS Fingerprinting & Real Browser Identity

> **Status:** PLANNING — Not yet started
> **Prerequisite:** Phase 2 complete ✅ — 410/410 tests passing, 30/30 build steps

---

## What Phase 3 IS

Replace `std.http.Client` as the HTTPS transport with AWR's own TLS stack. AWR will
own every byte of the TLS ClientHello and HTTP/2 connection preface, producing a
documented, stable, vendored JA4+ fingerprint that is distinctly AWR's — not
Chrome's, not a curl wrapper, not "browser-like." Wire `h2session.zig` (currently
bypassed) into the live HTTPS path so AWR's own HTTP/2 SETTINGS and WINDOW_UPDATE
frames are on the wire.

### Phase 3 IS these things

| # | Deliverable |
|---|---|
| 1 | BoringSSL vendored as pre-built static libs (`third_party/boringssl/`) |
| 2 | `src/net/tls_conn.zig` — Zig wrapper for BoringSSL handshake + I/O |
| 3 | AWR's own cipher suite list (distinct from Chrome 132) |
| 4 | AWR's own TLS extension list (GREASE, SNI, ALPN, supported_groups, sig_algs, ALPS) |
| 5 | AWR's JA4+ fingerprint documented and tested as a stable constant |
| 6 | `h2session.zig` wired into live HTTPS fetch path |
| 7 | H2 SETTINGS + WINDOW_UPDATE (increment: 15663105) on the wire |
| 8 | ALPN negotiation: "h2" → H2Session path; "http/1.1" → HTTP/1.1 over TLS |
| 9 | CA certificate verification (Mozilla bundle bundled) |
| 10 | `client.zig` `fetchHttpsViaStd` replaced with `fetchHttpsOwned` |

### Phase 3 is NOT these things

These are explicitly deferred. Do not let scope creep pull them into Phase 3:

- **Navigator object** (`navigator.userAgent`, `platform`, etc.) — Phase 4
- **Canvas / WebGL / AudioContext fingerprinting** — Phase 4
- **Mouse/keyboard timing model** — Phase 4
- **libvaxis TUI** — Phase 4
- **ECH full handshake completion** (fetching ECHConfig from DNS HTTPS record) — post-MVP
- **DoH/DoT DNS resolution** — post-MVP
- **Proxy support** — post-MVP
- **QUIC / HTTP/3** — post-MVP
- **Registering AWR's fingerprint with Cloudflare/DataDome** — post-Phase 3 (requires the fingerprint to exist first)
- **Async TLS I/O via libxev** — Phase 4. Phase 3 uses synchronous TLS I/O (`SSL_set_fd` + blocking socket or synchronous BIO) consistent with the current synchronous TCP path.

---

## Critical Design Decisions (Resolve Before Writing Code)

### Decision 1: AWR's JA4+ is NOT Chrome's

The Chrome 132 ClientHello in `Phase1-Networking-TLS.md` is a **reference**, not a
target. AWR must NOT produce `t13d1517h2_8daaf6152771_b6f405a00624` (Chrome 132's
JA4 hash). It must produce its own distinct, documented value.

**Recommended minimum diff from Chrome 132:**

Drop `TLS_RSA_WITH_3DES_EDE_CBC_SHA` (0x000A) from the cipher list. 3DES is
deprecated by RFC 8996 (March 2021). No modern browser should include it. This is
not a heuristic dodge — it is the correct thing for a new browser to do, and it
changes AWR's JA4 cipher hash.

AWR's resulting cipher list (15 entries, non-GREASE):

```
0x1301  TLS_AES_128_GCM_SHA256
0x1302  TLS_AES_256_GCM_SHA384
0x1303  TLS_CHACHA20_POLY1305_SHA256
0xC02B  TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
0xC02F  TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
0xC02C  TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
0xC030  TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
0xCCA9  TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
0xCCA8  TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
0xC013  TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA
0xC014  TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
0x009C  TLS_RSA_WITH_AES_128_GCM_SHA256
0x009D  TLS_RSA_WITH_AES_256_GCM_SHA384
0x002F  TLS_RSA_WITH_AES_128_CBC_SHA
0x0035  TLS_RSA_WITH_AES_256_CBC_SHA
```

The actual JA4 hash for this list **cannot be computed until Step 5** when the
BoringSSL stack is running. The hash is derived from sorted cipher IDs (excl.
GREASE) + sorted extension IDs. Leave a `TBD` placeholder in fingerprint.zig
until Step 5 produces the real value.

**⚠️ Flag:** If more deviation from Chrome 132 is desired, the extension list can
also differ (e.g., drop the ECH extension entirely, which changes the extension
count and hash). This is a product decision. The plan below defers ECH to
post-MVP and drops it from Phase 3, which naturally changes the extension count.

### Decision 2: BoringSSL Vendoring Strategy

BoringSSL is NOT in Homebrew. It cannot be fetched via `build.zig.zon` (no
semver releases; BoringSSL is pinned by commit hash). The three options:

| Option | Pros | Cons |
|--------|------|------|
| **A: Pre-built static libs in `third_party/`** | Fast, reproducible, no cmake needed | Binaries in git (~10MB/platform); manual update process |
| **B: `b.addSystemCommand` to run cmake** | No binaries in git | Requires cmake+go+nasm; fragile CI; slow (~3 min) |
| **C: Enumerate all C sources in build.zig** | Pure Zig build | BoringSSL has ~500 C files + Python codegen for asm stubs; impractical |

**Recommended: Option A.** Commit pre-built static libs for macOS/arm64 only
(primary dev platform). Add macOS/x86_64 and Linux/x86_64 when needed. Document
build steps in `third_party/boringssl/BUILD_NOTES.md`.

**⚠️ Flag:** BoringSSL's assembly code is generated by a Python script
(`go run src/tool/generate_build_files.go`). The generated `.S` files are
platform-specific. There is no way around this for Option A — the pre-built libs
must be built on the target platform. This is normal and documented; just make
sure the build notes are clear.

Directory layout:
```
third_party/boringssl/
  include/          (copied from BoringSSL source: include/openssl/*.h)
  lib/
    macos-arm64/
      libssl.a
      libcrypto.a
    macos-x86_64/   (future)
    linux-x86_64/   (future)
  COMMIT_HASH       (single line: the BoringSSL git commit used)
  BUILD_NOTES.md    (how to rebuild the static libs from source)
```

BoringSSL commit to target: The most recent commit that includes:
- ALPS support (`SSL_CTX_add_application_settings`)
- X25519MLKEM768 group (0x11EC)
- GREASE enabled by default in TLS 1.3

All three landed in BoringSSL by mid-2024. Any commit from 2025 is safe.

### Decision 3: SSL_set_fd vs Custom BIO

Phase 3 uses `SSL_set_fd` with the raw TCP socket file descriptor. This is
synchronous and bypasses libxev's event loop during TLS I/O — consistent with
the current Phase 1/2 synchronous TCP path.

**⚠️ Flag:** `SSL_set_fd` requires the underlying socket to be in **blocking**
mode during the TLS handshake and subsequent reads/writes. AWR's `TcpConn`
currently wraps a libxev socket which may be in non-blocking mode on some
platforms. Verify socket blocking mode before handshake; add `fcntl(fd, F_SETFL,
flags & ~O_NONBLOCK)` if needed. Re-enable non-blocking after TLS teardown.

The proper Phase 4 approach is a custom BoringSSL `BIO_METHOD` that routes
through libxev's async I/O. This is the right architecture but out of scope for
Phase 3.

### Decision 4: CA Certificate Verification

BoringSSL does not bundle a CA certificate store. AWR must provide one.

**Recommended:** Bundle Mozilla's CA bundle as
`third_party/ca-bundle/cacert.pem` (available from https://curl.se/ca/cacert.pem,
generated from Mozilla's NSS). At runtime, call
`SSL_CTX_load_verify_locations(ctx, "third_party/ca-bundle/cacert.pem", NULL)`.

**⚠️ Flag:** This file is ~220KB. It must be embedded in the binary or present at
runtime. For a CLI tool, embedding is preferred:
```zig
const ca_bundle = @embedFile("../../third_party/ca-bundle/cacert.pem");
```
Then pass to BoringSSL via `SSL_CTX_add_cert_data` / `X509_STORE` + in-memory
BIO. This requires writing a small C helper (`tls_awr_shim.c`) that accepts a
`const uint8_t *pem_data, size_t pem_len` and loads certs into the SSL_CTX.

**Alternative:** Use the system certificate store via macOS
`SecTrustEvaluate` / `SSL_CTX_set_custom_verify`. More complex but avoids the
bundled file. Defer to Phase 4.

---

## Atomic Steps

### Step 1 — BoringSSL Vendoring + build.zig Integration

**What:**
1. Build BoringSSL static libs from source on macOS/arm64. Commands:
   ```
   git clone https://boringssl.googlesource.com/boringssl third_party/boringssl-src
   cd third_party/boringssl-src && mkdir build && cd build
   cmake -DCMAKE_BUILD_TYPE=Release -GNinja ..
   ninja ssl crypto
   ```
2. Copy `build/ssl/libssl.a` and `build/crypto/libcrypto.a` to
   `third_party/boringssl/lib/macos-arm64/`.
3. Copy the `include/` directory to `third_party/boringssl/include/`.
4. Record the commit hash in `third_party/boringssl/COMMIT_HASH`.
5. Wire into `build.zig`:
   ```zig
   const boringssl_prefix = "third_party/boringssl";
   const boringssl_include = b.path(boringssl_prefix ++ "/include");
   const boringssl_lib     = b.path(boringssl_prefix ++ "/lib/macos-arm64");
   ```
   Note: use `b.path()` (relative to package root), NOT `std.Build.LazyPath{
   .cwd_relative = ... }` (that's for absolute paths like the homebrew installs).
6. Add a new `test-tls` step with a single smoke-test file that does:
   ```zig
   const ssl_c = @cImport({ @cInclude("openssl/ssl.h"); });
   test "BoringSSL SSL_library_init links" {
       _ = ssl_c.SSL_library_init();
   }
   ```
   This confirms the lib links and headers resolve before writing any real code.

**Files created/modified:**
- `third_party/boringssl/` (new directory tree)
- `build.zig` (add boringssl paths + `test-tls` step)
- `.gitignore` (add `third_party/boringssl-src/`)

**Completion criteria:**
- `zig build test-tls --summary all` → 1/1 tests pass
- `zig build test --summary all` → 410/410 still pass (no regression)
- `zig build` (exe) compiles without BoringSSL linked (BoringSSL not yet in exe
  module — that comes in Step 4)

**⚠️ Zig 0.15.2 gotcha:** `b.path()` for package-relative paths vs
`std.Build.LazyPath{ .cwd_relative = ... }` for absolute paths. The existing
build.zig uses `cwd_relative` for Homebrew paths. For `third_party/` you want
`b.path(...)`. Getting this wrong produces a confusing "file not found" error that
looks like a linker error.

**⚠️ BoringSSL gotcha:** BoringSSL's cmake build requires `go` (for the asm
codegen runner) and `ninja` (or `make`). On a fresh macOS dev machine: `brew install
go ninja`. Document in BUILD_NOTES.md.

**⚠️ Platform detection gotcha:** The `build.zig` currently hardcodes
`/opt/homebrew/opt/...` paths for nghttp2 and lexbor. This works on macOS/arm64
but silently breaks on macOS/x86_64 (where homebrew is at `/usr/local/`). Phase 3
is an opportunity to fix this for the `third_party/` approach — use
`b.host.result.cpu.arch` to select the right lib sub-directory.

---

### Step 2 — `tls_conn.zig` + `tls_awr_shim.c`

**What:**
Create `src/net/tls_conn.zig` — a TLS connection wrapper that:
- Takes an established `TcpConn` file descriptor and a hostname
- Runs a BoringSSL TLS handshake with AWR's cipher/extension configuration
- Exposes `readFn` / `writeFn` compatible with the existing TCP I/O patterns
- Reports the negotiated ALPN protocol ("h2" or "http/1.1")

Create `src/net/tls_awr_shim.c` — a thin C helper for:
- `awr_tls_ctx_new()` — creates and configures an `SSL_CTX`:
  - Sets cipher list (AWR's 15-entry list)
  - Enables GREASE (BoringSSL does this by default for TLS 1.3)
  - Sets supported groups (X25519MLKEM768, x25519, secp256r1, secp384r1)
  - Sets ALPN protos: `h2\x00http/1.1`
  - Sets signature algorithms (Chrome 132 list)
  - Configures ALPS for "h2" with AWR's H2 settings values
  - Sets `SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL)` with CA bundle loaded
- `awr_tls_ctx_free(ctx)`
- `awr_tls_conn_new(ctx, fd, hostname)` — creates `SSL*`, sets SNI, calls `SSL_connect`
- `awr_tls_conn_free(ssl)`
- `awr_tls_conn_read(ssl, buf, len)` → bytes read or error
- `awr_tls_conn_write(ssl, buf, len)` → bytes written or error
- `awr_tls_alpn_result(ssl, out_protocol, out_len)` → negotiated ALPN string
- `awr_tls_load_ca_bundle(ctx, pem_data, pem_len)` → loads PEM-encoded certs

Create `src/net/tls_awr_shim.h` — corresponding header.

`tls_conn.zig` wraps the C shim:
```zig
pub const TlsConn = struct {
    ssl: *c.SSL,
    alpn: TlsAlpn,

    pub const TlsAlpn = enum { h2, http11 };

    pub fn connect(fd: std.posix.fd_t, hostname: [*:0]const u8) TlsError!TlsConn { ... }
    pub fn deinit(self: *TlsConn) void { ... }
    pub fn readFn(self: *TlsConn, buf: []u8) TlsError!usize { ... }
    pub fn writeFn(self: *TlsConn, buf: []const u8) TlsError!usize { ... }
};
```

**Files created:**
- `src/net/tls_conn.zig`
- `src/net/tls_awr_shim.c`
- `src/net/tls_awr_shim.h`

**Build wiring:**
The `tls_conn` module needs BoringSSL added to its test step (same pattern as
h2session + nghttp2). Add to `build.zig`:
```zig
const tls_mod = b.createModule(.{
    .root_source_file = b.path("src/net/tls_conn.zig"),
    ...
});
const tls_test = b.addTest(.{ .name = "tls", .root_module = tls_mod });
tls_test.linkLibC();
tls_test.addCSourceFile(.{ .file = b.path("src/net/tls_awr_shim.c"), ... });
tls_test.addIncludePath(boringssl_include);
tls_test.addLibraryPath(boringssl_lib);
tls_test.linkSystemLibrary("ssl");
tls_test.linkSystemLibrary("crypto");
```

**Test coverage (target: ~12 new tests):**
- `TlsConn SSL_CTX creation does not error` (smoke test)
- `AWR cipher list has exactly 15 non-GREASE entries`
- `AWR cipher list does not contain TLS_RSA_WITH_3DES_EDE_CBC_SHA (0x000A)`
- `AWR cipher list contains all TLS 1.3 ciphers (0x1301, 0x1302, 0x1303)`
- `ALPN proto list encodes h2 and http/1.1`
- `CA bundle loads without error (in-memory PEM parse)`
- `tls_conn.readFn returns TlsError.ConnectionClosed on EOF`
- `tls_conn.writeFn returns TlsError.SendFailed on SSL_ERROR_SYSCALL`
- Network integration tests (commented out, manual only):
  - `integration: TLS handshake to example.com returns alpn=h2`
  - `integration: TLS handshake to neverssl.com falls back to http/1.1`

**Completion criteria:**
- `zig build test-tls --summary all` → 12+ tests pass
- No existing tests regress

**⚠️ BoringSSL ALPS API gotcha:** `SSL_CTX_add_application_settings` is BoringSSL's
ALPS API. Its signature in recent BoringSSL:
```c
int SSL_CTX_add_application_settings(SSL_CTX *ctx,
                                      const uint8_t *proto, size_t proto_len,
                                      const uint8_t *settings, size_t settings_len);
```
The `settings` bytes are NOT the raw SETTINGS frame — they are the encoded settings
payload (key-value pairs as defined by the ALPS draft). The values must match AWR's
H2 SETTINGS: `HEADER_TABLE_SIZE=65536, INITIAL_WINDOW_SIZE=6291456,
MAX_HEADER_LIST_SIZE=262144`. Write a helper in `tls_awr_shim.c` to encode this
payload, and test the encoding separately.

**⚠️ BoringSSL GREASE gotcha:** BoringSSL enables GREASE automatically for TLS 1.3
clients when the session is configured correctly. You do NOT call a
"set_grease_enabled" API — GREASE is opt-out, not opt-in. Verify this is actually
happening by checking that the ClientHello contains a GREASE cipher entry in the
integration test (JA4 echo from tls.peet.ws will show GREASE ciphers).

**⚠️ X25519MLKEM768 gotcha:** The named group `X25519MLKEM768` (0x11EC) was
previously called `X25519Kyber768Draft00` (0x6399) in earlier BoringSSL commits.
The IANA assignment happened in 2024. Verify the target BoringSSL commit uses
0x11EC, not 0x6399. The fingerprint spec (Phase1-Networking-TLS.md) says 0x11EC —
confirm this matches the pinned BoringSSL commit.

**⚠️ blocking socket gotcha:** Before calling `SSL_set_fd` and `SSL_connect`,
ensure the socket is in blocking mode. `TcpConn.init` in `tcp.zig` sets up a
libxev socket — verify whether it is blocking or non-blocking, and call
`fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)` if needed before the
handshake.

---

### Step 3 — AWR JA4+ Fingerprint Construction

**What:**
Compute, document, and hard-code AWR's stable JA4+ fingerprint. This step
depends on Step 2 being runnable (needs real BoringSSL to capture the ClientHello).

1. Stand up a test that hits `https://tls.peet.ws/api/clean` (a JA4 echo endpoint
   — returns the JA4 fingerprint AWR sends) OR capture the ClientHello with
   Wireshark/`ssldump` on localhost.

2. Record the JA4 value. Expected format: `t13d{N}{M}h2_{cipher_hash}_{ext_hash}`
   where N=cipher count (should be 15 for AWR's list) and M=extension count.

3. Add AWR-specific constants to `fingerprint.zig`:
   ```zig
   /// AWR's TLS cipher suite list (15 entries — Chrome 132 minus deprecated 3DES).
   pub const awr_ciphers = [15]u16{ ... };

   /// AWR's stable JA4 fingerprint — computed from the BoringSSL ClientHello
   /// at Step 3 of Phase 3. TBD until Step 3 runs.
   pub const awr_ja4 = "t13d????h2_????????????_????????????";

   /// AWR's stable JA4H fingerprint (HTTP header fingerprint).
   pub const awr_ja4h = "ge11nn????_????????????";
   ```

4. Add a `FINGERPRINT.md` document in `spec/` documenting AWR's fingerprint in
   full — JA4, JA4H, cipher list, extension list, named groups, ALPS settings —
   so it can be registered with bot-detection vendors.

5. Add GREASE per-session generation to `tls_conn.zig`. While BoringSSL injects
   GREASE automatically in the ClientHello, AWR's Zig layer should independently
   pick a session GREASE value (for potential use in H2 and other protocol layers):
   ```zig
   pub fn pickGrease(seed: u64) u16 {
       const idx = seed % 16;
       return fingerprint.grease_values[idx];
   }
   ```

**Files modified:**
- `src/net/fingerprint.zig` (add `awr_ciphers`, `awr_ja4`, `awr_ja4h`, `pickGrease`)
- `spec/FINGERPRINT.md` (new)

**Test coverage (target: ~8 new tests):**
- `awr_ciphers has exactly 15 entries`
- `awr_ciphers does not contain 0x000A (3DES)`
- `awr_ciphers contains TLS 1.3 mandatory ciphers (0x1301, 0x1302, 0x1303)`
- `awr_ciphers is a strict subset of chrome132_ciphers`
- `pickGrease always returns a value in grease_values`
- `pickGrease(0) != pickGrease(1)` for most inputs (probabilistic)
- `awr_ja4 starts with "t13d"` (format smoke test)
- `awr_ja4 does not equal chrome132_ja4` (explicit non-impersonation assertion)

Add this constant to `fingerprint.zig` to enable the last test:
```zig
/// Chrome 132's JA4 fingerprint — AWR must NOT produce this value.
pub const chrome132_ja4 = "t13d1517h2_8daaf6152771_b6f405a00624";
```

**Completion criteria:**
- `zig build test-net --summary all` → all fingerprint tests pass
- `awr_ja4` field populated with real computed value (not `TBD`)
- `spec/FINGERPRINT.md` exists and documents the full fingerprint

**⚠️ JA4 computation is external:** JA4 is computed by FoxIO's algorithm
(https://github.com/FoxIO-LLC/ja4). AWR does not compute JA4 internally — it emits
a ClientHello and a third-party tool measures the JA4. The tests assert the format
and that AWR's value ≠ Chrome's; they do NOT independently compute the JA4 hash.
This is correct — the authoritative JA4 comes from the wire, not from AWR's own
calculation.

---

### Step 4 — Wire h2session.zig into the Live HTTPS Path

**What:**
Replace `fetchHttpsViaStd` in `client.zig` with `fetchHttpsOwned` that routes
through `TlsConn` + `H2Session` (or HTTP/1.1 over TLS on fallback).

Additionally, patch `h2_shim.c` to send the Chrome 132 WINDOW_UPDATE frame after
SETTINGS — this is currently missing.

**Sub-task 4a: Add WINDOW_UPDATE to h2_shim.c**

In `awr_h2_session_new`, after `nghttp2_submit_settings`:
```c
/* Chrome 132 H2 connection preface: SETTINGS → WINDOW_UPDATE (connection level) */
nghttp2_submit_window_update(s->ng, NGHTTP2_FLAG_NONE, 0, 15663105);
```

This is queued (not sent immediately) — it flushes on the first `awr_h2_session_run`.

**Sub-task 4b: Implement `fetchHttpsOwned` in client.zig**

```zig
fn fetchHttpsOwned(self: *Client, parsed: Url, redirect_count: u8) anyerror!Response {
    // 1. Resolve DNS
    const addr = try self.resolveHost(parsed.host, 443);

    // 2. TCP connect
    var tcp_conn = try tcp.TcpConn.init(self.allocator, addr);
    defer tcp_conn.deinit();
    try tcp_conn.connect();

    // 3. TLS handshake
    const hostname_z = try self.allocator.dupeZ(u8, parsed.host);
    defer self.allocator.free(hostname_z);
    var tls = try tls_conn.TlsConn.connect(tcp_conn.fd(), hostname_z);
    defer tls.deinit();

    return switch (tls.alpn) {
        .h2     => self.fetchH2(parsed, &tls, redirect_count),
        .http11 => self.fetchHttp11OverTls(parsed, &tls, redirect_count),
    };
}
```

`fetchH2` sets up an `H2Session` with `TlsConn.writeFn` / `TlsConn.readFn` as
the send/recv callbacks, calls `submitGet`, runs until complete, converts the
`H2Response` to `client.Response`.

`fetchHttp11OverTls` builds an `http1.Request` (same as `fetchHttp`), serializes
it, sends via `tls.writeFn`, reads back via `tls.readFn` into `http1.readResponse`.

**Sub-task 4c: Update client.zig dispatch**

Replace:
```zig
if (parsed.is_https) {
    return self.fetchHttpsViaStd(full_url);
}
```
With:
```zig
if (parsed.is_https) {
    return self.fetchHttpsOwned(parsed, redirect_count);
}
```

Keep `fetchHttpsViaStd` in the file as a dead function with a big `// TODO: remove
after Phase 3 integration testing` comment. Delete it only after Step 5 confirms
the new path is stable.

**Files modified:**
- `src/net/h2_shim.c` (add WINDOW_UPDATE)
- `src/net/h2session.zig` (add WINDOW_UPDATE test; may need updated `@cImport` if
  shim header changes)
- `src/client.zig` (add `fetchHttpsOwned`, `fetchH2`, `fetchHttp11OverTls`;
  replace dispatch)
- `build.zig` (add BoringSSL to the `client` module and `page` module and `exe`)

**⚠️ Build wiring complexity alert:** `client.zig` currently has no C dependencies
and builds cleanly without any C linkage. Adding `tls_conn.zig` (which imports
`tls_awr_shim.c`) transitively adds BoringSSL to every module that imports
`client.zig`. That includes: the `client` test, the `page` test, and the `exe`
build step. Each of these needs `linkSystemLibrary("ssl")` and
`linkSystemLibrary("crypto")` added. **This is the highest-risk part of the
build.zig changes** — it will touch 4 build step definitions and could silently
produce an executable that panics at runtime due to missing symbol resolution.

Check each build step after wiring:
- `zig build test-client --summary all` 
- `zig build test-page --summary all`
- `zig build` (exe)
- `zig build test --summary all`

**⚠️ H2Session callback signature:** `h2session.zig`'s `H2Session.init` takes
`c.awr_h2_send_cb` / `c.awr_h2_recv_cb`. These are:
```c
typedef int (*awr_h2_send_cb)(const uint8_t *data, size_t len, void *user_data);
typedef int (*awr_h2_recv_cb)(uint8_t *buf,         size_t len, void *user_data);
```
`TlsConn.writeFn` / `TlsConn.readFn` have Zig-native signatures. You need small
adapter functions:
```zig
fn h2_tls_send(data: [*c]const u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int { ... }
fn h2_tls_recv(buf:  [*c]u8,       len: usize, ud: ?*anyopaque) callconv(.c) c_int { ... }
```
These adapters cast `ud` to `*TlsConn` and call its methods. The `callconv(.c)` is
required for the function pointer to be compatible with nghttp2's callback type.

**⚠️ Redirect handling over H2:** `H2Response` from `h2session.zig` doesn't include
`Location` headers in a ready-to-use form — they're encoded in the flat
`name\0value\0` buffer. The redirect logic in `fetchHttpsOwned` must iterate via
`H2Response.headerIterator()` to find `location`, then follow the same
redirect logic as `fetchHttp`. This is easy but easy to forget.

**Test coverage (target: ~8 new tests):**
- `h2session WINDOW_UPDATE is queued after SETTINGS` (new test in h2session.zig)
- `fetchHttpsOwned dispatches to h2 when ALPN is h2` (mock TlsConn)
- `fetchHttpsOwned dispatches to http11 when ALPN is http/1.1` (mock TlsConn)
- `fetchH2 follows Location header on 301` (mock H2Session)
- `fetchHttp11OverTls sends correct HTTP/1.1 request bytes` (mock TlsConn)
- `client.fetch still returns InvalidUrl for bad URL` (regression)
- `client.fetch still returns DnsResolutionFailed for invalid host` (regression)
- `client fetchHttpsViaStd still compiles` (it's kept in dead code for now)

**Completion criteria:**
- `zig build test --summary all` → 410 + new tests pass, 0 regressions
- `./zig-out/bin/awr https://httpbin.org/status/200` returns `{"status":200,...}` via new path
- `./zig-out/bin/awr https://example.com` continues to work

---

### Step 5 — End-to-End Verification + Fingerprint Documentation

**What:**
Verify the full stack end-to-end and compute AWR's actual JA4+ fingerprint value.

1. **JA4 echo test:** Hit `https://tls.peet.ws/api/clean` and parse the returned
   JSON. It echoes back the JA4 and JA4H of the connecting client. Assert:
   - `ja4` starts with `"t13d"` (TLS 1.3, domain SNI)
   - `ja4` does NOT equal `"t13d1517h2_8daaf6152771_b6f405a00624"` (Chrome 132)
   - `ja4` is stable across 3 consecutive connections (same hash each time)
   Record the value and paste into `fingerprint.zig`'s `awr_ja4` constant.

2. **H2 frame verification:** Use Wireshark (or `tcpdump` + TLS keylog) to verify
   on the wire:
   - SETTINGS frame present with AWR's 4 settings values
   - WINDOW_UPDATE frame present immediately after SETTINGS (increment: 15663105)
   - ALPN in ServerHello is "h2"
   - ClientHello contains GREASE cipher at position 0
   - ClientHello contains AWR's 15 non-GREASE cipher suites

3. **Real-site smoke tests** (network, commented out in CI):
   - `https://example.com` → 200, body contains "Example Domain"
   - `https://httpbin.org/get` → 200, body is valid JSON
   - `https://github.com` → 200 (or 301), non-empty body

4. **Update spec/FINGERPRINT.md** with the computed `awr_ja4` and `awr_ja4h` values.

5. **Remove `fetchHttpsViaStd`** from `client.zig` (it was kept in Step 4 as dead
   code — now delete it).

**Files modified:**
- `src/net/fingerprint.zig` (fill in `awr_ja4` and `awr_ja4h` with real values)
- `src/client.zig` (delete `fetchHttpsViaStd`)
- `spec/FINGERPRINT.md` (fill in computed values)

**Test coverage:**
- `awr_ja4 does not equal chrome132_ja4` (already added in Step 3, now passes with
  real value)
- `awr_ja4 is 36 characters long` (format validation; JA4 is always `t13dXXXXh2_12chars_12chars`)
- Integration test: `fetch https://tls.peet.ws/api/clean returns valid ja4`
  (marked `// integration — requires network`)

**Completion criteria:**
- `zig build test --summary all` → all tests pass (target: ~438+)
- `awr_ja4` constant in `fingerprint.zig` is NOT the placeholder `TBD` string
- `awr_ja4 != chrome132_ja4` asserted in a test
- `fetchHttpsViaStd` does not exist in `client.zig`
- H2 WINDOW_UPDATE confirmed on wire via packet capture
- `spec/FINGERPRINT.md` contains the computed fingerprint values

---

## Riskiest / Hardest Parts

### #1 — BoringSSL static lib build + git storage (HIGH RISK)

**Why hard:** BoringSSL requires Go + cmake/ninja, is commit-pinned (not versioned),
and produces platform-specific binaries. Committing 10MB+ of `.a` files to git
will shock anyone used to source-only repos. The build.zig integration for static
libs that live in `third_party/` rather than in Homebrew is a different pattern
from anything currently in the project.

**Concrete failure mode:** Developer pulls the repo on a new machine; libssl.a
is macOS arm64-only; they're on Linux x86_64. Nothing builds. Mitigation: clear
BUILD_NOTES.md and a CI step that validates the included lib matches the host arch.

### #2 — Build wiring: BoringSSL into all modules that import client.zig (HIGH RISK)

**Why hard:** `client.zig` has zero C dependencies today. Adding `tls_conn.zig`
(which wraps BoringSSL C code) makes BoringSSL a transitive dependency of
`client`, `page`, and the `exe`. In Zig's build system, each `b.addTest()` and
`b.addExecutable()` must independently link the C library. Missing one produces
a "undefined symbol" linker error that can look like a code bug.

**Mitigation:** After Step 4, run ALL of:
- `zig build test --summary all`
- `zig build test-client --summary all`
- `zig build test-page --summary all`
- `zig build` (exe build)

### #3 — Blocking socket assumption (MEDIUM RISK)

**Why hard:** `SSL_set_fd` requires blocking mode. `TcpConn` is built on libxev
which runs an event loop under the hood. On macOS, libxev uses kqueue with
non-blocking sockets. If the fd passed to BoringSSL is non-blocking, `SSL_connect`
will return `SSL_ERROR_WANT_READ` in a loop that the code may not handle correctly.

**Concrete failure mode:** `SSL_connect` returns -1, `SSL_get_error` returns
`SSL_ERROR_WANT_READ`, caller retries without running the event loop → deadlock.

**Mitigation:** `TcpConn.fd()` must expose the raw socket fd. Call
`fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)` in `tls_awr_shim.c`'s
`awr_tls_conn_new` before `SSL_connect`. Re-enable non-blocking if needed
before handing back to the caller. Add a test that asserts `SSL_connect` does
not return `SSL_ERROR_WANT_READ`.

### #4 — ALPS settings encoding (MEDIUM RISK)

**Why hard:** ALPS carries H2 SETTINGS in the TLS handshake. The payload is NOT
a raw H2 SETTINGS frame — it is a specific encoding defined by the ALPS draft
(draft-vvv-httpbis-alps). If the encoding is wrong, BoringSSL will either silently
ignore ALPS or abort the handshake, and JA4 will reflect ALPS presence/absence
incorrectly.

**Mitigation:** Write the ALPS encoding as a tested C helper function in
`tls_awr_shim.c`. Test it by asserting the byte-exact encoding against a
known-good reference (the ALPS draft has examples).

### #5 — H2Response → client.Response header mapping (MEDIUM RISK)

**Why hard:** `H2Response` uses a flat `name\0value\0` buffer, while
`client.Response` uses `http1.HeaderList`. The conversion is straightforward
but involves allocating a new HeaderList from the iterator — easy to leak
memory or to miscount pairs.

**Mitigation:** Write a helper function `headerListFromH2Response` in `client.zig`
with its own tests. Test it with the existing `H2Response` mock data from
`h2session_test`.

---

## Zig 0.15.2-Specific Gotchas

1. **`std.Io.Writer.Allocating`** — Present in `fetchHttpsViaStd` (being deleted
   in Step 5). The owned TLS path uses H2Response's body (already owned slice) or
   HTTP/1.1 response reading (through `http1.readResponse` which does its own
   allocation). You should NOT need `std.Io.Writer.Allocating` in the new path.
   If you find yourself reaching for it in `fetchHttp11OverTls`, double-check that
   you're calling `http1.readResponse(reader, allocator)` correctly.

2. **`callconv(.c)` for callback pointers** — The h2session tests already use this
   pattern correctly (`fn noop_send(...) callconv(.c) c_int`). All BoringSSL
   callbacks and h2-TLS adapter functions must follow the same pattern. Zig 0.15
   will error, not warn, if you omit `callconv(.c)` on a function used as a C
   callback.

3. **`b.path()` vs `std.Build.LazyPath{ .cwd_relative = ... }`** — In Zig 0.15,
   `b.path(rel)` is for paths relative to the package root (`build.zig.zon`
   location). `.cwd_relative` is for absolute paths (like Homebrew paths). Getting
   these swapped produces confusing "file not found" errors at build time.

4. **C source file compilation flags** — The existing `h2_shim.c` uses
   `"-std=c11"`. BoringSSL requires C11 as well, but `tls_awr_shim.c` may need
   specific BoringSSL-required defines (e.g., `BORINGSSL_IMPLEMENTATION`). Check
   BoringSSL's `include/openssl/base.h` for required defines when embedding.

5. **`@cImport` in test modules** — In Zig 0.15, `@cImport` is evaluated at
   compile time and the result is cached per module. If `tls_conn.zig` uses
   `@cImport({ @cInclude("openssl/ssl.h"); })`, the test binary for `tls_conn`
   must have `addIncludePath(boringssl_include)` set. Missing this produces a
   `@cImport` compile error that can look like a missing file error.

6. **`anyerror!Response` return type** — `client.zig`'s `fetchUrl` returns
   `anyerror!Response`. The new `fetchHttpsOwned` path will introduce new error
   types from `tls_conn.zig` (`TlsError`). These flow through `anyerror` without
   changes, but the test that does `try std.testing.expectError(FetchError.InvalidUrl,
   ...)` will still pass. Make sure any new error values in `FetchError` are
   documented and tested.

---

## Test Strategy

### New test files/modules

| Module | New Tests | Location |
|--------|-----------|----------|
| `tls_conn.zig` | ~12 | `src/net/tls_conn.zig` (inline tests) |
| `fingerprint.zig` additions | ~8 | `src/net/fingerprint.zig` (inline tests) |
| `h2session.zig` additions | ~2 | `src/net/h2session.zig` (inline tests) |
| `client.zig` new path | ~6 | `src/client.zig` (inline tests) |

### Updated build steps

| Step | Command |
|------|---------|
| `zig build test-tls` | New — runs tls_conn tests only |
| `zig build test-h2` | Updated — now includes WINDOW_UPDATE test |
| `zig build test-net` | Updated — now includes tls_conn tests |
| `zig build test-client` | Updated — tls path now requires BoringSSL linked |
| `zig build test` | Updated — includes all of the above |

### What to NOT test in unit tests

- The JA4 hash value itself (only verifiable via wire capture / echo server)
- TLS handshake success against a real server (network required; mark integration)
- X25519MLKEM768 key generation (internal to BoringSSL)

### What existing tests should NOT regress

The full existing 410-test suite must pass unchanged. The most likely regression
vectors:
- `test-client` (83 tests) — if BoringSSL linking breaks the module
- `test-page` (156 tests) — if page.zig transitively depends on client.zig which
  now needs BoringSSL
- `test-h2` (4+26 tests) — if h2_shim.c changes break existing behaviour

Run `zig build test --summary all` after every step, not just at the end.

---

## Estimated Test Count Delta

| Category | New Tests |
|----------|-----------|
| `tls_conn.zig` unit tests | +12 |
| `fingerprint.zig` AWR additions | +8 |
| `h2session.zig` WINDOW_UPDATE + preface sequence | +2 |
| `client.zig` new dispatch path | +6 |
| **Subtotal** | **+28** |

**Current total:** 410
**Projected Phase 3 total:** ~438

This is a conservative estimate. If Step 2's TLS mock infrastructure enables more
thorough `client.zig` testing, the count could reach ~445.

---

## Phase 3 Exit Criteria

All of the following must be true before Phase 3 is declared complete:

1. `zig build test --summary all` → **438+ tests passed, 0 skipped, 0 failed**
2. `zig build` → AWR binary compiles and links with BoringSSL (no `std.http.Client`
   in the HTTPS path)
3. `./zig-out/bin/awr https://example.com` → JSON output via owned TLS stack
   (confirm via packet capture that `std.crypto.tls` ClientHello signature is absent)
4. AWR's JA4 fingerprint is **documented in `spec/FINGERPRINT.md`** with the
   computed hash values (not placeholders)
5. **`awr_ja4 != chrome132_ja4`** asserted in a passing test in `fingerprint.zig`
6. **H2 WINDOW_UPDATE confirmed on wire** — Wireshark or `ssldump` shows increment
   15663105 immediately after the SETTINGS frame
7. **`fetchHttpsViaStd` does not exist** in `client.zig`
8. **`h2session.zig` is on the live HTTPS path** — confirmed by a test or comment
   that explicitly documents the execution path for an H2 request

---

## Underspecified Areas and Open Questions

These must be resolved before or during Phase 3, not after.

**Q1: ECH extension — include or exclude in Phase 3?**
The Chrome 132 spec includes ECH (0xFE0D). Full ECH requires DNS HTTPS records.
For Phase 3, options:
- A: Exclude ECH entirely. Simpler, changes extension count and JA4. Documents
  that AWR's fingerprint does not include ECH.
- B: Include ECH outer ClientHello with a synthetic/empty ECHConfig. BoringSSL
  supports this but requires careful configuration to avoid handshake failures.
- **Recommendation:** Exclude ECH in Phase 3 (Option A). Add it in Phase 4 or
  post-MVP. This is defensible — Safari and Firefox don't always send ECH either.
  Explicitly document the omission in `FINGERPRINT.md`.

**Q2: What is the `TcpConn.fd()` API surface?**
`tcp.zig` is not in the files reviewed here. The plan assumes `TcpConn` exposes
the raw socket file descriptor. If it does not, `tls_conn.zig` may need to reach
into the libxev internals or use a different TCP integration approach. **Verify
before starting Step 2.**

**Q3: ALPN fallback behavior — error or proceed?**
If a server negotiates neither "h2" nor "http/1.1" (rare but possible), what
should AWR do? Options: error out, assume http/1.1, or inspect the protocol string.
Recommendation: treat any unknown ALPN as "http/1.1". Document in code.

**Q4: Certificate verification failure behavior**
If cert verification fails (expired cert, unknown CA), should AWR:
- Return an error (correct for production)
- Continue with a warning (useful for agent use cases with self-signed certs)
Recommendation: strict verification by default; add a `verify_certs: bool = true`
field to `ClientOptions` to allow opt-out (with a loud log warning). This is a
`ClientOptions` change.

**Q5: BoringSSL binary size impact**
Current AWR binary size is uncharacterized. BoringSSL static libs are ~10MB per
platform. The PRD target is < 50MB stripped binary. BoringSSL + QuickJS +
Lexbor + nghttp2 could push past this. Run `zig build -Doptimize=ReleaseFast` and
`strip zig-out/bin/awr` and measure before shipping Phase 3.

---

## What the PRD's "Phase 3" Also Includes (Deferred to Phase 4)

The PRD's Phase 3 scope (weeks 9-12) includes Navigator object, Canvas/WebGL/
AudioContext fingerprinting, mouse/keyboard timing, and the libvaxis TUI. None of
these are in the plan above — this document scopes only the TLS/H2 work.

The plan recommends calling the TLS/H2 work "Phase 3a" and the behavioral
fingerprinting + TUI work "Phase 3b" (or renumbering to Phase 4). Shipping them
together in a 4-week window alongside BoringSSL vendoring is extremely aggressive
and likely to slip. The TLS stack is the dependency; behavioral fingerprinting and
TUI can proceed in parallel once the TLS stack is stable.
