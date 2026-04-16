# AWR

CLI-first MVP web browser for real pages.

## What it is

AWR is a terminal browser written in Zig.
It fetches pages, builds a DOM, runs page JavaScript, and renders readable output in the terminal.

The current product is CLI-first.
The browser path comes first, while WebMCP and MCP server flows remain supported secondary surfaces.

## What matters now

- CLI browser workflow is the primary user experience
- WPT-first execution guides DOM and JS work
- Real page fetch, parse, execute, and render are in scope
- WebMCP support exists, but it is not the primary framing for this MVP

## What is in scope

- Fetching pages over HTTP/1.1 and HTTP/2
- TLS via vendored BoringSSL and Chrome-like fingerprint control
- HTML parsing through Lexbor
- DOM queries and basic DOM mutation support
- JavaScript execution through QuickJS-NG
- Structured terminal rendering and interactive browse mode
- Curated WPT-style DOM tests and curated Test262-style JS tests

## What is out of scope

- Full browser engine parity
- Full upstream WPT coverage
- CSS layout engine
- Canvas or WebGL rendering
- Broad cross-platform polish

## Install dependencies

AWR currently targets macOS arm64 first.
The build expects Homebrew installs for `libnghttp2` and `lexbor`.

```bash
brew install libnghttp2 lexbor
zig version
```

## Build

```bash
zig build
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/awr`.

## Run

```bash
zig build run -- https://example.com
./zig-out/bin/awr https://example.com
./zig-out/bin/awr --json https://example.com
./zig-out/bin/awr browse https://example.com
./zig-out/bin/awr eval https://example.com 'document.title'
./zig-out/bin/awr post https://httpbin.org/post --data 'x=1'
./zig-out/bin/awr mcp-call https://example.com tool-name --input '{"x":1}'
./zig-out/bin/awr mcp-stdio https://example.com
```

## Test

```bash
zig build test
zig build test-e2e
zig build test-render
zig build test-wpt
zig build test-test262
```

Use targeted suites when changing a subsystem.
`test-wpt` and `test-test262` are the fastest signal for runtime behavior drift.

## Know the layout

```text
src/main.zig         CLI entry point
src/client.zig       HTTP client
src/page.zig         Fetch → parse → DOM → JS pipeline
src/render.zig       Terminal renderer
src/browser.zig      Interactive browser session
src/webmcp.zig       WebMCP support
src/mcp_stdio.zig    MCP stdio server
tests/wpt_runner.zig Curated WPT-style DOM harness
tests/test262_runner.zig Curated JS conformance harness
```

## Keep the framing straight

Think of AWR as a browser runtime you drive from the CLI.
MCP and WebMCP features build on that runtime rather than defining it.
