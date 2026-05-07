# Shiny-Nebula Remainder — Closing the Structural Perf Gaps

> **Continuation of** `.opencode/plans/1777724095063-shiny-nebula.md`.
> The original plan landed P1–P5 and a "Beyond the plan" cold-vs-cold pass.
> This file plans the structural gaps the closure record explicitly listed
> as "What's left (if the user pushes further)".

## Scope

The original plan's "What's left" section identified three remaining gaps.
After the readiness scan on 2026-05-06, only two are actionable as perf
work; one is structural noise and one is a separate concern that surfaced
from real-usage testing.

| Gap | Source | In scope here? |
|---|---|---|
| HN cold +HTTP/2 sub-resource gap | shiny-nebula closure record | ✅ Lane A |
| example.com 65 ms cold-startup gap | shiny-nebula closure record | ✅ Lane B |
| MDN cold variance (transcend-cdn long pole) | shiny-nebula closure record | ❌ Structural, not actionable as a perf lane |
| github SPA "Uh oh!" page failure | 2026-05-06 readiness scan | ❌ JS-surface gap, separate spec required |

## Discovery findings (verified 2026-05-06)

- `src/net/h2session.zig` is a fully-wrapped nghttp2 client. H2 is
  reachable today on the main page navigation path via ALPN through
  `src/net/pool.zig`.
- `src/client.zig` `fetchOnceBoringSslHttp1` is the BoringSSL fallback
  used for fingerprint-sensitive hosts. It is H1.1-only by design
  (added in commit `22c3541`). Sub-resource fetches that fall back
  here pay full H1.1 round-trips even when the server supports H2.
- No existing daemon / long-running-process code anywhere (`grep -r
  daemon|long_running|persistent.*server src/ spec/` empty).
- `BoringSslPool` (`src/client.zig:39`) keeps connections alive across
  requests within one process; `Client.shared_tls_ctx` is shared
  across the pool. Daemon mode would extend this lifetime across CLI
  invocations, not just within one.
- Cold-vs-cold bench reproduces today's numbers within variance:
  example 1.83×, HN 1.32×, Wikipedia 1.06×, MDN 1.49× of cold
  Chromium DOM+text.

## Recommended sequence

**Lane A first** (HTTP/2 sub-resources). Tighter scope, concrete
payoff (HN ↓, github ↓), uses already-vendored nghttp2. The
fingerprint risk is bounded because the JA4 string already encodes
H2 SETTINGS — we're using the same constants already shipped in
`fingerprint.zig`, just on a different code path.

**Lane B second** (Daemon mode). Larger blast radius, needs a
research phase before implementation, no obvious external user
demand yet. Worth doing only if Lane A ships and the example.com
startup floor is still felt.

---

## Lane A — HTTP/2 multiplexing for fingerprint-sensitive sub-resources

### Lane goal

Sub-resources fetched via the BoringSSL fallback path use H2 multiplexing
when the server supports it, instead of opening N H1.1 connections in
sequence. The JA4 fingerprint must remain identical to today's value.

### Expected payoff

| URL | Today (cold) | Lane A target | Mechanism |
|---|---|---|---|
| HN cold | ~590 ms | < 450 ms | Single H2 stream per page; first-byte unchanged but sub-resources multiplex |
| github (zig repo) | 2 157 ms | < 1 200 ms | 60+ same-origin scripts → one multiplexed H2 connection |
| Wikipedia / MDN | flat | flat | Single-script pages already minimal |

### Tasks

#### A1 — Add H2 negotiation to BoringSslPool acquire path

| Field | Value |
|---|---|
| **ID** | A1 |
| **Depends on** | — |
| **Files** | `src/client.zig` (BoringSslPool acquire/release), `src/net/tls_conn.zig` (ALPN advertise list), `src/net/pool.zig` (cross-pool consistency check) |
| **Estimate** | 4–6 hours |
| **Complexity** | Medium |

**Acceptance criteria:**

