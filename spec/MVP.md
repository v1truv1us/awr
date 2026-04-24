# AWR MVP — Canonical Umbrella Spec

> **Canonical execution spec.** If any other planning doc disagrees, this file wins.
>
> **Current status:** AWR ships a CLI-first browser-runtime MVP on the primary
> CLI surface. MVP closure is defined by the curated WPT/Test262 gates in this
> document and the no-stubs rule for the shipped runtime subset.

---

## 1. Product target

AWR's MVP is a **CLI-first browser runtime** that can:

1. load real pages from disk and the network;
2. execute the page JavaScript needed for agent workflows;
3. return stable machine-readable output and readable terminal output;
4. ground runtime correctness in curated Web Platform Tests and Test262 cases.

WebMCP remains a supported layer on top of that runtime, but browser/runtime
correctness is the primary MVP authority.

---

## 2. Canonical doc map

### Canonical now

| Document | Role |
|---|---|
| `spec/MVP.md` | Top-level canonical umbrella spec and change-control point |
| `spec/subspecs/mvp-remainder.md` | Active MVP completion track and execution order |
| `spec/subspecs/wpt-conformance.md` | Canonical WPT/Test262 runner, corpus, and merge-gate spec |
| `docs/adr/0001-spec-governance.md` | Historical record for spec/documentation governance decisions |

### Deferred, documented, not active now

| Document | Role |
|---|---|
| `spec/subspecs/mcp-stdio.md` | Deferred native MCP stdio server track |
| `spec/subspecs/browser-tui.md` | Deferred browser/TUI product track |
| `spec/Fingerprint-Plan.md` | Future-only fingerprinting roadmap |

### Background / historical only

| Document | Role |
|---|---|
| `spec/PRD.md` | Product context and rationale; not execution authority |
| `MVP_PLAN.md` | Historical record of the earlier WebMCP/browser slice |
| `MVP_BACKLOG.md` | Pre-consolidation backlog snapshot; not current priority authority |

---

## 3. Shipped baseline

These points are treated as already delivered baseline, not deferred wishlist:

- `awr <url>` is the main product path.
- `awr tools <url>` ships and exposes page-registered WebMCP tools.
- `awr call <url> <tool> <json>` ships and returns typed envelopes.
- `awr mock` ships as a local mock-page helper.
- real page fetch, HTML parsing, DOM construction, JS execution, and terminal
  rendering exist on the CLI path.

This shipped baseline is the closed MVP surface when the conformance and
no-stubs gates below remain green.

---

## 4. MVP closure gates

The MVP is only considered complete when all of the following are true:

1. `spec/subspecs/mvp-remainder.md` is satisfied.
2. `spec/subspecs/wpt-conformance.md` is satisfied.
3. `zig build test` is green without hangs or known broken steps on the default
   developer path.
4. curated WPT coverage is wired into the build and passes for the intended DOM,
   page, event, storage, GET-only request, history-subset, and viewport surface.
5. curated Test262 coverage is wired into the build and passes for the intended
   embedded JS runtime surface.
6. shipped APIs follow the **no-stubs rule**: any exposed surface must be real,
   or removed until it can be implemented correctly.

Those gates are the closure definition for the shipped MVP surface.

---

## 5. Closed MVP surface

The closed MVP surface is:

1. docs aligned to the canonical spec set and governance rules;
2. a green default baseline (`zig build test`, `zig build test-wpt`,
   `zig build test-test262`);
3. authoritative DOM, event, storage, and geometry behavior for the curated
   conformance target;
4. explicitly narrowed network/runtime request semantics:
   `fetch()` and `XMLHttpRequest` are async GET-only on the shipped MVP path;
5. explicitly narrowed browser-history semantics:
   `history` is limited to same-origin `pushState` / `replaceState` plus
   `length` and `state`;
6. viewport observers (`IntersectionObserver`, `ResizeObserver`) are not part of
   the shipped MVP surface until real render-backed semantics exist.

The closure record and remaining follow-on work live in
`spec/subspecs/mvp-remainder.md`.

---

## 6. No-stubs rule

The shipped MVP surface must not depend on placeholder APIs.

Rules:

1. if an API is exposed on the browser/runtime surface, it must work correctly
   for AWR's terminal-backed model;
2. if an API cannot yet be implemented correctly, do not expose it;
3. if an existing exposed API is currently stubbed, the active MVP track must
   either implement it or remove it before closure;
4. conformance growth is used to prove behavior, not to excuse missing runtime
   semantics.

---

## 7. Explicitly deferred

These tracks stay documented, but they are **not** in the active MVP closure
queue:

- native MCP stdio server work → `spec/subspecs/mcp-stdio.md`
- browser/TUI product-track expansion → `spec/subspecs/browser-tui.md`
- later fingerprinting / owned browser identity work →
  `spec/Fingerprint-Plan.md`

Do not treat deferred tracks as blockers for the active MVP closure work unless
this spec is amended.

---

## 8. Change control

No document becomes canonical by implication.

Any scope, authority, or closure-boundary change must:

1. edit `spec/MVP.md` first;
2. update the affected active or deferred sub-specs in the same change;
3. update `docs/adr/0001-spec-governance.md` if document authority,
   spec boundaries, or governance rules changed;
4. update README and agent-facing guidance files if the execution boundary or
   current-status framing changed.

This file stays intentionally short so the active-vs-deferred boundary is easy
to audit.
