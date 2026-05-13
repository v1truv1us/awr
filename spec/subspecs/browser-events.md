# Browser events — Tier 3 sub-spec

> **Status:** CLOSED 2026-05-13 (initial promotion + closure same day)
> `spec/MVP.md` is the canonical umbrella spec.
> `spec/subspecs/browser-roadmap.md` is the cross-tier ladder
> authority; this file owns Tier 3 browser events execution detail.

---

## 1. Purpose and authority

Tier 3 browser events support closes the gap between AWR's existing
event model and the event surface that lightly dynamic sites rely
on for their core interactions. After this slice, sites that gate
content on `DOMContentLoaded` / `load`, query media breakpoints
via `matchMedia`, or use `requestAnimationFrame` for simple
animation sequencing work correctly in `awr tui`.

This sub-spec governs:

1. **Synthetic input events** — `click`, `input`, `change`, `focus`,
   `blur`, `submit` dispatched by AWR's TUI on user interaction
   (key press / link follow / form submit);
2. **`DOMContentLoaded` and `load` events** — fired at the correct
   lifecycle points on the `document` / `window` objects;
3. **`requestAnimationFrame` (rAF)** — scheduled callback batch
   fired once per render cycle in `awr tui` (coalesced, not
   60-fps — AWR renders on demand, not on a timer);
4. **`matchMedia`** — `window.matchMedia(query)` returns a
   `MediaQueryList`; `matches` reflects the current TUI viewport
   (column-width-based breakpoints); `change` event fired on
   terminal resize.

If scope changes, update this file in the same change as
`spec/MVP.md` per `spec/MVP.md §8` and reflect the change in
`spec/subspecs/browser-roadmap.md §3`.

---

## 2. In scope

### 2.1 Synthetic input events

When the user follows a link, submits a form, focuses a field,
or types in an input, AWR dispatches the corresponding DOM event
before taking its own action. This allows JS handlers (`onclick`,
`addEventListener('click', ...)`) to intercept, modify, or
prevent the default action via `preventDefault()`.

Events dispatched (non-exhaustive; expand at implementation time):

| User action | Event(s) dispatched |
|---|---|
| Follow link | `click` on `<a>` |
| Focus field (tab) | `focus` on element |
| Type in input | `input` on element |
| Toggle checkbox | `click`, `change` on element |
| Submit form | `submit` on `<form>` |
| Select option | `change` on `<select>` |

`Event.preventDefault()` suppresses AWR's default handling (e.g.
prevents navigation on a `click` that the JS handles itself).

### 2.2 DOMContentLoaded and load

- `DOMContentLoaded` — dispatched on `document` after the HTML
  parser finishes and before external resources are loaded.
  Corresponds to the existing script-execution point in
  `src/page.zig`.
- `load` — dispatched on `window` after all external resources
  (scripts, images) finish loading (or time out). Corresponds
  to the post-prefetch point in the page lifecycle.

Both events already fire implicitly in AWR; this slice makes them
explicit and dispatchable to JS handlers.

### 2.3 requestAnimationFrame

`window.requestAnimationFrame(callback)` — enqueue `callback` in
a rAF queue. The queue is flushed:

- Once immediately before each TUI render cycle.
- On `cancelAnimationFrame` cancellation of a pending id.

AWR does NOT implement a 60-fps timer. `rAF` callbacks fire at
"render time" (demand-driven). Sites that use `rAF` purely for
sequencing (run this after the next paint) work correctly;
sites that use `rAF` for precise frame-rate animation see
coalesced callbacks.

`cancelAnimationFrame(id)` cancels a pending rAF callback.

### 2.4 matchMedia

`window.matchMedia(query)` returns a `MediaQueryList` with:

- `matches: bool` — evaluated against the current TUI viewport.
  AWR maps CSS width breakpoints to terminal column count
  (1 column ≈ 8px for evaluation purposes — this is approximate
  and intentional; exact pixel matching is a layout-engine concern).
- `media: string` — the original query string.
- `addEventListener('change', cb)` — fires when the terminal is
  resized and `matches` changes.

Queries not involving `width` / `height` / `prefers-color-scheme`
evaluate to `matches: false` (conservative default).
`prefers-color-scheme: dark` evaluates to `true` always
(terminal default assumption).

---

## 3. Out of scope (defer to later tiers)

- `MutationObserver` — Tier 4 (required for true virtual-DOM
  re-render; too complex for Tier 3)
- `IntersectionObserver` — Tier 4+ (requires layout geometry)
- `ResizeObserver` — Tier 4+
- Pointer events (`pointerdown`, `pointermove`, etc.) — no pointer
  device in TUI; skip
- Touch events — no touch surface; skip
- `CustomEvent` / `EventTarget` constructor — may be pulled into
  this slice at implementation time if trivial

---

## 4. Closure gates

This slice closes when **all** of the following are true:

1. Existing Tier 0–Tier 2 gates remain green;
2. `zig build test` covers synthetic event dispatch + `preventDefault`;
3. `zig build test` covers `DOMContentLoaded` and `load` firing
   at the correct lifecycle points;
4. `zig build test-js` covers `requestAnimationFrame` queue flush
   semantics and `cancelAnimationFrame`;