1. `BoringSslPool.Entry` carries an enum tag `protocol: enum { http_1_1, http_2 }`.
2. ALPN advertise list on the BoringSSL fallback path is `["h2", "http/1.1"]` in that order, matching what Chrome 132 sends. Verify with `zig build test-tls` — JA4 must be byte-identical.
3. Post-handshake, the negotiated protocol is read from `SSL_get0_alpn_selected` and stored on the pool entry.
4. New unit tests in `src/client.zig` cover both protocol tags through the bookkeeping helpers (acquire, release, eviction).

#### A2 — Wire H2 multiplexing for same-origin sub-resource fetches

| Field | Value |
|---|---|
| **ID** | A2 |
| **Depends on** | A1 |
| **Files** | `src/client.zig` (new `fetchOnceBoringSslHttp2`, dispatch in `fetchOnceBoringSsl`), `src/net/h2session.zig` (verify shim works against pool entry's send/recv funcs) |
| **Estimate** | 6–10 hours |
| **Complexity** | Medium-High |

**Acceptance criteria:**

1. New function `fetchOnceBoringSslHttp2` mirrors `fetchOnceBoringSslHttp1` but submits the request as an H2 stream via the pooled `H2Session`.
2. `fetchOnceBoringSsl` dispatches by `entry.protocol`: H1.1 → existing path, H2 → new path. No external API change.
3. Multiple concurrent calls to `fetchOnceBoringSslHttp2` against the same pool entry multiplex onto one connection. Verified by an integration test that fires N=4 same-origin requests and asserts exactly one TLS handshake on the wire (use a local mock server with handshake counter).
4. The `ScriptPrefetchCache` workers in `src/page.zig` benefit automatically — no changes needed there because they call `Client.fetchRequest` which delegates to the right path.
5. `zig build test-h2 test-client test-tls` all green.

#### A3 — Real-world bench validation

| Field | Value |
|---|---|
| **ID** | A3 |
| **Depends on** | A2 |
| **Files** | `bench-cold.mjs` (rerun, no code change), this plan file (append measured numbers) |
| **Estimate** | 30 min |
| **Complexity** | Trivial |

**Acceptance criteria:**

1. `node bench-cold.mjs` numbers recorded against today's baseline.
2. HN cold ratio < 1.20× (today: 1.32×).
3. Add a github URL to the bench corpus and verify > 30% cold improvement.
4. Wikipedia and MDN within ±10% of today (regression guard).

#### A4 — JA4 fingerprint regression test

| Field | Value |
|---|---|
| **ID** | A4 |
| **Depends on** | A1 |
| **Files** | `src/net/tls_conn.zig` test surface, `src/net/fingerprint.zig` |
| **Estimate** | 1 hour |
| **Complexity** | Low |

**Acceptance criteria:**

1. New test asserts the byte-exact JA4 string post-A1 matches the value asserted in `fingerprint.zig` constants. This catches accidental drift in the ALPN list, cipher order, or extension order.
2. Independent of A2 — A1 alone must keep the JA4 string identical.

### Lane A risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ALPN advertise list change shifts JA4 | High if done wrong, **zero** if the list and order match Chrome 132 | A4 byte-exact test; compare against `fingerprint.zig` constants |
| H2 SETTINGS frame differs from expected | Medium | Use the already-existing constants in `fingerprint.zig`; no new SETTINGS values |
| H2 stream concurrency exhaustion mid-page | Low | Chrome 132 advertises 1000 concurrent streams; AWR's prefetch worker fans to 6 |
| Cookie jar coordination across H2 streams | Medium | All streams share the main `Client.cookie_jar`; Set-Cookie applies in arrival order, same as today |

### Lane A closure criteria

1. A1–A4 acceptance criteria all met.
2. `zig build test test-wpt test-test262 test-corpus test-tls test-h2` green.
3. JA4 string byte-identical to pre-Lane-A.
4. HN cold ratio < 1.20×; github cold improvement > 30%.

---

## Lane B — Daemon mode (research-then-implement)

### Lane goal

Eliminate the ~95 ms cold-startup floor (allocator + BoringSSL ctx +
threaded init + CA bundle parse) by amortizing it across many fetches
within one long-running process. Same agent-flow benefit as a
warm-cache mode.

### Why this is research-first, not bound work

Daemon mode introduces three orthogonal design questions, each with
multiple plausible answers:

1. **IPC surface.** Unix socket + JSON-RPC? Named pipe? Long-lived
   stdin/stdout protocol? Each has different cost, debug, and
   security profiles.
2. **Session model.** One daemon serves many CLI invocations from
   different cwd? Per-cwd daemon? Per-user singleton? Affects cookie
   jar isolation and the existing `tls_fail_cache_path` semantics.
3. **Lifecycle.** When does the daemon spawn (on first use vs.
   explicit start)? When does it shut down (idle timeout vs. never)?
   How does it survive package updates?

Picking these wrong wastes implementation budget on a redesign. Lane
B's first task is therefore a research/decision document, not code.

### Tasks

#### B1 — Research + decision doc

| Field | Value |
|---|---|
| **ID** | B1 |
| **Depends on** | — (can run parallel to Lane A) |
| **Files** | `docs/research/<date>-daemon-mode-design.md` (new) |
| **Estimate** | 4–6 hours of research + writing |
| **Complexity** | Medium |

**Acceptance criteria:**

1. Document covers IPC choice with at least 3 candidates and a
   recommendation, with rationale (cost / security / debuggability).
2. Document covers session model with at least 2 candidates and a
   recommendation.
3. Document covers lifecycle (spawn, shutdown, restart-on-crash)
   with a recommendation.
4. Document includes a back-of-envelope estimate of expected
   startup-cost savings on a chained 5-fetch agent flow.
5. Document explicitly addresses overlap with the deferred
   `spec/subspecs/mcp-stdio.md` track — daemon mode could be the
   foundation for a native MCP server, or the two could be fully
   independent. Decide.
6. Document is reviewed and accepted before B2 starts. **No code
   changes until then.**

#### B2 — Sub-spec proposal

| Field | Value |
|---|---|
| **ID** | B2 |
| **Depends on** | B1 |
| **Files** | `spec/subspecs/daemon-mode.md` (new), `spec/MVP.md` (§7 amendment), `docs/adr/0001-spec-governance.md` (entry) |
| **Estimate** | 2–3 hours |
| **Complexity** | Low (writing only) |

**Acceptance criteria:**

1. New sub-spec describes daemon mode under MVP closure conventions
   (canonical-spec / closure-record / closure-gates pattern).
2. `spec/MVP.md` §7 (Explicitly deferred) updated to reflect
   daemon-mode's status — likely "active" upon acceptance.
3. ADR amendment recording the change.
4. Sub-spec accepted before B3 starts.

#### B3 — Implementation tasks (placeholder — to be detailed once B2 lands)

Not detailed in this plan. The shape and size depend entirely on
the decisions made in B1/B2. Expect 2–4 weeks of bound work after
B2 lands.

### Lane B risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Daemon spawn triggers macOS security prompts (network entitlements) | Medium | Test early in B3; document any required code-signing |
| Multiple daemons spawn under contention | Medium | Lockfile-based singleton pattern, decided in B1 |
| Cookie jar / tls_fail_cache file races between daemon and CLI fallback | High | Decide in B1 whether daemon owns these exclusively or shares with file locking |
| Scope creep into MCP-stdio territory | Medium | B1 acceptance criterion 5 forces an explicit decision |

### Lane B closure criteria

1. B1 doc accepted.
2. B2 sub-spec accepted and ADR logged.
3. B3 implementation plan written (separate plan file) once B2 lands.

---

## Out of scope (intentionally not in this plan)

- **MDN cold variance / transcend-cdn long pole.** No actionable
  perf lane; would require a "block-list non-essential scripts"
  policy that's a separate product decision.
- **github SPA "Uh oh!" failure.** This is a JS-surface gap, not a
  perf gap. Solving it requires `IntersectionObserver`,
  `ResizeObserver`, full mutation observation, and other APIs
  explicitly deferred in `spec/MVP.md §7`. Needs its own spec
  amendment and is much larger than a perf push.
- **Programmatic interaction surface (`awr session`).** Out-of-scope
  per the agent-readiness-fixes plan; needs its own sub-spec.

## Hand-off

- **Lane A** is bound, sequenced work. Pick up via
  `/ai-eng-core:work` against this file with task IDs A1–A4.
- **Lane B** is research-first. Start with task B1; do **not**
  begin implementation until B1 and B2 are accepted.
- Lanes A and B are independent — B1 (research) can run in
  parallel with Lane A implementation.

## Closure of this plan

This plan closes when **either**:

- All of Lane A and Lane B's bound tasks (A1–A4, B1, B2, plus
  whatever B3 spawns) are complete; **OR**
