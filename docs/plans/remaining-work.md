# AWR — Remaining Work & Parallel Execution Plan

> Status: planning / tracking doc (NOT canonical — `spec/MVP.md` wins on any conflict)
> Last updated: 2026-06-01
> Canonical authority: `spec/MVP.md` · Tier ladder: `spec/subspecs/browser-roadmap.md`
> Tier 4 decision gate: `docs/adr/0003-tier4-layout-strategy.md`

This document tracks the work remaining after Tiers 0–3 (plus daemon mode,
starter CSSOM, and the TUI Quality Track) closed. It exists to make the
**dependency structure** explicit so independent work can run in parallel.

It is a tracking doc, not a spec. Any scope/closure change still goes through
`spec/MVP.md §8` change-control.

---

## 1. Snapshot

| Tier / Track | Status |
|---|---|
| Tier 0 — Agent runtime baseline | **CLOSED** |
| Tier 1 — Interactive TUI parity | **CLOSED** 2026-05-11 |
| Tier 2 — Render + UX polish | **CLOSED** 2026-05-13 |
| Tier 3 — Lightly dynamic site support | **CLOSED** 2026-05-22 |
| Daemon mode (`awrd`) | **CLOSED** 2026-05-23 |
| Starter CSSOM | **CLOSED** 2026-05-27 (+ §2.1–2.9 post-closure additions through 2026-06-01) |
| TUI Quality Track | **CLOSED** 2026-05-30 |
| **Track A — No-layout CSS frontier** | **ACTIVE** — §2.8 `:not()/:is()/:where()` + §2.9 custom props/`var()` landed 2026-06-01; more slices remain |
| **Track B — Tier 4 decision evidence** | **EVIDENCE DELIVERED** 2026-06-01 (`docs/research/2026-06-01-tier4-*`); ADR amendment is a pending human decision |
| **Track C — Tier 4 layout execution** | BLOCKED on B's ADR amendment |
| **Track D — Tier 5 full SPA parity** | BLOCKED on C |
| **Track E — Native MCP stdio server** | **IMPLEMENTED** on `main` 2026-06-01 (`test-mcp` 35/35); DEFERRED→shipped promotion pending `spec/MVP.md §8` |
| **Track F — Doc hygiene** | **DONE** 2026-06-01 |
| **Track G — Brotli response decode** | **NEW / OPEN** — surfaced by Track B; see §5 |

AWR is already a usable browser replacement for humans and agents
(`spec/MVP.md §1`). Everything below grows reach; none of it is required for the
closed MVP surface to remain valid.

---

## 2. Dependency / parallelism map

```
                 ┌──────────────────────────────────────────┐
   PARALLEL ──►  │ A  No-layout CSS frontier   (code)        │
   (no shared    │ B  Tier 4 decision evidence (audit+POC)   │
    blocker)     │ E  Native MCP stdio server  (code)        │
                 │ F  Doc hygiene              (docs)        │
                 └──────────────────────────────────────────┘
                                   │
                          B amends ADR 0003
                                   ▼
                        ┌────────────────────┐
   SEQUENTIAL ──►       │ C  Tier 4 layout   │
                        └────────────────────┘
                                   │
                                   ▼
                        ┌────────────────────┐
                        │ D  Tier 5 full SPA │
                        └────────────────────┘
```

**Parallel-eligible now:** A, B, E, F — no shared blocker between them.
**Sequential:** C waits on B's ADR amendment; D waits on C.

### File-collision risk (matters for parallel code work)

| Track | Primary files touched | Collides with |
|---|---|---|
| A | `src/cssom/*`, `src/dom/node.zig`, `src/dom/bridge.zig`, `src/render.zig`, `tests/wpt/css_*.js` | B's POC (render/CSSOM paths) |
| B | `docs/adr/0003*`, new audit docs, a `LayoutAdapter` seam | A (if POC touches render) |
| E | `src/mcp_stdio.zig`, `src/main.zig` (subcommand wire-up) | low — isolated module |
| F | `STATUS.md`, `SPRINT_STATUS.md`, `docs/*` | none |

A and B's layout-adapter POC both reach into the render/CSSOM surface, so they
should run in **separate worktrees** to avoid stepping on each other. E and F
are cleanly isolated.

---

## 3. Track detail

### Track A — Finish the no-layout CSS frontier  · ACTIVE

**Goal:** push selector + cascade + CSSOM correctness as far as possible
*without* geometry. Every slice is WPT-gated; agent/corpus byte-output stays
unchanged (renderer cascade gated on `ansi_colors`).

Already landed (post-closure, `spec/subspecs/cssom.md §2.1–2.7`): compound +
combinator selectors, attribute selectors, computed-value serialization,
compiled-selector cache + exact renderer matching, structural pseudo-classes,
`@media` in the cascade, CSS-wide keywords + shorthand longhands, full color
serialization.

