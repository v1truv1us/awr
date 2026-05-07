# Daemon Mode — Design Decision Document

**Status**: B1 of `.opencode/plans/1778109534122-shiny-nebula-remainder.md` Lane B.
This document satisfies B1 acceptance criteria. **No code lands until
this doc is accepted.**

**Date**: 2026-05-07.

## 1. Problem and goal

AWR's per-invocation cold floor is ~95 ms even when the actual page
fetch and processing complete in <50 ms (`example.com` cold-vs-cold:
208 ms total, of which ~95 ms is the AWR process before the first
network byte). For agents chaining many fetches in a session, that's
multiplicative dead time.

Daemon mode amortizes the startup cost across many fetches by keeping
one long-running AWR process per user, with thin CLI-side clients
that talk to it over local IPC. Same architectural shape as Docker's
`docker` ↔ `dockerd` split.

**Goal**: median agent fetch in a chained session drops from
~200-700 ms to ~100-300 ms by eliminating the per-invocation
allocator init + BoringSSL ctx parse + CA bundle load + threaded init
+ TLS handshake (after the first), and by sharing `BoringSslPool`
keep-alive across invocations.

## 2. Three orthogonal design questions

This doc resolves each. Each section names candidates, picks one, and
gives the rationale.

### 2.1 IPC surface

**Candidates considered**:

1. **Unix domain socket + JSON-RPC 2.0**
   - One socket file at `$XDG_RUNTIME_DIR/awrd.sock`
   - Standard line-delimited or content-length-framed JSON-RPC
   - Multiple concurrent clients supported natively
   - Debuggable with `socat - UNIX-CONNECT:/tmp/awrd.sock`
   - Cost: ~3-5 KB per request envelope, <1 ms IPC roundtrip on local

2. **Long-lived stdin/stdout protocol** (one daemon per stdio conn)
   - Client spawns daemon and writes requests to its stdin
   - Each client spawns its own daemon → no startup amortization across
     parallel CLI invocations from different terminals / agents
   - Effectively just "background process" not "daemon"
   - Reject: doesn't solve the multi-CLI-invocation case

3. **Local HTTP server (e.g. on `127.0.0.1:7777`)**
   - Standard, easy to debug with `curl`
   - Brings full HTTP framing overhead, header parsing, etc.
   - Conflicts with `awr mock` which already binds 7777 by default
   - Surface for security misconfiguration (binding to `0.0.0.0`)
   - Reject: too heavyweight, carries non-trivial security
     surface that JSON-RPC over Unix socket avoids

4. **Length-prefixed binary protocol**
   - Lowest overhead (~64 bytes per request frame + body)
   - Can't debug without custom tooling
   - Reject: optimizing the wrong axis. The actual hot path is the
     page-processing inside the daemon (10-100 ms), not the IPC
     framing (<1 ms)

**Recommendation: Unix domain socket + JSON-RPC 2.0**, framed using
`Content-Length` HTTP-style headers (matching what the LSP / MCP
specs use, which means we can borrow well-tested clients).

Path: `${XDG_RUNTIME_DIR:-/tmp}/awrd-${UID}.sock` so multi-user systems
don't collide and the socket is in a directory the kernel cleans up.

### 2.2 Session model

**Candidates considered**:

1. **Per-user singleton, multi-cwd via parameter**
   - One daemon per UID, serves all CLI invocations for that user
   - Cookie-jar isolation: each request supplies a `cookie_scope`
     parameter; the daemon looks up / persists per-scope jars at
     `$AWR_COOKIE_JAR_DIR/<scope>.txt`. Scope can be a project path
     digest, a domain, or a literal user choice.
   - Shared: `BoringSslPool`, `std_tls_failed_hosts`, `shared_tls_ctx`,
     CA bundle parse, `H2Session` connection state
   - Coarse-grained: one runaway page that allocates 2 GB takes down
     all clients. Mitigation: per-request memory cap, daemon
     auto-restart on RSS threshold

2. **Per-cwd daemon** (one daemon per project directory)
   - Cleaner isolation; one project's runaway page can't affect
     another
   - But: now we're spawning N daemons for N projects, defeating the
     amortization goal for users who jump between projects
   - Cookie / cache state is naturally per-project (matches today's
     `AWR_COOKIE_JAR=./cookies.txt` pattern)
   - Reject: amortization-defeating for the common multi-project user

3. **Per-process spawn** (current behavior, no daemon)
   - Trivially correct; no shared state risks
   - Reject: this is the status quo we're trying to escape

**Recommendation: Per-user singleton with explicit `cookie_scope`
parameter on each request.** The CLI client computes a default scope
from `$PWD` (e.g. `sha1($PWD)[:12]`) so users land in
project-isolated cookie jars by default, and an explicit
`AWR_COOKIE_SCOPE=mywork` env var overrides.

Cookie jars persist to `${XDG_DATA_HOME:-$HOME/.local/share}/awr/cookies/<scope>.txt`,
matching the pattern already used by `awr <url>` per
`spec/subspecs/agent-browser.md §2`.

