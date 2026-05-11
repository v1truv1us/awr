# ADR 0001: Spec and documentation governance

- Status: Accepted
- Date: 2026-04-22

## Context

AWR had multiple planning and spec documents with overlapping authority. That made
it too easy for active scope, deferred work, and historical context to drift or
be misread.

The repo now has a clearer split:

- `spec/MVP.md` is the canonical umbrella spec.
- `spec/subspecs/mvp-remainder.md` is the active MVP completion track.
- `spec/subspecs/wpt-conformance.md` is the active conformance authority for
  curated WPT/Test262 work.
- `spec/subspecs/mcp-stdio.md`, `spec/subspecs/browser-tui.md`, and
  `spec/Fingerprint-Plan.md` are deferred tracks.
- `MVP_PLAN.md`, `MVP_BACKLOG.md`, and `spec/PRD.md` are historical/background
  references and are not execution authority.

That governance decision needs a durable historical record and a single place to
append future governance changes.

## Decision

We standardize spec/documentation authority as follows:

1. `spec/MVP.md` is the top-level canonical spec and change-control point.
2. `spec/subspecs/mvp-remainder.md` defines the active MVP completion work.
3. `spec/subspecs/wpt-conformance.md` defines the conformance runner/corpus
   authority for that work.
4. Deferred tracks must stay documented in their own files, but they do not
   control current execution priority unless `spec/MVP.md` is updated.
5. Historical/background documents may preserve rationale or prior plans, but
   they are non-canonical.
6. This ADR is the historical record for spec-boundary and documentation-
   authority decisions.
7. Any future change to canonical spec boundaries, document authority, or
   governance rules must update both the affected document and this ADR.

## Consequences

### Positive

- The repo has one clear authority chain for active work.
- Deferred work stays visible without competing with active execution.
- Historical docs remain useful without being mistaken for current direction.
- Future governance changes have an explicit audit trail.

### Tradeoffs

- Governance changes now require touching multiple docs.
- This ADR is intentionally living documentation, so it must be maintained when
  governance changes are made.

## Current status

Accepted and in force.

At the time of acceptance:

- Canonical umbrella spec: `spec/MVP.md`
- Active MVP completion track: `spec/subspecs/mvp-remainder.md`
- Active conformance authority: `spec/subspecs/wpt-conformance.md`
- Active agent-browser scope: `spec/subspecs/agent-browser.md`
- Deferred tracks: `spec/subspecs/mcp-stdio.md`,
  `spec/subspecs/browser-tui.md`, `spec/Fingerprint-Plan.md`
- Non-canonical historical/background docs: `MVP_PLAN.md`, `MVP_BACKLOG.md`,
  `spec/PRD.md`

## Amendment log for future governance decisions

Use this section for later updates to spec boundaries, document authority, or
documentation governance.

### 2026-04-22 — Initial governance consolidation

- Recorded `spec/MVP.md` as the canonical umbrella spec.
- Recorded `spec/subspecs/mvp-remainder.md` as the active execution spec.
- Recorded MCP stdio, browser/TUI, and fingerprint planning docs as deferred.
- Recorded `MVP_PLAN.md`, `MVP_BACKLOG.md`, and `spec/PRD.md` as historical or
  background only.

### 2026-04-23 — MVP closure and conformance authority update

- Reframed `spec/MVP.md` so MVP closure is gated by curated WPT/Test262,
  a green default test baseline, and the no-stubs rule.
- Reframed `spec/subspecs/mvp-remainder.md` from closure record to active MVP
  completion track.
- Added `spec/subspecs/wpt-conformance.md` as the canonical conformance
  authority for curated WPT/Test262 work.
- Recorded that README and agent-facing guidance files must be updated when the
  canonical execution boundary changes.

### 2026-04-23 — Closed MVP surface narrowing

- Recorded the closed shipped MVP surface as a narrower browser-runtime subset
  rather than a generic browser API.
- Removed `IntersectionObserver` and `ResizeObserver` from the shipped MVP
  surface until real render-backed semantics exist.
- Narrowed `history` to same-origin `pushState` / `replaceState` plus `length`
  and `state`.
- Narrowed `fetch()` and `XMLHttpRequest` to explicit async GET-only semantics.
- Updated README and canonical specs together so the closure claim matches the
  runtime and curated WPT corpus.

### 2026-04-27 — Agent-browser scope promoted to active

- Added `spec/subspecs/agent-browser.md` as a new active sub-spec governing
  POST in `fetch` and `XMLHttpRequest`, `<form method="post">` end-to-end
  submission through `awr browse`, and cookie jar disk persistence.
- Widened `spec/MVP.md §5.4` from "async GET-only" to "async GET and POST"
  with explicit body-shape constraints (string or `URLSearchParams` only).
- Removed "non-GET request semantics" from the explicit-deferred list in
  `spec/subspecs/mvp-remainder.md` and added a "Follow-on closed tracks"
  section pointing at the new sub-spec.
- Widened `spec/subspecs/wpt-conformance.md §3` target areas to include POST,
  form submission, and cookie persistence; updated §8 mapping table with the
  curated case files listed in `agent-browser.md §4`.
- Reason: AWR's CLI-first browser path is in scope for use as an autonomous
  agent's web client, and the GET-only narrowing made real-world login/auth
  flows infeasible. The widening is gated by curated WPT cases and preserves
  the JA4 fingerprint and HTTP/2 SETTINGS frame.
- Documents updated: `spec/MVP.md`, `spec/subspecs/agent-browser.md` (new),
  `spec/subspecs/mvp-remainder.md`, `spec/subspecs/wpt-conformance.md`,
  `AGENTS.md`, `CLAUDE.md`, `README.md`, this ADR.

### 2026-04-28 — Agent-browser closure gates closed

- Closed `spec/subspecs/agent-browser.md §5` gates by registering all five
  required curated WPT cases (`fetch_post_basic.js`,
  `fetch_post_form_encoded.js`, `xhr_post_basic.js`,
  `xhr_post_form_encoded.js`, `form_method_post.js`) in
  `tests/wpt_runner.zig`'s `curated_cases` array. POST round-trips run
  against an in-process echo server (`EchoServer` in the same file) on
  `127.0.0.1:18488`.
- Landed a `URLSearchParams` polyfill at `src/js/url_search_params.js` wired
  through `JsEngine.installWebApis` — required because QuickJS-NG ships no
  native `URLSearchParams` and the spec body-shape constraint is unusable
  without it.
- Fixed hidden-input round-trip in `src/render.zig` (register `type=hidden`
  fields with `field_type="hidden"` instead of skipping them) and
  `src/browser.zig` (added `isUserVisibleField` helper to keep hidden
  fields out of tab order while keeping them available for form
  submission). This implements the CSRF-token round-trip required by
  `agent-browser.md §2`.
- Added Zig-side end-to-end form-post integration test in `src/page.zig`
  that drives `processHtml → formMetaForField → fieldValueAttr →
  navigatePost` against a localhost `std.http.Server` on port `18489`.
  Verifies wire-level method/target/content-type/body, including hidden
  CSRF round-trip.
- Updated `spec/subspecs/wpt-conformance.md §8` mapping: 65 active curated
  WPT cases (was 61); only `cookies_persistence_roundtrip.js` remains
  deferred (requires `document.cookie` or harness binding, both out of
  MVP scope).
- Amended `spec/MVP.md §4.4` closure-gate phrasing from "GET-only request"
  to "GET+POST request, form-submission" to keep the canonical spec
  consistent with the closed gates.
- Reason: agent-browser.md §5 closure was the next concrete piece of MVP
  remainder work; the in-flight POST/form WPT files committed in
  `a2639bb` were unregistered pending the echo-server fixture and
  URLSearchParams polyfill.
- Documents updated: `spec/MVP.md`, `spec/subspecs/wpt-conformance.md`,
  this ADR.

### 2026-04-28 — Rendering sub-spec added (deferred track)

