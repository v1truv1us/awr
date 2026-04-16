# MVP Plan

Current CLI browser scope and ship criteria.

---

## Frame the product

AWR is a CLI-first MVP web browser.
It should be described as a browser runtime first and an MCP-capable tool host second.

---

## Ship the core path

Primary commands that define the MVP:

- `awr <url>`
- `awr --json <url>`
- `awr browse <url>`
- `awr eval <url> <expr>`
- `awr post <url> --data <body>`

Secondary commands that remain supported:

- `awr mcp-call <url> <tool-name>`
- `awr mcp-stdio <url>`

---

## Keep the scope explicit

In scope now:

- Real page fetch, parse, DOM construction, and JS execution
- Readable terminal output for the default CLI path
- Interactive browse mode
- Curated WPT-style DOM validation
- Curated Test262-style JS validation

Not in scope for this pass:

- Full upstream WPT integration
- Full browser parity
- Large rewrites of historical planning docs
- Reframing the product around MCP first

---

## Use WPT first

DOM and JS behavior should move toward conformance before new browser surface area.
When runtime behavior changes, prefer adding or tightening `test-wpt` and `test-test262` coverage.

Current harnesses are curated and intentionally narrow.
That is acceptable for the MVP as long as the browser path stays green and coverage grows with runtime work.

---

## Define done

The MVP is in good shape when all of these stay true:

1. `awr <url>` remains the clearest way to use the product
2. Fetch → parse → DOM → JS → render works on representative real pages
3. `zig build test`, `zig build test-e2e`, `zig build test-render`, `zig build test-wpt`, and `zig build test-test262` stay green
4. Docs describe AWR as a CLI browser first

---

## Prioritize next work

Highest-value follow-up work:

1. Expand curated WPT coverage for implemented DOM APIs
2. Expand curated Test262 coverage for implemented JS behavior
3. Tighten CLI docs and examples around the default browser flow
4. Preserve WebMCP support without letting it drive the main product story

---

## Ground changes in code

Keep docs aligned with files that already exist today:

- `src/main.zig`
- `src/page.zig`
- `src/render.zig`
- `src/browser.zig`
- `src/webmcp.zig`
- `tests/wpt_runner.zig`
- `tests/test262_runner.zig`
