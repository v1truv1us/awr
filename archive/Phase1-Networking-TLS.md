# Phase 1 — Networking & TLS | STATUS: COMPLETE ✅

---

## TLS Decision (final)

HTTPS uses `std.http.Client` (backed by `std.crypto.tls`). No other TLS backend exists.

**curl_impersonate was removed entirely** in commit `61b29c3` / `f2b57cd` (2026-03-27). There is no `TlsBackend` enum, no `TlsConn`, no `tls.zig`, no `tls_curl_shim.c` or `tls_curl_shim.h`. These files are gone and the build has no conditionals for them.

**Why this is correct**: AWR is a first-party browser. It will have its own TLS fingerprint in Phase 3 (BoringSSL stack, own JA4+ value) — not Chrome's. curl_impersonate's only use case was "look like Chrome while we build Phase 3" — not worth carrying the build complexity.

---

## What's Built

### `src/net/tcp.zig` — libxev async TCP (8 tests)

State machine: `idle → connecting → connected → draining → closed`. Timeouts enforced via libxev timer completions (connect: 10s, idle keepalive: 30s). Platform-transparent: io_uring (Linux), kqueue (macOS), IOCP (Windows).

### `src/net/http1.zig` — HTTP/1.1 request/response (12 tests)

Request serialization and response parsing. Preserves header insertion order (critical for fingerprinting). Skips H2 pseudo-headers when writing HTTP/1.1 wire format.

### `src/net/http2.zig` — HTTP/2 frame encoding (26 tests)

Pure Zig H2 frame encoder/decoder: DATA, HEADERS, SETTINGS, WINDOW_UPDATE, GOAWAY, RST_STREAM, PING. Chrome 132 SETTINGS values encoded: `1:65536;3:1000;4:6291456;6:262144`. WINDOW_UPDATE increment: `15663105`. Pseudo-header order: `:method, :authority, :scheme, :path`.

### `src/net/h2session.zig` — H2 session layer (4 tests)

Phase 3 scaffolding. Exists and is tested, but **not active in the default Phase 1/2 path**. See H2 Status section below.

### `src/net/pool.zig` — per-origin connection pool (14 tests)

Max 6 connections per origin (`scheme://host:port`) — matches Chrome's per-origin limit. Idle timeout: 30s. Max connection age: 5 minutes. Max requests per connection: 100.

### `src/net/cookie.zig` — RFC 6265 cookie jar (32 tests)

Domain suffix matching, path matching, expiry (session cookies and timestamped), `Secure`, `HttpOnly`, `SameSite` (Strict/Lax/None). `Set-Cookie` parsing and `Cookie:` header serialization.

### `src/net/url.zig` — URL parser (11 tests)

Parses scheme, host, port, path, query, fragment. Handles relative URLs and normalization.

### `src/net/fingerprint.zig` — fingerprint utilities (11 tests)

HTTP fingerprint construction utilities. Used for future JA4H header fingerprinting.

### `src/client.zig` — HTTP client (83 tests)

Top-level fetch layer. HTTP → direct TCP path. HTTPS → `std.http.Client` (handles TLS and ALPN internally). Redirect following (configurable max, default 10). Cookie jar integration. Returns `HttpResponse { status, headers, body }`.

---

## H2 Status (honest)

`h2session.zig` exists and is tested (4 tests) but is **not active in Phase 1 or Phase 2**.

The HTTPS path goes through `std.http.Client`, which negotiates H2 via OS ALPN when the server supports it — AWR's own H2 frame encoder (`http2.zig`) and session layer (`h2session.zig`) are **not on that path**.

AWR's own H2 session activates in **Phase 3**, when we wire `h2session.zig` into our BoringSSL TLS stack and take direct control of the connection. At that point, the Chrome 132 SETTINGS and WINDOW_UPDATE values in `http2.zig` become live.

---

## Phase 3 TLS Plan

1. Embed BoringSSL directly — owned and configured by this project
2. Define AWR's own cipher suite order and extension list (see Chrome 132 ClientHello reference below)
3. Produce a stable, documented AWR JA4+ fingerprint — **not** Chrome's fingerprint
4. Wire `h2session.zig` into the BoringSSL stack so AWR's own H2 SETTINGS/WINDOW_UPDATE are on the wire
5. Register the AWR fingerprint with bot-detection vendors (Cloudflare, Akamai, DataDome) for allowlisting

AWR sends `User-Agent: AWR/x.y`. It never ships code whose purpose is to deceive a server about what software is making the request.

---

## Chrome 132 ClientHello Specification (Phase 3 Reference Target)

This section is the ground truth for the Phase 3 BoringSSL stack. Phase 1/2 uses `std.crypto.tls` via `std.http.Client` and does **not** emit this fingerprint. Any deviation from these values in Phase 3 will produce a non-matching JA4+ fingerprint.

### TLS Version

- Minimum: TLS 1.2 (for compatibility)
- Maximum offered: TLS 1.3
- Negotiated (target): TLS 1.3

### Cipher Suites (16 non-GREASE, order-sensitive)

```
Position  Hex     Name
0         GREASE  (random from: 0x0A0A, 0x1A1A … 0xFAFA — same value per session)
1         0x1301  TLS_AES_128_GCM_SHA256
2         0x1302  TLS_AES_256_GCM_SHA384
3         0x1303  TLS_CHACHA20_POLY1305_SHA256
4         0xC02B  TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
5         0xC02F  TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
6         0xC02C  TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
7         0xC030  TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
8         0xCCA9  TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
9         0xCCA8  TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
10        0xC013  TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA
11        0xC014  TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
12        0x009C  TLS_RSA_WITH_AES_128_GCM_SHA256
13        0x009D  TLS_RSA_WITH_AES_256_GCM_SHA384
14        0x002F  TLS_RSA_WITH_AES_128_CBC_SHA
15        0x0035  TLS_RSA_WITH_AES_256_CBC_SHA
16        0x000A  TLS_RSA_WITH_3DES_EDE_CBC_SHA
```

### Extensions (order-sensitive)

```
Position  Extension           Notes
0         GREASE              Same per-session GREASE value as cipher GREASE
1         0x0000 SNI          server_name = target hostname
2         0x0017 extended_master_secret
3         0xFF01 renegotiation_info
4         0x000A supported_groups  (see Named Groups below)
5         0x000B ec_point_formats  uncompressed (0x00) only
6         0x0023 session_ticket
7         0x0010 ALPN         ["h2", "http/1.1"]
8         0x0005 status_request   (OCSP stapling)
9         0x0012 signed_cert_timestamps
10        0x0033 key_share     (see Key Share below)
11        0x002B supported_versions  [TLS 1.3 (0x0304), TLS 1.2 (0x0303)]
12        0x000D signature_algorithms  (see Sig Algs below)
13        0x0012 SCT           (duplicate intentional — Chrome sends both)
14        0x0015 padding       (variable length to reach 512-byte ClientHello)
15        0x4469 ALPS          (Application-Layer Protocol Settings)
16        0xFE0D ECH outer     (Encrypted Client Hello)
last      GREASE              Same per-session GREASE value, echoed at end
```

### Named Groups

```
Position  Value   Name
0         GREASE
1         0x11EC  X25519MLKEM768  (post-quantum, Chrome 132+)
2         0x001D  x25519
3         0x0017  secp256r1
4         0x0018  secp384r1
```

### Key Share

Chrome 132 sends key shares for the first two non-GREASE groups:
- X25519MLKEM768 (0x11EC): 1216-byte public key
- x25519 (0x001D): 32-byte public key

GREASE key share also included at position 0 (1-byte value `0x00`).

### Signature Algorithms

```
0x0403  ecdsa_secp256r1_sha256
0x0804  rsa_pss_rsae_sha256
0x0401  rsa_pkcs1_sha256
0x0503  ecdsa_secp384r1_sha384
0x0805  rsa_pss_rsae_sha384
0x0501  rsa_pkcs1_sha384
0x0806  rsa_pss_rsae_sha512
0x0601  rsa_pkcs1_sha512
```

