# MVP Roadmap

Near-term ship order for the CLI browser.

---

## Start from the current baseline

AWR already has the main browser pipeline in tree.
The root docs should reflect that reality instead of describing a future MCP-first product.

Implemented today:

- CLI entry point and subcommands in `src/main.zig`
- HTTP client, cookies, redirects, TLS, and H1/H2 routing
- HTML parsing, DOM construction, JS execution, and terminal rendering
- Interactive browse mode
- WebMCP extraction and MCP stdio support
- Curated WPT-style and Test262-style harnesses

---

## Ship in this order

P0 work:

1. Keep the default CLI browser flow solid
2. Expand WPT-style DOM coverage for behavior already implemented
3. Expand Test262-style JS coverage for behavior already implemented
4. Keep README and root docs aligned with the actual executable

P1 work:

1. Add more conformance cases before major new runtime features
2. Improve release packaging and clean-checkout setup docs
3. Add more real-site verification for the browser path

P2 work:

1. Broader cross-platform support
2. Larger conformance imports
3. Additional protocol and browser features beyond the MVP

---

## Keep WebMCP in bounds

WebMCP is implemented and worth preserving.
It should not displace the primary story that AWR is a browser runtime you drive from the CLI.

---

## Track success

Use these signals first:

- `awr <url>` is still the best demo
- `zig build test-wpt` and `zig build test-test262` grow over time
- Root docs match current commands and current code layout
- Browser improvements do not regress `mcp-call` or `mcp-stdio`

---

## Leave for later

These are valid cleanup targets, but not required for this docs pass:

- Older phase-by-phase planning docs
- Historical closure notes
- Deeper spec history outside the main PRD
