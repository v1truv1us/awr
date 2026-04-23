# AWR — Agentic Web Runtime

A headless terminal browser for AI agents. Loads pages and runs their
JavaScript with a CLI-first interface.

> **Canonical spec:** `spec/MVP.md`
> **Active work now:** `spec/subspecs/mvp-remainder.md`, `spec/subspecs/wpt-conformance.md`
> **Deferred tracks:** `spec/subspecs/mcp-stdio.md`,
> `spec/subspecs/browser-tui.md`, and `spec/Fingerprint-Plan.md`
> **Governance ADR:** `docs/adr/0001-spec-governance.md`

**Status:** AWR ships a usable CLI browser-runtime baseline, but MVP closure is
still active and is gated by the canonical WPT/Test262 conformance track and a
fully green default test baseline.

If canonical spec boundaries or document authority change, update both
`spec/MVP.md` and `docs/adr/0001-spec-governance.md` as part of the same change.

---

## Quick start

```bash
./scripts/bootstrap_deps.sh              # clones pinned libxev + zig-quickjs-ng locally
./scripts/bootstrap_lexbor.sh           # builds lexbor v2.5.0 into third_party/lexbor/install
zig build -Doptimize=ReleaseSafe \
  -Dlexbor-prefix=third_party/lexbor/install
                                        # produces zig-out/bin/awr (~9.9 MB)

./zig-out/bin/awr --version            # prints 0.0.<git-hash>
./zig-out/bin/awr tools experiments/webmcp_mock.html
./zig-out/bin/awr call  experiments/webmcp_mock.html \
    search_products '{"q":"Widget"}'
./zig-out/bin/awr call  experiments/webmcp_mock.html \
    add_to_cart '{"sku":"w-001","qty":2}'

# MVP operational smoke checks (local fixtures + mock server):
./scripts/mvp_smoke.sh
```

Requires Zig 0.16 and lexbor v2.5.0 on the system library path
(`/usr/local/{include,lib}` on Linux, `/opt/homebrew/opt/lexbor` on
macOS — see `third_party/lexbor/BUILD_NOTES.md`).

Agent wiring walk-through: [`docs/agent-integration.md`](docs/agent-integration.md).

Build + test + MVP-readiness runbook: [`docs/BUILD_MVP_READINESS.md`](docs/BUILD_MVP_READINESS.md).

---

## What works today ✅

### CLI surface (`src/main.zig`)

| Command | Behaviour |
|---|---|
| `awr --version` \| `-v` | Print `0.0.<git-hash>` |
| `awr <url>` | Load page, run scripts, print full envelope `{url,status,title,body_text,window_data,tools}` |
| `awr tools <url>` | Print the WebMCP tool array registered by the page |
| `awr call <url> <tool> <json-args>` | Invoke `<tool>`; print `{ok:true,value:...}` or `{ok:false,error:...,message:...}` |
| `awr mock` | Serve the local mock fixture for CLI/WebMCP smoke tests |

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
  `screen`, `localStorage` / `sessionStorage`, and other browser-facing APIs on
  the active conformance path.
- `window.location` is populated from the requested URL
  (`href`, `hostname`, `pathname`, `origin`, `search`, `protocol`).
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
  `test-e2e`, `test-wpt`, `test-test262`.
- macOS Homebrew paths auto-detected; Linux reads from `/usr/local`.

---

## Current caveats

- Native MCP stdio server mode remains deferred; use `awr tools` and `awr call`
  as the supported integration surface.
- Browser/TUI work and later fingerprinting remain deferred; `awr <url>` is the
  main shipped product path.
- MVP closure is still active: the repo is moving toward WPT/Test262-gated
  closure and removal of shipped stubs on the browser/runtime surface.

---

## Deferred tracks

See the canonical spec map in `spec/MVP.md`.

- **Active MVP completion track:** `spec/subspecs/mvp-remainder.md`
- **Conformance authority:** `spec/subspecs/wpt-conformance.md`
- **Deferred MCP stdio:** `spec/subspecs/mcp-stdio.md`
- **Deferred browser/TUI:** `spec/subspecs/browser-tui.md`
- **Deferred fingerprint roadmap:** `spec/Fingerprint-Plan.md`

---

## Repo layout

```
src/
  main.zig          CLI entry; subcommand dispatch
  page.zig          Page (owns HTTP client + JS engine); WebMCP callTool
  client.zig        Fetch orchestration for the shipped CLI/browser path
  dom/
    bridge.zig      JS↔DOM polyfill + WebMCP host
    node.zig        Zig DOM tree (from lexbor); querySelector*
  html/             lexbor parse wrapper
  js/engine.zig     QuickJS-NG wrapper; console/timer/fetch runtime hooks
  net/              HTTP/1.1, H2, TCP, TLS, cookies, URL, CA bundle
experiments/
  webmcp_mock.html  3-tool mock shop (search_products, get_price, add_to_cart)
docs/
  agent-integration.md   How to wire AWR into an agent
spec/
  MVP.md            Canonical umbrella spec
  PRD.md            Product context only; non-canonical for execution
  Fingerprint-Plan.md
  subspecs/
    mvp-remainder.md
    wpt-conformance.md
    mcp-stdio.md
    browser-tui.md
third_party/lexbor/       Build notes for lexbor dependency
```

---

## Known patch debt

`DEV_NOTES.md` tracks 10 items with their durable-fix plans.
Highest-priority:

1. #1  `zig-pkg/quickjs_ng/build.zig` patched in-place (cache-wipe fragile).
2. #2  `libxev` pinned to moving `refs/heads/main.tar.gz`.
3. #6  standalone network/runtime debt beyond the shipped CLI/browser MVP path.
4. #9  `JS_Eval` sentinel-termination is caller-enforced — would be
       nicer enforced by the type system (`evalOwned([:0]const u8)`).
5. #10 CSS selector coverage via lexbor's own selector engine.

---

## Licenses / dependencies

- [QuickJS-NG](https://github.com/quickjs-ng/quickjs) — MIT.
- [lexbor](https://github.com/lexbor/lexbor) — Apache 2.0, v2.5.0.
- [libxev](https://github.com/mitchellh/libxev) — MIT.
- BoringSSL (vendored macOS/arm64 static libs) — OpenSSL-derived licence.
