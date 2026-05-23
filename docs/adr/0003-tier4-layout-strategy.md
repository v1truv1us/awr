# ADR 0003 — Tier 4 Layout Strategy and Decision Log

- Status: Proposed / living decision record
- Date: 2026-05-23
- Owners: AWR maintainers
- Related specs: `spec/MVP.md`, `spec/subspecs/browser-roadmap.md`, `spec/subspecs/wpt-conformance.md`

## Context

AWR now has a starter CSSOM subset: stylesheet loading, inline `element.style`, and simple non-layout `getComputedStyle()` values. This improves feature detection and lets curated CSS WPT coverage begin, but it does **not** provide real CSS layout.

Tier 4 is the point where AWR must decide how to provide real geometry: CSS cascade/layout, box model, block/inline flow, flex/grid, text shaping, scroll-backed coordinates, and geometry-backed observers.

This decision affects AWR's core product identity:

- single Zig binary vs bundled renderer dependency;
- AWR-owned network/DOM/JS/cookie runtime vs embedded browser backend;
- terminal-first rendering control vs fast web compatibility;
- maintenance cost and security surface.

## Decisions made

| Decision | What was decided | Why |
|---|---|---|
| Starter CSSOM boundary | AWR may continue stylesheet loading, inline `element.style`, and simple non-layout `getComputedStyle()` values. | These improve real-page compatibility and can be covered by deterministic WPT cases without committing to a layout engine. |
| Tier 4 remains deferred | Full CSS layout, geometry-backed observers, flex/grid, box model, text shaping, and scroll layout are not active work. | Building or embedding layout changes AWR's architecture, packaging, security model, and maintenance burden. It needs explicit evidence first. |
| Add a layout adapter seam first | AWR should introduce a `LayoutAdapter` boundary before selecting a backend. | This keeps the TUI and agent APIs stable and lets us compare current heuristics, an external oracle, and possible native layout behind one contract. |
| First embed experiment is layout-only | If embedding is prototyped, use it as an out-of-process layout oracle first, not a full browser-runtime replacement. | AWR's product differentiator is one shared runtime for humans and agents. Replacing fetch/DOM/JS/cookies is a larger decision. |
| ADR amendment required for Tier 4 activation | No permanent Tier 4 backend or full-layout work starts without updating this ADR. | The decision has long-term cost and must be traceable to WPT/site/resource evidence. |

## Decision policy

Until this ADR is amended, AWR will follow the decisions above.

## Alternatives considered

### Option A — Embedded layout oracle / renderer service

Use a mature renderer out-of-process, likely starting with headless Chromium via CDP for proof-of-concept. AWR asks for layout boxes, text runs, geometry, and possibly simplified paint/snapshot data, then maps that into the terminal renderer.

Pros:

- fastest route to layout-backed WPT coverage;
- mature CSS cascade/layout/text behavior;
- reduces risk of years-long native layout work.

Cons:

- heavier runtime and packaging;
- sandboxing/resource-control requirements;
- risk of duplicating AWR's current network/DOM/JS/cookie runtime if the boundary is not kept narrow.

Initial preference: **best POC path**, but only as a layout oracle at first.

### Option B — Servo / LibWeb hybrid

Use a lighter browser engine component through an IPC shim.

Pros:

- more adaptable than Chromium for research;
- may be easier to tailor to terminal semantics.

Cons:

- not drop-in browser parity;
- integration and maintenance still significant;
- smaller ecosystem and less predictable WPT parity.

Initial preference: research candidate after the Chromium/CDP oracle proves the adapter shape.

### Option C — Zig-native layout engine

Build layout in Zig against AWR's existing DOM/runtime.

Pros:

- preserves small-binary, terminal-first identity;
- maximum control over TUI semantics;
- no browser-engine packaging dependency.

Cons:

- highest engineering cost;
- slowest path to compatibility;
- large ongoing maintenance surface: cascade, layout algorithms, text shaping, tables, flex/grid, scroll geometry, observers.

Initial preference: do **not** start unless target-site/WPT audits prove that AWR-specific layout behavior is more valuable than fast parity.

## Required evidence before final Tier 4 decision

A Tier 4 activation amendment must include:

1. **WPT delta audit**
   - List failing/high-priority WPT areas.
   - Tag each as: renderer heuristic, CSSOM-only, layout-required, browser-API-required, anti-bot/fingerprint-required, or out-of-scope.

2. **Target-site audit**
   - Include at minimum: Hacker News, Google Search, GitHub, Stack Overflow, Discourse/Reddit-like pages, and representative login flows.
   - For each, identify the blocking subsystem: layout, JS API, cookies/session, anti-bot, network, or renderer heuristic.

3. **Resource and packaging audit**
   - Team capacity and estimated maintenance burden.
   - Single-binary requirement strength.
   - Platform support and sandboxing story.

4. **Prototype result**
   - A layout-adapter POC returning terminal-usable boxes/text runs.
   - At least one curated WPT or corpus/smoke case proving the adapter improves real output.

## Layout adapter direction

AWR should introduce an internal adapter boundary before choosing the backend:

```text
Page/DOM/JS runtime
    -> LayoutAdapter
        -> heuristic/no-layout adapter (current behavior)
        -> external layout oracle adapter (POC)
        -> native Zig layout adapter (future possible)
    -> terminal render model
    -> TUI / agent outputs
```

The adapter should initially return a small terminal-oriented model:

- ordered text runs;
- line/column positions;
- element identity/back-pointers for links and fields;
- visibility/display decisions;
- bounding boxes in terminal cells where available;
- image/replaced-element placeholders.

JSON is acceptable for the first IPC prototype. Binary encodings can wait until the contract is stable.

## Decision log

### 2026-05-23 — Starter CSSOM remains non-layout

Decision: Starter CSSOM may continue, but full CSS layout remains deferred.

Reason: The current implementation loads stylesheets and exposes simple computed style. That is useful and WPT-gated, but does not answer the Tier 4 layout strategy.

### 2026-05-23 — Prefer layout-adapter seam before backend commitment

Decision: Add/plan a layout adapter before deciding between embedded and native layout.

Reason: This keeps the TUI and agent surfaces stable while allowing a Chromium/CDP oracle POC or later native implementation without rewriting callers.

### 2026-05-23 — First POC should be external layout oracle, not browser replacement

Decision: If/when prototyping embedding, use the external renderer only to answer layout/geometry questions first.

Reason: AWR's differentiator is one shared runtime for humans and agents. Replacing fetch/DOM/JS/cookies with a browser backend is a larger product decision and requires a separate ADR amendment.

## Amendment rule

Update this ADR whenever:

- Tier 4 scope changes;
- a layout backend is selected or rejected;
- the adapter contract changes materially;
- evidence from WPT/site audits changes the recommendation;
- AWR begins relying on an embedded engine for more than layout/geometry.
