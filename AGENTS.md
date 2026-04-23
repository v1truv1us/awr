# AGENTS.md — Subdirectory Agent Context

This file provides module-level guidance for agents working in specific parts of the AWR codebase. Read `CLAUDE.md` first for project-wide context.

Global framing:

- Treat AWR as a CLI-first browser runtime
- Prioritize real page execution and readable terminal output
- Use curated WPT and Test262 coverage as the first correctness signal for DOM and JS work
- Treat WebMCP as a supported layer on top of the browser runtime

Execution specs:

- Canonical umbrella spec: `spec/MVP.md`
- Active work now: `spec/subspecs/mvp-remainder.md`, `spec/subspecs/wpt-conformance.md`
- Deferred tracks: `spec/subspecs/mcp-stdio.md`, `spec/subspecs/browser-tui.md`, `spec/Fingerprint-Plan.md`
- Historical/background docs: `MVP_PLAN.md`, `MVP_BACKLOG.md`, `spec/PRD.md`
- Governance ADR: `docs/adr/0001-spec-governance.md`

Change control rule:

- If spec boundaries, canonical-document authority, or documentation governance changes, update `docs/adr/0001-spec-governance.md` in the same change.

---

## `src/net/` — Networking Stack

**Focus**: Networking, TLS, and transport correctness
**Test command**: `zig build test-net`, `zig build test-tls`, `zig build test-h2`, `zig build test-client`

### What lives here
TCP (libxev), TLS (BoringSSL), HTTP/1.1, HTTP/2 (nghttp2), URL parsing, cookies (RFC 6265), connection pooling, and fingerprint constants.

### Constraints
- **Header order is load-bearing.** Headers use `ArrayList` to preserve insertion order. Never sort, deduplicate, or reorder. This directly affects TLS and HTTP fingerprinting.
- **C shims bridge Zig ↔ C libraries.** `tls_awr_shim.c` wraps BoringSSL; `h2_shim.c` wraps nghttp2. Changes here require understanding both the Zig calling convention and the C library's memory model.
- **Fingerprint constants are in `fingerprint.zig`.** The cipher suite list, TLS extension order, and HTTP/2 SETTINGS values must match Chrome 132. Verify with `zig build test-tls` after any change.
- **BoringSSL is pre-built.** Static libs in `third_party/boringssl/lib/`. Do not attempt to compile BoringSSL from source.
- **Connection pooling (`pool.zig`) routes by ALPN.** H2 connections are multiplexed; H1.1 connections are keep-alive. The pool manages both.
- **Cookie jar (`cookie.zig`) follows RFC 6265.** Domain matching, path scoping, expiry, and secure-only flags are all implemented.

### Key relationships
- `client.zig` (one level up) wires everything in this directory together — it's the primary consumer.
- `tls_conn.zig` → `tcp.zig` (TLS wraps TCP)
- `h2session.zig` → `http2.zig` (session management wraps frame layer)
- `pool.zig` → `tls_conn.zig` + `h2session.zig` (pool manages connections)

---

## `src/js/` — JavaScript Engine

**Focus**: JavaScript runtime behavior
**Test command**: `zig build test-js`

### What lives here
QuickJS-NG wrapper providing `console.log`, `fetch()`, `setTimeout`, and Promise microtask draining.

### Constraints
- **`use_llvm = true` is required.** Any build target linking QuickJS-NG must set this flag in `build.zig`.
- **Single file**: `engine.zig` contains the entire JS runtime integration. It's self-contained.
- **Timers and `fetch()` ship on the CLI/browser MVP path.** Preserve their current behavior and extend them only with source-backed tests or fixtures.
- **Promise draining is explicit.** After script execution, the engine drains the microtask queue. This is called from `page.zig`.
- **Conformance work starts here.** When runtime behavior changes, check whether a curated WPT or Test262 case should be added or updated.

### Key relationships
- `page.zig` is the primary consumer — it creates the JS runtime, injects globals, and executes scripts.
- `dom/bridge.zig` injects `document.*` APIs into the JS context.
- `webmcp.zig` injects `navigator.modelContext` into the JS context.

---

## `src/html/` — HTML Parser

**Focus**: HTML parsing into DOM input
**Test command**: `zig build test-html`

