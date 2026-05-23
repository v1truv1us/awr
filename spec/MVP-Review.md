# AWR MVP Review — 2026-05-19

> **Purpose:** Candid readiness review against the tier ladder defined in
> `spec/subspecs/browser-roadmap.md` and the closure gates in `spec/MVP.md`.
> Not a planning doc — a snapshot assessment. Update when the state changes.

---

## 1. What's Done

### Phases and Tiers

**Phase 1 — Basic HTTP** (complete)
HTTP/1.1 request/response, URL parsing, RFC 6265 cookie jar, TCP via libxev,
connection pooling, and the foundational networking stack. All Phase 1 exit
criteria met; the JA4 fingerprint string (`t13d1512h1_8daaf6152771_07d4c546ea27`)
verified by automated test against `tls.peet.ws/api/all`.

**Phase 2 — Headless Page Runtime** (complete, 410/410 tests passing)
Full fetch → parse → DOM → JS pipeline. Lexbor HTML parsing, DOM tree in Zig,
QuickJS-NG JS engine, `document.querySelector` / `getElementById`, inline
`<script>` execution, `console.*`, `window.__awrData__`, `PageResult` envelope.
Baseline agent commands (`awr <url>`, `awr extract`, `awr tools`, `awr call`,
`awr mock`) ship and are exercised by integration tests.

**Phase 3 — BoringSSL TLS Vendoring** (complete)
Pre-built BoringSSL static libs in `third_party/boringssl/`. The `tls_awr_shim.c`
C bridge is live. `boringssl_fallback` conditional in `client.zig` routes
macOS/arm64 traffic through the BoringSSL path, with `BoringSslPool` keeping
TCP+TLS connections alive across requests (Chrome-limit constants: 6/origin,
100 req/conn, 30 s idle). The Chrome 132 JA4 fingerprint is verified by
automated TLS tests.

**Known client.zig fixes committed:**
- redirect use-after-free (body buffer freed before redirect follow)
- `HttpHeadersOversize` resolved by setting `read_buffer_size = 64 KB`
- HTTPS URL heap-allocated before redirect to prevent dangling pointer

**Tier 0 — Agent Runtime Baseline** (CLOSED)
WPT runner (`zig build test-wpt`), Test262 runner (`zig build test-test262`),
curated conformance corpus, no-stubs rule enforced. Agent-browser scope closed:
`fetch()` + `XMLHttpRequest` POST, `<form method="post">` end-to-end,
cookie jar disk persistence via `$AWR_COOKIE_JAR` in Netscape format.

**Tier 1 — Interactive TUI Parity** (CLOSED 2026-05-11)
All T1.1–T1.11 slices shipped: focus model, text-field input, checkbox/radio,
`<select>` inline picker, implicit form submission, history navigation, URL bar
(`:` prompt), cookie inspector, `awr session import chrome/firefox`,
TUI integration harness, Google + HN smoke flows. WPT corpus extended with
keyboard event, form submit event, and input/change semantics cases.
Verified: 106 WPT cases + 58 Test262 cases green.

**Tier 2 — Render + UX Polish** (CLOSED 2026-05-13, commit `b6dd220`)
Bookmarks (`awr bookmark add/list`), URL-bar autocomplete, form-render polish
(visible field boxes, labels), table sticky headers, code-block syntax
highlighting + line numbers, diff/patch rendering, image pipeline polish,
enriched cookie inspector (expiry, scope, secure flag). Corpus extended per
`render-polish.md §4`.

**Tier 3 — Lightly Dynamic Sites** (ACTIVE, partially closed)
Three of four sub-specs closed:
- `browser-history.md` CLOSED: `pushState` / `replaceState` / `popstate`,
  `back()` / `forward()` / `go()`.
- `browser-storage.md` CLOSED: `localStorage` per-origin disk persistence,
  `sessionStorage` in-memory.
- `browser-events.md` CLOSED: synthetic input events, `requestAnimationFrame`,
  `matchMedia` evaluation.

One sub-spec partially open:
- `browser-realtime.md` PARTIAL: EventSource (SSE) shipped as T3.D.1;
  WebSocket (T3.D.2) not yet landed.

**WebCrypto:** `getRandomValues` + `subtle.digest` shipped (T-93).
**data: URL scheme support** for `<script src>` shipped (T-92.2).
**react.dev hang fix:** total-fetch deadline added (T-94).
**Image pipeline:** wired into `awr tui` (T-92.1).

---

## 2. What's Blocking MVP (Critical Gaps)

"MVP" here means Tier 3 fully closed, which is the current active goal.

### Blocker: WebSocket (T3.D.2)

`browser-realtime.md` is PARTIAL. WebSocket — RFC 6455 upgrade handshake,
frame parsing (text, binary, ping/pong, close), JS `WebSocket` class with
`onopen` / `onmessage` / `onerror` / `onclose` / `send()` — is the last
unshipped piece of Tier 3. Until this lands, Tier 3 cannot close. Sites
using real-time feeds (live comment sections, Discourse, some auth flows)
remain broken in the TUI. This is the single most impactful open item.

### Known Bug: TlsInitializationFailed on HackerNews

Zig's pure-Zig TLS stack fails to connect to some large origins (HN being
the documented case). The code acknowledges this explicitly (`client.zig:30`):
those origins fall back to `fetchOnceBoringSslHttp1` via `boringssl_fallback`.
This is a **pre-existing issue, not a regression from Phase 3**, and the
fallback path works. However it is still a correctness boundary worth knowing:
any new origin that fails Zig TLS but is not macOS/arm64 (where the BoringSSL
fallback is available) would silently produce a network error rather than
a graceful fallback. This is not a Tier 3 blocker but is a reliability risk
for users on other platforms or architectures.

### Already Fixed (verified at HEAD)

These bugs were previously tracked as open tickets but are now closed in the
shipping codebase:

- **BUG-001 — H2 pseudo-header order:** `src/net/h2_shim.c:71-80` sends
  `:method`, `:authority`, `:scheme`, `:path`, matching Chrome 132. Closed.
- **BUG-002 — HTTPS redirect counter:** `src/client.zig:519-553` uses an
  iterative redirect loop with `redirects += 1`. The old recursive HTTPS path
  that reset the counter was removed. Closed.
- **BUG-003 — Cookie path matching + SameSite enforcement:**
  `src/net/cookie.zig:524-532` implements RFC 6265 §5.1.4 boundary checking
  (`/api` no longer matches `/apiOld`), and `cookie.zig:168-202` enforces
  `SameSite` at send time. Covered by unit tests. Closed.

### Daemon Mode — Active but Incomplete

`spec/subspecs/daemon-mode.md` is ACTIVE with a design doc (`docs/research/
2026-05-07-daemon-mode-design.md`). The `awrd` binary, Unix-socket JSON-RPC IPC,
and per-scope cookie jar cache are specified but not yet shipped. `AWR_DAEMON=1`
mode is documented as the opt-in path. The companion performance plan
(`.opencode/plans/1778109534122-shiny-nebula-remainder.md`) identified concrete
startup-time savings (HN: ~590ms → <450ms, GitHub: ~2157ms → <1200ms) that
daemon mode would enable. Not a gate for Tier 3 close, but it is listed as an
active sub-spec in `spec/MVP.md §2` and needs a closure record.

---

## 3. Nice-to-Have vs. Required

### Required for Tier 3 close

- WebSocket (T3.D.2) — the only hard gate

### Required before any public/production release (correctness fixes)

- None currently open. BUG-001, BUG-002, and BUG-003 are already fixed at
  HEAD. The remaining pre-release risk is the HN TLS fallback path (not a
  functional blocker) and the open WebSocket gate.

### Nice-to-Have (Tier 4+ or polish)

- Daemon mode (`awrd` binary + IPC) — real startup-time improvement, but
  the in-process path already works and daemon mode is explicitly opt-in
- H2 multiplexing for BoringSSL sub-resource fetches (Lane A from
  `.opencode/plans/1778109534122-shiny-nebula-remainder.md`) — would cut HN
  cold-fetch time; meaningful but not blocking any spec gate
- macOS Chrome encrypted-cookie import — `session_import.zig` deferred the
  Keychain path per `browser-tui.md §8.2`; Linux Chrome (unencrypted) and
  Firefox are already supported
- `multipart/form-data` POST bodies — explicitly out of scope in
  `agent-browser.md §3`; most form submission works via
  `application/x-www-form-urlencoded`
