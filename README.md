# AWR — Agentic Web Runtime

A headless terminal browser for AI agents. Loads pages, runs their
JavaScript, and exposes any WebMCP tools the page registers
(`navigator.modelContext.registerTool(...)`) as a CLI surface so an
agent can discover and invoke them.

**Status: v1 slice shipped** (commit [`950d954`](../../commit/950d954)
on `main`). The authoritative MVP contract lives in `spec/MVP.md`;
`MVP_PLAN.md` tracks the 7-step implementation slice. All seven steps
are ✅, and the end-to-end demo is verified against
`experiments/webmcp_mock.html`.

---

## Quick start

```bash
zig build -Doptimize=ReleaseSafe       # produces zig-out/bin/awr (~9.9 MB)

./zig-out/bin/awr --version            # prints 0.0.<git-hash>
./zig-out/bin/awr tools experiments/webmcp_mock.html
./zig-out/bin/awr call  experiments/webmcp_mock.html \
    search_products '{"q":"Widget"}'
./zig-out/bin/awr call  experiments/webmcp_mock.html \
    add_to_cart '{"sku":"w-001","qty":2}'
```

Requires Zig 0.16 and lexbor v2.5.0 on the system library path
(`/usr/local/{include,lib}` on Linux, `/opt/homebrew/opt/lexbor` on
macOS — see `third_party/lexbor/BUILD_NOTES.md`).

Agent wiring walk-through: [`docs/agent-integration.md`](docs/agent-integration.md).

---

## What works today ✅

### CLI surface (`src/main.zig`)

| Command | Behaviour |
|---|---|
| `awr --version` \| `-v` | Print `0.0.<git-hash>` |
| `awr <url>` | Load page, run scripts, print full envelope `{url,status,title,body_text,window_data,tools}` |
| `awr tools <url>` | Print the WebMCP tool array registered by the page |
| `awr call <url> <tool> <json-args>` | Invoke `<tool>`; print `{ok:true,value:...}` or `{ok:false,error:...,message:...}` |

`<url>` accepts `file://…`, bare filesystem paths, and (once the HTTP
rewrite lands) `http(s)://…`.

### HTML parsing

- Parsed via **lexbor v2.5.0** (vendored build notes in
  `third_party/lexbor/BUILD_NOTES.md`).
- Full HTML5 document tree extraction (`title`, `body`, elements,
  attributes, text).
- 14 parser tests in `src/html/parser.zig`, 15 DOM tests in
  `src/dom/node.zig`.

### JavaScript engine (`src/js/engine.zig`)

- **QuickJS-NG** runtime + context per `Page`, reset between
  navigations (no cross-page state bleed).
- ES2020+ language, `JSON`, `Array.from`, Promise chains,
  `drainMicrotasks` drives `Promise.resolve(...).then(...)` to
  completion before results are extracted.
- `console.log` / `.warn` / `.error` route to a pluggable
  `ConsoleSink` (stderr by default; tests inject a capture).
- 24 engine tests cover eval, exception propagation, Promise
  resolution, console serialization.

### DOM bridge (`src/dom/bridge.zig`)

JS sees real page data through a thin polyfill over five Zig callbacks:

- `document.querySelector(sel)` / `querySelectorAll(sel)` with
  tag / `#id` / `.class` / `tag#id` / `tag.class` **plus descendant
  combinators** (`#catalog li`).
- `document.getElementById(id)`, `document.title`, `document.body`,
  `document.head`, `document.documentElement`.
- `document.createElement`, `getElementsByClassName`,
  `getElementsByTagName`.
- Element: `getAttribute` / `setAttribute` / `hasAttribute` /
  `removeAttribute`, `textContent`, `innerHTML`, `outerHTML`, `id`,
  `className`, `classList.{add,remove,contains,toggle}`,
  `appendChild` / `removeChild` / `insertBefore` (JS-side only — not
  reflected back to the Zig tree, which is fine for read-mostly agent
  workflows).
- `window`, `location`, `navigator` (with `userAgent`), `history`,
  `screen`, `localStorage` / `sessionStorage`, `XMLHttpRequest` stub.
- `window.location` is populated from the requested URL
  (`href`, `hostname`, `pathname`, `origin`, `search`, `protocol`).
- Observers (`MutationObserver`, `IntersectionObserver`,
  `ResizeObserver`, `PerformanceObserver`) are no-op stubs so pages
  that construct them don't throw.
- 17 bridge tests in `src/dom/bridge.zig`.

### WebMCP

- `navigator.modelContext.registerTool(descriptor, handler)` —
  synchronous *and* Promise-returning handlers.
- `navigator.modelContext.unregisterTool(name)`.
- `navigator.modelContext.getTools()` → JSON-Schema-shaped descriptor
  list.
- `navigator.modelContext.callTool(name, args)` → Promise.
- Error envelopes emitted to the CLI: `ToolNotFound`, `InvalidArgs`,
  `ToolThrew`, `ToolRejected`, `NotSerializable`.
- Async tools resolve through microtask drain before the envelope
  is returned.
- 7 WebMCP-specific page tests (`src/page.zig` lines 568-731) covering
  empty pages, sync tools, async tools, throwing tools, unknown
  tools, and a full 3-tool mock-shop integration test.

### Build & tooling

- `zig build` → `zig-out/bin/awr` (~9.9 MB ReleaseSafe Linux x86_64).
- `zig build -Doptimize=ReleaseSmall|ReleaseFast` supported.
- Test steps: `zig build test`, `test-net`, `test-js`, `test-html`,
  `test-dom`, `test-client`, `test-h2`, `test-page`, `test-tls`,
  `test-e2e`.
