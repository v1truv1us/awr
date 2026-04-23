# MCP stdio — deferred sub-spec

> **Status:** DEFERRED
> Not part of the active work queue.
> `src/mcp_stdio.zig` exists, but this path is currently incomplete/stale.

---

## Purpose

Document the future native MCP stdio server track without implying that it
should be built now.

---

## Scope for later

When this track is explicitly activated, it should cover:

- auditing and finishing `src/mcp_stdio.zig`;
- aligning transport behavior with the shipped `awr tools` / `awr call`
  semantics;
- exposing stable `tools/list` and `tools/call` behavior over stdio;
- adding end-to-end tests for a real stdio server session.

---

## Not active yet because

- the primary browser-runtime MVP path is already shipped and this remains a
  follow-on track rather than a blocker;
- the shipped CLI already provides a workable shell integration surface;
- the current stdio implementation should be treated as deferred design/code,
  not a promised product surface.
