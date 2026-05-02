# WPT & Test262 Conformance — MVP Completion Spec

> Status: Superseded / historical record. MVP runtime/conformance closure has
> landed on `main`, and the closed narrowed surface is now defined by
> `spec/MVP.md`, `spec/subspecs/mvp-remainder.md`, and
> `spec/subspecs/wpt-conformance.md`. Do not continue executing the phases
> below.

## Goal

Make AWR's browser-runtime MVP correctness measurable through a curated Web
Platform Tests (WPT) and Test262 corpus. Every API shipped must be fully
implemented — no stubs. The WPT and Test262 runners must be wired into
`build.zig`, green on every run, and serve as the primary gate for future work.

This work must begin by updating the canonical spec documents so development is
driven from the written source of truth rather than retrofitting docs after the
fact.

## Guiding Principle

**No stubs.** Every API surface that ships in AWR must work correctly. If an
API cannot be implemented correctly for AWR's context (a terminal-based
browser), it should not be shipped at all. Pages that reference it will get a
meaningful error rather than silent no-ops.

The terminal IS the viewport. AWR renders DOM to ANSI-formatted terminal
output via `render.zig` → `ScreenModel`, and the TUI (`browser.zig` + `tui.zig`)
scrolls through it. APIs like `IntersectionObserver` and
`requestAnimationFrame` should be grounded in this real render pipeline.

## Delivery Rules

These rules apply to every phase in this spec:

1. If an API currently exists as a stub, it must either be fully implemented in
   the same slice or removed from the exposed surface before the slice lands.
2. Every new API or behavior change must land with at least one curated WPT or
   Test262 case that would fail without the implementation.
3. The default `zig build test` step must stay green after each completed
   slice. Do not defer breakage across phases.
4. Prefer thin vertical slices over large polyfill rewrites. For example:
   parent tracking + tests is one slice; classList liveness + tests is a later
   slice.
5. Runtime behavior wins over convenience. If AWR cannot model an API with
   terminal-backed semantics, do not expose that API yet.
6. Canonical docs update before implementation. `spec/MVP.md` and the active
   sub-specs must be updated with the intended closure criteria, scope, and
   execution order before code changes for that phase begin.
7. Implementation should not pause for design clarification if the plan already
   specifies a default behavior. When a choice is documented here, it is the
   execution authority unless the user revises the plan.

## Working Definition Of Done

A phase is only complete when all of the following are true:

- the implementation exists on the primary CLI/browser path;
- the relevant `zig build test-*` steps pass locally;
- the new curated WPT/Test262 cases are wired into the runner, not just added
  as loose files;
- any previously stubbed surface covered by that phase has been removed or made
  real;
- docs/spec text for that phase matches what the code actually ships.

For the overall program, this means the spec changes land first, then the code
works toward those written targets.

## Architecture Decisions

The plan assumes the following implementation direction unless explicitly
revised:

### A. Keep AWR's DOM as the source of truth

JS-facing element objects should remain lightweight wrappers over the Zig DOM,
not become a second DOM implementation. Mutation paths may cache JS-side state
for ergonomics, but Zig DOM state remains authoritative for:

- selector queries;
- render input;
- page extraction;
- viewport calculations.

### B. Prefer native bridge hooks for DOM-changing operations

For operations like `innerHTML`, `cloneNode`, and future fragment parsing,
prefer native bridge callbacks into Zig/Lexbor over implementing a separate JS
HTML parser. The JS layer should stay focused on DOM surface semantics, while
tree construction remains in Zig.

This is the selected MVP approach for `innerHTML` and fragment parsing work.

Default implementation shape:

- add a narrow native bridge entry point that accepts:
  - target element handle;
  - HTML fragment string;
  - replacement mode (`replace_children` for `innerHTML`);
- parse the fragment with Lexbor in Zig;
- import the resulting subtree into the authoritative Zig DOM;
- rebuild or refresh the corresponding JS wrappers for the affected subtree;
- emit mutation records for the replaced children.

Do not implement a second HTML parser in JS.

### C. Eventing stays in JS unless Zig needs to observe it

The event listener registry, propagation, and built-in DOM events can live in
the bridge JS layer unless a Zig subsystem needs visibility. MutationObserver,
IntersectionObserver, and ResizeObserver will need a mixed model because Zig
owns mutations and rendering data.

### D. Viewport APIs require render metadata

`ScreenModel` currently tracks rendered text, line boundaries, and links, but
not element-to-rendered-line ownership. Viewport-dependent APIs therefore need
new render metadata, not just bridge changes.

Required new render outputs:

- element handle → rendered line range(s);
- element handle → approximate rendered rect in terminal coordinates;
- a way to recompute those mappings after resize and re-render.

For MVP, "approximate" means terminal-cell-accurate for the renderer AWR
actually ships, not placeholder geometry.

Default metadata model:

- extend `ScreenModel` with an `element_boxes` collection;
- each entry stores:
  - stable DOM element handle/id;
  - `first_line`, `last_line`;
  - `x`, `y`, `width`, `height` in terminal cells;
  - visibility flags derived from the current viewport;
- recompute this metadata on every render pass rather than trying to patch it
  incrementally.

Default geometry semantics:

- block elements occupy the full rendered line span assigned by the renderer;
- inline elements occupy the exact text span emitted by the renderer where
  practical;
- if an inline element wraps across lines, its rect is the union of its wrapped
  line spans for MVP.

### E. Storage remains in-memory for MVP

`localStorage` and `sessionStorage` should be real and spec-like, but in-memory
for the lifetime of the page/session. File-backed persistence is explicitly not
required for MVP closure.

### F. TLS is part of the baseline

TLS compilation and test health are part of Phase 0 baseline closure. The plan
assumes `zig build test` is fully green before Phase 1 runner work begins.

Default fix strategy:

- keep TLS implementation behind the existing C shim boundary;
- replace removed Zig stdlib networking calls with AWR's own TCP layer;
- do not expand TLS scope beyond restoring the existing tested surface.

### G. Network-dependent tests use an explicit gate

Tests that require real outbound network access should not hang or silently rely
on ambient connectivity.

Default policy:

- unit and curated conformance tests must be hermetic by default;
- tests that truly require network access must be explicitly marked and skipped
  unless a network-enabled mode is requested;
- default `zig build test` should remain green in a normal local environment
  without requiring internet access.

### H. History API scope is intentionally narrow in MVP

`window.history` should not be shipped as a misleading browser-wide navigation
stack before the browser/TUI track is ready.

Default MVP scope:

- implement `history.state`, `history.length`, `pushState`, and `replaceState`
  for same-document state updates;
- update `window.location` URL pieces on successful `pushState` /
  `replaceState` calls;
- fire `popstate` only when real history traversal exists;
- do not expose `back`, `forward`, or `go` until they are real.

## Current State

### Documentation gap

The plan currently lives in `.opencode/plans/`, but the canonical execution
docs that developers will actually follow still need to be updated so there is
no drift between planning and implementation:

- `spec/MVP.md`
- `spec/subspecs/mvp-remainder.md`
- new active conformance sub-spec for WPT/Test262 work

No implementation phase should start until those docs reflect this plan's
closure model.

### What's broken

| Step | Status | Root cause |
|---|---|---|
| `test-js` | HANGS | Promise/fetch tests leave unsettled work; no drain in test context |
| `test-page` | HANGS | `drainAll(5_000)` blocks on libxev with no real timer fd in tests |
| `test-net` | HANGS | TCP connect tests block on real network with no timeout |
| `test-tls` | COMPILE FAIL | `std.net` removed in Zig 0.16; BoringSSL `DEFINE_STACK_OF` macros |

### What's passing

`test-dom`, `test-html`, `test-client`, `test-h2`, `test-e2e` — all green.

### What's unwired

- `tests/wpt_runner.zig` (11 curated DOM cases) — not in `build.zig`
- `tests/test262_runner.zig` (7 curated JS cases) — not in `build.zig`

### What's stubbed (must be replaced with real implementations)

These APIs exist in the bridge polyfill as no-ops or broken stubs:

| API | Current behavior | What it must do |
|---|---|---|
| `parentNode`/`parentElement` | Always returns `null` | Return actual parent element |
| `nextSibling`/`previousSibling` | Always returns `null` | Return actual sibling nodes |
| `cloneNode()` | Broken (references out-of-scope `d`) | Deep/shallow clone of element |
| `classList` | Static snapshot from parse time | Live object backed by `class` attribute; mutations update the attribute |
| `innerHTML` setter | Stores string only | Parse HTML fragment, create real child nodes |
| `outerHTML` getter | Naive tag wrapping | Serialize element + children properly |
| `addEventListener`/`removeEventListener` | No-op | Register real listeners with capture/bubble support |
| `dispatchEvent` | Returns `true` | Walk tree: capture → target → bubble; `stopPropagation`, `preventDefault` |
| `MutationObserver` | No-op | Actually observe mutations; deliver `MutationRecord` objects |
| `IntersectionObserver` | No-op | Observe elements; callback fires based on terminal viewport position |
| `ResizeObserver` | No-op | Observe elements; callback fires when rendered width changes |
| `PerformanceObserver` | No-op | Observe performance entries |
| `localStorage`/`sessionStorage` | No-op | In-memory per-session storage with full Web Storage API |
| `XMLHttpRequest` | No-op | Real implementation backed by AWR's HTTP client |
| `requestAnimationFrame` | Returns `0` | Fire callback before each terminal render; return cancelable ID |
| `cancelAnimationFrame` | No-op | Cancel pending rAF callback |
| `requestIdleCallback` | Returns `0` | Fire during idle periods in the event loop |
| `contains()` | Returns `false` | Check DOM tree containment |
| `window.history` | No-op pushState/replaceState | Maintain real history stack (back/forward need TUI, deferred) |

---

## Phase -1 — Canonical Spec Alignment (Blocking)

This phase happens before any code or runner work.

### -1.1 Update `spec/MVP.md`

Make `spec/MVP.md` explicitly state that MVP closure is gated by:

- curated WPT coverage for the browser/runtime surface;
- curated Test262 coverage for the JS runtime surface;
- a fully green default `zig build test` baseline;
- the no-stubs rule for shipped APIs.

The doc should stop reading as "MVP shipped" in a way that bypasses these
gates. It should instead describe the shipped baseline plus the remaining
conformance work required for closure.

### -1.2 Update `spec/subspecs/mvp-remainder.md`

Make it the active execution doc for this effort. It should include, at
minimum:

- the docs-first execution order;
- Phase 0 build stabilization;
- runner wiring;
- DOM bridge truthfulness fixes;
- event system, observers, storage, XHR, viewport work;
- WPT/Test262 corpus growth targets.

### -1.3 Add a dedicated conformance sub-spec

Create an active sub-spec such as `spec/subspecs/wpt-conformance.md` that
defines:

- the curated WPT runner scope and harness expectations;
- the curated Test262 runner scope and inclusion rules;
- corpus targets;
- how new cases are added;
- the verification commands that gate merges.

Required sections for this doc:

1. Purpose and authority
2. Runner architecture
3. WPT corpus definition and inclusion rules
4. Test262 corpus definition and inclusion rules
5. Harness features currently supported
6. Required commands and merge gates
7. Policy for adding, updating, or removing curated cases
8. Mapping from API areas to test files

### -1.4 Reconcile repo guidance docs

Update repo guidance docs that point engineers at execution sources of truth so
they reference the canonical docs above before implementation begins.

