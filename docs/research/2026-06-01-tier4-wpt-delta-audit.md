# Tier 4 WPT Delta Audit — 2026-06-01

> **Status:** Evidence artifact for `docs/adr/0003-tier4-layout-strategy.md`
> §"Required evidence before final Tier 4 decision", item 1 (WPT delta audit).
> **Read-only research.** This document does not amend any spec or ADR and does
> not change source behavior. It is a survey for human review.

## Scope and method

ADR 0003 requires a WPT delta audit that lists failing / high-priority WPT
areas and tags each as one of:

- **renderer-heuristic** — solvable in the terminal renderer / extraction
  heuristics without a layout engine;
- **CSSOM-only** — solvable in the non-layout CSSOM track
  (`spec/subspecs/cssom.md`), already CLOSED;
- **layout-required** — needs real CSS box/flow/flex/grid geometry (Tier 4);
- **browser-API-required** — needs a new JS/browser API surface, not layout;
- **anti-bot/fingerprint** — gated by network/fingerprint behavior, not DOM;
- **out-of-scope** — permanently excluded per
  `spec/subspecs/browser-roadmap.md §5`.

Ground truth used:

- `spec/subspecs/wpt-conformance.md §8` — the curated corpus mirror
  (documented baseline: **126 active curated WPT cases**, 58 Test262 cases as
  of 2026-05-31).
- `tests/wpt_runner.zig` and `tests/wpt/*.js` — the actual curated cases.
- `tests/corpus_runner.zig` + `tests/corpus/fixtures/*` — the rendered-output
  fidelity corpus (real-page expected snapshots).
- The Tier 4 scope sentence in `spec/subspecs/browser-roadmap.md §3`.

I ran the curated WPT runner (`zig build test-wpt`); it executes the cases
case-by-case (each `Running WPT case: …` line emits). The documented baseline
of 126 passing cases is treated as authoritative here; I did not attempt to
re-bless or modify any case.

Note on terminology: the curated corpus is **not** an upstream WPT mirror. It
is a hand-picked set that proves only the surface AWR claims to ship
(`wpt-conformance.md §3` inclusion rules). So the "delta" below is not a count
of upstream WPT failures — it is an analysis of which *Tier 4 capability areas*
are currently represented by a **negative/guard** case, a **terminal-proxy**
case, or **absent entirely**, and what each would require to become a real
positive case.

## Key structural finding

The curated corpus already contains the geometry/observer cases that Tier 4
would "flip on", but today they are written in one of two non-layout shapes:

1. **Guard cases that assert the API is absent** — these encode the
   no-stubs rule (`spec/MVP.md §6`): the API must not exist until it can be
   correct. Tier 4 would rewrite them into positive cases.
2. **Terminal-proxy cases that assert *terminal-cell* geometry** — these pass
   today against the renderer's screen model, not against CSS pixel layout.

Concretely:

| Curated case | Current shape | File |
|---|---|---|
| `intersection_observer.js` | Guard: asserts `typeof IntersectionObserver === 'undefined'` | `tests/wpt/intersection_observer.js` |
| `resize_observer.js` | Guard: asserts `typeof ResizeObserver === 'undefined'` | `tests/wpt/resize_observer.js` |
| `element_bounding_client_rect.js` | Terminal-proxy: asserts `rect.width/height > 0` only (no pixel coordinates) | `tests/wpt/element_bounding_client_rect.js` |
| `viewport_dimensions.js` | Terminal-proxy: `innerWidth/innerHeight` are the terminal cell grid (default 80×24), `screen == inner == outer` | `tests/wpt/viewport_dimensions.js` |

`getBoundingClientRect` is implemented (`getBoundingClientRectFn`,
`src/dom/bridge.zig:691`) by rendering the page to the **terminal screen model**
(`render.renderModel` → `model.rectForElement`) and reporting **terminal-cell**
top/left/width/height. That is honest geometry for the terminal, but it is not
CSS layout: there is no box model, no margins/padding/borders, no flow, no
flex/grid. The viewport is `viewport_width × viewport_height` cells
(`src/dom/bridge.zig:58`, default 80×24), scaled to fake CSS px only for
`matchMedia` (`* 8` / `* 16`, `src/dom/bridge.zig:1591`).

This is the crux of the Tier 4 decision: AWR already answers geometry queries
in terminal-cell units. The question Tier 4 asks is whether AWR needs *CSS-pixel
fidelity* for these answers, and the audit below shows the demand for that is
narrow.

## Area-by-area delta

### Already covered without layout (no Tier 4 demand)