Remaining candidate slices (each independent, each a failing→passing WPT case):
- `:not()`, `:is()`, `:where()` selector functions
- `@supports` evaluation
- `@import` resolution
- CSS custom properties (`--var` + `var()` substitution)
- `calc()` for non-layout values
- inheritance edge cases not yet covered

**Gate per slice:** new `tests/wpt/css_*.js` fails before, passes after;
`zig build test-wpt` + `zig build test-cssom` green; agent/corpus output
byte-identical.

**Stop line:** the moment a property needs box geometry it is Tier 4, not here.
Do not let this track become a layout engine (`cssom.md §6`).

### Track B — Produce the Tier 4 decision evidence  · OPEN (highest leverage)

**Goal:** generate the four artifacts ADR 0003 requires *before* any layout
code. This is the real gate on everything past Tier 3.

Sub-goals (themselves parallelizable):
1. **WPT delta audit** — tag every failing/high-priority WPT area as heuristic /
   CSSOM-only / layout-required / API-required / out-of-scope.
2. **Target-site audit** — HN, Google Search, GitHub, Stack Overflow,
   Discourse/Reddit-like, one login flow; name the blocking subsystem for each.
3. **Resource / packaging audit** — single-binary requirement strength vs.
   embed cost; sandboxing + platform story.
