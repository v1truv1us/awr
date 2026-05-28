# AWR — Project Status

> Last updated: 2026-05-28  
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
| — | Starter CSSOM | **CLOSED** 2026-05-27 |
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
- Tests use in-process compress→decompress round-trips (no network required)
- Run via `zig build test-net`

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
- Current implementation is a stub that returns `undefined` — documented in `src/js/engine.zig`
- Sufficient for Phase 2 surface but not spec-correct

### `setTimeout` / `setInterval`
- Degrade to stub behaviour when the libxev loop is not threaded through (`src/js/engine.zig`)

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
- **TCP per-thread event loop**: each connection runs its own libxev loop on a dedicated thread rather than sharing a loop; limits concurrency under high-connection daemon workloads (`TODO(libxev-phase2)` in `src/net/tcp.zig`).
- **`structuredClone` stub**: returns `undefined` instead of a deep clone; affects scripts that deep-clone objects during page init.
- **`setTimeout`/`setInterval` degrade to stubs** when the event loop is not threaded through the JS engine.
- **Pool/cookie `Io` threading**: `src/net/pool.zig` and `src/net/cookie.zig` use POSIX wall-clock reads directly rather than the `Io` abstraction — flagged for cleanup once `Io` APIs stabilize in Zig.
- **Tier 3 smoke gate not fully verified**: `spec/subspecs/browser-realtime.md §8` notes §4.5 manual smoke (SSE live-update in TUI) was marked deferred at closure time.

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
```
