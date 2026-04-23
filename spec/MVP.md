# AWR MVP — Canonical Umbrella Spec

> **Canonical execution spec.** If any other planning doc disagrees, this file wins.
>
> **Current status:** the WebMCP v1 CLI slice and the browser-runtime MVP path
> are shipped on the primary CLI surface. The closure record for that runtime
> work lives in `spec/subspecs/mvp-remainder.md`; remaining work is deferred.

---

## 1. Product target

AWR's MVP is a **CLI-first browser runtime** that can:

1. load real pages from disk and the network;
2. execute the page JavaScript needed for agent workflows;
3. return stable machine-readable output and readable terminal output.

WebMCP remains a supported shipped layer on top of that runtime, but it is
**not** the current execution track and it is **not** the authority for MVP
scope.

---

## 2. Canonical doc map

### Canonical now

| Document | Role |
|---|---|
| `spec/MVP.md` | Top-level canonical umbrella spec and change-control point |
| `spec/subspecs/mvp-remainder.md` | Completion record for the shipped browser-runtime MVP remainder |
| `docs/adr/0001-spec-governance.md` | Historical record for spec/documentation governance decisions |

### Deferred, documented, not active now

| Document | Role |
|---|---|
| `spec/subspecs/mcp-stdio.md` | Deferred native MCP stdio server track |
| `spec/subspecs/browser-tui.md` | Deferred browser/TUI track |
| `spec/Fingerprint-Plan.md` | Future-only fingerprinting roadmap |

### Background / historical only

| Document | Role |
|---|---|
| `spec/PRD.md` | Product context and rationale; not execution authority |
| `MVP_PLAN.md` | Historical record of the shipped WebMCP v1 slice |
| `MVP_BACKLOG.md` | Pre-consolidation backlog snapshot; not current priority authority |

---

## 3. Shipped baseline

These points are treated as already delivered baseline, not active plan items:

- `awr tools <url>` ships and exposes page-registered WebMCP tools.
- `awr call <url> <tool> <json>` ships and returns typed envelopes.
- `awr mock` ships as a local mock-page helper.
- `src/mcp_stdio.zig` exists, but the native MCP stdio path is incomplete/stale
  and remains deferred.

The main product path is still `awr <url>`.

---

## 4. MVP closure status

The primary CLI/browser MVP path is now treated as shipped. Its closure record is:

- `spec/subspecs/mvp-remainder.md`

That completion record covers the browser-runtime work that was required on the
primary CLI path:

- real HTTP/HTTPS page fetch and error handling;
- external script loading and core async JS runtime behavior;
- DOM mutation reflection and broader selector coverage;
- browser-path verification and documentation cleanup.

There is no active MVP implementation track beyond keeping that shipped surface
stable. Anything outside that shipped path is deferred unless this file is
explicitly changed.

---

## 5. Explicitly deferred

These tracks stay documented, but they are **not** in the active work queue:

- native MCP stdio server work → `spec/subspecs/mcp-stdio.md`
- browser/TUI work → `spec/subspecs/browser-tui.md`
- later fingerprinting / owned browser identity work →
  `spec/Fingerprint-Plan.md`

Do not treat deferred tracks as blockers for the shipped CLI/browser MVP path
unless this spec is amended.

---

## 6. Change control

No document becomes canonical by implication.

Any scope change must:

1. edit `spec/MVP.md` first;
2. update the affected sub-spec status (active or deferred);
3. update `docs/adr/0001-spec-governance.md` if document authority, spec boundaries, or governance rules changed;
4. update README/agent-facing references if the execution boundary moved.

This file stays intentionally short so the active-vs-deferred boundary is easy
to audit.