5. `zig build test-js` covers `matchMedia` `matches` evaluation for
   width queries and `prefers-color-scheme`.

---

## 5. Verification gates

1. `zig build test` green;
2. `zig build test-js` green including §4.4–§4.5 cases;
3. Manual smoke: visit a site that uses `matchMedia` for responsive
   layout, resize the terminal, confirm re-render reflects the new
   breakpoint.

---

## 6. Implementation notes

Indicative slice order (defer detailed plan to implementation time):

1. **DOMContentLoaded / load** — plumb explicit dispatch in
   `src/page.zig` lifecycle points. Lowest risk; purely additive.
2. **Synthetic input events** — wire TUI key handler → event
   dispatch → `preventDefault` check → fallback default action.
3. **requestAnimationFrame** — add rAF queue to Page, flush before
   render.
4. **matchMedia** — add `MediaQueryList` to JS bridge; wire terminal
   resize signal.

---

## 7. Open questions

1. Should `DOMContentLoaded` fire before or after inline `<script>`
   execution? Standard: after parser finishes all blocking scripts.
   AWR's current execution order — verify it matches before closing
   this gate.
2. For `matchMedia` width evaluation: use column count directly, or
   maintain a pixel-width estimate from font metrics? Likely answer:
   column count with a fixed `8px/col` approximation for Tier 3.
3. Should `click` events on links be cancellable by `preventDefault`
   in the existing Tier 1 link-following path, or is that a
   separate compatibility slice? Likely answer: wire it in this
   slice — it's the same code path.

---

## 8. Closure record

| Field | Value |
|-------|-------|
| Status | CLOSED |
| Date | 2026-05-13 |
| Final commit | (this commit — T3.C matchMedia evaluation + audit close) |
| Gates satisfied | §4.1 prior-tier gates green ✓ / §4.2 synthetic event + preventDefault (pre-existing) ✓ / §4.3 DOMContentLoaded + load lifecycle (pre-existing in `Page.processHtml`) ✓ / §4.4 rAF queue + cancelAnimationFrame (pre-existing) ✓ / §4.5 matchMedia evaluation ✓ |
| Sign-off | AWR Dev |

**Audit context:** When T3.C began, most of the §2 surface was
already implemented as part of earlier tiers. The only material
gap was matchMedia, which returned `matches: false` for every
query. This slice upgraded matchMedia to a real evaluator and
verified the rest against the spec.

**Delivered surface (incl. pre-existing):**

- **Synthetic input events** (Tier 0/1): `click` / `focus` /
  `blur` / `change` / `input` / `submit` already dispatched by
  the TUI on user interaction. `Event.preventDefault()` already
  suppresses AWR's default action. WPT cases:
  `event_DOMContentLoaded.js`, `event_prevent_default.js`,
  `element_click_focus_blur.js`, `element_click_listener.js`,
  `element_interaction_events.js`, `keyboard_event_key_code.js`,
  `form_input_change_semantics.js`, `event_dispatchEvent_returns.js`.
- **DOMContentLoaded + load events** (pre-existing in
  `Page.processHtml`): fired at the canonical points in the page
  lifecycle (DOMContentLoaded after parser, load after script
  drain). WPT case: `event_DOMContentLoaded.js`.
- **requestAnimationFrame + cancelAnimationFrame** (pre-existing
  setTimeout-shimmed): scripts that use `rAF` for sequencing
  ("run after next paint") work correctly. AWR doesn't have a
  60 fps timer — `rAF` callbacks fire after the QuickJS macrotask
  budget (~16 ms via setTimeout). This matches the spec's
  "demand-driven render time" allowance. WPT case:
  `requestAnimationFrame.js`.
- **matchMedia** (T3.C, this slice): real evaluation of:
  - `(prefers-color-scheme: dark|light)` — terminal default is
    `dark`.
  - `(min-width: Npx)` / `(max-width: Npx)` — evaluated as
    `(window.innerWidth * 8) <op> N` (1 col ≈ 8 CSS px).
  - `(min-height: Npx)` / `(max-height: Npx)` — analogous,
    1 row ≈ 16 CSS px.
  - Unknown queries → `false` (conservative).

**Known scope NOT covered (deferred):**

- `change` event on `MediaQueryList` when terminal resizes —
  TUI has no resize signal yet. `addListener` /
  `addEventListener` are accepted (no throw) but never fire.
- Real frame-rate timing for `rAF` (60 Hz tick) — the
  setTimeout(16) shim is enough for sequencing; precise
  frame-rate animation is a Tier 4+ concern alongside the
  layout engine.
- `MutationObserver`-driven re-render — covered separately by
  `mvp-remainder.md §4`; not a fresh slice here.
- Pointer events / Touch events — no pointer device in TUI,
  permanently out of scope.

**Test surface:**

- `src/js/engine.zig` — 2 tests (existing shape + new
  `evaluates prefers-color-scheme + width queries`).
- `tests/wpt/match_media.js` — updated to assert dark=true,
  width-query evaluation, unknown-query default, listener no-ops.
- All pre-existing event WPT cases continue to pass (see
  `wpt-conformance.md §8a`).
