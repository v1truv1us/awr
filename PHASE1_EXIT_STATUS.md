# Phase 1 Exit Status

This is the strict production-readiness read against `awr-spec/Phase1-Networking-TLS.md:739`.

Rule used here:

- `done` means verifiably true end-to-end, with the kind of evidence the spec asks for
- `partial` means some foundations/constants/tests exist, but not enough to mark complete
- `not done` means missing, contradicted by current code, or not yet verifiable

Current conclusion:

- Phase 1 is **not complete**
- Several items have useful foundations
- Multiple production blockers still exist in TLS, HTTP/2, redirects, pooling, and cookie semantics

## Item-by-Item Review

### 1. `tls.peet.ws/api/all` returns exact JA4 string by automated test

Status: **not done**

Evidence:

- The spec requires an automated verification against `tls.peet.ws/api/all`
- `src/net/tls.zig` only has an `example.com` integration smoke test, not a JA4 assertion
- no `tls.peet.ws/api/all` automated test is present in `src/`

What is needed:

- real curl-impersonate backend provisioned on this machine
- automated integration test that fetches `tls.peet.ws/api/all`
- assert returned `ja4` exactly matches `t13d1517h2_8daaf6152771_b6f405a00624`

### 2. Cipher suite list byte-matches Chrome 132 capture

Status: **partial**

Evidence:

- `src/net/fingerprint.zig:32` defines the expected 16 Chrome 132 ciphers
- unit tests confirm the constant list values in `src/net/fingerprint.zig:72`
- but there is no real wire-capture or live handshake verification that the emitted ClientHello matches

Production blocker:

- constants alone are not enough; the emitted TLS handshake must be verified on the wire

What is needed:

- capture-based test over the active TLS backend
- assert GREASE is first and the 16 following ciphers byte-match exactly

### 3. GREASE value is session-consistent and varies across sessions

Status: **not done**

Evidence:

- `src/net/fingerprint.zig:12` defines valid GREASE values
- there is no session GREASE selection implementation in repo code
- there is no multi-session verification test

What is needed:

- explicit session-level GREASE behavior verification
- automated test proving same handshake session reuses one GREASE value and separate sessions vary

### 4. X25519MLKEM768 at named_groups[1] with correct 1216-byte key share

Status: **not done**

Evidence:

- no code in `src/` validates `0x11EC`, `X25519MLKEM768`, or a 1216-byte key share
- no capture test or parser for this exists in repo code

What is needed:

- live capture or `tls.peet.ws`-style verification proving the exact named group order and key share size

### 5. ALPS extension present with correct H2 settings payload

Status: **not done**

Evidence:

- no ALPS-specific verification exists in `src/`
- no automated test asserts extension `0x4469` or payload bytes

What is needed:

- capture-based TLS extension verification
- explicit payload assertion against the Chrome 132 expectation

### 6. H2 SETTINGS frame encodes the exact Chrome 132 values, verified by frame capture test

Status: **partial**

Evidence:

- `src/net/http2.zig:84` defines the exact SETTINGS tuple
- `src/net/http2.zig:130` onward has byte-level unit tests for SETTINGS encoding
- `src/net/h2_shim.c:193` queues matching nghttp2 SETTINGS values
- but the spec requires frame-capture verification on the real H2 path, and that test does not exist

What is needed:

- capture the actual first SETTINGS frame on a live H2 connection
- verify exact bytes, not just helper constants

### 7. H2 connection-level WINDOW_UPDATE increment is `15663105`

Status: **partial**

Evidence:

- `src/net/fingerprint.zig:59` and `src/net/http2.zig:245` define and test the constant/encoder
- but there is no evidence the live H2 session actually emits this increment
- no explicit runtime WINDOW_UPDATE submission is visible in `src/net/h2_shim.c`

What is needed:

- either explicitly emit the connection-level WINDOW_UPDATE in the live H2 session, or prove nghttp2 is doing it as required
- add frame-capture verification

### 8. H2 pseudo-header order is `:method, :authority, :scheme, :path`

Status: **not done**

Evidence:

- the intended order is modeled in `src/net/fingerprint.zig:63` and checked in `src/net/http2.zig:120`
- but the live nghttp2 shim currently submits them in the wrong order in `src/net/h2_shim.c:220`
- current runtime order is:
  - `:method`
  - `:scheme`
  - `:authority`
  - `:path`

This is a concrete spec mismatch and a production blocker.

What is needed:

- fix `src/net/h2_shim.c`
- add live frame-capture verification

### 9. `awr fetch https://news.ycombinator.com` returns 200 with non-empty body on H2 path

Status: **not done**

Evidence:

- `src/client.zig:252` uses `TlsConn` for HTTPS in curl mode
- but `src/client.zig:275` still writes an HTTP/1.1 request over that TLS connection
- `src/client.zig` does not call `src/net/h2session.zig`
- no H2 client integration exists for the fetch path
- no `news.ycombinator.com` e2e test exists