- WebCrypto beyond `getRandomValues` + `subtle.digest` — Tier 5 territory
- `IntersectionObserver` / `ResizeObserver` — requires layout engine (Tier 4)
- Full SPA support — Tier 5; Twitter/X, Notion, Linear remain out of scope
  by design

---

## 4. Recommended Next 3–5 Steps

**Step 1 — Ship WebSocket (T3.D.2) to close Tier 3.**
This is the single gating item. RFC 6455 upgrade handshake over the existing
TLS path, frame parser (text/binary/ping/pong/close), JS `WebSocket` class
wired via QuickJS-NG, curated WPT case. The H2 framing code in
`src/net/h2session.zig` and the TLS path are already in place; WebSocket is
an HTTP/1.1 upgrade, so the stack needed (`tls_conn.zig`, `http1.zig`, the
event loop) is already exercised. Estimated scope: 1–2 weeks.

**Step 2 — Verify correctness fixes remain green.**
BUG-001, BUG-002, and BUG-003 are already fixed at HEAD. Confirm they stay
closed with `zig build test-net` and `zig build test-client` before any
WebSocket branch merges.

**Step 3 — Write the Tier 3 closure record and advance Tier 4 decision.**
When WebSocket lands and the Tier 3 WPT corpus passes, mark `browser-realtime.md`
CLOSED and write the Tier 3 closure record in `spec/subspecs/browser-roadmap.md`.
Then resolve the Tier 4 strategic question (`browser-roadmap.md §3` "Path A vs.
Path B"): embed Servo/Ladybird for layout, or build a minimal Zig layout engine.
This is the biggest architectural decision remaining and it gates `IntersectionObserver`,
real `getBoundingClientRect`, and scroll-driven content. Make the call as an ADR
so it doesn't drag.

**Step 4 — Resolve daemon-mode status.**
Daemon mode should either close (ship `awrd`) or be explicitly deferred with a
timeline, since it's currently listed as ACTIVE in the canonical spec but has no
shipping code. Leaving it ACTIVE indefinitely without shipping muddies the spec
map.

**Step 5 — Grow the Tier 3 WPT corpus to match shipped behavior.**
History, Storage, Events, and SSE are closed but the WPT corpus coverage in those
areas should be audited: `spec/subspecs/wpt-conformance.md §3` requires corpus
to grow alongside each tier. The corpus already includes storage, EventSource,
rAF, and WebCrypto cases, but a final audit should confirm coverage for
`localStorage`, `sessionStorage`, `pushState`/`popstate`, and `WebSocket` once
that lands. This should be a parallel track to Step 1, not a follow-on.

---

## Summary Table

| Area | Status | Gate |
|---|---|---|
| HTTP/1.1 stack | ✅ Complete | — |
| BoringSSL TLS + Phase 3 | ✅ Complete | — |
| Headless page runtime | ✅ Complete | — |
| Tier 0 (agent baseline) | ✅ CLOSED | — |
| Tier 1 (interactive TUI) | ✅ CLOSED 2026-05-11 | — |
| Tier 2 (render polish) | ✅ CLOSED 2026-05-13 | — |
| Tier 3 — History API | ✅ CLOSED | — |
| Tier 3 — Web Storage | ✅ CLOSED | — |
| Tier 3 — Browser Events + rAF + matchMedia | ✅ CLOSED | — |
| Tier 3 — EventSource (SSE) | ✅ Shipped (T3.D.1) | — |
| Tier 3 — WebSocket | ❌ Not landed (T3.D.2) | **Tier 3 gate** |
| Daemon mode (`awrd`) | 🔄 ACTIVE, no shipping code | ACTIVE sub-spec |
| BUG-001 H2 pseudo-header order | ✅ Closed (fixed at HEAD) | — |
| BUG-002 HTTPS redirect counter | ✅ Closed (fixed at HEAD) | — |
| BUG-003 Cookie path matching | ✅ Closed (fixed at HEAD) | — |
| TlsInitializationFailed (HN) | ⚠️ Pre-existing, fallback exists | Not blocking |
| Tier 4 (layout engine) | ⏸️ DEFERRED, decision pending | ADR required |
| Tier 5 (full SPA) | ⏸️ DEFERRED | — |
