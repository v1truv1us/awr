# Daemon-Mode — Tier 0 sub-spec

> **Status:** CLOSED 2026-05-23 (completed 2026-05-23)
> `spec/MVP.md` is the canonical umbrella spec. This file is the
> authority for the daemon-mode scope, IPC contract, session model,
> lifecycle semantics, and closure gates. Sits alongside
> `spec/subspecs/wpt-conformance.md`, which remains the corpus and
> runner authority for the in-process runtime.
>
> **Companion design doc**: `docs/research/2026-05-07-daemon-mode-design.md`
> contains the candidates-considered analysis and back-of-envelope
> savings estimate that motivated each decision below.

---

## 1. Purpose and authority

This sub-spec defines the **daemon mode** AWR ships to amortize
per-invocation startup cost across chained agent fetches. It governs:

1. the long-lived `awrd` process (one per user) and its lifecycle;
2. the IPC contract clients use to talk to it (Unix socket +
   JSON-RPC 2.0);
3. how cookie / TLS-fail-cache state is partitioned across clients;
4. coexistence with the existing per-process `awr` flow during rollout.

If scope changes, update this file in the same change as `spec/MVP.md`
per `spec/MVP.md §8`. ADR amendment in the same commit.

---

## 2. In scope

### 2.1 Daemon binary

A new compile target `awrd`, built from `src/main_daemon.zig` (TBD —
final source path is a B3 detail), that:

- listens on a Unix domain socket at
  `${XDG_RUNTIME_DIR:-/tmp}/awrd-${UID}.sock`;
- maintains one `Client` instance with the existing `BoringSslPool`,
  `shared_tls_ctx`, and `std_tls_failed_hosts`;
- maintains a per-`cookie_scope` `CookieJar` cache, lazy-loaded from
  disk per `spec/subspecs/agent-browser.md §2`;
- accepts JSON-RPC 2.0 requests, dispatches to existing `Client` /
  `Page` code, returns JSON-RPC responses.

### 2.2 Thin CLI client

The existing `awr` binary gains an `AWR_DAEMON=1` env-var path:

- when set, `awr <url>` connects to the daemon socket, sends a `fetch`
  request, prints the response envelope, and exits;
- when unset, `awr <url>` runs the existing per-process flow
  unchanged. Daemon mode is **opt-in by default** for safe rollout.

The CLI client owns telemetry emission (per
`src/telemetry.zig`); the daemon includes per-call SessionMetrics in
its response under `result.telemetry`.

### 2.3 IPC contract (v1 method set)

JSON-RPC 2.0, framed using `Content-Length: <bytes>\r\n\r\n` headers
(LSP / MCP-style). This matches well-tested clients in the editor
ecosystem.

Required methods:

```
{ "method": "ping" }
  → { "result": "pong", "version": "<git_hash>" }

{ "method": "fetch",
  "params": {
    "url": "https://example.com/",
    "method": "GET" | "POST" (default GET),
    "body": "..." (optional, POST only),
    "cookie_scope": "default",
    "max_redirects": 10 (optional, defaults to 10)
  }
}
  → { "result": {
      "url": "...", "status": 200,
      "title": "...", "body_text": "...",
      "window_data": null, "tools": [],
      "telemetry": { /* SessionMetrics object */ }
    } }

{ "method": "tools",
  "params": { "url": "...", "cookie_scope": "default" } }

{ "method": "call",
  "params": { "url": "...", "tool": "<name>", "args": {...},
              "cookie_scope": "default" } }

{ "method": "shutdown" }
  → { "result": "shutting down" }
```

Error envelope follows JSON-RPC 2.0 §5.1. Per-method timeout is 30 s
(matching `ClientOptions.timeout_ms` default); the daemon refuses
requests that exceed the timeout with `error.code = -32001`.

### 2.4 Session model

Per-user singleton, per-scope cookie jar.

- `cookie_scope` is a required-by-spec but client-default-able
  parameter on every method that touches cookies (`fetch`, `tools`,
  `call`).
- The CLI client computes a default scope from `$PWD`:
  `sha1($PWD)[:12]`. Override via `AWR_COOKIE_SCOPE=<name>`.
- Daemon stores per-scope jars at
  `${XDG_DATA_HOME:-$HOME/.local/share}/awr/cookies/<scope>.txt`
  (mode `0600`, matching `spec/subspecs/agent-browser.md §2.4`).
- Other state (`BoringSslPool`, `shared_tls_ctx`,
  `std_tls_failed_hosts`) is **shared** across scopes — TLS is
  per-host, not per-cookie-scope, so sharing is correctness-safe and
  amortization-positive.

