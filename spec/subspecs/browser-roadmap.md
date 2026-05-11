# Browser Roadmap — tiered capability ladder

> **Status:** ACTIVE (proposed 2026-05-09)
> `spec/MVP.md` is the canonical umbrella spec. This file is the
> authority for the **tiered capability ladder** AWR climbs to
> become a complete dual-surface (human TUI + agent API) browser
> for the readable web.
>
> Each tier names its own active sub-spec where execution-level
> detail lives. This file owns the cross-tier ordering and the
> closure-gate definitions that decide when one tier yields
> primacy to the next.

---

## 1. Purpose and authority

AWR is a CLI-first browser with two co-equal surfaces sharing one
session:

```
HUMAN  ──► awr browse <url>     (TUI: read pages, fill forms, follow links, history)
AGENT  ──► awr <url> | awr extract | awr tools | awr call
                                 (JSON / Markdown / WebMCP)
        \      shared CookieJar (per-scope)
         \──── shared Client / connection pool
              (daemon mode amortizes startup across both)
```

The shipped baseline (Tier 0, see §3) closed the **agent runtime**
half of the product. The active work climbs the ladder below to
close the **interactive human browser** half and grow the agent
surface's reach by adding browser APIs that real-world sites use.

This file is the cross-tier **roadmap and gate authority**. Sub-specs
pointed at by §3 own the per-tier execution detail.

If the tier ordering, closure gates, or active/deferred split change,
update this file in the same change as `spec/MVP.md` per
`spec/MVP.md §8`.

---

## 2. Design principles for the ladder

These rules apply across every tier:

1. **Dual-surface compatibility is non-negotiable.** Every feature
   must work for both `awr browse` (human TUI) and the agent
   commands (`awr <url>`, `awr extract`, `awr tools`, `awr call`).
   Cookies, sessions, and rendered DOM are shared between them.

2. **WPT-first.** A capability is not "implemented" until at least
   one curated WPT case in `tests/wpt_runner.zig` exercises it and
   passes. Tier closure requires the corpus to grow alongside the
   feature work (see `spec/subspecs/wpt-conformance.md §3`).

3. **No-stubs rule** (`spec/MVP.md §6`) applies at every tier. If
   an API can't be implemented correctly *yet*, it stays
   un-exposed.

4. **Tiers ship incrementally.** Higher tiers do not block lower
   tiers from being released. A Tier-1-complete AWR is a useful
   product even if Tier 4 is years away.

5. **The TUI and the agent surface render from the same DOM.**
   Whatever the agent's `awr extract` sees, the human's `awr
   browse` paints to the terminal. No divergent code paths.

6. **Anti-bot fingerprint stays Chrome-shaped.** Per
   `spec/Fingerprint-Plan.md` and `spec/subspecs/daemon-mode.md`,
   AWR's network behavior matches Chrome 132 by default. New
   browser-API additions must not introduce identifying anomalies
   (e.g., `navigator.webdriver === true`).

---

## 3. The tiers

