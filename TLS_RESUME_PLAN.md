# TLS Resume Plan

> **HISTORICAL DOCUMENT** — This plan was written when AWR's TLS strategy was
> based on `curl-impersonate`. That approach was **abandoned** in favor of
> direct BoringSSL integration (see `src/net/tls_conn.zig` + `src/net/tls_awr_shim.c`).
> The curl-impersonate code was removed in commits `61b29c3` and `f2b57cd`.
>
> This document is retained for reference only. The current TLS implementation
> uses vendored BoringSSL with Chrome 132 cipher/extension configuration. See
> `spec/FINGERPRINT.md` for the captured JA4 fingerprint and `PHASE1_EXIT_STATUS.md`
> for the current exit criteria status.

## Current State (as originally written)

- `src/net/tls.zig` is still a stub and returns `CurlImpersonateNotAvailable`.
- `src/client.zig` still routes HTTPS through `std.http.Client` instead of the owned TLS path.
- Prior AWR sessions established that on this machine:
  - Homebrew does not currently provide a working `curl-impersonate` formula/tap.
  - GitHub release `v0.6.1` only provides macOS `x86_64` binaries, not Apple Silicon.
  - The machine is `arm64`.
  - `cmake`, `ninja`, `python3`, and `go` are available.
  - `nss` was missing when the last session stopped.

## Recommended Direction

Use a native Apple Silicon source build of `curl-impersonate`, then wire AWR to it behind a selectable TLS backend.

Why this path:

- It keeps Phase 1 aligned with the spec goal: real TLS impersonation, not the temporary `std.http` path.
- It avoids depending on missing Homebrew packaging or Intel-only macOS tarballs.
- It gives a clean escape hatch if the native build remains brittle.

## Execution Plan

### 1. Stabilize dependency strategy

- Build `curl-impersonate` from source for `arm64`.
- Install or otherwise provide the missing `nss` dependency first.
- Prefer a deterministic install location:
  - repo-local vendor prefix, or
  - a stable system prefix with explicit build configuration.
- Expose paths via `build.zig` options or environment variables instead of hardcoding assumptions.

Recommended config knobs:

- `-Dtls-backend=stub|std|curl_impersonate`
- `-Dcurl-impersonate-prefix=/path/to/prefix`
- optionally `-Dnss-prefix=/path/to/prefix`

### 2. Make the build system backend-aware

Update `build.zig` so TLS wiring is conditional instead of all-or-nothing.

- Add a TLS backend option.
- Keep pure unit tests runnable without curl-impersonate installed.
- Only add C source files, include paths, and library links when `curl_impersonate` is selected.
- Link the required C libraries through the selected prefix rather than assuming `/opt/homebrew` only.

Expected outcome:

- `zig build test` still works in `stub` mode.
- curl-impersonate integration becomes an explicit, testable path instead of a hidden machine dependency.

### 3. Implement the curl shim boundary

Add a minimal C shim layer dedicated to the AWR TLS abstraction.

Suggested files:

- `src/net/tls_curl_shim.h`
- `src/net/tls_curl_shim.c`

Responsibilities of the shim:

- initialize and own the curl handle/context
- call `curl_easy_impersonate(...)`
- configure URL, connect-only mode, ALPN-related behavior, and verification settings
- expose connect/handshake, send, recv, and cleanup primitives
- return simple status codes that `src/net/tls.zig` can map into `TlsError`

Keep the shim thin. The Zig layer should remain the source of truth for state transitions.

### 4. Replace the Zig TLS stub with a real wrapper

Update `src/net/tls.zig` to wrap the shim through `@cImport`.

Implementation targets:

- `init()` creates a real handle when curl-impersonate backend is enabled
- `handshake()` moves state from `closed`/`handshaking` to `established`
- `send()` and `recv()` forward to the shim and map errors predictably
- `deinit()` always cleans up safely
- `negotiatedProtocol()` reflects actual ALPN result if available