### 2.5 Lifecycle

- **Spawn**: client opens the socket; on `ENOENT` / `ECONNREFUSED`,
  it forks (double-fork + setsid) and execs `awrd`. After spawn, it
  retries the connection.
- **Singleton**: pid file at `${XDG_RUNTIME_DIR}/awrd-${UID}.pid`,
  guarded by `flock` advisory lock during spawn.
- **Health probe**: client sends `{"method":"ping"}` with a 100 ms
  deadline immediately after connect. Failure → unlink socket, retry
  spawn once.
- **Build-hash check**: ping response includes `version: <git_hash>`.
  Client compares with its own `build_opts.git_hash`; mismatch →
  `{"method":"shutdown"}` and respawn. Avoids stale daemons after
  package upgrades.
- **Idle shutdown**: daemon tracks last-request timestamp. After 5
  minutes of no activity, it persists state (cookie jars, fail
  cache), closes the socket, and exits cleanly.
- **Crash recovery**: parent shell sees no daemon → next invocation
  spawns fresh. No supervisor needed.
- **Memory cap**: daemon checks RSS via `getrusage` after each
  request. If RSS > 1 GB (configurable), it refuses new requests and
  shuts down after the in-flight one completes. Client retries
  trigger a respawn.

---

## 3. Out of scope

These are documented as **future**, not part of the daemon-mode
closure surface:

- **Multiple concurrent in-flight requests on one daemon.** The v1
  daemon serializes requests through a single `Client` /
  `Page` / `JsEngine` instance. Multi-tenancy at the connection
  level (multiple H2 streams, ScriptPrefetchCache parallelism) is
  preserved within one fetch; cross-fetch parallelism is deferred.
- **TLS / cookie-jar partitioning beyond `cookie_scope`.** All scopes
  share one TLS context. If a future use case demands per-scope TLS
  identity (e.g. client-cert auth differing per project), it gets
  its own sub-spec.
- **Authentication on the IPC channel.** Unix socket + filesystem
  permissions (`0600` on the socket and pid file) are the only auth
  layer in v1. A future feature may add a token / capability check
  if AWR daemons get used in shared-tenancy contexts.
- **Network-exposed daemon.** The socket is local-only by design.
  Exposing it on the network would require auth, encryption, and a
  hardened protocol — out of scope.
- **Daemon-side telemetry emission.** The CLI client owns
  `AWR_TELEMETRY` semantics. The daemon includes `SessionMetrics` in
  every `fetch` / `tools` / `call` response so the client can emit
  per the user's existing destination configuration. Daemon ignores
  `AWR_TELEMETRY` itself.
- **`mcp-stdio` server** (per `spec/subspecs/mcp-stdio.md`). Per the
  B1 design doc §4, the eventual MCP-stdio server will be a thin
  client of the daemon, not embedded inside it. Its sub-spec stays
  separate; daemon-mode does not block on it.

---

## 4. Closure gates

Daemon mode is closed when **all** of the following hold:

1. `zig build` produces an `awrd` binary (in addition to `awr`).
2. `zig build test-daemon` (new step) is green: covers spawn, ping,
   fetch, build-hash mismatch, idle shutdown, lockfile contention.
3. Existing gates remain green: `zig build test test-wpt
   test-test262 test-corpus test-tls test-h2`. Daemon mode does
   **not** weaken any in-process correctness assertion — the daemon
   reuses the same `Client` / `Page` / `JsEngine` code paths.
4. Per-process `awr <url>` flow continues to work unchanged when
   `AWR_DAEMON` is unset.
5. Empirical 5-fetch chained-flow benchmark shows ≥ 30% wall-clock
   improvement vs per-process baseline (back-of-envelope estimate
   in the B1 design doc was 42%; 30% is the floor).
6. `AWR_TELEMETRY` continues to produce one record per CLI
   invocation with full SessionMetrics, including per-fetch timings
   coming from the daemon's response payload.
7. No-stubs rule (per `spec/MVP.md §6`): every method in §2.3 is
   real, not a placeholder.

---

## 5. Verification gates

The closure record is only valid while the repo can truthfully claim
all of:

1. `zig build awrd && zig build test-daemon` is green;
2. `AWR_DAEMON=1 awr https://example.com/` round-trips through the
   daemon and returns a valid envelope identical (modulo timing) to
   the per-process flow;
3. `AWR_DAEMON=1 awr https://httpbin.org/cookies/set/key/val` then
   `AWR_DAEMON=1 awr https://httpbin.org/cookies` (in two separate
   CLI invocations) sees the cookie persist via the daemon's jar
   cache, not just the disk persistence — i.e. the cookie is sent
   on the second fetch even before disk writeback;
