# AWR — Project Status

> Last updated: 2026-06-01  
> Canonical spec: `spec/MVP.md` | Tier ladder: `spec/subspecs/browser-roadmap.md`

---

## Tier Status Summary

| Tier | Name | Status |
|------|------|--------|
| 0 | Agent runtime baseline | **CLOSED** |
| 1 | Interactive TUI parity | **CLOSED** 2026-05-11 |
| 2 | Render + UX polish | **CLOSED** 2026-05-13 |
| 3 | Lightly dynamic site support | **CLOSED** 2026-05-22 |
| — | Daemon mode (`awrd`) | **CLOSED** 2026-05-23 |
| — | Starter CSSOM | **CLOSED** 2026-05-27 (§2.1–2.7 post-closure additions through 2026-05-31) |
| — | TUI Quality Track | **CLOSED** 2026-05-30 |
| 4 | Layout engine | **DEFERRED** (decision pending) |
| 5 | Full SPA parity | **DEFERRED** |

---

## Done

### Tier 0 — Agent Runtime Baseline
- `awr <url>`, `awr extract`, `awr tools`, `awr call`, `awr mock` all ship
- Full page pipeline: HTTP fetch → HTML parse → DOM → JS execution → terminal render
- HTTP/1.1 and HTTP/2 (nghttp2), TLS via BoringSSL with Chrome 132 JA4 fingerprint
- Cookie jar — RFC 6265, disk persistence, per-origin scoping
- `fetch()` and `XMLHttpRequest` — async GET and POST, `URLSearchParams` bodies
- `<form method="post">` end-to-end through `awr browse`
- WPT runner (`zig build test-wpt`) and Test262 runner (`zig build test-test262`) both wired and green; 122 WPT cases, 8 Test262 cases
- DOM bridge: parent/sibling tracking, live `classList`, Lexbor-backed `innerHTML`, `cloneNode`, `contains()`
- Full event system: `addEventListener`/`removeEventListener`/`dispatchEvent`, capture/bubble/target phases, `CustomEvent`, browser lifecycle events (`DOMContentLoaded`, `load`, `readystatechange`)
- `MutationObserver` with microtask delivery
- `localStorage` (per-origin disk persistence) and `sessionStorage` (in-memory)
- `getBoundingClientRect()`, `requestAnimationFrame` (demand-driven, not 60 Hz), terminal `window`/`screen` dimensions
- Terminal image rendering: Kitty, iTerm2 (OSC 1337), Sixel (median-cut), Unicode braille fallback; `<img>`, `<picture>`/`srcset`, CSS `background-image`; per-image safety caps + per-page budget

### Tier 1 — Interactive TUI
- Form fields: text inputs, textareas, checkboxes, radio groups, `<select>` picker, submit/reset
- Tab/Shift-Tab focus traversal with visible highlight
- Keyboard input in focused fields; Enter to submit
- In-session back/forward history navigation
- URL bar (`:`), reload (soft + hard)
- Inline cookie inspector + clear-cookies
- `awr session import chrome` / `awr session import firefox`

### Tier 2 — Render + UX Polish
- Form layout: visible input boxes, label association, focus highlighting
- Table sticky headers
- Code-block syntax highlighting (`--code-style=…`) and line numbers
- Diff/patch rendering for GitHub/GitLab PR pages and `text/x-diff`
- Bookmarks: `awr bookmark add` / `awr bookmark list`
- URL-bar history autocomplete (per-shell-session)
- Image pipeline: caching, decode budget tuning, Sixel palette polish
- Cookie inspector: per-cookie expiry, scope, and secure flag

### Tier 3 — Lightly Dynamic Sites
- History API: `pushState`, `replaceState`, `popstate`, `back`/`forward`/`go`, `length`, `state`
- `localStorage` disk-persisted per origin in daemon mode; `sessionStorage` in-memory
- `EventSource` (SSE): WHATWG-compliant incremental parser, `onopen`/`onmessage`/`onerror`, 13 unit tests
- `WebSocket` RFC 6455: frame codec, HTTP Upgrade handshake, text/binary/ping-pong/close frames, 9 unit tests
- `matchMedia`: predicate evaluation against terminal column width; `change` on resize
- `requestAnimationFrame` (demand-driven tick)
- Synthetic input events dispatched from TUI interactions