### What lives here
Lexbor HTML parser wrapper. Parses HTML strings into a tree that gets converted to AWR's DOM representation.

### Constraints
- **Single file**: `parser.zig` wraps the Lexbor C library.
- **Lexbor is via Homebrew.** Include/lib paths point to `/opt/homebrew/`.
- **Output is Lexbor's internal tree.** The DOM conversion (Lexbor tree → AWR `dom.Node`) happens in `dom/node.zig`, not here.

---

## `src/dom/` — DOM Tree & JS Bridge

**Focus**: DOM behavior exposed to page code
**Test command**: `zig build test-dom`

### What lives here
DOM tree types (`node.zig`) and the JS↔DOM bridge (`bridge.zig`). Provides query, mutation, and event-facing DOM behavior exposed to page code.

### Constraints
- **`node.zig` defines the tree structure.** `Node` is a tagged union of element, text, comment, etc. Tree traversal, querySelector, and getElementById live here.
- **`bridge.zig` exposes DOM to JS.** It registers `document.getElementById`, `document.querySelector`, `document.createElement`, etc. as QuickJS C functions.
- **No shipped stubs.** If a DOM-facing API is exposed on the MVP browser/runtime path, it must be real or removed until it can be implemented correctly.
- **WPT-first applies here most strongly.** Prefer changes backed by curated DOM conformance cases over one-off behavior tweaks.

### Key relationships
- `html/parser.zig` → `dom/node.zig` (parsed HTML becomes DOM nodes)
- `dom/bridge.zig` → `js/engine.zig` (bridge injects into JS runtime)
- `page.zig` orchestrates the full pipeline: parse → DOM → bridge → execute

---

## `src/` (root-level files) — Orchestration & UI

### `page.zig` — Page Orchestrator
**Test command**: `zig build test-page`

The integration hub. Fetches HTML via `client.zig`, parses via `html/parser.zig`, builds DOM via `dom/node.zig`, injects JS globals via `js/engine.zig` + `dom/bridge.zig` + `webmcp.zig`, executes `<script>` tags, drains promises, and returns results.

This file defines most real browser behavior.
Prefer changes that improve CLI page execution before adding new protocol surfaces.

### `client.zig` — HTTP Client
**Test command**: `zig build test-client`

Wires the entire `net/` stack into a usable HTTP client. Handles redirects, cookies, ALPN-based H1/H2 routing, and connection pooling. ~1200 lines.

### `render.zig` — Terminal Renderer
**Test command**: `zig build test-render`

Converts DOM trees into ANSI-formatted terminal output. Word wrapping, link footnotes, heading formatting, list rendering, and table layout live here.

### `browser.zig` + `tui.zig` — TUI Browser
Interactive terminal browser. Vim-style keys (j/k scroll, Enter follow link, q quit, / search). `browser.zig` is the session logic; `tui.zig` is raw terminal I/O.

### `webmcp.zig` — WebMCP Polyfill
Implements `navigator.modelContext.registerTool()`. Captures tool schemas registered by page scripts. Used by `page.zig` to extract WebMCP tools after script execution.

This is important, but it is not the primary MVP entry point.
Do not let WebMCP changes regress the CLI browser path.

### `mcp_stdio.zig` — MCP Server
JSON-RPC 2.0 server over stdin/stdout implementing the MCP protocol. Exposes `tools/list` and `tools/call` methods. Wraps `page.zig` for tool discovery and invocation.

This track is currently deferred; treat `spec/subspecs/mcp-stdio.md` as the
status doc, not this file's existence as proof of product readiness.

### `browse_heuristics.zig` — Content Extraction
Readability-style heuristics for extracting main content from web pages. Scores DOM nodes by content density to find the article/main content.

### `main.zig` — CLI Entry Point
Parses CLI arguments and dispatches to commands. The shipped browser/WebMCP CLI
surface includes the default fetch path plus `tools`, `call`, and `mock`.

`awr <url>` is the main product path.
Keep help text and defaults centered on the browser workflow.

### `test_e2e.zig` — End-to-End Tests
Integration tests that exercise the full pipeline (fetch → parse → render / fetch → parse → JS → WebMCP).

Also see:

- `tests/wpt_runner.zig` for curated DOM conformance coverage
- `tests/test262_runner.zig` for curated JS language coverage
