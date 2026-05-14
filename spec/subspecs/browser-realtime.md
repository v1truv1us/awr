# Real-time connections — Tier 3 sub-spec

> **Status:** PARTIAL — SSE landed 2026-05-13 (T3.D.1); WebSocket
> remains active for a follow-up session (T3.D.2).
> `spec/MVP.md` is the canonical umbrella spec.
> `spec/subspecs/browser-roadmap.md` is the cross-tier ladder
> authority; this file owns Tier 3 real-time connection execution
> detail.

---

## 1. Purpose and authority

Tier 3 real-time support enables sites that use server-sent events
(SSE) or WebSocket connections for live updates to degrade
gracefully rather than hanging or erroring in AWR. After this
slice, news tickers, live comment feeds (Discourse live updates),
and basic chat interfaces are reachable in `awr tui`.

This sub-spec governs:

1. **EventSource (SSE)** — `new EventSource(url)`,
   `onmessage`, `onerror`, `onopen`, `addEventListener`, `close()`;
   Content-Type `text/event-stream` parsing.
2. **WebSocket** — `new WebSocket(url, protocols?)`,
   `onopen`, `onmessage`, `onerror`, `onclose`, `send()`, `close()`;
   RFC 6455 upgrade handshake.

Both are read-path focused for Tier 3: AWR receives and dispatches
events; full bidirectional interaction (e.g. chat input) is a UX
concern addressed separately in the TUI layer.

If scope changes, update this file in the same change as
`spec/MVP.md` per `spec/MVP.md §8` and reflect the change in
`spec/subspecs/browser-roadmap.md §3`.

---

## 2. In scope

### 2.1 EventSource

- `new EventSource(url)` — opens an HTTP connection with header
  `Accept: text/event-stream`. AWR follows the SSE parsing spec:
  lines starting with `data:`, `event:`, `id:`, `retry:`.
- Events dispatched to JS callbacks on the main thread.
- Auto-reconnect on disconnect after `retry` ms (default 3000);
  capped at a reasonable maximum to avoid indefinite background
  connections in `awr tui` mode. AWR may close the connection
  on page navigation (`EventSource.close()` equivalent).
- `readyState` property: `CONNECTING=0`, `OPEN=1`, `CLOSED=2`.

### 2.2 WebSocket

- `new WebSocket(url, protocols?)` — performs the RFC 6455
  HTTP Upgrade handshake over TLS (`wss://`) or plain TCP (`ws://`).
- Frame types supported: text (UTF-8), binary (dispatched as
  `ArrayBuffer`), ping/pong (handled transparently), close.
- `send(data)` — accepts `string` or `ArrayBuffer`.
- AWR renders inbound text messages in the TUI as they arrive
  (streamed append to page body or a dedicated panel — UX deferred
  to implementation time).
- Connection lifecycle: opened on construction, closed on
  `ws.close()` or page navigation.

### 2.3 TUI integration

Real-time events that modify the DOM (via JS event handlers) trigger
an incremental re-render of the affected region. AWR does NOT
implement a full virtual DOM diff for Tier 3; instead, handlers
that call `document.getElementById(...).textContent = ...` or
similar simple DOM mutations are re-rendered via the existing
renderer on a short debounce (50 ms).

---

## 3. Out of scope (defer to later tiers)

- Full duplex interactive WebSocket chat UI (input forms, etc.) —
  addressed by Tier 3 form + Tier 4 dynamic layout work together
- `SharedWorker` / `ServiceWorker` WebSocket sharing — Tier 5+
- WebTransport — not planned for current tiers
- Server-sent binary events (binary `EventSource`) — not standard;
  skip

---

## 4. Closure gates

This slice closes when **all** of the following are true:

1. Existing Tier 0–Tier 2 gates remain green;
2. `zig build test` covers SSE parsing (data/event/id/retry fields,
   multi-line data, reconnect timer);
3. `zig build test` covers WebSocket handshake (upgrade request,
   101 response validation, frame read/write);
4. `zig build test-integration` includes an SSE round-trip against
   a local test server;
5. Manual smoke: open a page that uses `EventSource`, confirm
   events appear in the TUI without hanging.

---

## 5. Verification gates