- Added `spec/subspecs/rendering.md` as a new DEFERRED sub-spec covering
  two coordinated tracks: (A) terminal image rendering via Kitty / iTerm /
  Sixel / braille-fallback protocols for `<img>`, `<picture>`, `srcset`,
  and CSS `background-image`; and (B) a real-page render-quality corpus
  with snapshot-based fixtures plus per-fixture soft assertions, intended
  to catch render regressions that the synthetic WPT corpus cannot
  surface (long-URL line-wrap, CJK width math, malformed-HTML robustness,
  app-shell heuristics behavior).
- Updated `spec/MVP.md §7` deferred-tracks list to point at the new
  sub-spec.
- Reason: after agent-browser closure (`0a0e1b5`) and the neon-meadow
  heuristics fix (`adad620`), the next high-leverage gap is render
  quality on real production HTML and visual `<img>` support. The 65
  curated WPT cases prove API correctness; they don't prove the
  renderer's output looks right on a real Wikipedia article. The two
  tracks share closure gates (the corpus is the integration test for
  image rendering), so they live in one sub-spec rather than two
  cross-referencing each other.
- Track ordering is encoded in §7 of the new sub-spec: corpus harness
  skeleton lands first (text-only baseline), images land second with
  co-landed fixture-update PRs.
- Documents updated: `spec/MVP.md`, `spec/subspecs/rendering.md` (new),
  this ADR.

### 2026-04-28 — Rendering sub-spec promoted to ACTIVE; corpus harness landed

- Promoted `spec/subspecs/rendering.md` from DEFERRED to ACTIVE in the
  same change set as the first track-B code (real-page render-quality
  corpus harness skeleton + first fixture). Per the change-control
  discipline used for the agent-browser sub-spec promotion, the spec's
  ACTIVE claim now matches landed code.
- Landed harness skeleton: `tests/corpus_runner.zig` + `tests/corpus/`
  directory + `tests/corpus/README.md` + `scripts/update-corpus.sh` +
  `build.zig` `test-corpus` step. Uses the same module-graph shape as
  the curated WPT runner. Snapshot-based with per-fixture soft
  assertions (`min_text_bytes`, `must_contain`, `must_not_contain`).
  Bootstrap workflow: empty `.expected.txt` triggers one-time auto-seed
  from live render output; non-empty expected enforces strict diff.
  CI mode (`AWR_CORPUS_STRICT=1`) disables auto-seed.
- Seeded the first fixture: `tests/corpus/fixtures/example_com.html`
  (528 bytes, captured via `curl -sL https://example.com/`). Renders to
  147 bytes of text in the harness; `must_contain` set is `["Example
  Domain", "Learn more"]`.
- Updated `spec/MVP.md §7` to reflect the new active sub-spec, mirroring
  the agent-browser pattern: rendering is "active, not deferred"; Track
  A image rendering remains deferred-within-active until Track B's
  harness is established.
- Reason: the synthetic WPT corpus already proves API correctness
  (65 cases). What it does not prove — and what the neon-meadow
  blank-screen regression history demonstrates — is render-quality on
  real production HTML. The corpus harness closes that gap. Promoting
  the spec when the first harness commit lands keeps doc/code in sync.
- Documents updated: `spec/MVP.md`, `spec/subspecs/rendering.md`, this
  ADR, plus new harness sources (`tests/corpus_runner.zig`,
  `tests/corpus/README.md`, `scripts/update-corpus.sh`, `build.zig`
  test target wiring).

### 2026-04-30 — Closed `spec/subspecs/rendering.md` (Track A image rendering)

- Date: 2026-04-30
- Change: Marked the rendering sub-spec **closed** in `spec/MVP.md §7`
  and added image rendering as item 7 in §5's Closed MVP surface list.
  Track A (terminal image rendering) is now part of the shipped MVP
  surface; Track B (real-page render-quality corpus) was already
  complete pending Track A's gate-3.