### 2.3 Lifecycle

**Candidates considered**:

1. **Explicit `awrd start` / `awrd stop`** (Docker-style)
   - User must run `awrd start` once per session
   - Reject: defeats the "transparent speedup" goal; users who
     forget pay full per-invocation cost

2. **Spawn-on-first-use, idle-timeout shutdown**
   - First `awr <url>` invocation tries to connect to the socket;
     on `ENOENT` / `ECONNREFUSED`, spawns the daemon (double-fork +
     setsid) and retries connection
   - Daemon shuts itself down after configurable idle (default 5
     min). Client invocations within the window reuse it
   - Lockfile (`awrd.pid`) + `flock` advisory lock prevents the
     spawn race when two clients race the first connection

3. **Spawn-on-first-use, never shutdown**
   - Simpler than #2 but leaves a process running indefinitely; bad
     citizen on developer laptops, harder to update AWR cleanly

**Recommendation: spawn-on-first-use with 5-min idle timeout**.

- **PID file**: `${XDG_RUNTIME_DIR}/awrd-${UID}.pid` (parent of socket).
- **Spawn lock**: `flock` on the PID file during spawn so concurrent
  clients don't both fork-and-exec a daemon.
- **Health probe**: client opens the socket, sends `{"method":"ping"}`,
  expects `{"result":"pong"}` within 100 ms. Failure → assume stale,
  unlink socket, respawn.
- **Idle shutdown**: daemon tracks last-request timestamp; after 5 min
  of no activity, exits cleanly (closes pool, persists caches).
- **Restart on AWR upgrade**: client compares `build_opts.git_hash`
  with `daemon.version`; mismatch → send `{"method":"shutdown"}` and
  respawn. Avoids daemons getting stuck on stale binaries after a
  package update.
- **Crash recovery**: parent shell sees no daemon → next invocation
  spawns fresh. No supervisor needed.

## 3. Back-of-envelope perf estimate

A representative chained agent flow: 5 fetches to a mix of cold and
warm hosts.

```
Today (per-process spawn):
  fetch 1: 95 ms startup + 200 ms cold TCP+TLS+request = 295 ms
  fetch 2: 95 ms startup + 200 ms cold TCP+TLS+request = 295 ms  (different host)
  fetch 3: 95 ms startup + 200 ms cold TCP+TLS+request = 295 ms  (different host)
  fetch 4: 95 ms startup + 30 ms warm-cache               = 125 ms  (same host as #1, but pool died)
  fetch 5: 95 ms startup + 30 ms warm-cache               = 125 ms  (same host as #2, but pool died)
  TOTAL: 1135 ms
```

With daemon mode, the connection pool survives across CLI
invocations:

```
With daemon:
  fetch 1: 1 ms IPC + 200 ms cold TCP+TLS+request   = 201 ms  (host-A handshake)
  fetch 2: 1 ms IPC + 200 ms cold TCP+TLS+request   = 201 ms  (host-B handshake)
  fetch 3: 1 ms IPC + 200 ms cold TCP+TLS+request   = 201 ms  (host-C handshake)
  fetch 4: 1 ms IPC + 30 ms warm                     = 31 ms   (host-A, pool reused)
  fetch 5: 1 ms IPC + 30 ms warm                     = 31 ms   (host-B, pool reused)
  TOTAL: 665 ms
```

Estimated savings: **~470 ms across a 5-fetch chain (≈42%
faster)**. The win compounds with chain length: a 20-fetch chain
saves ~1.9 s.

For SPA-heavy single fetches (like github with 60+ scripts), daemon
mode adds no benefit since the optimization is already per-process —
those gains came from Lane A (H2 multiplexing).

**Where daemon mode does NOT help**:
- Single-fetch sessions (typical for one-off `awr <url>` calls)
- Cold network conditions where the network RTT dominates
- Pages where the JS work dominates (e.g. heavy SPA — daemon doesn't
  speed up V8/QuickJS)

The 470 ms estimate is **best case** (all 5 fetches in quick
succession, no daemon respawn between). Real agent flows have idle
gaps. With a 30-second median gap between fetches, the daemon stays
warm well within the 5-min idle window — savings track best-case.

## 4. Overlap with the deferred `mcp-stdio` track

`spec/subspecs/mcp-stdio.md` describes a deferred MCP stdio server
that exposes `awr <url>` / `awr tools` / `awr call` as MCP tools to a
parent process (Claude Desktop, Cursor, an agent harness). Three
possible relationships:

1. **MCP-stdio runs inside the daemon**
   - Daemon adds a `--stdio-mcp` mode that bypasses Unix-socket IPC
     and reads JSON-RPC from stdin / writes to stdout
   - One process, two IPC surfaces. More complex but reuses all
     state (pool, caches, JS engine)

2. **MCP-stdio is a thin client of the daemon**
   - `awr mcp-stdio` CLI translates incoming MCP requests into JSON-RPC
     calls to the daemon socket
   - Cleaner separation; daemon stays single-purpose
   - Adds one IPC hop but it's <1 ms each way