At minimum, reconcile references in:

- `AGENTS.md`
- repo-local `CLAUDE.md` / `.claude/CLAUDE.md` guidance files
- any subdirectory agent context files that make execution-scope or status
  claims
- `README.md` where applicable

This includes fixing drift in agent-facing instructions, not just user-facing
documentation. If a Claude/agent context file conflicts with `spec/MVP.md` or
the active sub-specs, it must be updated in the same documentation phase.

### Phase -1 exit criteria

- `spec/MVP.md` reflects WPT/Test262-gated MVP closure
- `spec/subspecs/mvp-remainder.md` reflects the active execution order
- an active conformance sub-spec exists and is referenced from `spec/MVP.md`
- repo guidance docs point to the updated canonical spec set
- agent/Claude guidance files are reconciled with the canonical spec set
- no implementation work has started against stale doc assumptions

---

## Phase 0 — Fix the Build (Blocking)

### 0.1 Fix `test-js` hang

**Problem:** Tests that use `fetch()` or `Promise` without draining leave
pending jobs that prevent the test runner from exiting.

**Fix:** Add explicit `drainMicrotasks()` calls in any test that creates
Promises or calls fetch. Ensure no test creates an unresolved Promise that
would loop forever.

**Verify:** `zig build test-js` exits in <30s with all tests passing.

### 0.2 Fix `test-page` hang

**Problem:** `drainAll(5_000)` in `processHtml` runs a 5-second libxev wait.
When no real timers can fire (test context), `tickOnce` blocks indefinitely.

**Fix:** Use `tickNoWait` instead of `tickOnce` when no real timer backend is
available. Cap the drain loop iterations. Consider a `test_mode` flag on
EventLoop that skips blocking waits.

**Verify:** `zig build test-page` exits in <60s with all tests passing.

### 0.3 Fix `test-net` hang

**Problem:** TCP connect tests in `tcp.zig` block on real outbound connections.

**Fix:** Add connect timeouts. Move any true outbound-connectivity tests behind
an explicit network gate and keep default test execution hermetic.

**Verify:** `zig build test-net` exits in <60s.

### 0.4 Fix `test-tls` compilation

**Problem:** `std.net.tcpConnectToHost` removed in Zig 0.16. BoringSSL
`DEFINE_STACK_OF` macros fail in Zig's C translator.

**Fix:**
- Replace `std.net` calls with libxev-based TCP (via existing `tcp.zig`)
- Isolate BoringSSL behind C shims — never `@cImport` BoringSSL headers
  directly; only import the thin shim functions from `tls_awr_shim.c`

This is not optional cleanup; it is required baseline work before the runner
expansion phases.

**Verify:** `zig build test-tls` compiles and runs.

### Phase 0 exit criteria

```
zig build test-dom     → PASS
zig build test-html    → PASS
zig build test-client  → PASS
zig build test-h2      → PASS
zig build test-e2e     → PASS
zig build test-js      → PASS, no hang
zig build test-page    → PASS, no hang
zig build test-net     → PASS, no hang
zig build test-tls     → PASS, compiles + runs
```

---

## Phase 1 — Wire the Runners

### 1.1 Add `test-wpt` to `build.zig`

Compile `tests/wpt_runner.zig` as a test step. Requires:
- Linking page.zig (→ client, DOM, JS engine, event loop)
- `use_llvm = true` (QuickJS-NG requirement)
- Link lexbor, QuickJS-NG, libc

**Verify:** `zig build test-wpt` runs 11 curated cases, exits clean.

### 1.2 Add `test-test262` to `build.zig`

Compile `tests/test262_runner.zig`. Simpler — only needs the JS engine.

**Verify:** `zig build test-test262` runs 7 curated cases, exits clean.

### 1.3 Promote to default `test`

Add both as dependencies of the top-level `test` step.

### 1.4 Normalize runner conventions

Before the corpus grows, both runners should follow the same conventions:

- one source of truth for the curated case list in each runner;
- deterministic fixture construction with no network dependency;
- clear failure output that prints the test name, failing assertion, and source
  file;
- support for growing the harness without copy/paste across many files.

Default runner shape:

- `tests/wpt_runner.zig` owns a single compile-time list of curated cases;
- each WPT case entry declares:
  - test name;
  - JS file path;
  - HTML fixture string or fixture file path;
  - whether async draining is required;
- `tests/test262_runner.zig` owns a parallel compile-time list of curated JS
  runtime cases;
- both runners print one line per case and a final summary with pass/fail
  counts;
- both runners exit non-zero on the first harness error summary, not by hanging.

Default harness support roadmap:

- initial required WPT harness features:
  `test`, `promise_test`, `assert_equals`, `assert_not_equals`,
  `assert_true`, `assert_false`, `assert_array_equals`, `assert_throws_js`;
- add more harness helpers only when a curated imported case requires them;
- do not bulk-import upstream helper surface preemptively.

### Phase 1 exit criteria

- `zig build test-wpt` exists and runs the curated WPT corpus
- `zig build test-test262` exists and runs the curated Test262 corpus
- `zig build test` depends on both runners
- runner failures identify the failing case and assertion directly

---

## Phase 2 — Fix Existing DOM Bridge Bugs

Primary file targets for this phase:

- `src/dom/bridge.zig`
- `src/dom/node.zig`
- `tests/wpt_runner.zig`
- curated WPT case files under `tests/wpt/`

These are prerequisite to expanding the WPT corpus — existing tests that
exercise these APIs are currently lying because the stubs silently succeed.

### 2.1 Parent and sibling tracking

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

- `parentNode` / `parentElement`: The bridge creates element objects from JSON
  but never sets parent references. When `appendChild`/`insertBefore` runs,
  the JS-side element must record its parent, and that parent must be
  queryable.