4. **Layout-adapter POC** — introduce the `LayoutAdapter` seam (heuristic
   adapter = today's behavior; external-oracle adapter = experiment); one
   corpus/WPT/smoke case proving the adapter improves real output.

**Gate:** ADR 0003 amended with a chosen path (A embed-oracle / B Servo-LibWeb /
C native-Zig); `spec/MVP.md` + `browser-roadmap.md` updated in the same change
(`spec/MVP.md §8`).

### Track C — Tier 4 layout execution  · BLOCKED on B

Real geometry: box model, block/inline flow, flexbox, basic grid, text shaping,
viewport tracking; unblocks true `getBoundingClientRect`, `IntersectionObserver`,
`ResizeObserver`, scroll-driven loads. Scope + closure gates defined at
activation. Do not start without B's ADR amendment.

### Track D — Tier 5 full SPA parity  · BLOCKED on C

Service Workers, IndexedDB, full `crypto.subtle`, Workers, fingerprint shimming
(canvas/WebGL/AudioContext per `spec/Fingerprint-Plan.md`), multi-tab TUI.
Permanently out of scope even here: WebGL/Canvas pixels, `<video>`/`<audio>`
playback, WebRTC (`browser-roadmap.md §5`).

### Track E — Native MCP stdio server  · OPEN (independent)

`spec/subspecs/mcp-stdio.md` — a thin client of daemon-mode. Off the tier ladder;
can land anytime, no ADR required. Isolated to `src/mcp_stdio.zig` + main wiring.

### Track F — Doc hygiene  · OPEN (independent, quick)

Reconcile drifted status docs against the governed spec set:
- `STATUS.md` still marks TUI Quality Track **ACTIVE** (closed 2026-05-30) and
  predates the CSSOM §2.1–2.7 additions.
- `SPRINT_STATUS.md` is stuck at 2026-05-09.

**Gate:** both reflect `spec/MVP.md` so the active/deferred boundary stays
auditable (`MVP.md §8`).

---

## 4. Parallel execution setup

Recommended concurrent streams (one worktree each, to avoid the A/B render-path
collision noted in §2):

| Stream | Track(s) | Worktree | Branch |
|---|---|---|---|
| 1 | A — CSS frontier | `.worktrees/track-a-css` | `track/a-css-frontier` |
| 2 | B — Tier 4 evidence | `.worktrees/track-b-tier4` | `track/b-tier4-evidence` |
| 3 | E — MCP stdio | `.worktrees/track-e-mcp` | `track/e-mcp-stdio` |
| 4 | F — Doc hygiene | (main, fast) or `.worktrees/track-f-docs` | `track/f-doc-hygiene` |

C and D are **not** scheduled — they are blocked and start only after B lands its
ADR amendment.

Each stream's definition of done is its track's **Gate** above. All streams must
keep the global gates green before merge: `zig build test`, `zig build test-wpt`,
`zig build test-test262`, and the TLS/H2 fingerprint tests
(`zig build test-tls`, `zig build test-h2`) — per the fingerprint constraint in
`CLAUDE.md` and `spec/MVP.md §4`.

---

## 5. 2026-06-01 parallel run — outcome & follow-ups

Four streams (A, B, E, F) ran concurrently in isolated worktrees, merged
conflict-free into `integration/parallel-tracks-2026-06-01`, and were
fast-forwarded onto `main`. Verified on the merged tree (real exit codes, not
pipe-masked): `zig build` green; `test-wpt` 128 cases / 0 failures; `test-cssom`
25/25; `test-mcp` 35/35; `test-tls` 35/44 (9 net-skipped, fingerprint intact);
`test-h2` 61/61; `test-dom` 38/38; `test-js` 81/82 (1 skipped).

### Open decisions for the maintainer
1. **MCP — PARKED (not now).** Track E's `src/mcp_stdio.zig` exists on `main` and
   is tested, but the MCP stdio server is **deferred and intentionally not a
   current priority** — it only becomes interesting much further along, once the
   reading-browser surface (P1 below) and any Tier 4 decision are settled. Leave
   it parked: `spec/MVP.md §7` + `spec/subspecs/mcp-stdio.md` keep it DEFERRED, no
   promotion now. Do **not** treat it as active work.
2. **Tier 4 path.** Track B's four evidence docs are ready; the ADR 0003
   amendment (path A/B/C, or "defer again in favor of P1") is the maintainer's
   call. Evidence says no tested site is blocked by layout (see §6).

### New follow-up tracks surfaced
- **Track G — Brotli response decode** *(OPEN, high value, ~bounded)*. AWR
  advertises `br` in `Accept-Encoding` to match the Chrome 132 fingerprint
  (`src/net/http1.zig:66`) but only decodes gzip/deflate/zstd, so Google Search,
  Google home, and Discourse return HTTP 200 but render as undecoded bytes
  (Track B target-site audit). Adding a Brotli decoder unblocks more real pages
  than Tier 4 and is fingerprint-safe (no header change). This is the strongest
  evidence-backed candidate for the next near-term slice.
- **Corpus re-bless** *(OPEN, small — in progress)*. The corpus is **hermetic**
  (every fixture renders an embedded `@embedFile`'d `.html`, no network — verified
  2026-06-02). `test-corpus`'s `wikipedia_octopus` snapshot is **stale** relative
  to the current renderer (`99495` expected vs `~87.9K` produced) — an earlier
  render change was never re-blessed; it has been red on `main` since before the
  2026-06-01 work and is not a regression. Fix = re-bless the snapshot.

### Remaining Track A slices (still no-layout)
`:has()`, `@supports`, `@import`, `calc()` for non-layout values, and inheritance
edge cases — each a failing→passing `tests/wpt/css_*.js`, stopping at the first
property that needs geometry.

---

## 6. Validated path to a "full terminal browser"

> Grounded in `docs/research/2026-06-01-tier4-*` (target-site + WPT-delta audits)
> and live observations on 2026-06-02 (TUI CRLF fix, Ghostty→kitty, SVG/image
> findings). "Full terminal browser" = the **readable web for humans + agents**,
> not Chromium parity.

**Already excellent (don't re-litigate):** Tiers 0–3 + the 2026-06-02 TUI fixes.
HN, GitHub, Stack Overflow, old.reddit all render cleanly; forms, history,
storage, WebSocket/SSE, CSSOM cascade, JS all work.

### P1 — Reach & fidelity (cheap, high-impact, mostly non-layout) ← do next
1. **Brotli decode** *(highest ROI)*. Google, Google Search, Discourse return
   HTTP 200 but undecoded Brotli — AWR advertises `br` (fingerprint) but only
   decodes gzip/deflate/zstd (`src/net/http1.zig:66`). Bounded networking fix;
   unblocks major sites; not layout.
2. **SVG handling.** stb_image is raster-only; SVG sources (HN's `y18.svg`) →
   a 1×1 placeholder blob. Minimum: degrade gracefully (skip/alt-text, not a
   degenerate blob); ideal: a rasterizer.
3. **Image vertical row-height.** A kitty image occupies `r` cell rows but the
   render model counts it as one logical line → rows after an image space oddly
   (the item-8 gap on HN). Renderer-layer fix, not a layout engine.
4. **Renderer whitespace polish.** GitHub's extracted text carries excess
   structural whitespace (renderer-heuristic).

**Key finding:** the target-site audit found **no tested site is blocked by
layout** — only Brotli (network), anti-bot (out of scope), and renderer polish.
The P1 cluster makes AWR a great daily-driver reader **without** the Tier 4
investment.

### P2 — Tier 4 layout engine (bounded, ADR-gated)
Small, well-bounded surface (per WPT-delta audit): CSS-pixel
`getBoundingClientRect`, `IntersectionObserver`/`ResizeObserver`, flexbox/grid,
box model, scroll geometry (`scrollTo` is a no-op today). Needed for JS that
**reads geometry to render** and **scroll-driven lazy-loading** — not basic
readability. Gated on `docs/adr/0003`; packaging evidence favors Path C
(native Zig) if pursued, but argues P1-first.

### P3 — Tier 5 SPA parity (deferred, after Tier 4)
Service Workers, IndexedDB, full `crypto.subtle`, Workers — X/Slack/Notion-class
apps. Only sensible after Tier 4. (MCP stdio, §"Open decisions", is also parked
in this far-out bucket.)

### Permanently out of scope
Per-site anti-bot (Cloudflare / new-reddit challenges), WebGL/WebGPU/Canvas
pixels, `<video>`/`<audio>` playback, WebRTC (`browser-roadmap.md §5`).

### Recommended sequence
**P1 cluster → (then decide) Tier 4 via ADR 0003 → Tier 5.** Brotli first.