### ALPS Extension (0x4469)

ALPS (Application-Layer Protocol Settings) carries H2 settings inside the TLS handshake. Must match the H2 SETTINGS frame values exactly:
```
protocol: "h2"
settings: HEADER_TABLE_SIZE=65536, INITIAL_WINDOW_SIZE=6291456, MAX_HEADER_LIST_SIZE=262144
```

### ECH (Encrypted Client Hello)

ECH outer cipher suite must be AES-consistent with the selected outer cipher suite. If the server doesn't support ECH, the outer ClientHello is used as-is. The inner ClientHello (when ECH is accepted) carries the real SNI.

---

## HTTP/2 SETTINGS Specification (Phase 3 Reference)

Chrome 132 H2 SETTINGS frame, sent immediately after connection preface:

```
HEADER_TABLE_SIZE      = 65536      (0x00001 = 65536)
ENABLE_PUSH            = (omitted — Chrome does not send this)
MAX_CONCURRENT_STREAMS = 1000       (0x00003 = 1000)
INITIAL_WINDOW_SIZE    = 6291456    (0x00004 = 6291456)
MAX_FRAME_SIZE         = (omitted)
MAX_HEADER_LIST_SIZE   = 262144     (0x00006 = 262144)
```

Encoded as: `1:65536;3:1000;4:6291456;6:262144`

### H2 WINDOW_UPDATE

After SETTINGS, Chrome sends a WINDOW_UPDATE for the connection-level flow control window:
```
stream_id: 0 (connection level)
increment: 15663105
```

### H2 Pseudo-Header Order

```
:method
:authority
:scheme
:path
```

### JA4H Fingerprint (HTTP headers)

JA4+ includes both JA4 (TLS) and JA4H (HTTP). The H component is derived from the first 4 non-pseudo headers and cookie header presence. Header ordering must match Chrome 132's canonicalization.

Chrome 132 default request headers (order-sensitive):
```
:method
:authority
:scheme
:path
accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7
accept-encoding: gzip, deflate, br, zstd
accept-language: en-US,en;q=0.9
cache-control: max-age=0
sec-ch-ua: "Not A(Brand";v="8", "Chromium";v="132", "Google Chrome";v="132"
sec-ch-ua-mobile: ?0
sec-ch-ua-platform: "macOS"
sec-fetch-dest: document
sec-fetch-mode: navigate
sec-fetch-site: none
sec-fetch-user: ?1
upgrade-insecure-requests: 1
user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36
```

---

## What is Out of Scope for Phase 1

- HTML parsing (Phase 2)
- JavaScript execution (Phase 2)
- DOM construction (Phase 2)
- Canvas/WebGL/AudioContext fingerprinting (Phase 3)
- Navigator object (Phase 3)
- TUI rendering (Phase 3)
- ECH full handshake completion (Phase 3)
- DoH/DoT DNS (Phase 3)
- Proxy support (post-MVP)
- QUIC/HTTP/3 (post-MVP)
- WebSockets (post-MVP)
- Certificate pinning (post-MVP)

---

## Exit Criteria (ACHIEVED)

`zig build test --summary all` → **410/410 tests passed**, 0 skipped, 0 failed, across 13 test suites:

| Suite | Tests |
|---|---|
| fingerprint | 11 |
| cookie | 32 |
| http1 | 12 |
| http2 | 26 |
| pool | 14 |
| url | 11 |
| tcp | 8 |
| h2session | 4 |
| js | 24 |
| html | 14 |
| dom | 15 |
| page | 156 |
| client | 83 |
| **total** | **410** |

CLI smoke tests:
- `./zig-out/bin/awr http://example.com` → JSON `{ url, status, title, body_text, window_data }`
- `./zig-out/bin/awr https://example.com` → JSON (HTTPS via std.http.Client)
- `./zig-out/bin/awr --version` → `0.0.<githash>`