- macOS Homebrew paths auto-detected; Linux reads from `/usr/local`.

---

## What's stubbed today ⚠️

### HTTP / HTTPS fetch

`awr` CLI commands against `http://` or `https://` URLs currently fail:

- `src/client.zig:122-127` `fetchHttp` → `ConnectionFailed`.
- `src/client.zig:134-139` `fetchHttpsViaStd` → `TlsNotAvailable`.
- `src/net/http1.zig:298-340` `readResponse` is dead code in the MVP
  (5 tests gated as `error.SkipZigTest`).

The MVP runs against `file://` or bare-path fixtures. Durable fix
tracked as `DEV_NOTES.md` #6: rewrite the owned HTTP/1.1 path against
`std.Io.Reader` / `std.Io.File` and thread an `Io` handle from
`main()` through `Page` → `Client`. This is the top item in MVP+1.

### JavaScript Web APIs

- `setTimeout` / `setInterval` return `0` and **never fire**
  (`src/js/engine.zig:286-293`). Phase 3 wires them to libxev timers.
- `fetch()` returns a rejected Promise with message `"fetch() not
  available in Phase 2 — use Client.fetch() at the Zig layer"`
  (`src/js/engine.zig:304-313`).
- `structuredClone` is `undefined`.

### DOM bridge

- `<script src="…">` external scripts are **skipped** — only inline
  `<script>` tags execute. External script loading is a Phase 3 item.
- DOM mutations from JS (`innerHTML=`, `appendChild`, `textContent=`)
  update the JS-side element only; they are not reflected back to the
  Zig DOM tree. Read-mostly agent workflows don't notice this; a
  WebMCP page that mutates the DOM and then queries it will see its
  own mutations, but subsequent `awr tools` / `awr call` invocations
  reload the page fresh.
- CSS selector support is deliberately minimal:
  - ✅ `tag`, `#id`, `.class`, `tag#id`, `tag.class`, descendant
    (`#catalog li`).
  - ❌ attribute selectors (`[data-id]`), pseudo-classes
    (`:hover`, `:first-child`), combinators (`>`, `+`, `~`),
    multi-class (`.a.b`).

### Test runner

On gVisor-backed containers the Zig 0.16 test runner panics with an
integer overflow inside `std.Progress.start`; the compilation itself
is fine. Runs cleanly on native Linux/macOS (`DEV_NOTES.md` #7).

---

## What's intentionally out of scope (Phase 3 / MVP+1)

Per `spec/PRD.md` and `MVP_PLAN.md:111-126`:

**MVP+1 (next):**
- Stdio MCP server mode (`awr serve`) so Claude Code can attach AWR as
  a native MCP tool server.
- Agent stdin/stdout JSON protocol (`awr agent`).
- Local HTTP server for the mock fixture (`awr mock`).
- `std.Io`-based HTTP/HTTPS rewrite (DEV_NOTES #6).

**Phase 3 (bot-detection track):**
- JA4+ TLS fingerprint matching (Chrome 132).
- H2 SETTINGS / header order fidelity.
- Canvas / AudioContext / WebGL fingerprint synthesis.
- libvaxis TUI renderer.

**Phase 3 JS surface:**
- Real `setTimeout` / `setInterval` dispatch via libxev.
- `fetch()` wired to the Zig HTTP client.
- Event loop for `requestAnimationFrame`.

---

## Repo layout

```
src/
  main.zig          CLI entry; subcommand dispatch
  page.zig          Page (owns HTTP client + JS engine); WebMCP callTool
  client.zig        Fetch orchestration (HTTP stubs here)
  dom/
    bridge.zig      JS↔DOM polyfill + WebMCP host
    node.zig        Zig DOM tree (from lexbor); querySelector*
  html/             lexbor parse wrapper
  js/engine.zig     QuickJS-NG wrapper; console/timer/fetch stubs
  net/              HTTP/1.1, H2, TCP, TLS, cookies, URL, CA bundle
experiments/
  webmcp_mock.html  3-tool mock shop (search_products, get_price, add_to_cart)
docs/
  agent-integration.md   How to wire AWR into an agent
spec/
  PRD.md            Product spec; MVP definition at :194
  Phase1-Networking-TLS.md
  Phase2-Plan.md
third_party/lexbor/       Build notes for lexbor dependency
```

---

## Known patch debt

`DEV_NOTES.md` tracks 10 items with their durable-fix plans.
Highest-priority:

1. #1  `zig-pkg/quickjs_ng/build.zig` patched in-place (cache-wipe fragile).
2. #2  `libxev` pinned to moving `refs/heads/main.tar.gz`.
3. #6  HTTP/HTTPS fetch stubbed (MVP+1 unblocker).
4. #9  `JS_Eval` sentinel-termination is caller-enforced — would be
       nicer enforced by the type system (`evalOwned([:0]const u8)`).
5. #10 CSS selector coverage via lexbor's own selector engine.

---

## Licenses / dependencies

- [QuickJS-NG](https://github.com/quickjs-ng/quickjs) — MIT.
- [lexbor](https://github.com/lexbor/lexbor) — Apache 2.0, v2.5.0.
- [libxev](https://github.com/mitchellh/libxev) — MIT.
- BoringSSL (vendored macOS/arm64 static libs) — OpenSSL-derived licence.
