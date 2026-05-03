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
- request integration (GET and POST) — `fetch()` and `XMLHttpRequest`;
- form submission (GET and POST) — `<form>` parse, render, and submit;
- cookie persistence across simulated process restart;
- same-origin history subset;
- terminal-backed geometry and viewport APIs.

The form-submission and cookie-persistence rows are governed by
`spec/subspecs/agent-browser.md`; they remain inside this conformance file's
inclusion rules and merge gates.

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
zig build test-doc
```

Subsystem-specific checks remain useful, but these four are the minimum
conformance gates for this track.

Rules:

1. `zig build test` must stay green on the default developer path.
2. `zig build test-wpt` must stay green.
3. `zig build test-test262` must stay green.
4. tests that require real outbound network access must be explicitly gated and
   must not make the default test path hang or fail due to missing connectivity.
5. `zig build test-doc` must stay green; §8 must mirror `curated_cases` at all
   times. Any change to either runner's `curated_cases` array must also update
   §8 in the same commit, or `zig build test-doc` will fail CI.

---

## 7. Policy for adding, updating, or removing curated cases

When adding a new curated case:

1. add the case to the runner's compile-time case list;
2. add the fixture and expected assertions;
3. ensure the case fails before the implementation and passes after it;
4. update this spec if a new API area or harness feature is being introduced;
5. update §8 in the same change — append the case to the matching `§8a` row
   (active) or add it to `§8b` (deferred) with a blocking-gap note, and bump
   the §8 header-note WPT/Test262 counts and date so the doc mirrors the
   `curated_cases` arrays. This is the conventional pre-closure contract
   defined in `specs/wpt-conformance-doc-hygiene/spec.md §6`.

Do not add speculative cases for surfaces that are still intentionally deferred.

Removing a curated case requires documenting why the behavior left MVP scope or
why the case was invalid.

---

## 8. Mapping from API areas to test files

> **Current status (as of 2026-05-01):** 91 active curated WPT cases pass via
> `zig build test-wpt`. 46 Test262 cases pass via `zig build test-test262`.
> All `spec/subspecs/agent-browser.md §4` closure-gate cases are active.
> Only one form/cookie row remains deferred — see §8b.

### §8a. Active curated cases

| Area | Active curated cases |
|---|---|
| DOM queries | `document_title.js`, `document_title_location.js`, `document_title_create_missing.js`, `document_getElementById.js`, `document_dynamic_getElementById.js`, `document_querySelector.js`, `document_querySelectorAll.js`, `document_getElementsBy.js`, `document_body_head.js`, `document_readyState.js`, `document_createElement.js`, `document_documentElement.js`, `document_visibility.js` |
| Selector semantics | `descendant_selectors.js`, `element_scoped_selectors.js`, `element_matches_attribute_selectors.js`, `element_querySelectorAll_array.js`, `selector_combinators.js` |
| DOM mutation | `element_innerHTML_setter.js`, `element_cloneNode.js`, `element_appendChild_dynamic.js`, `element_insertBefore.js`, `element_removeChild.js`, `element_createElement_chain.js`, `element_createElement_case.js` |
| Element attributes | `element_getAttribute_textContent.js`, `element_hasAttribute.js`, `element_id_className.js`, `element_classList.js`, `element_outerHTML.js`, `element_dom_getters_authoritative.js`, `element_setAttribute_basic.js`, `element_dataset.js`, `element_textContent_setter.js`, `element_classList_toggle_returns.js` |
| DOM relationships | `element_parentNode.js`, `element_siblings.js`, `element_contains.js`, `element_matches_closest.js`, `element_contains_relations.js`, `element_wrapper_identity.js` |
| Element interaction | `element_click_focus_blur.js`, `element_bounding_client_rect.js`, `element_click_listener.js` |
| Events | `event_add_remove.js`, `event_dispatch_bubble.js`, `event_custom.js`, `event_DOMContentLoaded.js`, `event_prevent_default.js`, `event_stop_propagation.js`, `event_properties.js`, `event_target_currentTarget.js`, `event_dispatchEvent_returns.js`, `event_constructors_alias.js`, `event_listener_options.js` |
| MutationObserver | `mutation_observer_childList.js`, `mutation_observer_attributes.js`, `mutation_observer_subtree.js`, `mutation_observer_takeRecords.js`, `mutation_observer_reflected_attributes.js`, `mutation_observer_characterData.js` |
| Storage | `storage_localStorage.js`, `session_storage_distinct.js`, `storage_event_payload.js` |
| XHR (GET + POST) | `xhr_basic_get.js`, `xhr_post_basic.js`, `xhr_post_form_encoded.js`, `xhr_rejects_unsupported.js` |
| `fetch()` (GET + POST) | `fetch_basic.js`, `fetch_post_basic.js`, `fetch_post_form_encoded.js`, `fetch_rejects_unsupported.js` |
| Forms (DOM) | `form_input_value_type.js`, `form_textarea_value.js`, `form_document_forms.js`, `form_button_select.js`, `form_method_post.js` |
| History | `history_push_replace_state.js`, `history_relative_url.js`, `history_state_length.js` |
| Viewport / observers | `viewport_dimensions.js`, `requestAnimationFrame.js`, `request_idle_callback.js`, `request_idle_callback_cancel.js`, `intersection_observer.js`, `resize_observer.js`, `window_basics.js` |
| Window / navigator | `navigator_basics.js`, `url_search_params_basics.js` |
| Harness / misc | `promise_test_basics.js`, `console_namespace.js` |
| JS runtime | 46 curated Test262 cases in `tests/test262_runner.zig` |

POST round-trip cases (`fetch_post_basic.js`, `fetch_post_form_encoded.js`,
`xhr_post_basic.js`, `xhr_post_form_encoded.js`) use an in-process echo server
(`EchoServer` in `tests/wpt_runner.zig`) that listens on `127.0.0.1:18488` and
returns `{METHOD}|{BODY}` for any request. The echo server is started once
before the test loop and shut down after.

`URLSearchParams` is provided by a polyfill installed at JS engine boot
(`src/js/url_search_params.js`, wired in `src/js/engine.zig`) — QuickJS-NG
does not ship URLSearchParams natively. The polyfill is required by the
`*_form_encoded` cases and by `spec/subspecs/agent-browser.md §2`.

`<form method="post">` end-to-end submission (parse → DOM ancestry walk →
URL-encoded body assembly with hidden-input CSRF round-trip → wire-level POST
through `Page.navigatePost`) is covered by the Zig integration test
`<form method=post> end-to-end submits hidden + edited fields to wire` in
`src/page.zig`. This complements `form_method_post.js` (DOM-side parse
coverage) and together they prove the full pipe per
`spec/subspecs/agent-browser.md §4` last paragraph.

### §8b. Deferred cases

The following case is intentionally absent from `tests/wpt/` and unregistered
in `curated_cases` because it depends on a runtime feature outside MVP scope.

| Test file | Blocking gap |
|---|---|
| `cookies_persistence_roundtrip.js` (not yet written) | Requires either `document.cookie` (not in MVP) or a harness-only binding; the cookie-jar serialize/deserialize/expiry/HttpOnly_ contract is exercised today by inline Zig tests in `src/net/cookie.zig` per `spec/subspecs/agent-browser.md §4` last row. |

When the blocking gap is resolved, write the case file, register it in
`curated_cases`, and verify `zig build test-wpt` stays green.

This mapping is the intended closure surface for the shipped MVP.
