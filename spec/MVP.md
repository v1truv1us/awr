# AWR MVP — Fully Qualified Definition

> **Single source of truth.** Supersedes the informal MVP scope that
> shipped as the initial `v1` slice (the in-page WebMCP plumbing alone).
> `spec/PRD.md` and `MVP_PLAN.md` defer to this file for the acceptance
> bar. MVP is declared done when every row in §5 is ✅ and every
> acceptance test in §3 passes on a clean
> `zig build -Doptimize=ReleaseSafe`.

> **Scope correction (effective April 21, 2026):**
> WebMCP is **not** part of MVP. WebMCP-related requirements and tests in
> this document are retained for historical context, but are now tracked as
> **MVP+1**. For MVP gating, treat FR-4, FR-5.3/FR-5.4/FR-5.7, and AT-1/AT-2/
> AT-3/AT-5 as non-blocking.

---

## 0. Target

A production-grade agentic web runtime that:

1. loads real web pages (HTTP, HTTPS, `file://`, bare paths);
2. runs the page's JavaScript — inline **and** external — to completion;
3. returns stable JSON page output suitable for downstream agent tooling.

**No stubs on any code path the agent exercises.** `TODO`, `unreachable`,
`error.NotImplemented`, or "Phase 3" gates inside FR-1 through FR-5 are
release blockers.

---

## 1. Functional Requirements

### FR-1  Page fetch

| # | Requirement |
|---|---|
| FR-1.1 | `awr <https-url>` fetches the page body over a real TLS connection. |
| FR-1.2 | `awr <http-url>` fetches the page body over a real TCP connection. |
| FR-1.3 | `awr file://…` and `awr <bare-path>` load from disk. |
| FR-1.4 | 3xx responses follow `Location` up to 10 hops; relative and absolute `Location` both resolve. |
| FR-1.5 | Network errors surface as a non-zero exit and a stderr diagnostic — never a silent empty body. |

### FR-2  HTML parse / DOM

| # | Requirement |
|---|---|
| FR-2.1 | Full HTML5 parse via lexbor. |
| FR-2.2 | DOM mutations performed by JS (`innerHTML=`, `textContent=`, `appendChild`, `removeChild`, `insertBefore`, `setAttribute`, `classList.*`) are visible to subsequent `querySelector*` calls in the same page load. |
| FR-2.3 | CSS selector support: `tag`, `#id`, `.class`, `tag#id`, `tag.class`, `[attr]`, `[attr=val]`, `:not(sel)`, descendant (` `), child (`>`), adjacent sibling (`+`), general sibling (`~`), multi-class (`.a.b`). |

### FR-3  JavaScript execution

| # | Requirement |
|---|---|
| FR-3.1 | Inline `<script>` executes via QuickJS-NG in document order. |
| FR-3.2 | External `<script src="…">` is fetched (same client as FR-1) and executed in order; `async`/`defer` honored. |
| FR-3.3 | `setTimeout` / `setInterval` / `clearTimeout` / `clearInterval` dispatch via a libxev-backed event loop; callbacks fire before `Page.processHtml` returns. |
| FR-3.4 | `fetch()` inside the page calls the same Zig HTTP client; returns a real `Response` with `.text()` / `.json()` / `.ok`. |
| FR-3.5 | `structuredClone(x)` is defined and round-trips JSON-compatible values. |
| FR-3.6 | Microtask queue drains between each macrotask and before result extraction. |
| FR-3.7 | `console.log`/`.warn`/`.error` route to a pluggable sink (stderr by default). |

### FR-4  WebMCP

| # | Requirement |
|---|---|
| FR-4.1 | `navigator.modelContext.registerTool(descriptor, handler)` — sync and Promise-returning handlers. |
| FR-4.2 | `navigator.modelContext.unregisterTool(name)`. |
| FR-4.3 | `navigator.modelContext.getTools()` → array of `{name, description, inputSchema}`. |
| FR-4.4 | `navigator.modelContext.callTool(name, args)` → Promise. |
| FR-4.5 | Error envelopes: `ToolNotFound`, `InvalidArgs`, `ToolThrew`, `ToolRejected`, `NotSerializable`. |

### FR-5  CLI

