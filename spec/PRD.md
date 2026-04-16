# AWR PRD

Product requirements for the CLI browser MVP.

---

## Define the product

AWR is a CLI-first web browser runtime written in Zig.
It fetches real pages, builds a DOM, executes page JavaScript, and returns readable terminal output or structured data.

WebMCP support is part of the product.
It is not the lead framing for the MVP.

---

## Solve the right problem

Developers and agents need a browser they can drive from the terminal.
That browser must work on real pages instead of stopping at raw HTTP fetches.

Current headless stacks are often too heavy, too opaque, or too tied to GUI-era assumptions.
AWR aims to be small, scriptable, and practical for CLI workflows.

---

## Describe the user journey

Primary journey:

1. Run `awr <url>`
2. Let AWR fetch, parse, execute, and render the page
3. Inspect readable output in the terminal

Extended journeys:

1. Run `awr --json <url>` for machine-readable output
2. Run `awr browse <url>` for interactive terminal browsing
3. Run `awr eval <url> <expr>` to probe the DOM or JS state
4. Run `awr mcp-call` or `awr mcp-stdio` when a page exposes WebMCP tools

---

## Define MVP requirements

Required now:

- CLI-first default experience
- Real page pipeline from network through JS execution
- Readable terminal rendering
- Curated conformance coverage for DOM and JS behavior
- Documentation that matches shipped commands and shipped files

Required later:

- Broader conformance imports
- More cross-platform polish
- Larger browser surface area beyond the current MVP

---

## Set product principles

1. Browser path comes first
2. WPT-first execution guides DOM and JS behavior
3. Docs stay grounded in the current executable
4. WebMCP builds on the browser runtime rather than replacing it

---

## Define technical shape

Core runtime:

- `src/client.zig` handles HTTP, cookies, redirects, and transport setup
- `src/page.zig` handles fetch → parse → DOM → JS orchestration
- `src/render.zig` handles readable terminal output
- `src/browser.zig` handles interactive browsing

Conformance layer:

- `tests/wpt_runner.zig` runs a curated WPT-style DOM corpus
- `tests/test262_runner.zig` runs a curated Test262-style JS subset

Protocol layer:

- `src/webmcp.zig` captures `navigator.modelContext` tool registration
- `src/mcp_stdio.zig` exposes discovered tools through MCP stdio

---

## Measure success

Primary success signals:

- `awr <url>` is the best product demo
- `zig build test` and `zig build test-e2e` stay green
- `zig build test-wpt` and `zig build test-test262` expand with runtime work
- Root docs describe the product the same way the executable behaves

---

## Keep scope tight

Out of scope for this MVP framing:

- Full browser parity
- Full upstream WPT compliance
- Large GUI-style feature sets
- Recasting the product as MCP-first