| WPT area (curated) | Tag | Note |
|---|---|---|
| DOM queries / selectors / mutation / attributes / relationships | renderer-heuristic / browser-API | CLOSED; no geometry needed. |
| Events, MutationObserver, custom events, listener options | browser-API-required (done) | CLOSED Tier 0/3. |
| Storage (local/session), cookies (DOM) | browser-API-required (done) | CLOSED. |
| `fetch` / XHR (GET+POST), forms (DOM + POST), history | browser-API-required (done) | CLOSED. |
| EventSource (SSE), WebSocket | browser-API-required (done) | CLOSED Tier 3. |
| WebCrypto subset | browser-API-required (done) | Tier 3 starter slice. |
| **CSSOM (15 cases)** — cascade, specificity, `!important`, computed-value serialization, structural pseudo-classes, `@media`, attribute/combinator selectors, color serialization | **CSSOM-only (done)** | CLOSED 2026-05-27 / extended 2026-05-31. This is the boundary ADR 0003 protects: cascade + computed *style* without layout. |
| `matchMedia`, viewport dimensions, navigator/window surface | renderer-heuristic / browser-API | Terminal-cell viewport is sufficient for these. |

### Areas that are layout-required (the actual Tier 4 surface)

| WPT area | Tag | What it needs that AWR lacks |
|---|---|---|
| `getBoundingClientRect` **CSS-pixel parity** | **layout-required** | Box model + block/inline flow + text shaping to produce real CSS px coordinates instead of terminal cells. Today's proxy passes a weak assertion (`> 0`); a real WPT geometry case (exact `width`/`x`/`y`) would fail. |
| `IntersectionObserver` | **layout-required** | Real scroll geometry + viewport intersection math. Currently a guard case. |
| `ResizeObserver` | **layout-required** | Content-box / border-box sizing from layout. Currently a guard case. |
| `css-flexbox` (upstream area) | **layout-required** | Flex line/main/cross sizing. No case today; out of curated scope. |
| `css-grid` (upstream area) | **layout-required** | Track sizing, placement. No case today. |
| Box model (margin/padding/border, box-sizing) | **layout-required** | No representation today. |
| `cssom-view` scroll geometry (`scrollTop`, `scrollHeight`, `scrollIntoView` with real offsets) | **layout-required** | `scrollTo`/`scrollBy` are no-ops today (`src/dom/bridge.zig:2765`). |
| `position` / `transform` geometry | **layout-required** | No representation today. |

### Areas that are out-of-scope even at Tier 5 (not Tier 4 demand)

| WPT area | Tag |
|---|---|
| Canvas2D pixel readback, WebGL/WebGPU geometry | out-of-scope (`browser-roadmap.md §5`) |
| `<video>`/`<audio>` media element layout/playback | out-of-scope |
| WebRTC geometry | out-of-scope |

### Areas blocked by fingerprint/network, not layout

These are not WPT-corpus rows but show up the moment a layout audit touches real
sites (see the companion `2026-06-01-tier4-target-site-audit.md`). They are
called out here so the WPT delta is not misread as "layout is the only gap":

| Symptom | Tag |
|---|---|
| Brotli (`br`) responses surface as binary garbage (Google, Discourse) | **anti-bot/fingerprint** — AWR advertises `gzip, deflate, br, zstd` to match Chrome 132 but only decodes `gzip, deflate, zstd` (`src/net/http1.zig:66-68`). |
| `www.reddit.com` returns a "Please wait for verification" challenge | **anti-bot/fingerprint** |

## What the delta says about Tier 4

1. **The layout-required surface is small and well-bounded.** It is essentially
   four things: pixel-accurate `getBoundingClientRect`, `IntersectionObserver`,
   `ResizeObserver`, and real scroll geometry — plus the box/flex/grid
   machinery needed to compute them. Everything else AWR claims is already
   covered without layout, including the entire CSSOM cascade.

2. **AWR already has a usable geometry seam in terminal-cell units.** The
   demand is not "AWR has no geometry" — it's "AWR's geometry is in cells, not
   CSS pixels." For agent/TUI consumers, cell geometry may be *more* useful
   than CSS px. This weakens the case for a heavyweight CSS-pixel engine and
   strengthens the case for a thin adapter that keeps cell geometry as the
   default.

3. **Several "Tier 4-looking" failures on real sites are actually
   fingerprint/network failures** (Brotli, anti-bot). Those would be fixed by a
   Brotli decoder, not by a layout engine — a far cheaper intervention. A
   layout decision should not be justified by sites that are actually failing
   on content-encoding.

4. **The corpus is structured to make Tier 4 activation cheap to *measure*.**
   The guard cases (`intersection_observer.js`, `resize_observer.js`) and the
   weak `bounding_client_rect` assertion are exactly the cases a Tier 4 POC
   would rewrite to prove "the adapter improved real output" (ADR 0003 evidence
   item 4). No new harness surface is required to start measuring.

## Recommendation input (not a decision)

The WPT delta favors a **minimal, adapter-mediated** layout capability over a
full browser-engine embed: the genuinely layout-required surface is four
geometry features, the cascade is already done in Zig, and the loudest
real-site failures are encoding/anti-bot, not layout. This points toward
keeping terminal-cell geometry as the default adapter and treating CSS-pixel
layout as an opt-in oracle — see `2026-06-01-tier4-layout-adapter-proposal.md`.