1. `zig build test` green;
2. `zig build test-integration` green with §4.4 SSE case;
3. Manual smoke: SSE page renders live updates; WebSocket page
   connects and displays server messages.

---

## 6. Implementation notes

Indicative slice order (defer detailed plan to implementation time):

1. **SSE first** — simpler (HTTP-based, no upgrade). Add SSE parser
   to `src/net/` and expose `EventSource` in the JS bridge.
2. **WebSocket second** — RFC 6455 upgrade in `src/net/`,
   `WebSocket` JS class in bridge, frame codec.
3. **TUI re-render hook** — debounced dirty-flag re-render triggered
   from event handler side-effects.

---

## 7. Open questions

1. Should AWR keep SSE connections alive across TUI navigation
   (background tab model) or close on navigate? Likely answer:
   close on navigate for Tier 3; background connections are a
   Tier 4+ UX decision.
2. WebSocket binary frames: `Blob` or `ArrayBuffer` dispatch?
   Likely answer: `ArrayBuffer` (simpler; Blob requires a separate
   object type).
3. Should `ws://` (plain TCP WebSocket) be supported or `wss://`
   only? Likely answer: `wss://` only for Tier 3 (security default;
   plain-TCP is rare in production).

---

## 8. Closure record

| Field | Value |
|-------|-------|
| Status | PARTIAL — SSE shipped, WebSocket pending |
| Date | 2026-05-13 (T3.D.1 — SSE only) |
| Final commit (so far) | (this commit — T3.D.1 EventSource) |
| Gates satisfied | §4.1 prior-tier gates ✓ / §4.2 SSE parsing (data/event/id/retry, multi-line, BOM, CR/LF/CRLF) ✓ / §4.3 WebSocket — **not yet** / §4.4 SSE round-trip — **partial** (parse-only WPT case; no live test server) / §4.5 SSE manual smoke — pending |
| Sign-off (T3.D.1) | AWR Dev |

**Delivered surface (T3.D.1 — SSE):**

- `src/net/sse.zig`: WHATWG-compliant incremental parser. Handles
  `data:` / `event:` / `id:` / `retry:` fields, multi-line data
  joined with `\n`, comment lines, BOM stripping, CR/LF/CRLF
  terminators (incl. CR-LF split across chunks), id-with-NUL
  ignoring, empty-data dispatch suppression. 13 unit tests.
- One native callback `__awr_sse_parse_all__(text) → JSON array`
  that runs the Zig parser over a complete body and returns
  events as `[{event, data, lastEventId}, ...]`.
- JS-side `EventSource` class: standard `CONNECTING/OPEN/CLOSED`
  constants, `addEventListener`/`removeEventListener`/`close()`,
  `onopen`/`onmessage`/`onerror` properties, dispatches events
  with `.data`/`.lastEventId`/`.origin` set per spec. Wraps
  `fetch` for the body, then drains parsed events.

**Honest scope limitation (intentional):**

EventSource is **request/response, not streaming**. AWR's page-
processing model has a bounded `drainAll` budget (1-2s), so
there is no "always-on" runtime where a long-lived background
SSE connection could deliver events. The current implementation:

- Fetches the full event-stream body, parses, dispatches all
  events at once — works for sites that send initial state via
  SSE (status pages, news bootstraps).
- Does NOT auto-reconnect on disconnect.
- Does NOT maintain the connection across navigations.

This is deliberately conservative. Real streaming + reconnect
will land in a follow-up slice once daemon-mode + TUI session
work creates a place for background connections to live.

**WebSocket — DEFERRED to next session (T3.D.2):**

Not implemented. Sub-spec sections §2.2 (WebSocket), §4.3
(closure gate), and §6.2 (slice 2) remain ACTIVE. Closure of
this sub-spec requires both T3.D.1 (done) and T3.D.2 (pending).

**Test surface (T3.D.1):**

- `src/net/sse.zig` — 13 unit tests covering the spec's parsing
  surface end-to-end.
- `src/dom/bridge.zig` — 3 JS-level tests (parse via the native,
  EventSource constructor + close shape, multi-line + retry).
- `tests/wpt/eventsource_parser.js` — new WPT case covering the
  EventSource shape + parser surface that closure gates require.