| # | Requirement |
|---|---|
| FR-5.1 | `awr --version` / `-v` → `0.0.<git-hash>` on stdout, exit 0. |
| FR-5.2 | `awr <url>` → one-line JSON `{url,status,title,body_text,window_data,tools}`. |
| FR-5.3 | `awr tools <url>` → JSON tools array (`[]` if none). |
| FR-5.4 | `awr call <url> <tool> <json>` → envelope `{ok, value}` or `{ok:false, error, message}`. |
| FR-5.5 | `{ok:false}` exits non-zero; success exits 0. |
| FR-5.6 | stdout carries only the documented JSON; all diagnostics go to stderr. |
| FR-5.7 | `awr mock [--port N]` serves `experiments/webmcp_mock.html` over HTTP (used to exercise the FR-1 path end-to-end). |

---

## 2. Non-Functional Requirements

| # | Requirement |
|---|---|
| NFR-1 | Zero stubs in FR-1 through FR-5 code paths. No `error.NotImplemented`, `error.TlsNotAvailable`, `error.ConnectionFailed`-as-sentinel, or `SkipZigTest` gates on required paths. |
| NFR-2 | `zig build -Doptimize=ReleaseSafe` produces a working binary on Linux x86_64 and macOS arm64. |
| NFR-3 | `zig build test` passes on native Linux and macOS (gVisor `std.Progress` panic is documented in `DEV_NOTES.md` and CI runs off gVisor). |
| NFR-4 | No allocator leaks over 100 iterations of `awr tools` / `awr call` against the mock fixture (`test-e2e` loop). |
| NFR-5 | Binary size ≤ 15 MB ReleaseSafe. |

---

## 3. Acceptance Tests (hard gate)

Each of these must produce the documented output against a clean build.

### AT-1  Local file, sync WebMCP tool

```bash
$ ./zig-out/bin/awr tools experiments/webmcp_mock.html
```
→ JSON array containing `search_products`, `get_price`, `add_to_cart`
  descriptors with `inputSchema` objects.

### AT-2  Async (Promise-returning) tool

```bash
$ ./zig-out/bin/awr call experiments/webmcp_mock.html add_to_cart \
    '{"sku":"w-001","qty":2}'
{"ok":true,"value":{"cart_size":1,"total":19.98}}
```

### AT-3  Error envelope, non-zero exit

```bash
$ ./zig-out/bin/awr call experiments/webmcp_mock.html nope '{}'
{"ok":false,"error":"ToolNotFound","message":"No tool registered with name nope"}
$ echo $?
1
```

### AT-4  Real HTTPS fetch

```bash
$ ./zig-out/bin/awr https://example.com | jq -r .title
Example Domain
```

### AT-5  Mock HTTP server round-trip

```bash
$ ./zig-out/bin/awr mock --port 7777 &
$ ./zig-out/bin/awr tools http://localhost:7777/webmcp_mock.html
# identical JSON to AT-1
```

### AT-6  External `<script src>`

Fixture `experiments/external_script.html` loads `./tools.js`
via `<script src="./tools.js">`; `tools.js` calls `registerTool`.
`awr tools` must list that tool.

### AT-7  `setTimeout` + `fetch` inside page

Fixture `experiments/async_tool.html` registers a tool whose handler
schedules `setTimeout(…, 50)` and calls `fetch('/data.json')` on the
mock server. The invocation envelope must carry the fetched body.

### AT-8  DOM mutation visible to re-query

A tool handler that appends an element and immediately calls
`document.querySelector` on the appended node must find it inside the
same invocation.

### AT-9  CSS selector coverage

`src/dom/node.zig` tests exercise every selector in FR-2.3.

### AT-10  Exit-code discipline

`awr --version` exits 0; `awr nonsense://url` exits non-zero with a
stderr diagnostic; `awr tools <good-url>` exits 0 with stdout JSON.

### AT-11  Leak-free repeated invocation

```bash
$ for i in $(seq 1 100); do
    ./zig-out/bin/awr call experiments/webmcp_mock.html get_price \
        '{"sku":"w-002"}' > /dev/null
  done
```
RSS growth ≤ 5 MB; no allocator leaks reported under `ReleaseSafe`.

---

## 4. Explicitly Out of Scope for MVP

These stay deferred — listed here so we never silently expand scope:

- JA4+ TLS fingerprint matching (Phase 3).
- libvaxis TUI renderer (Phase 3).
- Canvas / AudioContext / WebGL fingerprint synthesis (Phase 3).
- WebSocket / Server-Sent Events.
- Service workers / Web Workers / SharedWorker.
- `XMLHttpRequest` beyond the existing no-op stub (modern pages use
  `fetch`; FR-3.4 covers that).
- CSS layout / rendering (this is a headless tool; we parse, not
  render).
- MCP stdio server mode (MVP+1; `awr call`'s envelope is already
  MCP-shaped, so shell-tool integrations work today).
- Multi-tab / multi-window / `window.open`.
- Cookies as first-class state across invocations (each `awr` call
  loads the page fresh).

---

## 5. Stub Closure Checklist

Every row must be ✅ before MVP is declared done. Paths refer to the
current `main`; line numbers may drift as implementation evolves.

| # | Stub | Location | Unblocks | Status |
|---|------|----------|----------|--------|
| S1 | HTTP/HTTPS fetch returns `ConnectionFailed`/`TlsNotAvailable` | `src/client.zig:122-139`, `src/net/http1.zig:298-340` | FR-1.1, FR-1.2, AT-4, AT-5 | ❌ |
| S2 | External `<script src>` silently skipped | `src/dom/bridge.zig` script-walk | FR-3.2, AT-6 | ❌ |
| S3 | `setTimeout`/`setInterval` return 0, never fire | `src/js/engine.zig:286-293` | FR-3.3, AT-7 | ❌ |
| S4 | `fetch()` in JS returns rejected Promise | `src/js/engine.zig:304-313` | FR-3.4, AT-7 | ❌ |
| S5 | `structuredClone` undefined | `src/js/engine.zig` | FR-3.5 | ❌ |
| S6 | JS DOM mutations not reflected to Zig tree | `src/dom/bridge.zig` mutation hooks | FR-2.2, AT-8 | ❌ |
| S7 | CSS selectors missing `[attr]`, `:not`, `>`, `+`, `~`, multi-class | `src/dom/node.zig` selector engine | FR-2.3, AT-9 | ❌ |
| S8 | `awr mock` subcommand does not exist | `src/main.zig` | FR-5.7, AT-5 | ❌ |
| S9 | `DEV_NOTES.md` patch debt #1, #2, #4, #5 (build-system fragility) | see DEV_NOTES | NFR-2 | ❌ |

---

## 6. Execution order

Each step lands in its own commit with a test that was previously
impossible to write. No step starts until the prior step's acceptance
test passes.

1. **S1** HTTP/HTTPS fetch — owned HTTP/1.1 over `std.Io.Reader`, TLS
   via `std.crypto.tls`. Threads `std.Io` through `main` → `Page` →
   `Client`. Unblocks AT-4.
2. **S8** `awr mock` subcommand — minimal in-process HTTP server over
   the same network stack as S1. Unblocks AT-5.
3. **S2** External `<script src>` — fetch via S1, execute via the
   existing `JSEngine.eval`. Unblocks AT-6.
4. **S3 + S4** libxev event loop + `fetch()` JS binding — wires
   `setTimeout`/`setInterval`/`fetch` into one macrotask loop that
   `Page.processHtml` drains before returning. Unblocks AT-7.
5. **S6** DOM mutation reflection — JS mutation callbacks update the
   Zig DOM via lexbor mutators. Unblocks AT-8.
6. **S7** CSS selector coverage — swap `src/dom/node.zig` matching to
   lexbor's CSS selector engine (`lxb_selectors_*`). Unblocks AT-9.
7. **S5** `structuredClone` — trivial JS-side polyfill plus test.
8. **S9** Build-system patch debt — pin `libxev`, vendor QuickJS-NG
   under `third_party/`, add `-Dlexbor-prefix=`, Linux BoringSSL libs.
   Not user-facing but required for NFR-2.

After step 8: CI runs the full AT-1 through AT-11 suite; if green, we
tag `mvp-v2` and flip the README's status banner to "MVP production —
no stubs".

---

## 7. Change control

This file is the MVP contract. Anything not listed in §1/§2/§3 is
explicitly out of scope (§4). Adding a new requirement means:

1. Propose the change as a PR that edits this file.
2. If accepted, the corresponding stub/test goes into §5/§3.
3. No change becomes "MVP" by accident through a feature PR.

The earlier "MVP v1" (the in-page WebMCP plumbing — commit `499fff4`)
remains the foundation; this document is the full contract.