- `nextSibling` / `previousSibling`: Must reflect actual sibling order in the
  parent's children list.

Default implementation detail:

- maintain parent pointers in the authoritative Zig DOM;
- JS wrapper getters should derive from that authoritative tree rather than a
  detached JS-only structure.

**WPT tests to add:**
- `element_parentNode.js` — appendChild sets parentNode
- `element_siblings.js` — nextSibling/previousSibling after append/insert/remove

### 2.2 Live classList

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

The current `classList` is a frozen snapshot created at element construction.
It must be a live object where:
- `add()` / `remove()` / `toggle()` mutate the element's `class` attribute
- `contains()` checks the current attribute value
- The `className` getter reflects the same state

Default implementation detail:

- `classList` is a facade over the current `class` attribute value;
- tokenization follows ASCII whitespace splitting for MVP;
- duplicate class tokens are prevented on `add()`.

**WPT tests to add:**
- `element_classList.js` — add, remove, toggle, contains, className sync

### 2.3 innerHTML setter that creates real nodes

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

Setting `innerHTML` must parse the HTML string and create real child nodes
(queryable via `firstChild`, `querySelector`, etc.). The simplest approach:
wrap the fragment in a container div, parse it via the existing Lexbor parser,
and import the resulting nodes into the bridge.

Default behavior details:

- setting `innerHTML` replaces all existing child nodes;
- inserted nodes become immediately visible to selectors, rendering, and
  mutation observers;
- script tags inserted via `innerHTML` are parsed as nodes but not executed as
  a side effect of assignment.

**WPT tests to add:**
- `element_innerHTML_setter.js` — innerHTML setter creates queryable children

### 2.4 cloneNode that actually clones

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

Currently broken — references out-of-scope variable `d`. Must produce a new
element with copied attributes and (for deep clone) recursively copied children.

Default behavior details:

- `cloneNode(false)` copies the node and attributes but no children;
- `cloneNode(true)` copies the full descendant subtree;
- event listeners are not copied;
- cloned nodes start detached with no parent.

**WPT tests to add:**
- `element_cloneNode.js` — cloneNode creates independent copy

### 2.5 contains() that checks containment

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

Must walk the descendant tree and return `true` if the argument is a descendant.

Default behavior details:

- a node contains itself;
- `contains(null)` returns `false`.

**WPT tests to add:**
- `element_contains.js` — contains() returns correct boolean

### 2.6 Remove-or-implement sweep for current bridge surface

Before moving on to events, audit every currently exposed bridge API that is
still stubbed or misleading and either:

- implement it in full if it belongs to Phases 2-3, or
- remove it from the exposed surface until its phase is ready.

This prevents the WPT corpus from silently passing against fake behavior.

### Phase 2 exit criteria

- parent/sibling relationships are correct after all supported mutations
- `classList`, `className`, and `class` attribute stay in sync
- `innerHTML` creates real child nodes that selector queries can see
- `cloneNode` works for shallow and deep clone cases
- `contains()` reflects actual DOM ancestry
- no known misleading bridge APIs remain exposed for this phase's surface area

---

## Phase 3 — Implement Full Event System

Primary file targets for this phase:

- `src/dom/bridge.zig`
- `src/page.zig`
- `tests/wpt_runner.zig`
- curated WPT event cases under `tests/wpt/`

### 3.1 Event target infrastructure

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

Implement a real event listener registry per element. Each element gets:
- `__listeners` map: `{ [type]: [{callback, capture, once}] }`

`addEventListener(type, callback, options)`:
- Store callback with capture flag
- Support `once` option
- Support `AbortSignal` via `options.signal`

`removeEventListener(type, callback, options)`:
- Remove matching listener (same callback + capture)

Default implementation detail:

- listener identity is callback + event type + capture flag;
- duplicate registrations with the same identity are ignored.

### 3.2 Event dispatch with capture and bubble

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

`dispatchEvent(event)`:
1. Build the propagation path: target → parent → ... → document → window
2. **Capture phase:** Walk from window down to target, fire capture listeners
3. **Target phase:** Fire non-capture listeners on target
4. **Bubble phase:** Walk from target up to window, fire non-capture listeners
5. Support `event.stopPropagation()` (stops after current listener)
6. Support `event.stopImmediatePropagation()` (stops within current phase)
7. Support `event.preventDefault()` (sets `defaultPrevented` flag, return false from dispatchEvent)

Default propagation scope for MVP:

- `window` and `document` participate in the propagation path;
- propagation path is derived from the authoritative DOM parent chain;
- exceptions thrown by listeners surface as JS exceptions in the current task
  after listener dispatch completes.

### 3.3 Event constructors

`Event(type, {bubbles, cancelable})`:
- `type`, `bubbles`, `cancelable`, `target`, `currentTarget`
- `eventPhase` (CAPTURING=1, AT_TARGET=2, BUBBLING=3)
- `timeStamp` (performance.now() or Date.now())
- `isTrusted` (false for dispatchEvent, true for browser-initiated — always false for now)

`CustomEvent(type, {detail, bubbles, cancelable})`:
- Extends Event with `detail` property

`MouseEvent`, `KeyboardEvent`, `FocusEvent`, `TouchEvent`:
- Extend Event with type-specific properties

### 3.4 Built-in events

Fire real events at appropriate times:
- `DOMContentLoaded` — after all scripts execute, before drainAll
- `load` — after drainAll completes
- `readystatechange` — document transitions
- `error` — script execution errors, failed fetches

Default lifecycle order for page processing:

1. parse DOM
2. install bridge globals
3. execute document-order scripts
4. fire `DOMContentLoaded`
5. drain microtasks and pending macrotasks
6. fire `load`

