# Phase 1 Closure Plan

> **PARTIALLY HISTORICAL** — This plan was written when AWR used `curl-impersonate`
> and `std.http.Client` for HTTPS. The project has since moved to **direct BoringSSL
> integration**. Many items listed as "production blockers" below have been resolved:
>
> | Original Blocker | Current Status |
> |---|---|
> | H2 pseudo-header order wrong | **Fixed** — verified by wire-capture test |
> | Cookie path matching too permissive | **Fixed** — RFC 6265 §5.1.4 boundary check |
> | HTTPS redirect counter reset | **Fixed** — increments correctly |
> | Client not ALPN-aware | **Fixed** — routes h2 vs http11 based on negotiation |
> | Pool not integrated | **Fixed** — acquire/release/close in live paths |
> | No JA4/ALPS/GREASE verification | **Partially fixed** — JA4 live test exists; wire-level capture for cipher/GREASE/MLKEM/ALPS still needed |
> | curl-impersonate setup | **Abandoned** — replaced by BoringSSL |
>
> See `PHASE1_EXIT_STATUS.md` for the current item-by-item status.

This plan is the production-ready path to close Phase 1 against `awr-spec/Phase1-Networking-TLS.md:739`.

## Non-Negotiables

Phase 1 is not complete until:

- all 14 exit items are backed by automated evidence
- the evidence comes from the real curl-impersonate/nghttp2 path, not stub mode or stdlib fallback
- the owned AWR client path handles both negotiated HTTP/2 and HTTP/1.1 fallback correctly
- known correctness bugs in H2, cookies, redirects, and pooling are fixed
- the final verification matrix passes on an M-series Mac within the spec timing budget

## Current Production Blockers

- `src/net/h2_shim.c`
  - pseudo-header order is wrong for the live H2 path
- `src/net/cookie.zig`
  - request path matching is too permissive for RFC 6265 behavior
- `src/client.zig`
  - HTTPS redirect recursion resets the counter instead of incrementing it
  - HTTPS fetch path is not ALPN-aware and does not route to `src/net/h2session.zig`
- `src/net/pool.zig`
  - per-origin constants/tests exist, but the pool is not fully integrated into the real client flow
  - total-cap accounting is incomplete
- `src/net/tls.zig` and integration tests
  - no live JA4 / ALPS / GREASE / MLKEM verification exists yet
- `build.zig`
  - current default backend is still `stub`, so production proof needs its own explicit verification path

## Workstreams

### Workstream 1: Production backend and verification harness

Goal: make the production TLS/H2 backend the basis of Phase 1 proof.

Deliverables:

- documented curl-impersonate + nghttp2 setup for the target M-series machine
- dedicated production verification commands using `-Dtls-backend=curl_impersonate`
- clear separation between:
  - unit tests
  - live TLS verification
  - local H2 frame verification
  - external smoke tests

Required outputs:

- one repeatable command set for “Phase 1 production verification”
- timings recorded on target hardware

Suggested file targets:

- `build.zig`
- `TLS_RESUME_PLAN.md`
- new test entrypoints/docs as needed

Acceptance gate:

- every closure claim can be run under the production backend without relying on stub mode

### Workstream 2: Fix confirmed correctness bugs first

Goal: remove known spec mismatches before deeper integration.

Tasks:

1. Fix H2 pseudo-header order in `src/net/h2_shim.c`
   - required order: `:method, :authority, :scheme, :path`
2. Fix RFC 6265 path-match behavior in `src/net/cookie.zig`
   - `/api` must not match `/apiOld`
   - add boundary-aware path tests
3. Fix HTTPS redirect recursion in `src/client.zig`
   - propagate `redirect_count + 1`
4. Decide and implement Phase 1 `SameSite` enforcement semantics
   - parsing alone is not enough for production-readiness

Acceptance gate:

- no currently-known correctness bug remains in H2 header order, cookie path matching, redirect counting, or SameSite send behavior

### Workstream 3: Wire the real client path

Goal: make `Client.fetch()` use the owned protocol path correctly after TLS negotiation.

Tasks:

1. Make HTTPS fetch ALPN-aware in `src/client.zig`
   - `.http2` -> route to `src/net/h2session.zig`
   - `.http1_1` -> route to HTTP/1.1 over `TlsConn`
2. Connect `src/net/h2session.zig` send/recv callbacks to `TlsConn`
3. Preserve cookies, redirects, headers, and response parsing across both negotiated protocols
4. Integrate `src/net/pool.zig` into the actual client flow
   - acquire/release by origin
   - reuse healthy connections
   - enforce max 6 per origin under real load
   - fix total-count accounting on add/evict/close/error

Acceptance gate:

- `awr fetch https://news.ycombinator.com` uses a genuine H2 path
- `awr fetch https://example.com` uses the owned HTTP/1.1 fallback path when negotiated
- pooling behavior is part of the runtime path, not just isolated unit logic

### Workstream 4: Add wire-level verification for TLS and H2

Goal: convert constants into evidence.

Tasks:

1. Add live JA4 verification against `tls.peet.ws/api/all`
   - assert exact `ja4`
2. Add live or captured TLS verification for:
   - cipher suite order
   - GREASE first / session-consistent / cross-session variable
   - `X25519MLKEM768` at named group position 1
   - correct 1216-byte key share
   - ALPS extension `0x4469` with expected payload
3. Add deterministic H2 frame verification for:
   - SETTINGS bytes
   - connection WINDOW_UPDATE increment `15663105`
   - pseudo-header order on live submitted requests

Acceptance gate:

- exit items 1 through 8 are verified by automated live/capture tests, not just by helper constants

### Workstream 5: Final production closure matrix

Goal: make Phase 1 completion a binary, defensible decision.

Tasks:

1. Run the full production matrix
2. Record timing for `zig build test` and relevant production suites on target hardware
3. Produce a pass/fail report for each exit item
4. Freeze Phase 2 work until all gates are green

Acceptance gate:

- all 14 Phase 1 items pass with production-backend evidence

## Exit Item Closure Matrix

### 1. Exact JA4 at `tls.peet.ws/api/all`

Need:

- automated live test under curl backend
- exact assertion: `t13d1517h2_8daaf6152771_b6f405a00624`

### 2. Exact cipher suite order on wire

Need:

- capture/parser verification of the emitted ClientHello
- confirm GREASE at position 0 and 16 Chrome ciphers in exact order after it

### 3. GREASE behavior across sessions

Need:

- session-level GREASE test proving same-session consistency and cross-session variance

### 4. X25519MLKEM768 and 1216-byte key share

Need:

- handshake capture or equivalent proof for named group order and key share length

### 5. ALPS extension and payload

Need:

- explicit extension presence and payload assertion

### 6. H2 SETTINGS exact bytes

Need:

- live submitted H2 SETTINGS verification, not just `src/net/http2.zig` helper tests

### 7. H2 WINDOW_UPDATE exact increment

Need:

- proof the live H2 session sends the required connection-level increment

### 8. H2 pseudo-header order

Need:

- fix live order in `src/net/h2_shim.c`
- add live frame verification

### 9. H2 fetch path for `news.ycombinator.com`

Need:

- actual client integration with `src/net/h2session.zig`
- e2e test proving 200 + non-empty body

### 10. Owned HTTP/1.1 fallback path for `example.com`

Need:

- explicit ALPN-aware fallback path in client
- e2e proof under curl backend, not stdlib fallback evidence alone

### 11. Max-6-per-origin under concurrent load

Need:

- real concurrent stress test against the integrated pool
- total-count accounting correctness

### 12. Cookie jar semantics

Need:

- RFC-correct path matching
- correct domain/secure/httpOnly behavior
- explicit `SameSite` send semantics good enough for production Phase 1 expectations

### 13. Redirect handling

Need:

- automated 3-hop success test
- automated >10 failure test
- coverage for both HTTP and HTTPS paths

### 14. Test timing budget on M-series Mac

Need:

- measured production-relevant test run
- under-10-second result for the spec-defined unit scope

## Recommended Execution Order

### Session 1

- establish production verification commands
- fix H2 header order
- fix cookie path matching
- fix redirect counter bug
- define SameSite enforcement scope for Phase 1

### Session 2

- wire ALPN-aware client routing
- connect `TlsConn` to `H2Session`
- integrate connection pooling into the client path
- add protocol-aware e2e tests

### Session 3

- add JA4 verification test
- add handshake capture checks for cipher/GREASE/MLKEM/ALPS
- add H2 frame verification for SETTINGS/WINDOW_UPDATE/pseudo-header order

### Session 4

- add pool stress test
- add redirect chain integration tests
- add stronger cookie integration tests
- tighten all production verification docs/commands

### Session 5

- run the full closure matrix on target hardware
- record timing and evidence
- only then mark Phase 1 complete

## Release Criteria Before Phase 2

Do not start Phase 2 until all of these are true:

- the owned HTTPS client path is protocol-correct
- live TLS/H2 wire behavior matches Chrome 132 where the spec requires it
- redirects, cookies, and pooling are verified under production conditions
- the production verification matrix is green and reproducible

## Final Recommendation

Treat Phase 1 closure as a release block.

The next implementation work should focus on:

1. correctness bug fixes
2. real H2 client integration
3. production verification harness
4. live wire-level proof

Only after those are complete should Phase 2 work resume.
