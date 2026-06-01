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
1. **MCP promotion (governance).** Track E's `src/mcp_stdio.zig` is real, tested,
   and now on `main`, but `spec/MVP.md §7` + `spec/subspecs/mcp-stdio.md` still
   classify the track DEFERRED. Decide: formally promote via a `spec/MVP.md §8`
   amendment, or keep as present-but-not-promoted.
2. **Tier 4 path.** Track B's four evidence docs are ready; the ADR 0003
   amendment (path A/B/C, or "defer again in favor of Brotli") is the maintainer's
   call.

### New follow-up tracks surfaced
- **Track G — Brotli response decode** *(OPEN, high value, ~bounded)*. AWR
  advertises `br` in `Accept-Encoding` to match the Chrome 132 fingerprint
  (`src/net/http1.zig:66`) but only decodes gzip/deflate/zstd, so Google Search,
  Google home, and Discourse return HTTP 200 but render as undecoded bytes
  (Track B target-site audit). Adding a Brotli decoder unblocks more real pages
  than Tier 4 and is fingerprint-safe (no header change). This is the strongest
  evidence-backed candidate for the next near-term slice.
- **Corpus hermeticity / re-bless** *(OPEN, small)*. `test-corpus`'s
  `wikipedia_octopus` fixture live-fetches Wikipedia; the page drifted
  (99495 → 87421 bytes) so the snapshot is stale and the gate is red on `main`
  (pre-existing, not a regression — confirmed byte-identical on base `8b85b66`).
  Re-bless the snapshot and/or make corpus fixtures hermetic so an external site
  can't redden the gate.

### Remaining Track A slices (still no-layout)
`:has()`, `@supports`, `@import`, `calc()` for non-layout values, and inheritance
edge cases — each a failing→passing `tests/wpt/css_*.js`, stopping at the first
property that needs geometry.