### WPT tests to add:
- `event_add_remove.js` — addEventListener + removeEventListener
- `event_dispatch_bubble.js` — dispatchEvent with capture and bubble phases
- `event_stop_propagation.js` — stopPropagation, stopImmediatePropagation
- `event_prevent_default.js` — preventDefault, defaultPrevented
- `event_custom.js` — CustomEvent with detail
- `event_DOMContentLoaded.js` — DOMContentLoaded fires after scripts

### Phase 3 exit criteria

- listeners can be added and removed with matching semantics
- event propagation path is correct for capture, target, and bubble phases
- `dispatchEvent` return value matches `defaultPrevented` semantics
- `stopPropagation` and `stopImmediatePropagation` behave distinctly
- built-in page lifecycle events fire in a predictable order

---

## Phase 4 — Implement MutationObserver

Primary file targets for this phase:

- `src/dom/bridge.zig`
- `src/page.zig` if microtask integration needs adjustment
- `tests/wpt_runner.zig`
- curated WPT observer cases under `tests/wpt/`

### 4.1 Mutation record tracking

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

Every mutation path must be instrumented to record changes:

| Mutation type | Triggered by |
|---|---|
| `childList` | appendChild, insertBefore, removeChild, innerHTML setter |
| `attributes` | setAttribute, removeAttribute, classList mutations |
| `characterData` | textContent setter, innerHTML setter on text nodes |

When a MutationObserver is observing an element, mutations that match the
observed types generate `MutationRecord` objects:
- `type`, `target`, `addedNodes`, `removedNodes`, `previousSibling`, `nextSibling`
- `attributeName`, `attributeNamespace`, `oldValue` (if `attributeOldValue: true`)
- `characterData.oldValue` (if `characterDataOldValue: true`)

### 4.2 Observer lifecycle

- `observe(target, options)` — start watching with {childList, attributes, characterData, subtree, ...}
- `disconnect()` — stop watching, clear pending records
- `takeRecords()` — return pending records and clear queue

Observer callbacks fire as microtasks after the current task completes.

Default delivery detail:

- batch records per observer per task;
- deliver observers in registration order;
- if an observer callback causes more mutations, those queue a later microtask
  batch rather than re-entering the same delivery.

### WPT tests to add:
- `mutation_observer_childList.js` — observe appendChild/removeChild
- `mutation_observer_attributes.js` — observe setAttribute/removeAttribute
- `mutation_observer_subtree.js` — observe deep subtree changes

### Phase 4 exit criteria

- every supported mutation path produces correct `MutationRecord` values
- observer callbacks run as microtasks after the triggering task
- `takeRecords()` drains pending records correctly
- subtree observation works across nested descendants

---

## Phase 5 — Implement Storage

Primary file targets for this phase:

- `src/dom/bridge.zig`
- `tests/wpt_runner.zig`
- curated WPT storage cases under `tests/wpt/`

### 5.1 In-memory Web Storage

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

`localStorage` and `sessionStorage` backed by in-memory `Map`:

Full API:
- `getItem(key)` → string | null
- `setItem(key, value)` → void (throws on quota exceeded)
- `removeItem(key)` → void
- `clear()` → void
- `key(index)` → string | null
- `length` → number

`localStorage` persists for the Page lifetime.
`sessionStorage` is the same instance (both in-memory per session for MVP).

Default quota behavior:

- no artificial tiny quota for MVP;
- only allocator failure should cause quota-like errors unless a real quota is
  added intentionally.

Storage events: When `setItem`/`removeItem`/`clear` is called, fire a
`StorageEvent` on `window` (same-context notification).

### WPT tests to add:
- `storage_localStorage.js` — setItem, getItem, removeItem, clear, length, key

### Phase 5 exit criteria

- `localStorage` and `sessionStorage` expose the full MVP API surface
- storage mutations update `length` and `key(index)` correctly
- same-context storage events fire with correct payloads
- no storage methods silently no-op

---

## Phase 6 — Implement XMLHttpRequest

Primary file targets for this phase:

- `src/dom/bridge.zig`
- `src/page.zig` / JS engine host integration as needed
- `tests/wpt_runner.zig`
- curated WPT XHR cases under `tests/wpt/`

### 6.1 Real XHR backed by AWR's HTTP client

**Files:** `src/dom/bridge.zig` (BRIDGE_POLYFILL)

Implement `XMLHttpRequest` that:
- `open(method, url, async)` — stores method + URL
- `send(body)` — makes real HTTP request via AWR's FetchHost
- `setRequestHeader(name, value)` — stores headers
- `abort()` — cancels request
- Fires events: `readystatechange`, `load`, `error`, `loadend`
- Sets `status`, `statusText`, `responseText`, `responseURL`
- `getAllResponseHeaders()`, `getResponseHeader(name)`

Async XHR uses the event loop (Promise-based internally).

Default MVP XHR scope:

- async requests required;
- text response support required;
- `responseType` advanced modes can remain unexposed until implemented;
- same transport path as `fetch()` to avoid divergent networking behavior.

### WPT tests to add:
- `xhr_basic_get.js` — open + send + readystatechange + responseText

### Phase 6 exit criteria

- XHR can perform a basic async GET successfully
- readyState transitions are observable in order
- response headers and body are accessible after load
- abort and network-error paths do not hang the event loop

---

## Phase 7 — Implement Viewport-Dependent Observers

These depend on the render pipeline (`render.zig` → `ScreenModel`). The
terminal dimensions are the viewport.

### 7.0 Render metadata foundation

Before implementing any viewport observer, extend rendering so each rendered
element can be mapped back to terminal coordinates. `ScreenModel` will need a
new metadata payload beyond text/lines/links.

Minimum required metadata:

- element handle;
- first rendered line;
- last rendered line;
- approximate x/y/width/height in terminal cells;
- invalidation behavior on resize and rerender.

Primary file targets for this phase:

- `src/render.zig`
- `src/page.zig`
- `src/browser.zig`
- `src/tui.zig`
- `src/dom/bridge.zig`
- curated WPT viewport cases under `tests/wpt/`

Without this, `IntersectionObserver`, `ResizeObserver`, and element
`getBoundingClientRect()` will remain guesswork.

### 7.1 Terminal viewport dimensions

Expose real terminal dimensions through `window`:
- `innerWidth` / `innerHeight` — actual terminal columns/rows
- `outerWidth` / `outerHeight` — same as inner for terminal
- `screen.width` / `screen.height` — terminal dimensions
- `devicePixelRatio` — always 1 for terminal
- `window.resize` event — fired when terminal size changes (SIGWINCH)

### 7.2 requestAnimationFrame

Fire callbacks before each render cycle:
- `requestAnimationFrame(callback)` → ID
- Callback receives `DOMHighResTimeStamp`
- `cancelAnimationFrame(id)` cancels
- In CLI mode: fires once after page load (single render)
- In TUI mode: fires on each redraw (scroll, resize)

Default scheduling detail:

- rAF callbacks run before the render pass associated with that frame;
- multiple queued callbacks for the same frame share the same timestamp.

### 7.3 IntersectionObserver

Grounded in the rendered `ScreenModel`:
- `observe(target)` — register element for observation
- `callback(entries)` fires when element's rendered position enters/leaves the visible terminal rows
- `unobserve(target)`, `disconnect()`
- Entry: `{isIntersecting, target, intersectionRatio, boundingClientRect, rootBounds}`

This requires elements to have positions in the ScreenModel (row ranges).
When the user scrolls in TUI mode, intersection changes must be detected.

Default observer model:

- root is the terminal viewport only for MVP;
- threshold array support may be limited to `0` and `1` initially unless the
  full threshold list is implemented in the same slice;
- if partial threshold support is chosen, only the supported threshold API
  surface should be exposed.

### 7.4 ResizeObserver

Observe changes to an element's rendered width:
- `observe(target)` — register element
- `callback(entries)` fires when rendered width changes (e.g., terminal resize)
- Entry: `{target, contentRect: {width, height}}`

Default trigger conditions:

- terminal resize;
- rerender that changes the element's line wrapping footprint.

### WPT tests to add:
- `viewport_dimensions.js` — innerWidth/Height match terminal
- `requestAnimationFrame.js` — rAF fires, returns ID, cancelable
- `intersection_observer.js` — observe() registers, callback fires for visible elements

### Phase 7 exit criteria

- terminal dimensions exposed to JS match actual render dimensions
- rAF callbacks run against real render cycles, not synthetic timers
- viewport observer callbacks are driven by render metadata and scroll/resize
  changes
- `getBoundingClientRect()` returns terminal-backed geometry rather than zeros

---

## Phase 8 — Expand WPT Corpus (Queries + Mutations)

Primary file targets for this phase:

- `tests/wpt_runner.zig`
- `tests/wpt/*.js`
- fixture helpers referenced by the runner

With all bridge bugs fixed (Phase 2), expand the query and mutation test
coverage.

### 8.1 Document queries

| Test file | What it covers |
|---|---|
| `document_body_head.js` | `document.body`, `document.head`, `document.documentElement` |
| `document_createElement.js` | `createElement(tag)`, `tagName`, `nodeType` |
| `document_createTextNode.js` | `createTextNode(text)`, `nodeType`, `textContent`, `data` |
| `document_createDocumentFragment.js` | `createDocumentFragment()`, appendChild, querySelectorAll |
| `document_getElementsBy.js` | `getElementsByClassName`, `getElementsByTagName` |

### 8.2 Element properties

| Test file | What it covers |
|---|---|
| `element_tagName_id_className.js` | `tagName` getter, `id`/`className` getters+setters |
| `element_hasAttribute.js` | `hasAttribute()`, `removeAttribute()` round-trips |
| `element_outerHTML.js` | `outerHTML` getter reflects tag + attributes + children |
| `element_children_childNodes.js` | `children`, `childNodes`, `firstChild`, `lastChild` count |
| `element_dataset.js` | `dataset` getter reads/writes `data-*` attributes |

### 8.3 Selectors

| Test file | What it covers |
|---|---|
| `selector_attribute.js` | `[attr]`, `[attr=value]`, `[attr="quoted"]` |
| `selector_pseudo_not.js` | `:not()` pseudo-class |
| `selector_combinators.js` | `>`, `+`, `~` combinators |
| `selector_universal.js` | `*` universal selector |
| `selector_multi_class.js` | `.foo.bar` multi-class |

### 8.4 DOM mutations

| Test file | What it covers |
|---|---|
| `mutation_create_append.js` | createElement + appendChild → queryable |
| `mutation_setAttribute.js` | setAttribute → getAttribute round-trip |
| `mutation_removeAttribute.js` | removeAttribute → getAttribute returns null |
| `mutation_textContent.js` | textContent setter replaces children |
| `mutation_removeChild.js` | removeChild detaches, parentNode becomes null |
| `mutation_insertBefore.js` | insertBefore positions correctly |
| `mutation_innerHTML_setter.js` | innerHTML setter creates real child nodes |

---

## Phase 9 — Expand WPT Corpus (Window + Browser APIs)

Primary file targets for this phase:

- `tests/wpt_runner.zig`
- `tests/wpt/*.js`

### 9.1 Window and navigator

| Test file | What it covers |
|---|---|
| `window_navigator.js` | `navigator.userAgent`, `.language`, `.platform`, `.cookieEnabled` |
| `window_location.js` | `location.href`, `.pathname`, `.hostname`, `.protocol`, `.origin`, `.search` |
| `window_screen.js` | `screen.width`/`.height`, `innerWidth`/`innerHeight` match terminal |
| `window_event_types.js` | `Event`, `CustomEvent` constructors with correct properties |
| `window_history.js` | `history.length`, `pushState`, `replaceState`, `state` |