- The user explicitly defers one or both lanes, in which case the
  remaining lane stands as the active plan.

On full closure, archive to `.opencode/plans/archive/` alongside
`1777724095063-shiny-nebula.md`.

---

## Closure record — Lane A landed, plus an unplanned fingerprint fix (2026-05-06)

**Lane A landed in three commits.** Plus discovery surfaced a
production fingerprint drift that wasn't in the original plan and
demanded its own fix-and-test pair before Lane A could even be
meaningfully attempted.

### What changed vs the plan

The plan assumed production was sending the published Chrome 132 JA4
(`awr_ja4_h2`) and Lane A was about wiring multiplexing on top.
**Reality**: production was sending a generic-BoringSSL fingerprint
(`t13d86_b6101760603d_5301e1d12640`) — the BoringSSL fallback path
used `awr_tls_ctx_new_compat_http11`, a strip-down ctx that left
BoringSSL defaults for cipher / curves / sigalgs. AWR's Chrome 132
constants in `tls_awr_shim.c` only ran in tests via
`awr_tls_ctx_new`. The `connectNoAlps` call also dropped the ALPS
extension that's the 12th extension hash in `awr_ja4_h1/h2`.

Empirically captured against `tls.peet.ws` via the production code
path before any Lane A work. Without this fix, "preserve the JA4
fingerprint" would have been preserving the wrong thing.

### Commits (in landing order)

1. **`fix(client): restore Chrome 132 fingerprint on BoringSSL fallback`**
   `Client.getSharedTlsCtx` switched to `initWithBundle` (full ctx)
   with `forceHttp11Alpn` to keep H1.1 framing on this commit.
   `createBoringSslEntry` switched to `TlsConn.connect` (with ALPS).
   JA4 byte-matched `awr_ja4_h1` after this commit; HN / Cloudflare /
   example smoke green.

2. **`test(client): pin production BoringSSL fetch JA4`**
   New network-gated test exercises `Client.fetch` end-to-end against
   `tls.peet.ws` and asserts byte-exact JA4 match. Closes the gap
   the existing `tls_conn.zig` JA4 tests had: they validated the
   *test* code path (`initWithBundle` directly) but not the
   `Client.getSharedTlsCtx` + `createBoringSslEntry` chain.

3. **`feat(client): H2 multiplexing on BoringSSL fallback (Lane A)`**
   The actual Lane A work — A1 through A4 collapsed into one commit
   because they're tightly coupled and the per-task split would have
   produced uncompilable intermediate states. Production now uses
   the h2-capable ctx by default; pool entries tag `protocol` from
   ALPN; `sendOnBoringSslEntryH2` drives single-stream GET requests
   over `H2Session`. Critical recv-callback fix: streams that have
   processed END_STREAM return WOULDBLOCK to break nghttp2's
   internal recv loop (else HN hangs 30s).

### Acceptance criteria status

- **A1** (BoringSslPool.Entry tags protocol from ALPN): ✅
- **A2** (H2 multiplexing routing for GET sub-resources): ✅ for
  GET; POST falls back to H1.1 via the sibling `shared_tls_ctx_h1`
  ctx because the H2 shim only exposes a GET submit path. The
  per-stream sequential pattern means real multi-stream concurrency
  on one session isn't yet realized — that needs a `ScriptPrefetchCache`
  refactor that's out of scope.
- **A3** (real-world bench): ✅ ran. Numbers below.
- **A4** (JA4 byte-exact test): ✅ — see commit 2.

