# WPT/Test262 conformance — closure authority

> **Status:** CLOSED FOR CURRENT MVP SURFACE
> `spec/MVP.md` is the canonical umbrella spec.
> This file is the authority for curated conformance runners, corpus scope, and
> merge gates.

---

## 1. Purpose and authority

This sub-spec defines how AWR proves browser-runtime correctness for the closed
current MVP surface.

It covers:

- the curated WPT runner;
- the curated Test262 runner;
- inclusion rules for both corpora;
- harness support expectations;
- the commands that gate merges and MVP closure.

If conformance scope changes, update this file in the same change.

---

## 2. Runner architecture

### WPT runner

`tests/wpt_runner.zig` is the single runner for curated browser/runtime WPT
cases.

Default structure:

- one compile-time curated case list;
- each case declares:
  - case name;
  - JS file path;
  - HTML fixture string or file path;
  - whether async drain behavior is required.

The runner must:

- execute deterministically;
- avoid ambient network dependency;
- print case-level pass/fail output;
- exit non-zero on failure without hanging.

### Test262 runner

`tests/test262_runner.zig` is the single runner for curated embedded-JS
language/runtime cases.

Default structure:

- one compile-time curated case list;
- deterministic execution;
- case-level pass/fail output;
- no dependency on DOM or network behavior unless the case is intentionally
  about that runtime integration boundary.

---

## 3. WPT corpus definition and inclusion rules

The curated WPT corpus exists to validate the browser/runtime surface AWR
actually intends to ship for MVP.

Include a WPT case only when it:

1. validates real shipped behavior on the CLI/browser path;
2. would fail without the implementation being added or fixed;
3. is deterministic in the repo's supported test environment;
4. does not require upstream browser subsystems that AWR does not claim to ship
   for MVP.

Target MVP WPT areas:

- document and element queries;
- DOM mutation behavior;
- event dispatch and lifecycle behavior;
- mutation observation;
- storage;
- GET-only XHR/fetch integration;
- same-origin history subset;
- terminal-backed geometry and viewport APIs.

The curated WPT corpus should cover the shipped MVP surface and reject or omit
APIs that are intentionally outside it.

---

## 4. Test262 corpus definition and inclusion rules

The curated Test262 corpus exists to validate embedded JS runtime behavior that
real page execution depends on.

Include a Test262 case only when it:

1. validates language/runtime behavior used by pages, bridge code, or conformance
   harnesses;
2. isolates JS runtime regressions independently from DOM concerns;
3. runs deterministically in the embedded QuickJS-based runtime.

The curated Test262 corpus should cover the embedded JS runtime behavior that the
shipped MVP surface depends on.

---

## 5. Harness features currently supported

The WPT harness shim should stay intentionally narrow.

Required initial support:

- `test`
- `promise_test`
- `assert_equals`
- `assert_not_equals`
- `assert_true`
- `assert_false`
- `assert_array_equals`
- `assert_throws_js`

Add additional helpers only when a curated imported case requires them.
Do not bulk-import unused harness surface.

---

## 6. Required commands and merge gates

The default merge and MVP-closure commands are:

```bash
zig build test
zig build test-wpt
zig build test-test262
```

Subsystem-specific checks remain useful, but these three are the minimum
conformance gates for this track.

Rules:

1. `zig build test` must stay green on the default developer path.
2. `zig build test-wpt` must stay green.
3. `zig build test-test262` must stay green.
4. tests that require real outbound network access must be explicitly gated and
   must not make the default test path hang or fail due to missing connectivity.

---

## 7. Policy for adding, updating, or removing curated cases

When adding a new curated case:

1. add the case to the runner's compile-time case list;
2. add the fixture and expected assertions;
3. ensure the case fails before the implementation and passes after it;
4. update this spec if a new API area or harness feature is being introduced.

Do not add speculative cases for surfaces that are still intentionally deferred.

Removing a curated case requires documenting why the behavior left MVP scope or
why the case was invalid.

---

## 8. Mapping from API areas to test files

The exact file list may grow, but these areas define the intended MVP conformance
surface:

| Area | Representative curated cases |
|---|---|
| DOM queries | `document_title.js`, `document_querySelector.js`, `document_querySelectorAll.js` |
| Selector semantics | descendant selectors, attribute selectors, combinators, `:not`, multi-class |
| DOM mutation | `mutation_create_append.js`, `mutation_innerHTML_setter.js`, `mutation_removeChild.js` |
| DOM relationships | `element_parentNode.js`, `element_siblings.js`, `element_contains.js`, `element_cloneNode.js` |
| Events | `event_add_remove.js`, `event_dispatch_bubble.js`, `event_custom.js`, `event_DOMContentLoaded.js` |
| MutationObserver | `mutation_observer_childList.js`, `mutation_observer_attributes.js`, `mutation_observer_subtree.js` |
| Storage | `storage_localStorage.js` |
| GET-only XHR/fetch | `xhr_basic_get.js`, `xhr_rejects_unsupported.js`, `fetch_basic.js`, `fetch_rejects_unsupported.js` |
| History subset | `history_push_replace_state.js`, `history_relative_url.js` |
| Viewport APIs | `viewport_dimensions.js`, `requestAnimationFrame.js`, `element_bounding_client_rect.js` |
| JS runtime | curated Test262 cases in `tests/test262_runner.zig` |

This mapping is the intended closure surface for the shipped MVP.
