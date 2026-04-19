# Integrating AWR with an AI Agent

AWR is a WebMCP-aware terminal browser. A page served to AWR registers
tools via `navigator.modelContext.registerTool(...)`; AWR discovers those
tools and exposes them on the command line. Any agent framework that can
shell out — Claude Code's Bash tool, Aider, a custom loop — can invoke
page-hosted tools by calling the AWR CLI.

This guide covers the MVP integration pattern: **agent → CLI → page →
typed JSON**. A native stdio MCP server (`awr serve`) is tracked as
MVP+1 in `MVP_PLAN.md:111-126`; until it lands, the CLI envelope
shape already matches the MCP `tools/list` + `tools/call` shape, so a
thin shell wrapper is enough.

## Prerequisites

- A release build of AWR:
  ```bash
  zig build -Doptimize=ReleaseSafe
  ```
- A page that calls `navigator.modelContext.registerTool(descriptor, handler)`.
  `experiments/webmcp_mock.html` is the reference fixture and registers
  three tools: `search_products`, `get_price`, `add_to_cart`.

## The CLI surface

AWR's CLI is intentionally small so it composes with any agent:

| Command | Purpose | Output |
|---------|---------|--------|
| `awr <url>` | Load page, run its scripts, print the full envelope | `{url, status, title, body_text, window_data, tools}` |
| `awr tools <url>` | Load page, print only the tools array | `[{name, description, inputSchema}, ...]` |
| `awr call <url> <tool> <json>` | Load page, invoke `<tool>` with `<json>` args | `{"ok": true, "value": ...}` or `{"ok": false, "error": "...", "message": "..."}` |
| `awr --version` | Print the build hash | `0.0.<git_hash>` |

`<url>` can be an `http(s)://` URL, a `file://` URL, or a bare
filesystem path. (HTTP/HTTPS fetch is currently stubbed on Zig 0.16;
use `file://` or a local path for the MVP. Durable fix is tracked in
`DEV_NOTES.md:71-87` (#6).)

## End-to-end demo against the mock fixture

From the repo root:

```bash
# 1. Discover the tools the page registered.
./zig-out/bin/awr tools experiments/webmcp_mock.html
# -> [{"name":"search_products","description":"…","inputSchema":{…}},
#     {"name":"get_price",      "description":"…","inputSchema":{…}},
#     {"name":"add_to_cart",    "description":"…","inputSchema":{…}}]

# 2. Invoke a sync tool.
./zig-out/bin/awr call experiments/webmcp_mock.html \
    search_products '{"q":"Widget"}'
# -> {"ok":true,"value":[{"sku":"w-001","name":"Widget A","price":9.99},
#                       {"sku":"w-002","name":"Widget B","price":14.99},
#                       {"sku":"w-003","name":"Widget C","price":19.99}]}

# 3. Invoke an async tool (Promise-returning handler).
./zig-out/bin/awr call experiments/webmcp_mock.html \
    add_to_cart '{"sku":"w-001","qty":2}'
# -> {"ok":true,"value":{"cart_size":1,"total":19.98}}

# 4. Invoke an unknown tool or one that throws — errors surface in the envelope.
./zig-out/bin/awr call experiments/webmcp_mock.html nope '{}'
# -> {"ok":false,"error":"ToolNotFound","message":"No tool registered with name nope"}
```

Each invocation loads the page fresh, runs its scripts, registers tools,
drains microtasks, and returns the result on stdout — suitable for
piping into any agent's toolchain.

## Wiring AWR into Claude Code

Claude Code does not speak MCP stdio to AWR directly yet (that's MVP+1).
The reference integration uses Claude Code's **Bash tool** as the
transport:

1. Start a Claude Code session in a working directory where AWR is on
   the `$PATH` (or note the absolute path to `zig-out/bin/awr`).
2. Tell the session what page it should use and what the tools are:
   > "Treat `awr tools path/to/page.html` as your list of tools and
   > `awr call path/to/page.html <tool> <json-args>` as invocation. The
   > response envelope is `{ok, value|error|message}` JSON."
3. Claude Code calls `awr tools …` once to discover the schema, then
   calls `awr call …` each time it wants to invoke a tool.

Because `awr call`'s envelope is structurally identical to MCP's
`tools/call` result (`{ok, value}` / `{ok:false, error, message}`),
swapping the Bash-tool bridge for a native `awr serve` subcommand later
is a transport-layer change only; the agent side of the contract does
not move.

## Envelope shape (stable contract)

Every `awr call` response is a single-line JSON object:

```jsonc
// Success — handler returned synchronously or the Promise resolved.
{ "ok": true, "value": <any JSON the handler returned> }

// The tool threw synchronously.
{ "ok": false, "error": "ToolThrew", "message": "<err.message>" }

// The tool's Promise rejected.
{ "ok": false, "error": "ToolRejected", "message": "<err.message>" }

// The tool name wasn't registered on this page.
{ "ok": false, "error": "ToolNotFound", "message": "No tool registered with name <name>" }

// Bad JSON in the args argument.
{ "ok": false, "error": "InvalidArgs", "message": "<parse error>" }
```

Agents should treat `ok:false` the same as any tool-call failure they'd
receive from a direct MCP server: surface the message, decide whether to
retry, fail gracefully.

## Writing a WebMCP-ready page

The minimum a page needs is one `registerTool` call:

```html
<!doctype html>
<html><body>
<script>
  navigator.modelContext.registerTool(
    {
      name: 'say_hello',
      description: 'Greet somebody by name.',
      inputSchema: {
        type: 'object',
        properties: { name: { type: 'string' } },
        required: ['name'],
      },
    },
    function ({ name }) {
      return { greeting: `Hello, ${name}!` };
    }
  );
</script>
</body></html>
```

Run it:

```bash
./zig-out/bin/awr call hello.html say_hello '{"name":"World"}'
# -> {"ok":true,"value":{"greeting":"Hello, World!"}}
```

Promise-returning handlers are supported — AWR drains microtasks
between the invocation and the result fetch, so any `Promise.resolve`
chain completes before the envelope is emitted.

## Limits and gotchas

- **`<script src>` is not fetched** — external scripts are skipped. The
  MVP targets pages whose WebMCP registration is inline.
- **HTTP/HTTPS fetch is stubbed** on Zig 0.16 (`src/client.zig:122-139`).
  Use `file://` or bare paths until the `std.Io`-based rewrite lands
  (`DEV_NOTES.md:71-87`).
- **CSS selector support is minimal** — `tag`, `#id`, `.class`,
  `tag#id`, `tag.class`, and descendant combinators (`#a b c`). Attribute
  selectors, pseudo-classes, and `>`/`+`/`~` are not supported
  (`DEV_NOTES.md` #10).
- **`setTimeout` / `fetch` inside the page are no-ops / rejected** —
  async work must resolve synchronously or through `Promise.resolve`
  chains; scheduled callbacks never fire (Phase 3).

## Related specs

- `spec/PRD.md:194-220` — MVP definition and deliverables.
- `MVP_PLAN.md` — the 7-step slice this MVP shipped.
- `DEV_NOTES.md` — patch-debt items and durable-fix plans.
