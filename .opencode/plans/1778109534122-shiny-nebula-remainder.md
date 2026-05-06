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