### Daemon Mode (`awrd`)
- Long-lived `awrd` binary on Unix socket (`${XDG_RUNTIME_DIR}/awrd-${UID}.sock`)
- JSON-RPC 2.0 IPC; shared `Client` + `BoringSslPool` across callers
- Per-cookie-scope `CookieJar` cache with disk persistence
- Auto-spawn + build-hash staleness check from `awr` CLI
- Idle shutdown, PID-file singleton, RSS cap, ping deadline
- `AWR_DAEMON=1` opt-in; per-process fallback unchanged

### Starter CSSOM — CLOSED 2026-05-27
- `src/cssom/` module: `style.zig`, `parser.zig`, `cascade.zig`, `computed.zig`
- Stylesheet loading: `<style>` blocks and `<link rel="stylesheet">`
- `element.style` / `CSSStyleDeclaration`: `cssText`, `getPropertyValue`, `setProperty`, `removeProperty`
- Author stylesheet rule parsing with pre-parsed selectors
- Cascade: specificity scoring, source order, `!important`, inline-wins-over-author
- `getComputedStyle()` for non-layout properties: `display`, `visibility`, `white-space`, `text-transform`, `font-weight`, `font-style`, `color`, `background-color`
- Renderer integration: `display:none` and `visibility:hidden` suppressed in output
- WPT cases: §4.1–§4.6 coverage (`css_style_declaration.js`, `css_inline_computed_style.js`, `css_style_block.js`, `css_external_stylesheet.js`, `css_cascade_basics.js`, `css_important.js`, `css_computed_properties.js`)
- WebCrypto subset: `crypto.getRandomValues()` + `subtle.digest()`

#### Post-closure CSSOM additions (§2.1–§2.7, through 2026-05-31)
Closure boundary is unchanged (2026-05-27); these are no-layout CSS extensions
made on top of the closed track, each backed by curated WPT cases. Full detail:
`spec/subspecs/cssom.md §2.1–§2.7`.
- **§2.1** `text-decoration` + `text-align` added to the computed-style set; UA-stylesheet defaults extended (`strong`→bold, `em`→italic, `a`→underline, `del`→line-through, `th`→center). Compound (`div.foo`) and combinator (`section p`, `ul > li`, sibling) selectors match with proper AND/ancestor semantics; attribute selectors (`[attr]`, `[attr=v]`, `~= |= ^= $= *=`) honored in the cascade. Coverage: `css_ua_text_defaults.js`, `css_combinator_cascade.js`, `css_attribute_selectors.js`
- **§2.2** `getComputedStyle` returns resolved values (`bold`→`"700"`, colors → `"rgb(…)"`/`"rgba(…)"`), serialized only at the `getComputedStyle` boundary; `element.style.*` keeps authored values. Coverage: `css_computed_value_serialization.js`
- **§2.3** Compiled-selector cache + exact compound/combinator/attribute matching in the renderer (flat-OR fallback above 48 complex text rules; script-facing cascade always exact)
- **§2.4** Structural pseudo-classes: `:first-child`, `:last-child`, `:only-child`, `:nth-child(an+b)`, and `*-of-type` variants. Coverage: `css_structural_pseudo.js`
- **§2.5** `@media` rules applied in the cascade via a Zig port of the `matchMedia` model (`(min|max)-width/height`, `prefers-color-scheme`, `screen`/`all`). Coverage: `css_media_cascade.js`
- **§2.6** Shorthand longhands (`text-decoration`→`-line`, `font`→`-style`/`-weight`) + CSS-wide keywords (`inherit`/`initial`/`unset`) at the getComputedStyle boundary. Coverage: `css_wide_keywords.js`
- **§2.7** Full CSS extended named-color set, `hsl()`/`hsla()`, `transparent`, and `currentColor` in the getComputedStyle color serializer. Coverage: `css_color_serialization.js`

### Real-site support (H2 + decompression) — LANDED 2026-05-27
- BoringSSL H2 path now decompresses gzip/deflate/zstd response bodies
- BoringSSL-first path inversion: Chrome fingerprint used by default, std.http fallback only for non-HTTPS
- body_text extraction uses zero-alloc inline style check (fast on large pages)
- Verified: HN (~1.2s), Wikipedia (~0.9s), GitHub (~2.1s), Stack Overflow (~4s), old.reddit.com (~1.5s), audiofile.app (~0.9s)
- Note: www.reddit.com blocked by Cloudflare JS challenge; old.reddit.com returns full content