This means the actual client H2 path is not wired.

What is needed:

- ALPN-aware branch in the client
- if H2 negotiated, route request through `h2session`
- add e2e test against `https://news.ycombinator.com`

### 10. `awr fetch https://example.com` returns 200 with non-empty body on HTTP/1.1 fallback

Status: **partial**

Evidence:

- `src/test_e2e.zig:100` has an HTTPS success test in fallback mode
- but fallback mode there is `std.http.Client`, not the owned AWR network stack
- `build.zig:10` still defaults the TLS backend to `stub`
- in curl mode, `src/client.zig:275` always writes HTTP/1.1 text without an explicit ALPN-driven HTTP/1.1 fallback branch

Production blocker:

- the spec wants AWR's real stack proven, not just stdlib fallback behavior

What is needed:

- explicit negotiated-protocol handling
- owned HTTP/1.1 fallback path after TLS handshake
- e2e verification under the production TLS backend

### 11. Connection pool enforces max-6-per-origin under concurrent load

Status: **not done**

Evidence:

- `src/net/pool.zig:15` defines `MAX_PER_ORIGIN = 6`
- `src/net/pool.zig:293` tests the per-origin cap in a unit test
- but there is no concurrent stress test
- `MAX_TOTAL` is declared but not enforced: `src/net/pool.zig:16`, `src/net/pool.zig:118`, `src/net/pool.zig:157`
- the pool does not appear integrated into `src/client.zig`

Production blockers:

- no real concurrency verification
- no client integration
- total connection accounting is incomplete

What is needed:

- integrate pool into the fetch path
- enforce total cap and correct accounting on eviction/close
- add concurrent stress test proving max-6-per-origin under load

### 12. Cookie jar correctly handles domain, path, secure, httpOnly, SameSite

Status: **partial**

Evidence:

- parsing/storage exists in `src/net/cookie.zig`
- tests exist for domain, path, secure, httpOnly, SameSite parsing in `src/net/cookie.zig:197`
- but request-path matching is too permissive in `src/net/cookie.zig:138`
- current logic uses `startsWith(request_path, cookie_path)`, so `/api` would incorrectly match `/apiOld`
- `SameSite` is parsed but not enforced when sending cookies
- `http_only` is stored but not meaningfully exercised beyond parse/storage

Production blockers:

- RFC path matching is not correct
- SameSite send semantics are not implemented

What is needed:

- implement RFC 6265 path-match rules
- add tests for `/api` vs `/apiOld`
- implement SameSite-aware send policy or make request context explicit enough to enforce it correctly

### 13. Redirect chain of 3 hops follows; chain > 10 errors

Status: **not done**

Evidence:

- redirect-following logic exists in `src/client.zig:191` and `src/client.zig:329`
- HTTP path increments redirect count correctly at `src/client.zig:211`
- HTTPS curl path resets redirect count to `0` at `src/client.zig:347`
- only a trivial option test exists for `max_redirects` in `src/client.zig:408`
- no automated 3-hop redirect integration test exists

This is a concrete correctness bug on the HTTPS path.

What is needed:

- fix HTTPS redirect recursion to pass `redirect_count + 1`
- add integration tests for:
  - successful 3-hop chain
  - failure when chain exceeds 10

### 14. `zig build test` passes all unit tests in under 10 seconds on M-series Mac

Status: **partial**

Evidence:

- unit tests have previously passed in this conversation
- but current default build is `stub` TLS in `build.zig:10`
- there is no checked-in timing benchmark or automated assertion for the `< 10s` requirement
- there is no production-backend proof that the full relevant test matrix still passes within budget

Production blocker:

- green tests in stub mode are not enough to declare Phase 1 production-ready

What is needed:

- define the production Phase 1 test command set
- run and record timings on an M-series Mac with the intended backend/deps
- make sure the production configuration, not just stub mode, is green

## Production-Readiness Summary

Strict result:

- `done`: **0 / 14**
- `partial foundation exists`: several
- `blocked by missing verification or live integration`: most
- `contains confirmed correctness bugs`: at least items **8, 12, 13**

## Minimum Gating Before Calling Phase 1 Complete

1. Provision the real production TLS backend and prove it on this machine
2. Add live verification for items 1 to 8, not just constants/unit helpers
3. Wire the actual H2 client path for item 9
4. Replace reliance on stdlib fallback as the main proof for item 10
5. Fix pool, cookie, and redirect correctness gaps
6. Re-run the final Phase 1 matrix under the production backend and timing budget

## Recommendation

Do not mark Phase 1 complete yet.

If the goal is production-readiness before moving on, the next step should be a Phase 1 closure plan that turns each `partial/not done` item above into a concrete implementation + verification task list.
