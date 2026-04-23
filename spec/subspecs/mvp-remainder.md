# MVP remainder — active completion track

> **Status:** ACTIVE
> `spec/MVP.md` is the canonical umbrella spec.
> This file defines the active execution order for closing the browser-runtime
> MVP.

---

## Goal

Close the remaining gap between AWR's shipped CLI browser-runtime baseline and a
fully qualified MVP backed by curated WPT and Test262 coverage.

This track is about making `awr <url>` behave like a real terminal-backed
browser runtime and proving that behavior through the repo's default test and
conformance gates.

---

## Working rules

1. docs first: update canonical docs and agent guidance before implementation;
2. no stubs: shipped APIs must be real or removed;
3. keep `zig build test` green as each slice lands;
4. every new behavior change must land with corresponding curated conformance
   coverage.

---

## Execution order

### Phase -1 — Canonical spec alignment

Update the canonical source-of-truth docs before code work begins:

- `spec/MVP.md`
- `spec/subspecs/mvp-remainder.md`
- `spec/subspecs/wpt-conformance.md`
- `AGENTS.md`
- `CLAUDE.md`
- `README.md` where execution/status references would drift otherwise

Exit criteria:

- canonical docs describe WPT/Test262-gated MVP closure;
- agent guidance files match the canonical doc set;
- no active implementation proceeds against stale documentation.

### Phase 0 — Build stabilization

Restore a trustworthy default test baseline.

Required closures:

- fix `test-js` hangs;
- fix `test-page` hangs;
- fix `test-net` hangs/timeouts;
- fix `test-tls` compilation on the supported toolchain;
- keep the default test path hermetic unless a test is explicitly marked as
  network-gated.

Exit criteria:

- `zig build test` exits cleanly without known broken default steps.

### Phase 1 — Runner wiring

Wire curated conformance into the build:

- add `zig build test-wpt`;
- add `zig build test-test262`;
- make both part of the default `zig build test` path;
- normalize runner output and failure reporting.

Exit criteria:

- both runners are build steps;
- both runners execute deterministically;
- failures identify the failing curated case directly.

### Phase 2 — DOM/bridge truthfulness fixes

Eliminate misleading or broken DOM bridge behavior needed by the curated WPT
surface.

Minimum required work:

- parent and sibling tracking;
- live `classList` semantics;
- Lexbor-backed `innerHTML` replacement;
- correct `cloneNode` behavior;
- correct `contains()` behavior;
- remove or implement any remaining stubbed bridge API within this phase's
  surface area.

Exit criteria:

- selectors, mutations, and tree relationships observed by JS match the
  authoritative Zig DOM and the curated WPT target.

### Phase 3 — Full event system

Implement real event behavior for the exposed runtime surface.

Minimum required work:

- `addEventListener` / `removeEventListener`;
- `dispatchEvent` with capture, target, and bubble phases;
- `preventDefault`, `stopPropagation`, `stopImmediatePropagation`;
- `Event` and `CustomEvent` constructors;
- browser lifecycle events needed by the page pipeline (`DOMContentLoaded`,
  `load`, `readystatechange`, `error`).

Exit criteria:

- curated event WPT cases pass;
- the runtime no longer exposes listener APIs as fake no-ops.

### Phase 4 — MutationObserver

Implement real mutation observation integrated with the authoritative DOM and
microtask delivery.

Exit criteria:

- curated mutation-observer WPT cases pass;
- record delivery matches the supported mutation surface.

### Phase 5 — Storage

Implement real in-memory `localStorage` and `sessionStorage` for the page
lifetime, including same-context storage events.

Exit criteria:

- curated storage WPT cases pass;
- no storage method silently no-ops.

### Phase 6 — XMLHttpRequest

Implement real XHR backed by the same transport path as `fetch()`.

Exit criteria:

- curated XHR WPT cases pass;
- async XHR does not hang the event loop.

### Phase 7 — Viewport-backed APIs

Ground geometry and viewport observers in AWR's real terminal render pipeline.

Minimum required work:

- terminal-cell-accurate geometry metadata in rendered output;
- `getBoundingClientRect()`;
- `requestAnimationFrame`;
- `IntersectionObserver`;
- `ResizeObserver`;
- terminal dimension exposure through `window` and `screen`.

Exit criteria:

- curated viewport WPT cases pass;
- observer behavior is derived from real render metadata, not placeholder
  values.

### Phase 8 — Curated WPT growth

Grow the curated WPT corpus until it covers the intended MVP browser/runtime
surface.

Target areas:

- document and element queries;
- DOM mutation behavior;
- event semantics;
- observer semantics;
- storage and XHR;
- viewport-backed APIs.

### Phase 9 — Curated Test262 growth

Grow the curated Test262 corpus until it covers the embedded JS runtime behavior
that real page execution depends on.

### Phase 10 — Final doc closure

When the closure gates are met, update canonical docs to reflect the closed MVP
state without weakening the governance boundary.

---

## First landing slices

Unless a later slice is needed to unblock the current one, implementation lands
in this order:

1. docs alignment
2. `test-js` stabilization
3. `test-page` stabilization
4. `test-net` stabilization and network gating
5. `test-tls` restoration
6. WPT runner wiring
7. Test262 runner wiring + default test integration
8. parent/sibling truthfulness
9. live `classList`
10. Lexbor-backed `innerHTML`
11. `cloneNode` and `contains()`
12. core event dispatch and lifecycle events

---

## Verification gates

The track is only complete when the repo can truthfully claim all of the
following:

1. `zig build test` is green on the default developer path;
2. `zig build test-wpt` is green;
3. `zig build test-test262` is green;
4. the curated conformance corpus covers the intended MVP surface defined in
   `spec/subspecs/wpt-conformance.md`;
5. shipped APIs on that surface no longer rely on stubs.

---

## Explicitly not in scope for this active track

- finishing native MCP stdio server mode
- browser/TUI product-track expansion beyond the viewport-backed APIs needed by
  browser-runtime closure
- later fingerprinting and browser-identity work

Those remain documented, but deferred.