- Track A landed across eleven sub-step commits (4a–4g, plus Steps 5–10):
  - `a651bc7` 4a/4b — vendor stb_image + decoder wrapper with safety caps
  - `049e7c7` 4c — byte-bounded LRU cache for decoded images
  - `5a97f10` 4d — protocol detection + `--images=…` flag
  - `9da7be8` 4e — braille fallback downsampler (2×4 Unicode glyphs)
  - `dfb5f1c` 4f — `RenderOptions.image_lookup` raw-byte emit path
  - `e49c8a3` Step 5 — Kitty graphics encoder (RGBA APC, `q=2` silent)
  - `b54a6b1` Step 6 — iTerm2 OSC-1337 inline encoder (file-bytes pass-through)
  - `82f0d6e` Step 5+ — `awr render` pipeline orchestrator
  - `7f28934` Step 7 — Sixel encoder + median-cut palette quantization
  - `fff304d` Step 9 — `<picture>` / `srcset` picker with min/max-width
    media queries
  - `78547d8` Step 10 — CSS `background-image: url(...)` resolve + emit
    on content-bearing landmarks (`<header>`, `<section>`, `<figure>`)
- Closure gates per `spec/subspecs/rendering.md §6` — all green:
  1. `zig build test` — green (773/804; 31 net-skipped)
  2. `zig build test-wpt` — green; curated count unchanged
  3. `zig build test-image` — 113/113 across 8 modules
  4. `zig build test-corpus` — 12 fixtures unchanged (model layer text-only)
  5. `zig build test-tls` — JA4 fingerprint unchanged
  6. `zig build test-h2` — HTTP/2 SETTINGS unchanged
  7. `grep -rn "TODO|stub|unimplemented" src/image/` empty
  8. `awr render --images=auto|kitty|sixel | tee` is escape-free
     (non-TTY override forces `.none` regardless of mode)
  9. Peak RSS during `test-corpus` < 128 MiB
  10. `spec/MVP.md §5,§7` and this ADR amended in the same change set
      as the closing commit.
- Reason: the rendering sub-spec was the last ACTIVE sub-spec on the
  MVP closure path. With four real protocol encoders, an end-to-end
  pipeline that respects JA4 fingerprint discipline (uses the same
  `Client.fetchRequest` as page navigation), and a non-TTY safety
  override that protects gate 8, AWR's CLI-first browser runtime now
  renders real images on real pages without abandoning its core
  fingerprint guarantee. Closing the sub-spec on the same commit as
  the spec amendment keeps doc/code in sync.
- Documents updated: `spec/MVP.md` (§5 added item 7; §7 reclassified
  rendering as closed), this ADR.

### 2026-05-02 — Reconcile agent-browser.md status header with ADR 2026-04-28

- Date: 2026-05-02
- Change: Updated `spec/subspecs/agent-browser.md` heading and status line from
  "active sub-spec / Status: ACTIVE" to "closure record / Status: CLOSED FOR
  CURRENT MVP SURFACE (per ADR 2026-04-28)". No functional change — the closure
  was already recorded in the ADR and reflected in `spec/MVP.md §7`; the sub-spec
  file header was simply not updated at closure time.
- Reason: governance drift surfaced during doc-hygiene reconciliation work
  (`specs/wpt-conformance-doc-hygiene/spec.md`). The ADR 2026-04-28 entry and
  `spec/MVP.md §7` both say agent-browser is closed; the sub-spec file itself
  still said ACTIVE. Fixed in the same commit for consistency.
- Documents updated: `spec/subspecs/agent-browser.md`, this ADR.

### 2026-05-07 — Promote daemon-mode to an active sub-spec

- Date: 2026-05-07
- Change: Added `spec/subspecs/daemon-mode.md` as a new active sub-spec
  governing the long-lived `awrd` process, Unix-socket JSON-RPC IPC,
  per-cookie-scope state partitioning, and lifecycle (spawn-on-first-use,
  flock singleton, build-hash check, 5-minute idle shutdown). Updated
  `spec/MVP.md §2` (canonical doc map) and §7 (deferred-tracks block now
  carries a daemon-mode "active" callout alongside the rendering closure
  record). The companion design doc
  `docs/research/2026-05-07-daemon-mode-design.md` records the
  candidates-considered analysis and ~42% expected savings on a 5-fetch
  chained agent flow.
