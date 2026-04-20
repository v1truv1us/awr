# AWR MVP Plan — WebMCP Mock Server Demo

> **Authoritative MVP contract:** `spec/MVP.md` is the fully qualified
> definition (functional requirements, acceptance tests, stub-closure
> checklist). This plan describes the **v1 slice** — the in-page WebMCP
> plumbing — which is ✅ shipped. The production bar (`v2`, "no stubs")
> lives in `spec/MVP.md` §5/§6.
>
> **Target (v1):** the MVP defined in `spec/PRD.md:194` — a self-contained
> WebMCP demo showing AWR load a page, discover registered tools, and
> execute a tool with typed JSON results.
>
> **Branch:** `claude/complete-mvp-X2DcT` (merged to `main` at commit `499fff4`)
>
> **Phases status:**
> - Phase 1 (Networking): shipped with `std.http.Client`/`std.crypto.tls`; strict
>   JA4 milestone moved to Phase 3 per `spec/PRD.md:128`.
> - Phase 2 (JS env): ✅ complete per `spec/Phase2-Plan.md`.
> - Phase 4 MVP (WebMCP): ✅ **SHIPPED** — all seven steps below are
>   marked ✅; end-to-end demo verified against
>   `experiments/webmcp_mock.html`.
>
> Phase 3 fingerprinting and TUI are deliberately out of scope for the MVP
> per `spec/PRD.md:194` ("requires no real bot detection, no real TUI, no real
> fingerprinting — just the WebMCP plumbing working end-to-end").

---

## MVP deliverable, restated

Per PRD:

1. A page exposes 2-3 tools via `navigator.modelContext.registerTool({...})`.
2. AWR loads the page, discovers the tools.
3. An external caller (CLI / agent) receives the tool list and can invoke one.
4. The result comes back as typed JSON.

---

## Atomic steps

### Step 1 — `navigator.modelContext` in the DOM bridge polyfill ✅

Add a WebMCP host to `src/dom/bridge.zig`'s `BRIDGE_POLYFILL`. The polyfill
holds a per-context tool registry in JS:

- `navigator.modelContext.registerTool(desc)`
- `navigator.modelContext.unregisterTool(name)`
- `navigator.modelContext.getTools()` → array of `{name, description, inputSchema}`
- `navigator.modelContext.callTool(name, args)` → `Promise<result>`

Plus three internal hooks Zig calls via `evalString`:

- `__awr_getToolsJson__()` → `JSON.stringify(getTools())`
- `__awr_callToolJson__(name, argsJson)` → invokes `execute`, stashes result
  in a global slot, returns sentinel `"__AWR_PENDING__"`
- `__awr_resolveToolJson__()` → reads the slot after `drainMicrotasks`

**Tests (in `src/dom/bridge.zig`):**
- `navigator.modelContext` exists and is an object
- `registerTool` stores and `getTools()` returns a serialisable list
- `callTool` returns a Promise that resolves through `drainMicrotasks`
- unknown tool → rejected promise / `{ok:false, error: ...}`

### Step 2 — Surface registered tools in `PageResult` ✅

In `src/page.zig`:

- Add `tools_json: ?[]const u8 = null` to `PageResult` (null when empty, JSON
  array string otherwise).
- After `drainMicrotasks`, evaluate `__awr_getToolsJson__()` via `evalString`.
  If result is `"[]"`, free and store null; otherwise keep the JSON.
- Free in `PageResult.deinit`.

**Tests:** JS that calls `registerTool` on a single tool → `tools_json`
contains the name.  JS that doesn't → `tools_json == null`.

### Step 3 — `Page.callTool(name, args_json) → []u8` ✅

Add a method to `Page` that:

1. Builds a JS call: `__awr_callToolJson__(<name>, <argsJson>)` with
   single-quoted string escaping (reuse `writeJsStr`).
2. Runs `evalString`; if the result is `"__AWR_PENDING__"`, call
   `drainMicrotasks` and then `evalString("__awr_resolveToolJson__()")`.
3. Returns the resulting `{ok, result|error}` JSON, heap-allocated.

**Tests:** sync tool, async tool, unknown tool, exception in `execute`.

### Step 4 — CLI subcommands ✅

Extend `src/main.zig`:

- `awr <url>` (default): include `tools` field in JSON output (raw JSON, or
  `null` when no tools).
- `awr tools <url>`: prints just the tools JSON array (`[]` if none).
- `awr call <url> <tool> <argsJson>`: loads the page, invokes the tool,
  prints the call result JSON.

### Step 5 — Mock WebMCP page fixture ✅

Add `experiments/webmcp_mock.html` registering 2-3 demo tools
(`search_products`, `add_to_cart`, `get_price`). The fixture is consumable
via `awr tools file://…` (if file:// is wired) **or** by feeding the HTML
directly into `Page.processHtml` from a test.

### Step 6 — End-to-end MVP integration test ✅

One test in `src/page.zig` that loads the fixture HTML via `processHtml`,
asserts all three tool descriptors surface in `PageResult.tools_json`, calls
`get_price`, and asserts the typed JSON result.

### Step 7 — Commit + push ✅

Shipped on `claude/complete-mvp-X2DcT`, fast-forward merged to `main` at
commit `499fff4`. Root-cause fixes for two silent-failure bugs landed in
the same branch:
- `JS_Eval` input null-termination (`src/page.zig::executeScriptsInElement`,
  `src/page.zig::callTool`).
- Descendant CSS combinator support in `src/dom/node.zig::collectCompound`.

---

## Out of scope for this MVP slice

These remain for later work and are *not* required by the PRD MVP definition:

- External `<script src>` network loading
- A standalone MCP server process exposing AWR tools to Claude Code over
  stdio (Phase 4 deliverable; the MVP definition only requires that the
  interaction "can be logged to a shareable terminal session", which the
  CLI subcommands cover)
- Fingerprint synthesis / Canvas / WebGL / AudioContext (Phase 3)
- libvaxis TUI (Phase 3)
- Phase 1 strict JA4 closure (deferred to Phase 3 per PRD)

A follow-up MVP+1 will add a tiny stdio MCP server wrapper so Claude Code
can discover AWR-hosted tools directly; the JSON returned by
`awr tools/call` is already the MCP-compatible shape.