3. **Independent processes**
   - `awrd` daemon and `awr-mcp-stdio` server are separate; they
     don't share state
   - Simplest mentally; loses the shared-pool benefit

**Recommendation: option 2 (thin MCP-stdio client of the daemon)**.

Reasons:
- Keeps the daemon single-purpose (Unix-socket JSON-RPC server)
- MCP-stdio inherits all daemon perf benefits without daemon code
  having to know about MCP framing
- If MCP-stdio later needs MCP-specific features (e.g. progress
  notifications back to the parent), they live in the thin client,
  not the daemon
- Decision can be deferred: daemon can ship without MCP-stdio at all,
  and MCP-stdio (when it does ship) just becomes a `awr mcp-stdio`
  subcommand that opens the daemon socket

This decision means **mcp-stdio's deferred status doesn't block
daemon-mode work**. The daemon ships first; mcp-stdio is an
optional thin client added later.

## 5. Wire format (informative, not normative)

Sketched here so reviewers can imagine the surface. Final shape lives
in the future `spec/subspecs/daemon-mode.md` (B2 task) — not this doc.

### Initial method set (v1)

```
{ "jsonrpc": "2.0", "id": 1, "method": "ping" }
  → { "jsonrpc": "2.0", "id": 1, "result": "pong" }

{ "jsonrpc": "2.0", "id": 2, "method": "fetch",
  "params": {
    "url": "https://example.com/",
    "cookie_scope": "default",
    "max_redirects": 10
  }
}
  → { "jsonrpc": "2.0", "id": 2, "result": {
        "url": "...", "status": 200, "title": "...",
        "body_text": "...", "window_data": null, "tools": [],
        "telemetry": { ... full SessionMetrics ... }
      }
    }

{ "jsonrpc": "2.0", "id": 3, "method": "tools",
  "params": { "url": "https://example.com/", "cookie_scope": "default" } }

{ "jsonrpc": "2.0", "id": 4, "method": "call",
  "params": { "url": "...", "cookie_scope": "default",
              "tool": "search", "args": { "q": "..." } } }

{ "jsonrpc": "2.0", "id": 5, "method": "shutdown" }
```

Note: each request includes `cookie_scope`. This is the **session
isolation key** — the daemon's only multi-tenant dimension. Cookie
jars and `tls_fail_cache` are scoped per-cookie_scope; the
`BoringSslPool` and `shared_tls_ctx` are shared across scopes (no
correctness impact since TLS is per-host, not per-cookie-scope).

Telemetry on the daemon side: every `fetch` call's
`SessionMetrics` is included in the response under `result.telemetry`,
so the CLI client can write JSON Lines to the same `AWR_TELEMETRY`
destination the user already configured. Daemon ignores
`AWR_TELEMETRY` itself; the client owns emission.

## 6. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Stale daemon after AWR upgrade | High | Build-hash check on every connect; client respawns on mismatch |
| Cookie scope confusion (request to wrong jar) | Medium | Explicit `cookie_scope` param required, no implicit default — CLI client computes a scope, passes it through |
| Daemon spawn race when two CLIs collide | Medium | `flock` on pid-file; loser connects to winner's socket |
| Memory growth across long sessions | Medium | Auto-restart at RSS threshold (e.g., 1 GB); config knob in v2 |
| Pool-shared-by-many-clients fairness | Low | `BoringSslPool` is FIFO and capped at MAX_PER_ORIGIN=6; one client can't starve others on the same origin |
| macOS sandbox / network entitlements | Medium | Test early in B3 against codesigned binary; document any required entitlement |

## 7. What's NOT decided here

This doc deliberately stops at decisions, not implementation details.
Out of scope, deferred to B2 (sub-spec) and B3 (implementation):

- Exact JSON-RPC framing (Content-Length headers vs newline-delimited)
- Per-method timeout strategy
- Fault-injection / chaos testing approach
- Migration / coexistence with current per-process flow during rollout
  (probably opt-in via `AWR_DAEMON=1` env var initially)

## 8. Acceptance criteria check

Per `.opencode/plans/1778109534122-shiny-nebula-remainder.md` B1:

| Criterion | Status |
|---|---|
| 1. IPC choice w/ ≥3 candidates + recommendation | ✅ §2.1 |
| 2. Session model w/ ≥2 candidates + recommendation | ✅ §2.2 |
| 3. Lifecycle (spawn / shutdown / restart) recommendation | ✅ §2.3 |
| 4. Back-of-envelope estimate on 5-fetch chain | ✅ §3 |
| 5. Explicit decision on `mcp-stdio.md` overlap | ✅ §4 |
| 6. Reviewed and accepted before B2 starts | **Pending** — this doc, awaiting review |

## 9. Hand-off to B2

If accepted: B2 produces `spec/subspecs/daemon-mode.md` codifying the
canonical-spec / closure-record / closure-gates pattern that
`spec/MVP.md` requires for active sub-specs. ADR amendment in the
same change. Then B3 (implementation) follows once B2 lands.

If rejected: this doc names what to amend and why.