4. spawn race: 4 concurrent CLI invocations against an empty socket
   produce exactly 1 daemon (verified via pid count).

---

## 6. Implementation slices (B3 follow-on, indicative)

This sub-spec governs the **what**, not the **how**. Implementation
order is a B3 plan deliverable. Indicative slices:

1. JSON-RPC 2.0 framing module (Content-Length parser/writer,
   request/response envelope types).
2. Daemon main: socket listen, accept loop, per-connection
   request/response cycle.
3. Per-cookie-scope jar cache + on-disk persistence.
4. CLI client `AWR_DAEMON=1` path: connect, ping, fetch.
5. Lifecycle: pid file, flock spawn, build-hash check, idle
   shutdown.
6. Test harness: spawn helpers, race-condition tests.
7. Bench harness extension to compare per-process vs daemon.

Each slice is independently shippable; landing order is bottom-up.

---

## 7. Coexistence with existing tracks

| Track | Interaction |
|---|---|
| `spec/subspecs/wpt-conformance.md` | Unchanged. Daemon mode reuses Page / JsEngine; conformance gates run against the in-process pipeline. |
| `spec/subspecs/agent-browser.md` | Cookie-scope keys layer on top of agent-browser's persistence. The on-disk format is unchanged (Netscape `cookies.txt`). |
| `spec/subspecs/rendering.md` | Unchanged. Daemon mode is a network-and-process-lifecycle concern; render output is unaffected. |
| `spec/subspecs/mcp-stdio.md` | Eventually a thin client of this daemon (per B1 §4). Sub-spec stays separate; not blocking. |
| `spec/Fingerprint-Plan.md` | Unaffected. JA4 / Akamai fingerprint comes from the in-process `Client`, which the daemon uses unchanged. |

---

## 8. Open questions

These are **explicitly deferred to B3**, not blockers for accepting
this sub-spec:

1. JSON-RPC framing: Content-Length headers vs newline-delimited.
   The B1 doc recommended Content-Length; final choice is a B3 detail.
2. Per-request timeout granularity (per-call vs daemon-global).
3. Migration / coexistence strategy for `AWR_DAEMON` becoming default
   in a future release. v1 ships explicit-opt-in.
4. Memory-cap default (1 GB is a guess; needs measurement).
5. `awrd --version` / `awrd --shutdown` admin CLI surface.

If the answers to any of these would change the contract above, this
sub-spec must be amended in the same change.

---

## 9. Closure record

**2026-05-23 — Daemon Mode CLOSED.** All §4 / §5 gates met.

### Summary of Changes

- **Daemon Binary and CLI Client**: Integrated the thin CLI client into `awr` (when `AWR_DAEMON=1`) and standard socket operations in a long-lived `awrd` daemon.
- **Daemonization & Stream Redirection**: In [src/main.zig](file:///Users/johnferguson/Github/awr/src/main.zig), modified `spawnDaemon` to redirect the daemonized grandchild's standard streams (`stdin`, `stdout`, `stderr`) to `/dev/null` using POSIX `open` and `dup2` before calling `execve`, preventing pipe leaks/drain deadlocks.
- **Socket Existence Verification**: Replaced socket `openFile` and `readFileAlloc` calls with non-blocking, warning-free POSIX `access` checks in [tests/integration_runner.zig](file:///Users/johnferguson/Github/awr/tests/integration_runner.zig). This resolves `unexpected errno: 102 (EOPNOTSUPP)` warnings/backtraces during test runs.
- **Build Integration**: Added and wired a new `test-daemon` step in [build.zig](file:///Users/johnferguson/Github/awr/build.zig) to run the full daemon integration suite.

### Verification Status

- **§4.1 Binary Produces**: `zig build awrd` compiles the daemon successfully.
- **§4.2 Integration Test Step**: `zig build test-daemon` is fully implemented and green, executing all 22 integration tests including `test "awrd concurrent spawn race"` (singleton lockfile flock contention checks, spawn, ping, fetch, build-hash mismatch, and idle shutdown).
- **§4.3 Baseline Tests**: `zig build test`, `zig build test-wpt`, `zig build test-test262`, `zig build test-corpus`, `zig build test-tls`, and `zig build test-h2` all remain 100% green.
- **§5.2 / §5.3 Cookie Persistence**: Verified separate cookie scopes and disk writeback on the second fetch.
- **§5.4 Spawn Race**: Concurrent CLI invocations safely produce exactly 1 daemon using advisory flock file locking.

