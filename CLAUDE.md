# AWR — CLI Browser Runtime

## What This Is

AWR is a CLI-first MVP web browser written in Zig.
Its main job is to fetch real pages, execute enough DOM and JS to make them useful, and render practical output in the terminal.

WebMCP and MCP server mode are supported features.
They should be treated as extensions of the browser runtime, not the primary framing for the product.

## Principles

1. **Think Before Coding** — Read the relevant source files before making changes. Understand the existing patterns, error handling, and memory management in the file you're touching.
2. **Simplicity First** — Zig rewards straightforward code. Don't add abstractions unless they remove duplication or prevent bugs. Prefer explicit over clever.
3. **Surgical Changes** — Change only what's needed. AWR has a working TLS fingerprint and 700+ passing tests. A stray change to header ordering or TLS config breaks the product's core value.
4. **Goal-Driven Execution** — Every change should improve the CLI browser, runtime correctness, or a concrete test gap. If you can't name the goal, stop and ask.
5. **WPT-First Execution** — Prefer browser behavior that moves curated WPT and Test262 coverage forward before adding custom surface area.

## Build & Test

```bash
zig build              # Build
zig build test         # Run all tests
zig build run          # Build and run
zig fmt src/           # Format
```

### Targeted test commands
```bash
zig build test-net     # Networking stack only
zig build test-tls     # TLS fingerprint tests
zig build test-client  # HTTP client tests
zig build test-h2      # HTTP/2 tests
zig build test-js      # QuickJS engine tests
zig build test-html    # HTML parser tests
zig build test-dom     # DOM tree/bridge tests
zig build test-page    # Page orchestrator tests
zig build test-render  # Renderer tests
zig build test-e2e     # End-to-end integration tests
zig build test-wpt     # WPT DOM conformance subset
zig build test-test262 # JS conformance subset
```

### Dependencies
- **Zig** 0.14+ (primary toolchain)
- **BoringSSL** — pre-built static libs in `third_party/boringssl/` (not compiled during build)
- **nghttp2** — via Homebrew (`/opt/homebrew/`)
- **lexbor** — via Homebrew (`/opt/homebrew/`)
- **libxev** — Zig package (event loop)
- **QuickJS-NG** — Zig package (JS engine, requires `use_llvm = true`)
- **CA bundle** — Mozilla roots in `third_party/ca-bundle/`

## Product framing

Primary experience:

1. `awr <url>` renders readable terminal output
2. `awr tools <url>` returns discovered WebMCP tools
3. `awr call <url> <tool> <json>` invokes a discovered WebMCP tool
4. `awr mock` serves local test fixtures

Secondary experience:

1. deferred native MCP stdio work
2. deferred browser/TUI expansion beyond the core browser-runtime MVP closure

When docs or code comments need a one-line description, use **CLI-first web browser runtime**.

## Architecture

```
src/main.zig           CLI entry: default fetch path plus tools/call/mock
src/client.zig         HTTP client — wires TLS + H1/H2 + cookies + redirects + pooling
src/page.zig           Page orchestrator — fetch → parse → DOM → JS bridge → scripts
src/render.zig         Terminal renderer — ANSI formatting, word wrap, link footnotes, tables
src/browser.zig        TUI browser session — vim keys, scroll, link nav, search
src/tui.zig            Raw terminal I/O
src/webmcp.zig         navigator.modelContext polyfill — tool registration/discovery/invocation
src/mcp_stdio.zig      MCP JSON-RPC 2.0 server over stdin/stdout
src/browse_heuristics.zig  Content extraction heuristics (readability-style)
src/test_e2e.zig       End-to-end integration tests

src/net/
  tls_conn.zig         TLS via BoringSSL — fingerprint-controlled handshake
  http1.zig            HTTP/1.1 request/response
  http2.zig            HTTP/2 frame layer
  h2session.zig        HTTP/2 session management (nghttp2 C shim)
  tcp.zig              TCP via libxev
  pool.zig             Connection pooling (keep-alive, ALPN routing)
  url.zig              URL parser
  cookie.zig           RFC 6265 cookie jar
  fingerprint.zig      JA4 fingerprint constants (Chrome 132)
  ca_bundle.zig        CA certificate loading
  tls_awr_shim.c       BoringSSL C interop shim
  h2_shim.c            nghttp2 C interop shim

src/js/engine.zig      QuickJS-NG wrapper — console, fetch(), setTimeout, Promises
src/html/parser.zig    Lexbor HTML parser wrapper
src/dom/node.zig       DOM tree types, querySelector, getElementById
src/dom/bridge.zig     JS ↔ DOM bridge and active conformance surface
```

## Code Conventions

- **Doc comments**: Every `.zig` file starts with a `///` doc comment explaining purpose and constraints. Maintain this.
- **Co-located tests**: Tests live at the bottom of each source file (`test "..." { ... }`), not in separate files. Integration/conformance tests are the exception (`tests/`, `src/test_e2e.zig`).
- **Explicit allocators**: All allocation takes an `Allocator` parameter. `GeneralPurposeAllocator` in main, `testing.allocator` in tests.
- **Error unions + errdefer**: Zig error unions everywhere. Always `errdefer` to clean up on failure paths.
- **Network tests skip gracefully**: Integration tests that need network print `"skipping..."` and return early rather than failing.
- **Local test servers**: Many integration tests spawn HTTP servers on localhost threads with semaphore synchronization.
- **Header order matters**: HTTP headers are stored in `ArrayList` to preserve insertion order. This is critical for TLS/HTTP fingerprinting — do not sort, deduplicate, or reorder headers.
- **Memory**: `std.ArrayList` (not `ArrayListUnmanaged`) with explicit allocator args in most places.

## Current status

Browser runtime status:

- Networking, TLS, cookies, redirects, and H1/H2 routing are implemented
- Page fetch → parse → DOM → JS → render pipeline is implemented
- CLI commands for the default fetch path plus `tools`, `call`, and `mock` exist
- Curated WPT and Test262 coverage exists in-tree, but MVP closure remains gated by wiring, build health, corpus growth, and removal of shipped stubs

WPT-first status:

- Curated WPT and Test262 suites are the primary correctness signal for DOM and JS work
- The active execution authority is the canonical spec set, not this summary

## Critical Constraints

1. **Don't break the fingerprint.** The JA4 string, cipher suite order, TLS extension order, and HTTP/2 SETTINGS frame are the product. Verify with `zig build test-tls` after any net/ changes.
2. **macOS/arm64 is the primary platform.** Homebrew paths are hardcoded in `build.zig`. Cross-platform is a future concern.
3. **BoringSSL is vendored, not built.** Static libs live in `third_party/boringssl/lib/`. The C shim (`tls_awr_shim.c`) bridges Zig ↔ BoringSSL.
4. **`use_llvm = true` for QuickJS modules.** Any build target that links QuickJS-NG must set this flag. See `build.zig` for the pattern.
5. **Keep docs product-first.** Describe AWR as a CLI browser runtime first. Mention WebMCP after the browser path.

## Spec & Planning Docs

- `README.md` — quickest product and CLI overview
- `AGENTS.md` — module guidance for code changes
- `spec/MVP.md` — canonical umbrella spec and closure rules
- `spec/subspecs/mvp-remainder.md` — active MVP completion track
- `spec/subspecs/wpt-conformance.md` — conformance runner/corpus authority
- `docs/adr/0001-spec-governance.md` — spec governance record
- `spec/PRD.md` — product context only; not execution authority