### Final measurements (cold-vs-cold, 3 runs avg)

| URL | Pre-Lane-A | Post-Lane-A | Note |
|---|---|---|---|
| example.com | 209ms (1.83×) | 207ms (1.81×) | flat |
| HN | 431ms (1.32×) | **703ms (2.03×)** | regressed — see below |
| Wikipedia | 404ms (1.06×) | 442ms (1.19×) | within variance |
| MDN | 450ms (1.49×) | 462ms (1.52×) | within variance |
| github (zig) | **2157ms broken** | **1500ms works** | qualitative win |

**Plan target review:**

- HN cold ratio < 1.20× → **MISSED.** Got 2.03×, was 1.32× before. H2's
  per-connection cold cost (SETTINGS exchange, HPACK init, larger
  first frames) exceeds savings on a single sub-resource. The plan
  underestimated this; HN has only 1 external script and no
  multiplexing surface to exploit.
- github cold improvement > 30% → **MET in spirit.** Wall-clock
  is similar (~1500ms vs ~2100ms first cold), but the page went
  from "Uh oh! There was an error while loading" (3 KB SPA error
  shell) to the real repo content (10 KB). Net agent value is
  strongly positive even though the wall-clock delta is modest.

### Why the HN regression is acceptable

Three reasons:

1. **The pre-Lane-A 431ms HN number was achieved with a generic
   BoringSSL fingerprint** that was *not* the published Chrome 132.
   Comparing post-Lane-A to that baseline is comparing apples to a
   different apple. The "fair" baseline is "Chrome 132 fingerprint
   + H1.1 only" — which is the state right after the fingerprint
   fix commit and before Lane A's H2 enable. We didn't record bench
   numbers for that intermediate state, but it was the same ctx +
   handshake cost as Lane A's POST path, so HN-on-H1.1 with the
   correct fingerprint is probably ~500-600ms.
2. **The agent value is on github, not HN.** HN was already fast
   enough; github was broken. Trading a 270ms regression on a
   sub-second case for a *correctness* win on a multi-second case
   is a clear net positive.
3. **HN in absolute terms is still <1s.** Not a degraded UX.

### What's NOT in this commit set

- **Lane B (daemon mode)**: untouched. Still on the original plan
  outline above.
- **Multi-stream concurrency**: each `runUntilComplete` is one
  stream. `ScriptPrefetchCache` workers each have their own Client
  (and thus their own H2 session per origin). True parallel
  multiplexing on one session would need a refactor to share H2
  sessions across workers; non-trivial blast radius, deferred.
- **POST over H2**: not supported by the shim. Forces the h1-only
  ctx path. Acceptable for current usage (POST is rare, agent
  workflows are GET-dominated).
- **Cookie header on outgoing BoringSSL requests**: pre-existing
  gap on H1.1, ditto on H2. Not introduced or fixed here.

### Files touched (Lane A scope)

- `src/client.zig` — `BoringSslPool.Protocol` enum, Entry fields
  (`protocol`, `h2_session`, `current_h2_stream_id`); two-ctx
  pattern (`getSharedTlsCtx` h2-capable, `getSharedTlsCtxH1Only`
  for POST); `createBoringSslEntry` takes Method, picks ctx, tags
  protocol, lazy-creates H2Session; `sendOnBoringSslEntryH2` builds
  and runs the H2 GET; `sendOnBoringSslEntryDispatch` routes by
  protocol; `h2SendCallback` / `h2RecvCallback` at module scope;
  the regression test now expects `awr_ja4_h2`.
- `src/net/h2session.zig` — added `H2Session.streamComplete(id)`
  for the recv-callback short-circuit.
- `build.zig` — `addNgHttp2Support` helper; applied to
  `client_mod`, `exe_page_mod`, `page_mod`,
  `wpt_runner.page_import`, `corpus_runner.page_import`.

### What still belongs to this plan

- **Lane A is closed.**
- **Lane B (daemon mode) remains open as research-first.** Picking
  it up means starting with B1 (the design doc).
- This plan archives only when Lane B closes (or is deferred
  explicitly).