- Reason: per-invocation startup cost (~95 ms baseline) is the floor on
  AWR's cold latency. For chained agent fetches, that cost is
  multiplicative dead time — Lane A's H2 multiplexing closed the
  fingerprint and protocol gaps but can't address the per-process
  spawn cost. Daemon mode amortizes startup across many fetches via a
  long-lived `awrd` process. Decision was driven by the B1 design doc;
  this ADR records the spec-governance promotion.
- The sub-spec is **active**, not closed: B3 (implementation) is
  pending. No code lands until B3 has its own plan and follows the
  closure-gates in `spec/subspecs/daemon-mode.md §4`. Per-process
  `awr <url>` flow continues unchanged; daemon-mode opt-in via
  `AWR_DAEMON=1` for safe rollout.
- Decision on overlap with `spec/subspecs/mcp-stdio.md`: mcp-stdio
  remains deferred but its eventual implementation will be a thin
  client of the daemon, not embedded inside it. Documented in the
  daemon sub-spec §3.
- Documents updated: `spec/subspecs/daemon-mode.md` (new),
  `spec/MVP.md §2 + §7`, `docs/research/2026-05-07-daemon-mode-design.md`
  (already committed earlier today as B1), this ADR.

### 2026-05-09 — Tier ladder formalized; browser-tui promoted to ACTIVE (Tier 1)

- Change: AWR's product framing reframed from "CLI-first agent
  browser runtime + deferred TUI" to **dual-surface CLI-first
  terminal browser** (one binary; humans via `awr browse`, agents
  via `awr <url>` / `awr extract` / `awr tools` / `awr call`;
  shared cookie jar, connection pool, and DOM via the daemon).
  Capability growth organized into a **tiered ladder** with five
  tiers documented in `spec/subspecs/browser-roadmap.md §3`:
  - Tier 0: agent runtime baseline (CLOSED — was the "MVP")
  - Tier 1: interactive TUI parity with lynx/w3m (now ACTIVE)
  - Tier 2: render + UX polish (deferred)
  - Tier 3: lightly dynamic site support — History API,
    localStorage, WebSocket, MutationObserver, synthetic input
    events (deferred)
  - Tier 4: layout engine — the gating constraint for SPA
    support (deferred; ADR amendment required to activate
    because of strategic choice between building a Zig layout
    engine vs embedding Servo/Ladybird/Chromium)
  - Tier 5: full SPA + parity polish (deferred)
- `spec/subspecs/browser-tui.md` rewritten from a 31-line
  DEFERRED stub into the active **Tier 1 sub-spec** with concrete
  scope (form-field interaction, focus management, keyboard
  input, history navigation, URL bar, cookie inspector, browser-
  cookie import via SQLite reads of Chrome / Firefox cookie
  stores), §4 closure gates including end-to-end HN sign-in
  smoke flow, and §6 implementation slice ordering.
- `spec/subspecs/browser-roadmap.md` added (new) as the
  cross-tier authority. Owns tier ordering, the WPT-growth
  contract (§4), permanently-out-of-scope items (§5 — WebGL,
  video playback, WebRTC, single-site bot-detection arms races),
  and tier-promotion governance (§6).
- `spec/subspecs/wpt-conformance.md` updated to acknowledge that
  the corpus listed in §3/§8 is the **Tier 0 baseline**; new
  tiers grow the corpus per `browser-roadmap.md §4`.
- Reason: the originally-stated MVP framing said "execute enough
  DOM and JS to make them useful" — implicitly Tier 0. As that
  surface closed, the conversation about whether AWR is "a real
  browser" or "an agent runtime" needed an explicit answer. The
  product owner clarified the goal is the former, with explicit
  honesty about which tiers of the web AWR will reach (most of
  it) vs which are out of scope at every tier (X.com, Facebook,
  modern Slack/Discord — full SPAs depending on rendering loops).
  The tier ladder makes the trajectory auditable and gives every
  tier a defined closure gate, preventing scope drift.
