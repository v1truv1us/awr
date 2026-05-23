# AWR — Agentic Web Runtime

A dual-surface CLI-first terminal browser, written in Zig. One binary
serves both **humans** in the terminal (`awr browse`) and **AI agents**
via JSON / Markdown / WebMCP — sharing one cookie jar, one connection
pool, one rendered DOM.

> **Spec index:** `SPEC.md`
> **Canonical spec:** `spec/MVP.md`
> **Cross-tier roadmap:** `spec/subspecs/browser-roadmap.md`
> **Tier 0 closure record:** `spec/subspecs/mvp-remainder.md`, `spec/subspecs/wpt-conformance.md`
> **Tier 1 closed sub-spec:** `spec/subspecs/browser-tui.md`
> **Deferred tracks:** Tier 4 layout engine, Tier 5 SPA parity, `spec/subspecs/mcp-stdio.md`, `spec/Fingerprint-Plan.md`
> **Governance ADR:** `docs/adr/0001-spec-governance.md`

**Status:**
- **Tier 0** (CLI-first agent runtime + daemon mode + WPT/Test262 gates) is
  CLOSED and shipped.
- **Tier 1** (interactive TUI parity with lynx/w3m: form fields, focus,
  keyboard input, history, URL bar, cookie inspector, browser-cookie
  import) is CLOSED and shipped.
- **Tiers 2–3** (render/UX polish and lightly dynamic site support: History,
  Storage, SSE, WebSocket, events) are CLOSED under curated WPT/Test262 gates.
- **Starter CSSOM** is active under `spec/subspecs/cssom.md` and remains
  explicitly non-layout.
- **Tiers 4–5** (real CSS/layout engine and full SPA parity) are documented in
  `spec/subspecs/browser-roadmap.md §3` and deferred.

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

# Full smoke gate — MVP fixtures + bug-fix regression suite (B1/B2/B3
# hangs, cookie persistence, end-to-end sign-in, markdown extract).
# Honors AWR_SMOKE_OFFLINE=1 to skip network checks for CI.
zig build smoke
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
| `awr render <url> [--width N]` | Load page, print the rendered terminal text (human-readable, ANSI-friendly) |
| `awr extract <url>` | Load page, print Markdown for LLM agents (chrome-filtered, headings + inline `[text](url)` preserved) |
| `awr post <url> [k=v ...]` | POST URL-encoded form fields, follow redirects, absorb cookies |
| `awr submit <url> [--form=SEL] [k=v ...]` | Load page, find `<form>`, merge user fields with hidden inputs (CSRF), POST to the form's action |
| `awr tools <url>` | Print the WebMCP tool array registered by the page |
| `awr call <url> <tool> <json-args>` | Invoke `<tool>`; print `{ok:true,value:...}` or `{ok:false,error:...,message:...}` |
| `awr browse <url>` | Open URL in interactive terminal browser (vim keys, scroll, link nav, form fill) |
| `awr mock` | Serve the local mock fixture for CLI/WebMCP smoke tests |

`<url>` accepts `file://…`, bare filesystem paths, and `http(s)://…`.

#### Sign-in flow

Set `AWR_COOKIE_JAR` to persist cookies across invocations (Netscape
`cookies.txt` format, curl/wget compatible). Then chain `submit` →
`extract`:

```bash
export AWR_COOKIE_JAR=$HOME/.local/state/awr/cookies.txt

# Load login page, parse the form (CSRF auto-pulled from hidden input),
# POST credentials, follow the 302 to dashboard.
awr submit https://site/login user=alice password=hunter2

# Subsequent fetches carry the session cookie.
awr extract https://site/dashboard > dashboard.md
```

Per `spec/subspecs/agent-browser.md §2`, supported cookie attributes
include `Max-Age=`, `Expires=` (RFC 6265 §5.1.1 dates), `Path`,
`Domain`, `Secure`, `HttpOnly`, `SameSite`. `<form method="post">` and
`<form method="get">` are both submitted by `awr submit` with hidden-
input round-trip for CSRF tokens.

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
  `appendChild` / `removeChild` / `insertBefore`.
- `window`, `location`, `navigator` (with `userAgent`), `screen`, and in-memory
  `localStorage` / `sessionStorage`.
- `history` is intentionally limited to same-origin `pushState` /
  `replaceState` plus `length` and `state`.
- `fetch()` and `XMLHttpRequest` accept async GET and POST requests. POST
  bodies are strings or `URLSearchParams` instances stringified to
  `application/x-www-form-urlencoded`. Other methods, init keys, and body
  shapes still throw. See `spec/subspecs/agent-browser.md`.
- Starter CSSOM is intentionally narrow and governed by
  `spec/subspecs/cssom.md`: stylesheet loading, inline `element.style`, cascade
  for a small property set, and simple non-layout `getComputedStyle()` values
  such as `display` / `visibility`.
- `IntersectionObserver` and `ResizeObserver` are not part of the shipped MVP
  surface.
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

### Observability

`AWR_TIMING=1` prints `[timing] phase=Nms` lines to stderr — useful for
interactive debugging of a single fetch.

`AWR_TELEMETRY` opts into structured per-session metrics emitted as one
JSON Lines record per invocation. Catches perf regressions in
aggregate logs without linking against any observability SDK.

```bash
AWR_TELEMETRY=1                  awr <url>   # → stderr
AWR_TELEMETRY=stderr             awr <url>   # → stderr (alias)
AWR_TELEMETRY=/var/log/awr.jsonl awr <url>   # → append to file
```

The schema is versioned (`v: 1`) and includes top-level phase
timings, sub-phase breakdowns, and external-script-fetch
aggregates. See `src/telemetry.zig` for the current field list.
Pipe to `jq`, ship to Loki / Datadog / Sentry / OTLP-via-fluentbit
without recompiling AWR.

---

## Current caveats

- Native MCP stdio server mode remains deferred; use `awr tools` and `awr call`
  as the supported integration surface.
- Browser/TUI work and later fingerprinting remain deferred; `awr <url>` is the
  main shipped product path.
- The closed MVP surface is intentionally narrower than a full browser API.
  See `spec/MVP.md` and `spec/subspecs/wpt-conformance.md` for the exact shipped
  subset.

---

## Spec map

See the canonical spec map in `spec/MVP.md`.

- **Cross-tier roadmap:** `spec/subspecs/browser-roadmap.md`
- **Tier 0 closure record:** `spec/subspecs/mvp-remainder.md`
- **Conformance authority (corpus grows with active tiers):** `spec/subspecs/wpt-conformance.md`
- **Tier 1 closed sub-spec:** `spec/subspecs/browser-tui.md`
- **Deferred MCP stdio:** `spec/subspecs/mcp-stdio.md`
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
    browser-roadmap.md   Cross-tier capability ladder (T0-T5)
    browser-tui.md       Tier 1 closed: interactive TUI parity
    mvp-remainder.md     Tier 0 closure record
    wpt-conformance.md   Curated WPT/Test262 corpus + gates
    agent-browser.md     Tier 0 agent surface (closed)
    rendering.md         Tier 0 terminal renderer (closed)
    daemon-mode.md       Tier 0 long-lived `awrd` (closed)
    cssom.md             Active starter CSSOM: non-layout style/cascade
    mcp-stdio.md         Deferred native MCP stdio server
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
