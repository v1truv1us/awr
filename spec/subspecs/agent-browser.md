# Agent-Browser — closure record

> **Status:** CLOSED FOR CURRENT MVP SURFACE (per ADR 2026-04-28)
> `spec/MVP.md` is the canonical umbrella spec. This file is the authority for
> the agent-browser scope and its WPT/Test262 closure gates. Sits alongside
> `spec/subspecs/wpt-conformance.md`, which remains the corpus and runner
> authority.

---

## 1. Purpose and authority

This sub-spec defines the **agent-usable browser** surface AWR ships beyond the
GET-only browser-runtime MVP. It governs four behaviors:

1. `fetch()` POST requests with a string or `URLSearchParams` body;
2. `XMLHttpRequest` POST requests with a string or `URLSearchParams` body;
3. `<form method="post">` submission honored end-to-end through the TUI
   (`awr browse`) and the page pipeline;
4. cookie jar disk persistence so logged-in state survives process restart.

If scope changes, update this file in the same change as `spec/MVP.md` per
`spec/MVP.md §8`.

---

## 2. In scope

The agent-browser surface ships:

- `fetch(url, init)` accepting `init.method ∈ {"GET","POST"}` and `init.body`
  as a string or a `URLSearchParams` instance whose `.toString()` produces an
  `application/x-www-form-urlencoded` body.
- `XMLHttpRequest` accepting `xhr.open("POST", url)` and `xhr.send(body)`
  where `body` is a string or `URLSearchParams`. Async-only.
- `<form method="post" action="...">` submitted through `awr browse`:
  - method extracted from the parent `<form>` element on render;
  - action resolved against the current page URL;
  - hidden-input `value` attributes included in the encoded body when the user
    did not edit the field (CSRF-token round-trip);
  - URL-encoded payload sent with `Content-Type:
    application/x-www-form-urlencoded`.
- Cookie jar disk persistence:
  - **Format:** Netscape `cookies.txt` (curl/wget compatible).
  - **Path resolution order:** `$AWR_COOKIE_JAR` if set, else
    `$XDG_STATE_HOME/awr/cookies.txt`, else `$HOME/.local/state/awr/cookies.txt`.
  - **Activation:** opt-in by env var presence. Not enabled by default. No
    CLI flag is required.
  - **File mode:** `0600`.
  - **Lifecycle:** loaded on `Client.init`, written on `Client.deinit`. Errors
    are non-fatal (offline-first).
  - **Skipped on save:** session cookies (`expires == null`) and expired
    cookies.

All four behaviors close under WPT-gated correctness per
`spec/subspecs/wpt-conformance.md` and the `spec/MVP.md §6` no-stubs rule.

---

## 3. Out of scope

These are intentionally not in this sub-spec's closure surface and remain
deferred or rejected:

- `multipart/form-data` POST bodies.
- Streamed request bodies (`ReadableStream`, chunked uploads).
- `xhr.setRequestHeader()` and arbitrary custom request headers from JS;
  the polyfill continues to throw on these.
- `IntersectionObserver` / `ResizeObserver` (per `spec/MVP.md §5.6`).
- Full browser-history traversal beyond `pushState` / `replaceState`
  (per `spec/MVP.md §5.5`).
- `<button formmethod>` / `<button formaction>` submission overrides.
- Concurrent multi-process cookie-jar writes; only one `awr` process at a
  time should own the configured jar path.
- HTTP/2 POST in the handwritten `src/net/h2session.zig`. JS `fetch()` rides
  `std.http.Client`, which negotiates h2 and serializes request bodies
  internally. The handwritten H2 path is exercised only by fingerprint tests
  today; POST support there is a deferred follow-on.
- Persisted HTTP cache layers (etag / Cache-Control). Cookies persist; bodies
  do not.

---

## 4. Curated WPT case requirements

Per `spec/subspecs/wpt-conformance.md §7`, every behavior in §2 lands with at
least one curated WPT case that fails before implementation and passes after.

Required cases:

| Behavior | Curated case file | Notes |
|---|---|---|
| `fetch()` POST with string body | `tests/wpt/fetch_post_basic.js` | Round-trips through an in-process echo server |
| `fetch()` POST with `URLSearchParams` body | `tests/wpt/fetch_post_form_encoded.js` | Asserts `application/x-www-form-urlencoded` payload |
| XHR POST with string body | `tests/wpt/xhr_post_basic.js` | Replaces the prior `xhr_rejects_unsupported.js` |
| XHR POST with `URLSearchParams` body | `tests/wpt/xhr_post_form_encoded.js` | New |
| `<form method="post">` parse + submit | `tests/wpt/form_method_post.js` | DOM-level: parsed `form.method === "POST"` |
| Cookie jar serialize/deserialize | inline tests in `src/net/cookie.zig` | A WPT case requires either `document.cookie` (not in MVP) or a harness-only binding; deferred until one of those lands. The Zig-side round-trip + expiry-drop + malformed-row tolerance + HttpOnly_ prefix tests are the current contract. |

The previously curated cases `tests/wpt/xhr_rejects_unsupported.js` and
`tests/wpt/fetch_rejects_unsupported.js` are amended (not removed): the
POST-rejection assertions are dropped; rejection assertions for genuinely
out-of-scope inputs (`init.headers`, `init.credentials`,
`xhr.setRequestHeader`) remain.

A Zig-side integration test (`tests/browser_form_post_test.zig` or equivalent)
backs `<form method="post">` submission end-to-end against an in-process
`std.http.Server`. This complements the JS-level WPT case — together they
prove the full pipe.

---

## 5. Closure gates

The agent-browser surface is closed when all of the following are true:

1. `zig build test` is green on the default developer path.
2. `zig build test-wpt` is green and includes every case listed in §4.
3. `zig build test-tls` is green; the JA4 fingerprint is unchanged from the
   pre-amendment baseline (POST adds a body, not a handshake).
4. `zig build test-h2` is green; the HTTP/2 SETTINGS frame is unchanged.
5. Each behavior in §2 is real per `spec/MVP.md §6` no-stubs rule. Stubs that
   merely log or no-op are not acceptable.
6. `spec/MVP.md §5` is consistent with this sub-spec; the GET-only narrowing
   is amended in the same change set as the first agent-browser code lands.

---

## 6. Risks and constraints

- **TLS fingerprint discipline** (per `spec/MVP.md §3` and AGENTS.md §`src/net/`).
  Adding POST does not perturb ClientHello. SETTINGS frame is connection-level
  and emitted before any stream. Verify with `zig build test-tls && zig build
  test-h2` on every code-touching session.
- **Header order** is load-bearing. Do not sort, dedupe, or reorder headers
  when adding `Content-Type` or `Content-Length` for POST. Append at the
  position the browser fingerprint expects.
- **Cookie file permissions** must be `0600`. Auth tokens may be stored.
- **Body lifetime across the JS↔Zig boundary**: JS strings must be copied into
  a Zig allocator before async work and freed in the response path. Mirror
  `src/js/engine.zig:419`.
- **Backwards compatibility**: `Client.fetch(url)` and `FetchHost.fetch(url)`
  continue to exist as backwards-compat wrappers calling new `Request`-shaped
  entries with method=GET. Existing callers in `src/test_e2e.zig`,
  `src/page.zig`, and elsewhere remain unmodified.

---

## 7. Landing order (informational)

The closure order is documented for reviewer convenience; future amendments
need not preserve it:

1. spec amendment (this file + `spec/MVP.md` + `spec/subspecs/*.md` + ADR);
2. cookie persistence (`Client`, `cookie.zig`, `cookie_path.zig`);
3. `fetch()` POST (`engine.zig`, `client.zig`, `page.zig`);
4. `XMLHttpRequest` POST (`bridge.zig`);
5. `<form method="post">` (`render.zig`, `browser.zig`, `page.zig`).

Each step lands with its curated WPT case(s) per §4 and runs the §5 gates.