### `--header` flag — LANDED 2026-05-28
- `awr <url> --header "Name: Value"` — injects custom headers on GET path
- `awr post <url> --json ... --header "Name: Value"` — same for POST path
- Flows through all three fetch paths: stdlib H1, BoringSSL H1, BoringSSL H2
- Enables Bearer token auth for REST APIs (Supabase, Firebase, custom JWTs)
- See `docs/audiofile-e2e.sh` for full authenticated audiofile.app flow

### Decompression regression tests — LANDED 2026-05-28
- 5 unit tests in `src/client.zig` cover gzip, deflate, zstd, identity, and empty-body
- Tests use pre-compressed byte literals (no compress-side dependency on Zig stdlib)
- Run via `zig build test-client`

### BoringSSL H1 decompression — LANDED 2026-05-28
- `sendOnBoringSslEntry` (BoringSSL HTTP/1.1 path) now decodes `Content-Encoding: gzip/deflate/zstd`
- Previously only the H2 and stdlib paths decompressed; BoringSSL H1 POST responses were raw
- Fixes `awr post --json` against Supabase and other gzip-default HTTPS APIs

### audiofile.app e2e — VERIFIED 2026-05-28
- Full flow verified: homepage → sign-in (Supabase JWT) → search → add to wishlist → re-fetch and verify
- `docs/audiofile-e2e.sh` requires `AUDIOFILE_EMAIL` + `AUDIOFILE_PASSWORD` for a confirmed account
- `$AWR_COOKIE_JAR` persists regular cookies; JWT auth uses `--header "Authorization: Bearer <token>"`

---

## TUI Quality Track — CLOSED 2026-05-30

All five items resolved. Full spec: `spec/subspecs/tui-quality.md`.

| Item | Priority | Status |
|------|----------|--------|
| §2.1 Inline link word-wrap | P1 | **DONE** 2026-05-30 |
| §2.2 Loading indicator | P2 | **DONE** 2026-05-30 |
| §2.3 Help modal (`h` key) | P3 | **DONE** 2026-05-30 |
| §2.4 Table linearization (HN readable) | P4 | **DONE** 2026-05-30 |
| §2.5 Navigation header feedback | P5 | **DONE** 2026-05-30 (satisfied by §2.2) |

All closure gates from `tui-quality.md §4` verified:
- `zig build test` green (1196 tests, including new T-Q2.2, T-Q2.3, §2.1, §2.4 tests)
- `zig build test-corpus` green — 9 snapshots re-blessed to improved output
- HN `must_contain` passes; `wikipedia_octopus` re-blessed
- `h` listed in `awr tui --help` and welcome cheat sheet
- §2.5 satisfied by §2.2 `loading_url` mechanism

**§2.1 fix:** `pending_space` flag on `RenderState` carries inter-word spacing
across inline-node boundaries (text nodes + `<a>` + other inline elements).
`flowWord` helper replaces per-call `need_space`. 9 corpus fixtures re-blessed
(all genuine readability improvements: `eight-limbedmollusc` → `eight-limbed
mollusc`, etc.).

**§2.2 + §2.5:** `loading_url` + live-terminal capture in `runWith` paint a
`⟳ Loading…` header frame before the blocking `page.navigate()`.

**§2.3:** `show_help` overlay (`h` → open, any key → dismiss). `drawHelpOverlay`
follows select-picker/cookie-inspector overlay pattern.

**§2.4:** `hasThCell` + `renderLayoutTable` — tables with no `<th>` render in
DOM reading order (cells left-to-right, rows top-to-bottom, no column alignment).
HN, YC jobs, and layout-table pages are now fully readable. Data tables
(with `<th>`) are unchanged. `col > 0` row-separator condition works around
`at_line_start` tracking invariant (only cleared when `hang_indent > 0`).

---

## In Progress / Partially Done