Each tier names its **scope sentence** (the one-line "this works
when…"), the **active sub-spec** that owns its execution detail,
and a **WPT corpus area** that proves it.

### Tier 0 — Agent runtime baseline (CLOSED)

**Scope sentence**: Agents can fetch real pages, run page JS,
absorb cookies, persist them across processes, and consume page
output as JSON, Markdown, or WebMCP tools.

**Sub-specs (closed)**:
- `spec/subspecs/mvp-remainder.md` — closure record
- `spec/subspecs/wpt-conformance.md` — corpus + runner authority
- `spec/subspecs/agent-browser.md` — fetch/XHR POST, form POST,
  cookie persistence
- `spec/subspecs/rendering.md` — terminal render + image
  protocols
- `spec/subspecs/daemon-mode.md` — long-lived `awrd` + JSON-RPC
  IPC, per-scope cookie jars, shared Client

**Closure gates (verified)**: `zig build test` + `zig build
test-wpt` + `zig build test-test262` green; daemon §4 gates met
(see `spec/subspecs/daemon-mode.md §4`).

This tier is the foundation everything else stands on.

---

### Tier 1 — Interactive TUI parity (CLOSED 2026-05-11)

**Scope sentence**: A human can use `awr browse <url>` to read,
log into, and interact with traditional web apps as easily as
they would in lynx / w3m / elinks.

**What it covers**:

- form-field interaction (text inputs, textareas, checkboxes,
  radio groups, single-select dropdowns, submit/reset buttons)
- focus management (tab/shift-tab to move between focusable
  elements; visible focus indicator)
- keyboard input into focused fields (printable chars, backspace,
  arrow keys within a field, enter to submit)
- click on non-link interactive elements (`<button>`, `<input
  type="submit">`, `<input type="checkbox">`, etc.) via Enter or
  Space on the focused element
- in-session history navigation (back/forward, with state
  preserved per page)
- address bar / URL navigation without leaving the TUI
- reload (soft + hard)
- inline cookie inspector + clear-cookies action
- session import: read cookies from Chrome / Firefox jar files
  into AWR's jar so a logged-in human's existing session is
  immediately usable

**What it explicitly does NOT cover**:

- new browser APIs (`History` pushState, `localStorage`,
  `WebSocket`, etc.) — those land in Tier 3
- real layout, scroll-driven loads, or `IntersectionObserver` —
  Tier 4
- full-SPA support — Tier 5

**Active sub-spec**: `spec/subspecs/browser-tui.md` (this file's
companion; promoted from DEFERRED to ACTIVE in the same change
that promoted browser-roadmap.md).

**WPT corpus area**: form interaction, focus/blur events,
keyboard event semantics, submit-via-enter, history.length /
state across same-origin navigations.

**Closure gates** (Tier 1 closes when **all** are true):

1. existing Tier 0 gates remain green;
2. `zig build test-wpt` covers form interaction, focus event,
   keyboard event, and same-origin navigation cases;
3. **two** end-to-end smoke flows land, exercising
   complementary Tier 1 surface (full detail in
   `spec/subspecs/browser-tui.md §4`):
   - **Google search round-trip**: open `https://www.google.com/`,
     type a query, press Enter, verify results render, follow
     a result link.
   - **HN sign-in flow**: open
     `https://news.ycombinator.com/login`, fill credentials,
     submit, navigate to a logged-in page via the URL bar,
     verify session cookie persisted.
4. `awr session import chrome` / `awr session import firefox`
   produce a jar file the page pipeline + TUI both honor;
5. cookie inspector + clear-cookies action documented in
   `awr browse`'s help screen.

---

### Tier 2 — Render + UX polish (ACTIVE 2026-05-11)

**Scope sentence**: The terminal-rendered page is good enough that
a human can do daily reading and form work without missing
visual signals.

**What it covers**:

- form layout: visible boxes around inputs, labels properly
  associated, focused field visibly highlighted in the rendered
  output
- table rendering improvements: sticky headers when scrolled
  past the first viewport
- code-block rendering: syntax highlighting (best-effort, opt-in
  per `--code-style=…`) and line numbers
- diff and patch rendering for GitHub/GitLab PR pages and
  `text/x-diff` content
- bookmarks (`awr bookmark add` / `awr bookmark list`)
- address-bar history autocomplete (per-shell-session)
- image rendering polish (caching, decode budget tuning, sixel
  palette quality)
- cookie inspector enriched (per-cookie expiry, scope, secure
  flag visible)

**Sub-spec(s)**: `spec/subspecs/render-polish.md` (ACTIVE since
2026-05-11; owns slice-level execution detail).

**WPT corpus area**: minimal new coverage — a few `<pre>` /
Content-Type cases per `render-polish.md §4`.

**Closure gates**: see `render-polish.md §4` (bookmarks +
autocomplete + form/table/code/diff/image polish + cookie
inspector enrichment, each with a code-side test + smoke flow).

---

### Tier 3 — Lightly dynamic site support (DEFERRED)

**Scope sentence**: Sites that aren't full SPAs but use modern
JavaScript for tabs, comments, live updates, or auth flows
work end-to-end.

**What it covers** (each is roughly 1-3 weeks):

- `History` API — `pushState` / `replaceState` / `popstate`
  events. Currently §5.5 of `spec/MVP.md` limits us to length +
  state; this tier extends to full same-origin behavior.
- `localStorage` and `sessionStorage` — currently shipped as
  in-memory per page; persist `localStorage` per origin to disk
  alongside cookies in daemon mode.
- `WebSocket` — protocol upgrade from HTTP/1.1 (we have H2
  framing already; WS is a few-hundred-LoC Zig module + a JS
  shim).
- `EventSource` (Server-Sent Events) — chunked HTTP/1.1.
- `MutationObserver` — already covered in §4 of
  `spec/subspecs/mvp-remainder.md`; extend to records the runtime
  doesn't currently emit.
- synthetic input events (`element.click()`, `.focus()`, programmatic
  `dispatchEvent(new MouseEvent(...))`) — some of this exists;
  audit and complete.
- `fetch` / `XHR` — extend method set beyond GET/POST per
  `spec/subspecs/agent-browser.md` if specific cases require
  PUT/PATCH/DELETE.
- `requestAnimationFrame` — already shipped as a stub; back with
  a real 60 Hz tick from the libxev event loop.
- `MediaQueryList` (`matchMedia`) — basic predicate evaluation
  against terminal dimensions.

**Sub-spec(s)**: TBD — likely splits into `browser-history.md`,
`browser-storage.md`, `browser-realtime.md` (WS+SSE), and
`browser-events.md`.

**WPT corpus area**: history, storage, websocket, mutation
observer, event constructors.

**Closure gates**: defined when activated. Indicative target:
Reddit (new design), Stack Overflow, modern Discourse forums,
GitLab UI, common Rails/Django/Phoenix apps work end-to-end.

---

### Tier 4 — Layout engine (DEFERRED, gating constraint)

**Scope sentence**: The DOM has real geometry. `getBoundingClientRect`
returns true coordinates, scroll positions are real,
`IntersectionObserver` and `ResizeObserver` work correctly.

**What it covers**:

- CSS parser (the subset real sites use — flexbox, grid, block,
  inline, position, transforms)
- box model: margins, padding, borders, content-box vs border-box
- block flow + inline layout + text shaping
- flexbox layout
- grid layout (basic — full grid is a Tier 5 polish item)
- viewport tracking with terminal-cell-accurate dimensions
- `IntersectionObserver` and `ResizeObserver` — currently
  excluded by `spec/subspecs/mvp-remainder.md` and `spec/MVP.md
  §5.6`. This tier flips them on.
- scroll events backed by real layout, scroll-driven content
  loads work

**Strategic note**: this is the **single biggest decision point**
in the roadmap. Two paths:

- **Path B (build it)**: 12-18 person-months for a minimal Zig
  layout engine. Preserves AWR's single-binary, fast-startup,
  Chrome-fingerprint character.
- **Path A (embed it)**: integrate Servo or Ladybird's layout
  component (or shell out to a CDP-controlled Chromium for the
  layout-dependent paths). Faster to ship Tier 4, but
  fundamentally changes what AWR is.

This sub-spec stays deferred until that decision is made
explicitly. Do not start Tier 4 work without an ADR amendment
recording the chosen path.

**Sub-spec(s)**: TBD when activated.

**WPT corpus area**: css-flexbox, css-grid, intersection-observer,
resize-observer, scroll, geometry-utils.

**Closure gates**: defined when activated.

---

### Tier 5 — Full SPA + parity polish (DEFERRED)

**Scope sentence**: SPAs that treat the browser as a runtime —
X.com, modern Slack, Notion, Linear — render meaningfully and
respond to interaction.

**What it covers**:

- Service Workers (separate JS context, fetch interception)
- IndexedDB
- Web Crypto (full `crypto.subtle` surface backed by BoringSSL)
- Worker / SharedWorker
- ResizeObserver, PerformanceObserver (full)
- Notifications, Permissions stubs
- anti-bot fingerprint shimming (canvas, WebGL, AudioContext,
  font enumeration) per the existing `spec/Fingerprint-Plan.md`
- multi-tab session model in the TUI

**Strategic note**: this tier only makes sense after Tier 4. Even
with all of Tier 5 done, sites that depend on real GPU
compositing (canvas-based games, WebGL globes, video calls)
remain out of scope by the nature of a terminal browser.

**Sub-spec(s)**: TBD when activated.

**WPT corpus area**: service-workers, indexeddb, web-crypto,
workers.

**Closure gates**: defined when activated.

---

## 4. WPT growth contract

`spec/subspecs/wpt-conformance.md §3` lists the corpus areas that
correspond to the **closed** Tier 0 surface. As tiers come online,
that list grows. Each tier's closure gates require:

1. matching WPT cases land in the curated corpus before the tier
   is marked closed;
2. those cases fail before the tier's implementation work and pass
   after;
3. `spec/subspecs/wpt-conformance.md §8` (the `curated_cases`
   mirror) is updated in the same change as the tier's closure
   record.

A tier cannot close while the corpus tells a different story than
the implementation.

---

## 5. Out of scope, explicitly

These are documented permanently-out-of-scope items, even at
Tier 5. They are NOT future work — they're in this section to
prevent the project from drifting toward them:

- WebGL, WebGPU, Canvas2D pixel-level access (terminal has no
  pixel surface)
- `<video>` / `<audio>` playback (not a media player)
- WebRTC / camera / microphone (not an interactive call client)
- bot-detection arms-race against any single site (we ship
  Chrome-shaped fingerprints; we don't promise undetectability
  against per-site detection iterating against AWR specifically)
- Chromium-feature parity for its own sake

If you find yourself wanting to add one of these to the roadmap,
the question to ask first is: *is AWR still the right tool for
this user, or is Playwright/Puppeteer better?*

---

## 6. Cross-tier governance

1. promotion of a tier from DEFERRED to ACTIVE requires an ADR
   amendment in the same change;
2. demotion of an ACTIVE tier (deciding to drop scope) requires
   the same;
3. `spec/MVP.md §2` document map must list the tier's active
   sub-spec when the tier is active;
4. tier closure records live in the tier's sub-spec, not in this
   file — this file only governs ordering and gates.

This file stays short on per-tier detail to keep the cross-tier
view auditable.