- Tier 1 promotion did NOT change Tier 0 closure gates; all
  existing tests (`zig build test`, `test-wpt`, `test-test262`,
  `test-integration`, `smoke`) remain green.
- Documents updated: `spec/MVP.md` (status, doc map §2,
  deferred-tracks §7), `spec/subspecs/browser-roadmap.md` (new),
  `spec/subspecs/browser-tui.md` (full rewrite, status flipped
  to ACTIVE), `spec/subspecs/mvp-remainder.md` ("not in scope"
  list updated to point at tier authorities),
  `spec/subspecs/wpt-conformance.md` (status note + Tier 1
  area listing in §3), `README.md` (status block + spec map
  + repo layout), `CLAUDE.md` (product framing + primary
  experience list), `AGENTS.md` (global framing + execution
  specs list), this ADR.

### 2026-05-11 — Tier 1 CLOSED; Tier 2 promoted to ACTIVE

- Change:
  - `spec/subspecs/browser-tui.md` status header flips from
    ACTIVE → CLOSED. All §4 closure gates met: Tier 0 baseline
    green, curated WPT corpus extended for §4.2 (form input
    events, focus/blur, keyboard event semantics, submit-via-Enter,
    history `length`/`state` round-trip), two end-to-end smoke
    flows in `scripts/browse_smoke.sh`, `awr session import
    <browser>` ships, cookie inspector + clear-cookies documented
    in `awr tui --help` + welcome screen. §9 Progress record
    renamed to Closure record with the slice-by-slice mapping.
  - `spec/subspecs/browser-roadmap.md` Tier 1 line flips to
    `(CLOSED 2026-05-11)`; Tier 2 line flips from `(DEFERRED)`
    to `(ACTIVE 2026-05-11)` and gains a pointer to the new
    sub-spec.
  - **New file `spec/subspecs/render-polish.md`** — Tier 2
    execution authority. §1 purpose, §2 in-scope (bookmarks,
    URL-bar autocomplete, form-render polish, table sticky
    headers, code-block rendering + opt-in syntax highlighting,
    diff/patch rendering, image polish, cookie-inspector
    enrichment), §4 closure gates, §6 nine-slice ordering
    (T2.1–T2.9) starting with bookmarks (T2.1 — T-89 backlog
    item).
  - `spec/subspecs/wpt-conformance.md` previously bumped 103 →
    106 cases in the Tier 1 closure change; Tier 2 adds a small
    number of `<pre>` / Content-Type cases per `render-polish.md`
    when each slice lands.
- Reason: Tier 1 functional slices (T1.1–T1.11) shipped over
  T-60…T-86, with T-87 closing the §4.2 WPT-corpus gap. The
  natural next surface is the "feel finished" gap — bookmarks
  + URL history + diff/code/table polish — which the roadmap
  always called out as Tier 2 but parked at DEFERRED. The
  promotion is uncontroversial (no strategic forking point like
  Tier 4 has), so it lands as a normal ADR amendment.
  Tier 2 deliberately stays out of dynamic-page territory (no
  `History` API, no WebSocket, no real layout); those remain
  in Tier 3/4/5.
- Tier 0/1 closure gates UNCHANGED. All existing tests
  (`zig build test`, `test-wpt`, `test-test262`,
  `test-integration`, `smoke`) remain green.
- Documents updated: `spec/subspecs/browser-tui.md` (status
  flipped to CLOSED, §9 became Closure record),
  `spec/subspecs/browser-roadmap.md` (Tier 1 → CLOSED, Tier 2
  → ACTIVE with sub-spec pointer), `spec/subspecs/render-polish.md`
  (new), `spec/subspecs/wpt-conformance.md` (status banner
  updated in the T-87 change), this ADR.

### Template for future amendments

- Date:
- Change:
- Reason:
- Documents updated:
