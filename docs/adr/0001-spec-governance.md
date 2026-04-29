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

### Template for future amendments

- Date:
- Change:
- Reason:
- Documents updated:
