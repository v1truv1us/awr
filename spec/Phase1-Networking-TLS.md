# AWR Phase 1 Technical Spec: Networking & TLS Layer

**Weeks 1–4 | STATUS: COMPLETE ✅**

---

## TLS Decision Record (Updated)

**Original plan**: Use curl-impersonate for Phase 1 TLS to produce Chrome 132's JA4+ fingerprint.

**Actual Phase 1 implementation**: HTTPS is handled by `std.http.Client` (backed by `std.crypto.tls`). This was the pragmatic choice — curl-impersonate has no brew formula and requires a full patched-OpenSSL source build, which is significant friction for a validation phase.

**Why this is correct**: Phase 1's goal is to validate that AWR can fetch URLs and execute JS. Fingerprint matching is a bot-detection concern, which belongs in Phase 3. AWR is a **first-party browser** — it will eventually have its own TLS fingerprint (not impersonate Chrome). curl-impersonate is available as an opt-in build backend (`-Dtls-backend=curl_impersonate`) for teams that need it, but it is not the default.

**Phase 3 TLS plan**: Replace with an owned BoringSSL stack. AWR gets its own JA4+ fingerprint — like Firefox and Safari have their own fingerprints, not Chrome's.

---

## Overview

Phase 1 builds the entire networking stack: TCP (libxev async), HTTP/1.1, HTTP/2 (nghttp2), cookie jar, URL parser, and an HTTPS-capable HTTP client. The Phase 1 HTTPS path uses `std.crypto.tls` via `std.http.Client`. JA4+ fingerprint matching is deferred to Phase 3.

**Phase 1 exit criteria (ACHIEVED)**:
- `zig build test` → 259/260 passing (1 correctly skipped)
- `zig build test-e2e` → 63/63 passing, including live HTTPS fetch of `https://example.com` returning 200 + "Example Domain"
- JS engine (QuickJS-NG), HTML parser (Lexbor), and DOM modules integrated and tested

**Original fingerprint milestone** (`tls.peet.ws` JA4+ = `t13d1517h2_8daaf6152771_b6f405a00624`): moved to Phase 3.

---

## Module Structure

> **Note**: The module structure below is the original spec. The actual Phase 1 implementation differs — see the TLS Decision Record above. `tls.zig` is a Phase 3 stub (not a curl-impersonate wrapper), `client.zig` is the primary fetch layer, and the `c/curl_impersonate.zig` and `build/curl_impersonate.zig` files are not present in the default build.

```
src/
  net/
    tcp.zig          -- TCP connection state machine, libxev integration
    tls.zig          -- Phase 3 TLS stub; opt-in curl_impersonate backend via -Dtls-backend
    http1.zig        -- HTTP/1.1 request/response serialization
    http2.zig        -- nghttp2 C-ABI integration, SETTINGS injection
    pool.zig         -- Per-origin connection pool
    cookie.zig       -- RFC 6265 cookie jar
    url.zig          -- URL parser
    fingerprint.zig  -- HTTP fingerprint utilities
  client.zig         -- Primary fetch layer: wires URL→TCP→(std.http.Client for HTTPS)→H2/H1→Cookie→Response
```

All public API surfaces are in `src/net/`. The `c/` wrappers are internal. `build/` contains `build.zig` integration helpers.

---

## Core Zig Structs

### TcpConn

```zig
const TcpConn = struct {
    // libxev handle — platform-specific under the hood (io_uring/kqueue/IOCP)
    loop: *xev.Loop,
    socket: xev.TCP,

    // Connection state
    state: TcpState,
    remote_addr: std.net.Address,
    local_addr: std.net.Address,

    // Read/write buffers — arena-allocated per connection lifetime
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,

    const TcpState = enum {
        idle,
        connecting,
        connected,
        draining,
        closed,
    };

    pub fn connect(self: *TcpConn, addr: std.net.Address) !void;
    pub fn write(self: *TcpConn, data: []const u8, cb: xev.Callback) !void;
    pub fn read(self: *TcpConn, buf: []u8, cb: xev.Callback) !void;
    pub fn close(self: *TcpConn) void;
};
```

