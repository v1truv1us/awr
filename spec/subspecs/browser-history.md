# History API — Tier 3 sub-spec

> **Status:** ACTIVE (promoted from DEFERRED to ACTIVE 2026-05-13)
> `spec/MVP.md` is the canonical umbrella spec.
> `spec/subspecs/browser-roadmap.md` is the cross-tier ladder
> authority; this file owns Tier 3 History API execution detail.

---

## 1. Purpose and authority

Tier 3 History API support enables client-side navigation without
full page reloads. After this slice, sites that push URL state
via `pushState` / `replaceState` (GitHub file browser, many SPAs,
Discourse topic threads) remain navigable in `awr tui` rather than
breaking on the first SPA-style link click.

This sub-spec governs:

1. `history.pushState(state, title, url)` — updates `location.href`
   and adds an entry to the session history stack;
2. `history.replaceState(state, title, url)` — same as pushState
   but replaces the current entry;
3. `history.back()` / `history.forward()` / `history.go(n)` —
   traverse the session history stack;
4. `popstate` event — fired on `window` when the active history
   entry changes via `back()`/`forward()`/`go()`;
5. `location.href` setter — equivalent to `history.pushState` for
   same-origin URLs; cross-origin falls through to a new fetch.

If scope changes, update this file in the same change as
`spec/MVP.md` per `spec/MVP.md §8` and reflect the change in
`spec/subspecs/browser-roadmap.md §3`.

---

## 2. In scope

### 2.1 Session history stack

An in-process, per-tab history stack (not persisted). Each entry
stores `{ url, state, title }`. AWR's existing `b` (back) and
`f` (forward) TUI bindings drive `history.back()` /
`history.forward()` when the JS history stack is non-empty.

Stack implementation lives in the Page orchestrator
(`src/page.zig`) alongside the existing TUI back/forward logic.

### 2.2 pushState / replaceState

JS bridge methods on the `history` object. When called:

1. Resolve the target URL relative to `document.URL`.
2. Same-origin: push/replace in the stack, update `location.href`,
   dispatch `popstate` with the provided state object.
3. Cross-origin: throw `SecurityError` (standard behaviour).
4. `title` argument is accepted but ignored (browsers do the same).

### 2.3 popstate dispatch

Fire `popstate` on `window` with a `PopStateEvent` (`.state`
containing the stored state object) whenever the active entry
changes via `back()` / `forward()` / `go()`. Use the existing
JS event dispatch path in `src/dom/bridge.zig`.

### 2.4 location.href setter

`location.href = url` treated as `history.pushState(null, '', url)`
for same-origin assignments; cross-origin triggers a new top-level
fetch (same as clicking a link).

### 2.5 TUI integration

When `history.back()` is called from JS, the TUI's existing `b`
binding should remain consistent. The session history stack is the
single source of truth; TUI and JS share it.

---

## 3. Out of scope (defer to later tiers)

- Persistent history (cross-session) — Tier 4+
- `hashchange` event (URL fragment only) — may be pulled into this
  slice at implementation time if trivial; document the decision.
- Full SPA re-render driven by `MutationObserver` — Tier 4
- `history.scrollRestoration` — Tier 4+

---

## 4. Closure gates

This slice closes when **all** of the following are true:

1. Existing Tier 0 + Tier 1 + Tier 2 gates remain green;
2. `zig build test` covers `pushState` / `replaceState` /
   `popstate` dispatch semantics;
3. `zig build test-js` confirms the JS bridge methods are callable
   and produce the correct `location.href` side-effect;
4. At least one WPT `history` case added to the curated corpus
   (`zig build test-wpt` green);
5. `awr tui` back/forward bindings work correctly after a JS
   `pushState` call.

---

## 5. Verification gates

1. `zig build test` green;
2. `zig build test-js` green;
3. `zig build test-wpt` green and includes §4.4 history case(s);
4. Manual smoke: navigate a Discourse thread that uses pushState,
   press `b`, confirm URL reverts correctly.

---

## 6. Implementation notes

Indicative slice (defer detailed plan to implementation time):

1. Add `HistoryStack` struct to `src/page.zig` (entries, cursor).
2. Expose `history.pushState`, `history.replaceState`,
   `history.back`, `history.forward`, `history.go` on the JS
   `history` object via the bridge.
3. Wire `location.href` setter to `pushState` / fetch as described.
4. Fire `popstate` via existing event dispatch on cursor movement.
5. Update TUI `b`/`f` bindings to drive the shared stack.

---

## 7. Open questions

1. Should `history.go(0)` trigger a page reload or a no-op?
   Standard says reload; AWR may treat as no-op for Tier 3.
2. Does the existing TUI `b` binding need disambiguation when the
   JS stack and the fetch history both have entries?
   Likely answer: JS stack takes priority when non-empty.

---

## 8. Closure record

_Not yet closed._