### libxev Phase 2 — shared event loop (deferred with tagged TODOs)
- `src/net/tcp.zig`: each TCP connection spawns a dedicated thread + per-connection `loop.run(.until_done)`; flagged `TODO(libxev-phase2)` for migration to a shared loop with async callbacks
- `src/net/pool.zig`: pool mutex uses a direct POSIX wall-clock read; flagged `TODO(durable)` for proper `Io` threading
- `src/net/cookie.zig`: clock access flagged `TODO(durable)` for explicit `Io` parameter

### WebSocket / SSE — one-shot only, no streaming
- Both `EventSource` and `WebSocket` collect the full response/frame stream before dispatching events
- No auto-reconnect, no background connections across navigations, no post-open `send()` for WebSocket
- Full streaming + reconnect deferred until daemon-mode session lifetime creates a home for background connections

### `structuredClone`
- Implemented as a JS polyfill: primitives, Date, RegExp, Map, Set, Array, and plain objects are deep-cloned. Does not handle ArrayBuffer, TypedArray, or circular references (Tier 4+ territory).

### `setTimeout` / `setInterval`
- Fully implemented via libxev timer queue in the Page/TUI path. In the isolated `test-js` target (no EventLoop), timers are no-ops — intentional for the standalone test binary.

---

## Explicitly Deferred

- **Tier 4 — Layout engine**: full CSS layout, box model, flex/grid, text shaping, geometry-backed observers (`IntersectionObserver`, `ResizeObserver`). Decision pending: build native Zig layout engine (~12–18 person-months) vs. embed external layout oracle (Servo/Ladybird/CDP). Requires ADR amendment before any work starts. See `docs/adr/0003-tier4-layout-strategy.md`.
- **Tier 5 — Full SPA parity**: Service Workers, IndexedDB, full Web Crypto, Workers, Notifications, multi-tab TUI session, anti-bot canvas/WebGL/font fingerprint shimming.
- **Native MCP stdio server**: `spec/subspecs/mcp-stdio.md` — will be a thin client of daemon-mode. Not active.
- **Fingerprinting roadmap**: `spec/Fingerprint-Plan.md` — owned browser identity work. Not active.
- **`IntersectionObserver` / `ResizeObserver`**: blocked on Tier 4 layout.

### Permanently out of scope
WebGL/WebGPU, `<video>`/`<audio>` playback, WebRTC, canvas pixel-level access, Chromium-feature parity for its own sake.

---

## Known Issues / Bugs

- **WebSocket/SSE not streaming**: both are one-shot collect-then-dispatch; sites that rely on live push without page reload will not update incrementally (documented limitation in `spec/subspecs/browser-realtime.md §8`).
- **WebSocket/SSE one-shot collect**: both collect the full stream before dispatching; live-push sites won't update incrementally without a page reload (documented, `spec/subspecs/browser-realtime.md §8`).
- **TCP per-thread event loop**: each connection runs its own libxev loop on a dedicated thread; limits concurrency under high-connection daemon workloads (`TODO(libxev-phase2)` in `src/net/tcp.zig`).
- **`setTimeout`/`setInterval` in standalone JS tests**: in the `test-js` target there is no EventLoop, so timers are no-ops. In the Page/TUI path the EventLoop is always attached and timers fire correctly.
- **Pool/cookie `Io` threading**: `src/net/pool.zig` and `src/net/cookie.zig` use POSIX wall-clock reads directly rather than the `Io` abstraction — flagged for cleanup once `Io` APIs stabilize in Zig.
- **`test-render` build step does not exist**: render unit tests are co-located in `src/render.zig` and run under `zig build test`; there is no standalone `zig build test-render` step.

---

## Verification Commands

```bash
zig build test          # Full default suite (includes WPT + Test262)
zig build test-wpt      # Curated WPT browser/runtime cases
zig build test-test262  # Curated JS language conformance
zig build test-net      # Networking stack
zig build test-tls      # TLS fingerprint
zig build test-h2       # HTTP/2
zig build test-js       # QuickJS engine
zig build test-html     # HTML parser
zig build test-dom      # DOM tree + bridge
zig build test-page     # Page orchestrator
zig build test-render   # Renderer
zig build test-e2e      # End-to-end integration
zig build test-daemon   # Daemon mode integration
zig build test-corpus   # Render corpus harness (12 fixtures)
zig build test-image    # Image encoder + picker (113 tests)
# Note: there is no standalone test-render step. Renderer unit
# tests are co-located in src/render.zig and run under zig build test.
```