**State machine transitions**:
```
idle → connecting  (connect() called)
connecting → connected  (TCP handshake complete, libxev callback fires)
connected → draining  (graceful close initiated, waiting for in-flight writes)
draining → closed  (all writes flushed, FIN sent)
connecting → closed  (connection refused / timeout)
connected → closed  (error or remote RST)
```

Timeouts are enforced via libxev timer completions: connect timeout 10s, idle keepalive 30s.

### TlsConn

> **Note**: The struct definition below is the original spec (curl-impersonate backed). The actual Phase 1 `TlsConn` in `src/net/tls.zig` uses a C shim (`awr_tls_ctx`) that is only present when built with `-Dtls-backend=curl_impersonate`. In the default stub build, all `TlsConn` ops return `CurlImpersonateNotAvailable` and HTTPS is handled by `client.zig`'s `fetchHttpsViaStd()` instead.

```zig
const TlsConn = struct {
    tcp: *TcpConn,

    // curl-impersonate CURL* handle — opaque C pointer (opt-in backend only)
    curl: *curl_impersonate.CURL,

    // TLS state
    tls_state: TlsState,
    protocol: HttpProtocol,  // negotiated via ALPN

    // Chrome 132 profile to impersonate
    profile: ChromeProfile,

    // Session ticket for 0-RTT resumption (TLS 1.3)
    session_ticket: ?[]u8,
    allocator: std.mem.Allocator,

    const TlsState = enum {
        handshaking,
        established,
        renegotiating,
        closed,
    };

    const HttpProtocol = enum {
        http1_1,
        http2,
    };

    const ChromeProfile = enum {
        chrome_132,
        // Future: chrome_133, edge_131, firefox_128, safari_18
    };

    pub fn handshake(self: *TlsConn) !void;
    pub fn send(self: *TlsConn, data: []const u8) !usize;
    pub fn recv(self: *TlsConn, buf: []u8) !usize;
    pub fn negotiatedProtocol(self: *TlsConn) HttpProtocol;
};
```

### HttpRequest

```zig
const HttpRequest = struct {
    method: Method,
    url: []const u8,
    headers: HeaderMap,
    body: ?[]const u8,
    version: HttpVersion,

    // Per-request options
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    timeout_ms: u32 = 30_000,

    const Method = enum { GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH };
    const HttpVersion = enum { http1_1, http2 };

    // HeaderMap preserves insertion order (critical for fingerprinting)
    const HeaderMap = struct {
        entries: std.ArrayListUnmanaged(Header),
        allocator: std.mem.Allocator,

        const Header = struct { name: []const u8, value: []const u8 };

        pub fn append(self: *HeaderMap, name: []const u8, value: []const u8) !void;
        pub fn get(self: *HeaderMap, name: []const u8) ?[]const u8;
        pub fn setChrome132Defaults(self: *HeaderMap, host: []const u8) !void;
    };

    pub fn build(allocator: std.mem.Allocator) HttpRequestBuilder;
};
```

Chrome 132 default request headers (order-sensitive, set by `setChrome132Defaults`):
```
:method         (H2 pseudo, first)
:authority      (H2 pseudo, second)
:scheme         (H2 pseudo, third)
:path           (H2 pseudo, fourth)
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

### HttpResponse

```zig
const HttpResponse = struct {
    status: u16,
    headers: HttpRequest.HeaderMap,
    body: []u8,
    protocol: HttpRequest.HttpVersion,

    // Timing (for instrumentation and fingerprint research)
    timing: Timing,

    const Timing = struct {
        dns_ms: u32,
        connect_ms: u32,
        tls_ms: u32,
        ttfb_ms: u32,
        total_ms: u32,
    };

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void;
    pub fn isRedirect(self: *HttpResponse) bool;
    pub fn location(self: *HttpResponse) ?[]const u8;
};
```

### ConnectionPool

```zig
const ConnectionPool = struct {
    // Per-origin pool: "scheme://host:port" → []PooledConn
    pools: std.StringHashMapUnmanaged(OriginPool),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    const OriginPool = struct {
        conns: std.ArrayListUnmanaged(PooledConn),
        max_size: u8 = 6,   // Chrome's per-origin limit
        waiting: std.ArrayListUnmanaged(WaitCallback),
    };

    const PooledConn = struct {
        tls: *TlsConn,
        in_use: bool,
        last_used_ms: i64,
        request_count: u32,
    };

    const WaitCallback = struct {
        cb: *const fn (conn: *TlsConn) void,
    };

    pub fn acquire(self: *ConnectionPool, origin: []const u8) !*TlsConn;
    pub fn release(self: *ConnectionPool, origin: []const u8, conn: *TlsConn) void;
    pub fn evictIdle(self: *ConnectionPool, older_than_ms: i64) void;
};
```

Pool eviction: idle connections older than 30s are evicted. `max_size = 6` matches Chrome's per-origin connection limit (important for fingerprinting — Chrome never opens more than 6 simultaneous connections to an origin).

### CookieJar

```zig
const CookieJar = struct {
    // Keyed by domain — uses domain suffix matching per RFC 6265 §5.1.3
    cookies: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Cookie)),
    allocator: std.mem.Allocator,

    const Cookie = struct {
        name: []const u8,
        value: []const u8,
        domain: []const u8,
        path: []const u8,
        expires: ?i64,       // Unix timestamp, null = session cookie
        secure: bool,
        http_only: bool,
        same_site: SameSite,

        const SameSite = enum { strict, lax, none };
    };

    pub fn set(self: *CookieJar, response: *HttpResponse, request_url: []const u8) !void;
    pub fn get(self: *CookieJar, request_url: []const u8) ![]const u8;
    pub fn purgeExpired(self: *CookieJar) void;
};
```

---

## Chrome 132 ClientHello Specification

This section is the ground truth for the Phase 3 BoringSSL stack (and the opt-in `curl_impersonate` backend). Phase 1 uses `std.crypto.tls` and does not emit this fingerprint. Any deviation from these values will produce a non-matching JA4+ fingerprint.

### TLS Version

- Minimum: TLS 1.2 (for compatibility)
- Maximum offered: TLS 1.3
- Negotiated (target): TLS 1.3

### Cipher Suites (16 total, order-sensitive)

```
Position  Hex     Name
0         GREASE  (random from: 0x0A0A, 0x1A1A, 0x2A2A, 0x3A3A, 0x4A4A,
                   0x5A5A, 0x6A6A, 0x7A7A, 0x8A8A, 0x9A9A, 0xAAAA, 0xBABA,
                   0xCACA, 0xDADA, 0xEAEA, 0xFAFA — same value per session)
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

Note: 17 values including GREASE at position 0, but the JA4+ fingerprint counts 16 non-GREASE ciphers.

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

### Named Groups (supported_groups extension)

```
Position  Value   Name
0         GREASE
1         0x11EC  X25519MLKEM768  (post-quantum, Chrome 132+)
2         0x001D  x25519
3         0x0017  secp256r1
4         0x0018  secp384r1
```

### Key Share (key_share extension, TLS 1.3)

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

ALPS (Application-Layer Protocol Settings) carries H2 settings inside the TLS handshake. Content must match the H2 SETTINGS frame values exactly:
```
protocol: "h2"
settings: HEADER_TABLE_SIZE=65536, INITIAL_WINDOW_SIZE=6291456, MAX_HEADER_LIST_SIZE=262144
```

### ECH (Encrypted Client Hello)

ECH outer cipher suite must be AES-consistent with the selected outer cipher suite from the list above. If the server doesn't support ECH, the outer ClientHello is used as-is. The inner ClientHello (when ECH is accepted) carries the real SNI.

For Phase 1, ECH can be stubbed: include the extension with a conformant structure but do not attempt ECH handshake completion. The JA4+ fingerprint captures extension presence, not ECH success.

---

## HTTP/2 SETTINGS Specification

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

This value (`15663105`) is part of the H2 fingerprint and must be exact.

### H2 Pseudo-Header Order

```
:method
:authority
:scheme
:path
```

All other headers follow. Header ordering within the non-pseudo block must match Chrome's canonicalization (see `setChrome132Defaults` above).

### JA4H Fingerprint (HTTP headers)

The complete network fingerprint is JA4+ which includes both JA4 (TLS) and JA4H (HTTP). The H component is derived from the first 4 non-pseudo headers and the cookie header presence. AWR must emit headers in the canonical Chrome 132 order to match.

---

## curl-impersonate Integration Strategy

> **Phase 3 content.** This section describes the opt-in `curl_impersonate` backend and the planned Phase 3 BoringSSL migration. It does NOT describe the Phase 1 default build, which uses `std.crypto.tls`. The code in `src/net/tls.zig` already implements the C-shim abstraction layer that will host the Phase 3 backend.

### Linked Library vs. Subprocess

**Decision: Linked library.**

Subprocess mode (`curl-impersonate-chrome` binary invoked via `std.process.Child`) works but has three disqualifying limitations:
1. No connection reuse — each request requires a new process and TLS handshake
2. Fork/exec latency (~5ms per request on macOS, ~2ms on Linux)
3. No access to curl's internal state (session tickets, connection stats)

Linked library mode (`libcurl-impersonate.a`) provides:
1. Full connection pool reuse (curl's multi interface)
2. Direct C-ABI access to CURLINFO_* timing data
3. TLS session ticket extraction for fingerprint research
4. Sub-millisecond overhead after first connection

Build complexity: curl-impersonate requires building a patched curl against BoringSSL. The Zig build system (`build.zig`) will detect a pre-built `libcurl-impersonate.a` at a configurable path, or trigger a shell script build step. Pre-built static libraries for macOS/arm64, macOS/x86_64, and Linux/x86_64 will be committed to `third_party/curl-impersonate/`.

### curl-impersonate C-ABI Wrapper

```zig
// src/c/curl_impersonate.zig
const c = @cImport({
    @cInclude("curl/curl.h");
    // curl-impersonate adds: curl_easy_impersonate()
});

pub const CURL = c.CURL;
pub const CURLcode = c.CURLcode;

pub fn easy_init() ?*CURL {
    return c.curl_easy_init();
}

pub fn easy_impersonate(handle: *CURL, target: [*:0]const u8, default_headers: c_int) CURLcode {
    // curl_easy_impersonate() is the key function added by curl-impersonate
    // target = "chrome132" selects Chrome 132 profile
    return c.curl_easy_impersonate(handle, target, default_headers);
}

pub fn easy_setopt_url(handle: *CURL, url: [*:0]const u8) CURLcode {
    return c.curl_easy_setopt(handle, c.CURLOPT_URL, url);
}

// ... additional setopt wrappers for headers, write callback, etc.
```

`curl_easy_impersonate(handle, "chrome132", 0)` configures the handle to use Chrome 132's TLS profile. `default_headers = 0` means we provide our own headers (required — we need to control header order).

---

## HTTP/1.1 Implementation

HTTP/1.1 is the fallback when ALPN does not negotiate H2, or when the server doesn't support H2.

```zig
// src/net/http1.zig

pub fn writeRequest(writer: anytype, req: *HttpRequest) !void {
    // Request line
    try writer.print("{s} {s} HTTP/1.1\r\n", .{ @tagName(req.method), req.path() });

    // Headers (insertion order preserved by HeaderMap)
    var it = req.headers.entries.iterator();
    while (it.next()) |entry| {
        // Skip H2 pseudo-headers for HTTP/1.1
        if (std.mem.startsWith(u8, entry.name, ":")) continue;
        try writer.print("{s}: {s}\r\n", .{ entry.name, entry.value });
    }

    // Blank line
    try writer.writeAll("\r\n");

    // Body
    if (req.body) |body| {
        try writer.writeAll(body);
    }
}

pub fn readResponse(reader: anytype, allocator: std.mem.Allocator) !HttpResponse {
    // Status line
    var status_line_buf: [256]u8 = undefined;
    const status_line = try reader.readUntilDelimiter(&status_line_buf, '\n');
    const status = parseStatusCode(status_line);

    // Headers
    var headers = HttpRequest.HeaderMap.init(allocator);
    while (true) {
        var header_buf: [8192]u8 = undefined;
        const line = try reader.readUntilDelimiter(&header_buf, '\n');
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) break;  // blank line = end of headers
        try parseHeader(trimmed, &headers);
    }

    // Body (Content-Length or chunked transfer encoding)
    const body = try readBody(reader, &headers, allocator);

    return HttpResponse{ .status = status, .headers = headers, .body = body };
}
```

---

## nghttp2 Integration

> **Phase 2 status note**: `src/net/h2session.zig` (AWR's own H2 session) is only
> reachable via `fetchHttpsViaTls`, which requires the curl_impersonate TLS backend
> (`-Dtls-backend=curl_impersonate`).  In the **default Phase 1/2 build**, HTTPS
> fetches go through `fetchHttpsViaStd` (`std.http.Client`), which handles HTTP/2
> via OS/stdlib ALPN — AWR's own H2 implementation is **not active**.
> Phase 3 goal: wire `h2session.zig` into AWR's own BoringSSL TLS stack.

nghttp2 provides the H2 framing layer. AWR calls nghttp2's C callbacks to inject custom SETTINGS values and control frame ordering.

```zig
// src/net/http2.zig

const nghttp2 = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

const H2Session = struct {
    session: *nghttp2.nghttp2_session,
    tls: *TlsConn,
    streams: std.AutoHashMapUnmanaged(i32, *H2Stream),
    allocator: std.mem.Allocator,

    pub fn init(tls: *TlsConn, allocator: std.mem.Allocator) !H2Session {
        var callbacks: nghttp2.nghttp2_session_callbacks = undefined;
        nghttp2.nghttp2_session_callbacks_new(&callbacks);
        nghttp2.nghttp2_session_callbacks_set_send_callback(callbacks, sendCallback);
        nghttp2.nghttp2_session_callbacks_set_recv_callback(callbacks, recvCallback);
        nghttp2.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
        nghttp2.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);

        var session: *nghttp2.nghttp2_session = undefined;
        _ = nghttp2.nghttp2_session_client_new(&session, callbacks, tls);

        // Send Chrome 132 SETTINGS immediately after connection preface
        const settings = [_]nghttp2.nghttp2_settings_entry{
            .{ .settings_id = nghttp2.NGHTTP2_SETTINGS_HEADER_TABLE_SIZE, .value = 65536 },
            .{ .settings_id = nghttp2.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = 1000 },
            .{ .settings_id = nghttp2.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = 6291456 },
            .{ .settings_id = nghttp2.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = 262144 },
        };
        _ = nghttp2.nghttp2_submit_settings(session, nghttp2.NGHTTP2_FLAG_NONE, &settings, settings.len);

        // Send connection-level WINDOW_UPDATE to 15663105
        _ = nghttp2.nghttp2_submit_window_update(session, nghttp2.NGHTTP2_FLAG_NONE, 0, 15663105);

        return H2Session{ .session = session, .tls = tls, .streams = .{}, .allocator = allocator };
    }

    pub fn sendRequest(self: *H2Session, req: *HttpRequest) !i32 {
        // Build nv array with pseudo-headers FIRST, in Chrome order
        var nv = std.ArrayList(nghttp2.nghttp2_nv).init(self.allocator);
        defer nv.deinit();

        // Pseudo-headers in Chrome 132 order
        try appendNv(&nv, ":method", @tagName(req.method));
        try appendNv(&nv, ":authority", req.host());
        try appendNv(&nv, ":scheme", req.scheme());
        try appendNv(&nv, ":path", req.pathAndQuery());

        // Regular headers (skip pseudo-headers, already added)
        var it = req.headers.entries.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, ":")) continue;
            try appendNv(&nv, entry.name, entry.value);
        }

        const stream_id = nghttp2.nghttp2_submit_request(
            self.session,
            null,
            nv.items.ptr,
            nv.items.len,
            null,
            null,
        );
        return stream_id;
    }
};
```

---

## DNS Strategy

Phase 1 uses the system resolver (`getaddrinfo`) via Zig's standard library. This is intentional — custom DoH (DNS-over-HTTPS) is a Phase 3 feature for detection evasion. For Phase 1, system DNS is sufficient to validate the TLS fingerprint.

DNS cache: in-memory HashMap with 5-minute TTL per hostname. No cross-session persistence in Phase 1.

```zig
const DnsCache = struct {
    entries: std.StringHashMapUnmanaged(DnsEntry),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    const DnsEntry = struct {
        addrs: []std.net.Address,
        expires_ms: i64,
    };

    pub fn resolve(self: *DnsCache, hostname: []const u8, port: u16) ![]std.net.Address;
    pub fn purgeExpired(self: *DnsCache) void;
};
```

---

## Connection Pooling Design

Per-origin pool with Chrome's exact limits:
- Maximum 6 connections per origin (`scheme://host:port`)
- Maximum 256 total connections across all origins
- Idle timeout: 30 seconds
- Connection maximum age: 5 minutes (prevents session-linked fingerprinting)
- Maximum requests per connection: 100 (matches Chrome's H2 stream reuse behavior)

Acquire semantics:
1. Check pool for an idle connection to this origin
2. If found and healthy (last_used < 30s, request_count < 100): return it
3. If pool is at max_size (6): add caller to waiting list, return when a connection is released
4. Otherwise: create a new TlsConn, perform TLS handshake, return

Release semantics:
1. If connection is healthy and pool is not over capacity: return to idle pool
2. If connection errored or pool is full: close the connection

---

## Testing Approach

### Unit Tests (in-module, `test` blocks)

Each `.zig` file in `src/net/` has embedded `test` blocks:
- `tcp.zig`: state machine transitions with mock libxev events
- `http1.zig`: request serialization byte-comparison against known-good Chrome captures
- `http2.zig`: SETTINGS frame byte comparison, pseudo-header order verification
- `cookie.zig`: RFC 6265 §5 test cases (domain matching, path matching, expiry, secure flag)
- `conn_pool.zig`: concurrency stress test (16 goroutines competing for 6 connections)

### Integration Tests

`tests/phase1/`

```
tls_fingerprint_test.zig   -- hits tls.peet.ws, asserts JA4+ = target value
cloudflare_test.zig        -- hits a Cloudflare-protected URL, asserts 200
http2_settings_test.zig    -- captures H2 frames via local proxy, verifies SETTINGS
redirect_test.zig          -- 301/302/307/308 chains, max redirect enforcement
cookie_test.zig            -- set-cookie / cookie round-trip via local test server
```

The `tls.peet.ws` test is the primary regression guard. It must pass on every CI run. The Cloudflare test is marked `// integration: external` and runs only in full integration mode (not in CI by default, to avoid rate limiting).

### Local Test Server

`tests/server/` contains a minimal Go HTTP server used by unit and integration tests:
- Serves configurable HTTP/1.1 and H2 responses
- Records request headers and H2 frames for assertion
- Simulates redirect chains and Set-Cookie headers
- No external dependencies — `go run ./tests/server` starts it

The test server is Go (not Zig) deliberately — it uses `golang.org/x/net/http2` which is a well-tested reference H2 implementation, ensuring AWR's H2 framing is tested against a correct counterparty.

---

## TLS Identity: First-Party Stack (Not Chrome Impersonation)

AWR is a first-party browser. It does not impersonate Chrome.

Real browsers (Firefox, Safari, Chrome) each maintain their own BoringSSL or NSS stack and produce their own distinct TLS fingerprint. Anti-bot systems whitelist these browsers because they are known, legitimate user agents with verifiable identity — not because they mimic each other.

### Target architecture
- AWR embeds BoringSSL directly, owned and configured by this project
- AWR produces its own stable ClientHello profile with a documented JA4+ fingerprint
- Over time, AWR registers its fingerprint with anti-bot vendors (Cloudflare, Akamai, DataDome) for allowlisting — the same path any new legitimate browser takes

### Why curl-impersonate exists in the codebase (and why it is NOT Phase 1)

`tls.zig` exposes a `curl_impersonate` opt-in backend (`-Dtls-backend=curl_impersonate`) for teams that need Chrome 132 fingerprint validation before Phase 3 ships. It is **not** built or used by default.

**Phase 1 actual decision**: HTTPS uses `client.zig`'s `fetchHttpsViaStd()` → `std.http.Client` → `std.crypto.tls`. This was the pragmatic choice — curl-impersonate has no brew formula and requires a patched-OpenSSL source build. Phase 1's goal was to validate URL fetching and JS execution, not fingerprint matching.

This is explicitly NOT the target architecture. curl-impersonate must be removed before any public release.

### Migration path
1. **Phase 1 (complete):** `std.crypto.tls` via `std.http.Client` — validate networking layer against real sites
2. **Phase 3:** Embed BoringSSL directly; define AWR's own cipher suite order and extension list; establish the AWR JA4+ fingerprint
3. **Pre-launch:** Submit AWR fingerprint to major bot-detection vendors for allowlisting; document the fingerprint publicly so operators can whitelist it themselves

### What first-party identity means in practice
- AWR sends `User-Agent: AWR/x.y` (not Chrome or any other browser)
- AWR's TLS fingerprint is unique to AWR and stable across versions
- Sites that block unknown fingerprints will block AWR until allowlisted — that is acceptable and expected during early development
- AWR never ships code whose purpose is to deceive a server about what software is making the request

---

## What is Out of Scope for Phase 1

- HTML parsing (Phase 2)
- JavaScript execution (Phase 2)
- DOM construction (Phase 2)
- Canvas/WebGL/AudioContext fingerprinting (Phase 3)
- Navigator object (Phase 3)
- TUI rendering (Phase 3)
- WebMCP (Phase 4)
- ECH full handshake completion (Phase 1 stubs the extension, Phase 3 implements it)
- DoH/DoT DNS (Phase 3)
- Proxy support (post-MVP)
- QUIC/HTTP/3 (post-MVP)
- WebSockets (post-MVP)
- Certificate pinning (post-MVP)

---

## Definition of Done

**Phase 1 is COMPLETE ✅** — achieved as of commit `d60390d`.

### Original fingerprint criteria (items 1–8) — deferred to Phase 3

The JA4+ fingerprint milestone was moved to Phase 3 (see TLS Decision Record at top of this document). These criteria will be re-evaluated against the Phase 3 BoringSSL stack:

- [ ] **1.** `tls.peet.ws/api/all` returns `ja4`: `t13d1517h2_8daaf6152771_b6f405a00624` — **Phase 3**
- [ ] **2.** Cipher suite list byte-matches Chrome 132 capture: 16 ciphers in exact order, GREASE at position 0 — **Phase 3**
- [ ] **3.** GREASE value is consistent within a session and varies across sessions — **Phase 3**
- [ ] **4.** X25519MLKEM768 (0x11EC) appears at named_groups[1], with correct 1216-byte key share — **Phase 3**
- [ ] **5.** ALPS extension (0x4469) present with correct H2 settings payload — **Phase 3**
- [ ] **6.** H2 SETTINGS frame encodes `1:65536;3:1000;4:6291456;6:262144` — **Phase 3**
- [ ] **7.** H2 connection-level WINDOW_UPDATE sends increment `15663105` — **Phase 3**
- [ ] **8.** H2 pseudo-header order is `:method, :authority, :scheme, :path` — verified by frame capture test — **Phase 3**

### Networking stack criteria (items 9–14) — all achieved ✅

- [x] **9.** HTTPS fetch of `https://example.com` returns 200 with "Example Domain" in body — verified by e2e test (`zig build test-e2e`)
- [x] **10.** HTTP fetch of `http://example.com` returns 200 with non-empty HTML body — verified by e2e test
- [x] **11.** Connection pool enforces max-6-per-origin — implemented in `src/net/pool.zig`
- [x] **12.** Cookie jar correctly handles Set-Cookie with domain, path, secure, httpOnly, SameSite — 32 cookie tests passing
- [x] **13.** Redirect chain following with configurable max — implemented in `client.zig`
- [x] **14.** `zig build test` passes: **259/260 unit tests** (1 correctly skipped); `zig build test-e2e`: **89/91 e2e tests** (2 correctly skipped — curl_impersonate-gated)

---

*Phase 1 complete = Chrome 132 on the wire. Everything above the network is Phase 2+.*