Important constraint:

- preserve existing unit-test behavior in `stub` mode so non-integration tests remain stable.

### 5. Route the client through `net/tls.zig`

Update `src/client.zig` so HTTPS does not bypass AWR's TLS layer.

- Remove the current hardwired `std.http.Client` HTTPS path for the curl-impersonate backend.
- Route HTTPS fetches through `TlsConn` and the same request/response pipeline used by the plain TCP path as much as possible.
- Keep `std` backend as an optional fallback only if needed during bring-up.

Goal:

- one client path for AWR networking behavior
- backend selection changes transport details, not client semantics

### 6. Tighten verification in layers

Run validation in this order:

1. Build-only validation
   - confirm artifacts are `arm64`
   - confirm headers/libs are resolved from the intended prefix
2. Unit tests
   - `zig build test-net`
   - `zig build test-client`
3. HTTPS connectivity
   - `https://example.com/`
4. Fingerprint verification
   - `tls.peet.ws` or equivalent endpoint
5. Protocol verification
   - confirm negotiated protocol and expected behavior for HTTP/2 targets

### 7. Add explicit Phase 1 gates

Once the backend works, add or enable tests that map to the missing Phase 1 checklist items.

Priority items:

- HTTPS fetch through the owned TLS path
- JA4/fingerprint verification on a known endpoint
- ALPS/ALPN-related validation where observable
- HTTP/2 path verification for a real HTTPS target

## Risks And Fallbacks

### Risk: native Apple Silicon build is brittle

Fallback:

- keep `tls-backend=std` available as a non-spec fallback during bring-up
- do not treat it as Phase 1 completion

### Risk: curl-impersonate API does not map neatly to the current `send/recv` abstraction

Fallback:

- narrow the first implementation to a working HTTPS request path
- then refactor streaming semantics once real traffic is stable

### Risk: fingerprint mismatch even after successful TLS integration

Fallback:

- pin a known-good upstream release/profile
- make fingerprint checks integration-only and explicit
- compare actual settings against the spec before further client work

## First Implementation Session Checklist

- confirm current working tree and avoid overwriting existing user changes
- install/provide `nss`
- build curl-impersonate from source for `arm64`
- add backend flags to `build.zig`
- add `tls_curl_shim.h` and `tls_curl_shim.c`
- wire `src/net/tls.zig` to the shim
- route HTTPS in `src/client.zig` through `TlsConn`
- run unit tests
- run HTTPS e2e
- add fingerprint verification step

## Concrete File-By-File Order

Follow this order during implementation so the repo stays buildable as long as possible.

### Step 1: `build.zig`

Make the build backend-aware before touching runtime behavior.

- add a `tls-backend` option with values:
  - `stub`
  - `std`
  - `curl_impersonate`
- add optional prefix inputs for:
  - curl-impersonate
  - nss
- keep current pure-Zig tests working in `stub` mode
- conditionally wire C sources and link flags only for `curl_impersonate`
- keep `src/net/tls.zig` testable even when curl-impersonate is unavailable

Definition of success for this step:

- build configuration can express all three modes without forcing immediate code changes elsewhere

### Step 2: `src/net/tls_curl_shim.h`

Create the narrowest possible C boundary.

Suggested surface:

- opaque context allocation/free
- handshake/connect entry point
- send/recv entry points
- negotiated protocol query if needed
- simple integer return codes for predictable Zig mapping

Do not put policy in this header. Keep it mechanical.

### Step 3: `src/net/tls_curl_shim.c`

Implement the curl-impersonate bridge.

Responsibilities:

- own a context struct containing the curl handle and any small buffers/state
- initialize curl safely
- call `curl_easy_impersonate(...)` with the pinned profile
- configure connect-only mode and TLS verification
- expose send/recv wrappers suitable for Zig
- expose cleanup that is always safe to call

Important implementation note:

- the first goal is a stable HTTPS request path, not perfect abstraction purity

### Step 4: `src/net/tls.zig`

Replace the stub with a backend-aware wrapper.

- preserve current unit-testable state transitions
- map shim return values into `TlsError`
- keep `CurlImpersonateNotAvailable` available for disabled/misconfigured cases
- make `init`, `handshake`, `send`, `recv`, and `deinit` all work in backend-selected mode
- update or add integration tests only after the basic wrapper compiles

Key constraint:

- `stub` mode must still preserve the current no-dependency behavior

### Step 5: `src/client.zig`

Remove the current split-brain HTTPS behavior.

- replace `fetchHttpsViaStd()` as the default HTTPS path when `curl_impersonate` is selected
- keep request building, cookie handling, redirects, and response parsing aligned with the plain HTTP code path as much as possible
- if `std` backend remains available, keep it clearly gated behind backend selection instead of hardwired behavior

Concrete focus areas in the current file:

- `fetchUrl()` currently special-cases HTTPS too early
- `fetchHttpsViaStd()` is currently Phase-1-blocking technical debt
- any refactor should minimize duplication between HTTP and HTTPS request/response flow

### Step 6: `src/test_e2e.zig`

Reclassify tests by backend and intent.

- keep plain HTTP tests independent of curl-impersonate
- keep generic HTTPS connectivity tests separate from fingerprint tests
- add backend-specific gating or naming so failures are easy to interpret

Recommended test split:

- plain HTTP behavior tests
- generic HTTPS success tests
- curl-impersonate fingerprint verification tests

### Step 7: `src/client.zig` unit tests and `src/net/tls.zig` tests

After the transport path works, tighten tests in the two most affected modules.

- in `src/net/tls.zig`:
  - preserve existing stub-mode tests
  - add opt-in integration coverage for real handshake/send path
- in `src/client.zig`:
  - add backend-sensitive HTTPS expectations
  - ensure redirect and cookie behavior still works after transport changes

## Session-by-Session Resume Checklist

Use this if implementation gets split across multiple sessions.

### Session A: dependency and build plumbing

- provide/install `nss`
- build curl-impersonate for `arm64`
- update `build.zig`
- verify the build can discover include/lib paths

Stop point:

- repository builds in `stub` mode and at least starts compiling the curl backend path

### Session B: TLS transport wiring

- add `tls_curl_shim.h`
- add `tls_curl_shim.c`
- update `src/net/tls.zig`
- get TLS unit/integration compilation passing

Stop point:

- a direct TLS handshake succeeds against a simple HTTPS target

### Session C: client integration

- route `src/client.zig` through `TlsConn`
- remove the hard dependency on `fetchHttpsViaStd()` for the main path
- keep redirects/cookies/headers working

Stop point:

- `client.fetch("https://example.com/")` succeeds through the owned TLS layer

### Session D: verification and Phase 1 gates

- update `src/test_e2e.zig`
- add fingerprint verification
- validate protocol/fingerprint expectations against the spec

Stop point:

- repo has explicit evidence for the remaining Phase 1 TLS items

## Immediate Next Actions

When implementation mode begins, start here:

1. Inspect the current `build.zig` and add backend options first.
2. Resolve the native dependency path for `nss` and curl-impersonate on `arm64`.
3. Add the shim files before modifying client behavior.
4. Update `src/net/tls.zig` next.
5. Only then refactor `src/client.zig` away from `std.http.Client`.
6. Finish by splitting and tightening `src/test_e2e.zig` coverage.

## Definition Of Done For This Resume Track

- AWR no longer depends on `std.http.Client` for its main HTTPS path.
- curl-impersonate is selectable and usable on this Apple Silicon machine.
- unit tests still pass without forcing curl-impersonate on every environment.
- HTTPS requests succeed through the AWR TLS abstraction.
- the repo is in position to complete the remaining Phase 1 verification items.