### 9.2 Console and async

| Test file | What it covers |
|---|---|
| `console_namespace.js` | console.log/warn/error exist and produce output | EXISTS |
| `promise_test_basics.js` | Promise.resolve, await | EXISTS |
| `promise_chaining.js` | .then chains, .catch, .finally |
| `promise_async_functions.js` | async/await syntax in tests |
| `setTimeout_basic.js` | setTimeout fires callback (requires event loop) |
| `fetch_basic.js` | fetch() returns Promise with Response shape (text(), json()) |

---

## Phase 10 — Expand Test262 Corpus

The current 7 cases cover basic ES6+ syntax. Target: ~30 cases.

### Already exists (7)
- let/const block scoping, arrow functions, destructuring, template literals,
  classes/methods, optional chaining, promise drain

### New cases to add (~23)

| Test file | What it covers |
|---|---|
| `spread_rest.js` | spread operator, rest parameters |
| `for_of.js` | for...of loops, iterators |
| `symbol_basic.js` | Symbol(), Symbol.for(), Symbol.keyFor() |
| `map_set.js` | Map, Set basic operations (set, get, has, delete, size, iteration) |
| `proxy_reflect.js` | Proxy trap basics (get, set, has) |
| `generators.js` | function*, yield, yield*, generator protocol |
| `async_await.js` | async functions, await, try/catch with async |
| `promise_all_race.js` | Promise.all, Promise.race, Promise.allSettled, Promise.any |
| `object_entries.js` | Object.entries, Object.values, Object.keys, Object.fromEntries |
| `array_methods.js` | Array.from, .flat, .flatMap, .find, .findIndex, .includes |
| `string_methods.js` | padStart, padEnd, repeat, startsWith, endsWith, includes |
| `default_parameters.js` | default parameter values, destructured defaults |
| `error_subtypes.js` | TypeError, RangeError, SyntaxError hierarchy and properties |
| `date_basic.js` | Date constructor, now(), toISOString(), getTime() |
| `typed_arrays.js` | Uint8Array, Float64Array basic operations, .set(), .subarray() |
| `text_encoder.js` | TextEncoder.encode(), TextDecoder.decode() |
| `globalThis.js` | globalThis exists, globalThis === window |
| `well_known_symbols.js` | Symbol.iterator, Symbol.toPrimitive, Symbol.toStringTag |
| `weak_ref.js` | WeakRef, FinalizationRegistry basics |
| `bigint.js` | BigInt constructor, arithmetic, mixed type errors |
| `nullish_coalescing_assignment.js` | ??=, ||=, &&= |
| `top_level_await.js` | top-level await in modules (if supported) |
| `import_meta.js` | import.meta existence and shape |

### 10.1 Test262 inclusion rule

Only include curated Test262 cases that exercise language/runtime behavior AWR
depends on for real page execution. The goal is not breadth for its own sake,
but regression protection for the embedded JS runtime and bridge assumptions.

Primary file targets for this phase:

- `tests/test262_runner.zig`
- curated JS cases referenced by that runner

### Phase 10 exit criteria

- curated Test262 corpus reaches roughly 30 meaningful cases
- every case runs under the repo's `test-test262` step
- failures isolate language/runtime regressions independently from DOM issues

---

## Phase 11 — Update Specs

### 11.1 Rewrite `spec/MVP.md` closure criteria

Replace "shipped" status with concrete pass-rate targets:

```
MVP closure requires:
- zig build test-wpt passes all curated cases (target: ~50)
- zig build test-test262 passes all curated cases (target: ~30)
- zig build test exits clean (no hangs, no compile failures)
- All APIs are fully implemented — zero stubs in the bridge polyfill
```

### 11.2 Update `AGENTS.md`

Add `zig build test-wpt` and `zig build test-test262` to the build/verify
commands. Update WPT-first guidance with corpus targets and the no-stubs rule.

### 11.3 Create `spec/subspecs/wpt-conformance.md`

Active sub-spec documenting:
- Every curated test case with expected behavior
- testharness_shim API surface
- Process for adding new cases
- Target pass rates
- API implementation status (what's real vs. what's excluded)

These documentation tasks are expected to begin in Phase -1, then receive
maintenance updates as implementation proceeds.

Required final documentation state:

- `spec/MVP.md` is the canonical closure doc;
- `spec/subspecs/mvp-remainder.md` is the active implementation track doc;
- `spec/subspecs/wpt-conformance.md` is the authoritative conformance/runners
  doc;
- `AGENTS.md`, `CLAUDE.md`, and related agent context files make no conflicting
  status or scope claims.

---

## Execution Order

```
Phase -1: Canonical spec alignment
  -1.1 Update spec/MVP.md
  -1.2 Update spec/subspecs/mvp-remainder.md
  -1.3 Add spec/subspecs/wpt-conformance.md
  -1.4 Reconcile AGENTS.md / README.md references
  → Exit: canonical docs updated before code work begins

Phase 0: Fix the build (blocking)
  0.1 Fix test-js hang
  0.2 Fix test-page hang
  0.3 Fix test-net hang
  0.4 Fix test-tls compilation
  → Exit: zig build test exits clean

Phase 1: Wire the runners
  1.1 Add test-wpt to build.zig
  1.2 Add test-test262 to build.zig
  1.3 Promote to default test
  → Exit: zig build test-wpt, test-test262 run green

Phase 2: Fix existing DOM bridge bugs
  2.1 Parent and sibling tracking
  2.2 Live classList
  2.3 innerHTML setter
  2.4 cloneNode
  2.5 contains()
  → Exit: existing + new WPT cases pass

Phase 3: Full event system
  3.1 Event listener registry
  3.2 Dispatch with capture/bubble
  3.3 Event constructors
  3.4 Built-in events (DOMContentLoaded, load)
  → Exit: event WPT cases pass

Phase 4: MutationObserver
  4.1 Mutation record tracking
  4.2 Observer lifecycle
  → Exit: mutation WPT cases pass

Phase 5: Storage
  5.1 In-memory Web Storage
  → Exit: storage WPT cases pass

Phase 6: XMLHttpRequest
  6.1 Real XHR backed by HTTP client
  → Exit: XHR WPT cases pass

Phase 7: Viewport-dependent observers
  7.0 Render metadata foundation
  7.1 Terminal viewport dimensions
  7.2 requestAnimationFrame
  7.3 IntersectionObserver
  7.4 ResizeObserver
  → Exit: viewport WPT cases pass

Phase 8: Expand WPT corpus (queries + mutations)
  → Exit: ~50 total WPT cases pass

Phase 9: Expand WPT corpus (window + browser APIs)
  → Exit: all WPT cases pass

Phase 10: Expand Test262 corpus
  → Exit: ~30 total Test262 cases pass

Phase 11: Update specs
  → Exit: docs reflect reality
```

## First 12 Execution Slices

These are the default landing slices after plan approval.

1. Phase -1 doc alignment across `spec/MVP.md`, `mvp-remainder`,
   `wpt-conformance`, `AGENTS.md`, and Claude context files.
2. Fix `test-js` non-terminating behavior.
3. Fix `test-page` non-terminating behavior.
4. Fix `test-net` timeout behavior and network gating.
5. Restore `test-tls` compilation behind shim boundaries.
6. Wire `test-wpt` into `build.zig`.
7. Wire `test-test262` into `build.zig` and promote both runners to default
   `test`.
8. Fix parent/sibling truthfulness and add corresponding WPT cases.
9. Fix live `classList` and add corresponding WPT cases.
10. Implement Lexbor-backed `innerHTML` replacement and add WPT cases.
11. Fix `cloneNode` and `contains()` and add WPT cases.
12. Implement core event dispatch and lifecycle events with WPT coverage.

Implementation should continue in this order unless a later slice is needed to
unblock the current one.

## Milestone Matrix

This matrix is the intended landing order for implementation work after the
plan is approved.

| Milestone | Scope | Must stay green |
|---|---|---|
| M0 | Phase -1 canonical doc alignment | spec review |
| M1 | Phase 0 build stabilization | `zig build test` |
| M2 | Phase 1 runner wiring | `zig build test`, `test-wpt`, `test-test262` |
| M3 | Phase 2 bridge truthfulness fixes | `zig build test-dom`, `test-page`, `test-wpt` |
| M4 | Phase 3 event system | `zig build test-page`, `test-wpt` |
| M5 | Phase 4 mutation observer | `zig build test-page`, `test-wpt` |
| M6 | Phases 5-6 storage + XHR | `zig build test-page`, `test-wpt`, `test-e2e` |
| M7 | Phase 7 viewport APIs | `zig build test-page`, `test-wpt`, browser/TUI checks |
| M8 | Phases 8-10 corpus growth | full `zig build test` |
| M9 | Phase 11 doc closure | full `zig build test` + spec review |

## Verification Matrix

| Concern | Primary command | Secondary evidence |
|---|---|---|
| DOM selectors/mutations | `zig build test-dom` | curated WPT DOM cases |
| JS runtime semantics | `zig build test-test262` | `zig build test-js` |
| Page lifecycle / bridge | `zig build test-page` | curated WPT page cases |
| HTTP client / fetch / XHR | `zig build test-client` | `zig build test-e2e`, WPT fetch/XHR cases |
| Event loop determinism | `zig build test-js` | `zig build test-page` |
| Viewport-backed APIs | browser/TUI targeted checks | curated viewport WPT cases |

## Open Decisions

These decisions are now fixed for MVP execution:

1. `innerHTML` parsing path:
   use a native Zig/Lexbor bridge callback.
2. TLS test scope on Zig 0.16:
   fix in Phase 0 and keep the default `zig build test` baseline fully green.
3. Viewport geometry fidelity:
   use terminal-cell-accurate geometry for `getBoundingClientRect()` and
   viewport-observer calculations.

## What's NOT In Scope

- Full upstream WPT suite (~100K+ tests) — curated subset only
- CSS rendering engine — AWR renders to terminal text, not pixels
- Shadow DOM, Web Components
- WebAssembly
- Service Workers, Web Workers
- WebGL, Canvas 2D (terminal has no pixel surface)
- Drag and drop
- File API (beyond file:// script loading)
- WebSocket (defer until HTTP client is more mature)
- WebRTC, media APIs
- BrowserAudit, Speedometer, JetStream benchmarks

## Key Risks

1. **Phase 0 hangs are the critical path.** Every subsequent phase depends on a
   deterministic test runner. If `drainAll` can't be fixed, all `promise_test`
   WPT cases will hang.

2. **Event dispatch requires parent tracking.** Phases 2 and 3 are coupled —
   capture/bubble requires walking the tree, which requires correct parent
   pointers. Fix parent tracking first.

3. **innerHTML setter needs HTML parsing in JS context.** The simplest approach
   is calling back into Lexbor via a new native callback, but this adds a C
   dependency to the bridge. Alternative: implement a minimal HTML parser in
   JS. Decision needed.

4. **Viewport-dependent observers need render integration.** IntersectionObserver
   requires knowing which ScreenModel lines correspond to which elements. This
   needs a mapping from DOM elements to rendered line ranges — new
   infrastructure in `render.zig`.

5. **testharness_shim fidelity.** As the corpus grows, the shim may need
   `setup()`, `step_func()`, `promise_rejects()`, `assert_throws_dom()`,
   `assert_array_approx_equals()`, etc.
