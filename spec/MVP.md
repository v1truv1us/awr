# AWR MVP — Canonical Umbrella Spec

> **Canonical execution spec.** If any other planning doc disagrees, this file wins.
>
> **Current status:** Tier 0 (CLI-first agent browser runtime) is **CLOSED**
> and shipped under curated WPT/Test262 gates. Tier 1 (interactive human
> TUI parity with lynx/w3m) is **ACTIVE** per
> `spec/subspecs/browser-roadmap.md`. Subsequent tiers (rendering polish,
> dynamic-site browser APIs, layout, full SPA support) are documented and
> deferred. This file remains the change-control point for any tier
> promotion or scope change.

---

## 1. Product target

AWR is a **dual-surface CLI-first browser**: one Zig binary, two
co-equal interfaces sharing one session.

1. **Human surface** (`awr browse <url>`): a terminal UI for reading,
   navigating, and interacting with pages — keyboard navigation, form
   fill, history, cookie management.
2. **Agent surface** (`awr <url>`, `awr extract`, `awr tools`,
   `awr call`): clean JSON / Markdown / WebMCP outputs for LLM and
   tool-using agents.

Both surfaces render from the same DOM tree and share the same
cookie / connection state via the daemon (`spec/subspecs/daemon-mode.md`).
A human can log in once; an agent operating in the same scope picks up
the authenticated session.

The product climbs a tiered capability ladder
(`spec/subspecs/browser-roadmap.md`) from the closed Tier 0 agent
runtime upward toward broader site coverage. WebMCP remains a
supported layer on top of the runtime; browser/runtime correctness
remains the primary MVP authority and is gated by curated Web Platform
Tests and Test262 cases.

---

## 2. Canonical doc map

### Canonical now

| Document | Role |
|---|---|
| `spec/MVP.md` | Top-level canonical umbrella spec and change-control point |
| `spec/subspecs/browser-roadmap.md` | **Cross-tier capability ladder.** Tier ordering, tier-promotion gates, and the WPT-growth contract that ties tier closure to corpus growth |
| `spec/subspecs/mvp-remainder.md` | Tier 0 closure record (was: active MVP completion track) |
| `spec/subspecs/wpt-conformance.md` | Canonical WPT/Test262 runner, corpus, and merge-gate spec; corpus grows with each active tier |
| `spec/subspecs/agent-browser.md` | Tier 0 agent-browser scope (closed): POST in fetch+XHR, form `method=post`, cookie persistence |
| `spec/subspecs/rendering.md` | Tier 0 rendering scope (closed): terminal render + image protocols |
| `spec/subspecs/daemon-mode.md` | Tier 0 daemon-mode scope (active → closing): long-lived `awrd` + JSON-RPC IPC for amortized startup |
| `spec/subspecs/browser-tui.md` | **Tier 1 closed sub-spec**: interactive TUI parity (form fields, focus, keyboard input, history, URL bar, cookie inspector, browser-cookie import) |
| `spec/subspecs/render-polish.md` | **Tier 2 closed sub-spec**: render + UX polish (bookmarks, URL-bar autocomplete, form/table/code/diff/image polish, cookie inspector enrichment) |
| `spec/subspecs/browser-history.md` | **Tier 3 active sub-spec**: History API (`pushState`, `replaceState`, `popstate`) |
| `spec/subspecs/browser-storage.md` | **Tier 3 active sub-spec**: Web Storage (`localStorage` persisted, `sessionStorage` in-memory) |
| `spec/subspecs/browser-realtime.md` | **Tier 3 active sub-spec**: real-time connections (WebSocket + EventSource/SSE) |
| `spec/subspecs/browser-events.md` | **Tier 3 active sub-spec**: browser events (synthetic input, `DOMContentLoaded`/`load`, `requestAnimationFrame`, `matchMedia`) |
| `docs/adr/0001-spec-governance.md` | Historical record for spec/documentation governance decisions |

### Deferred, documented, not active now

| Document | Role |
|---|---|
| `spec/subspecs/mcp-stdio.md` | Deferred native MCP stdio server track (will be a thin client of daemon-mode per its B1 design doc) |
| `spec/Fingerprint-Plan.md` | Future-only fingerprinting roadmap |

Tiers 4–5 (layout engine, full SPA parity) are described in
`spec/subspecs/browser-roadmap.md §3` but do not yet have dedicated
sub-specs; they're created when promoted to ACTIVE.

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
   page, event, storage, GET+POST request, form-submission, history-subset, and
   viewport surface (POST/forms scope governed by
   `spec/subspecs/agent-browser.md`).
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
   `fetch()` and `XMLHttpRequest` are async-only and accept the GET and POST
   methods. POST bodies are strings or `URLSearchParams` instances stringified
   to `application/x-www-form-urlencoded`. All other methods, init keys, and
   body shapes still throw. See `spec/subspecs/agent-browser.md`;
5. explicitly narrowed browser-history semantics:
   `history` is limited to same-origin `pushState` / `replaceState` plus
   `length` and `state`;
6. viewport observers (`IntersectionObserver`, `ResizeObserver`) are not part of
   the shipped MVP surface until real render-backed semantics exist;
7. terminal image rendering for `<img>`, `<picture>` / `srcset`, and CSS
   `background-image` on `<header>` / `<section>` / `<figure>`. Protocols:
   Kitty graphics, iTerm2 inline (OSC 1337), Sixel with median-cut palette
   quantization, and a 2×4 Unicode-braille fallback. `--images=…` flag with
   `auto` detection (Kitty / iTerm env signals + Sixel CSI probe) and a hard
   non-TTY override that forces `.none` so `awr render | tee` stays escape-
   free. Per-image safety caps (4 MiB encoded / 16 MP decoded) and a
   per-page fetch budget (32 images, surplus → text alt-refs). See
   `spec/subspecs/rendering.md`.

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

These tracks stay documented, but they are **not** in the active queue:

- native MCP stdio server work → `spec/subspecs/mcp-stdio.md`
- later fingerprinting / owned browser identity work →
  `spec/Fingerprint-Plan.md`
- Tiers 2–5 of the browser-roadmap (rendering polish, dynamic-site
  browser APIs, layout engine, full SPA parity) →
  `spec/subspecs/browser-roadmap.md §3`. These do not have dedicated
  sub-specs yet; sub-specs are created at promotion time.

The agent-browser scope (POST in `fetch` and XHR, `<form method=post>` end-to-
end through `awr browse`, cookie jar disk persistence) is governed by
`spec/subspecs/agent-browser.md` and is **closed** (per ADR
2026-04-28 entry). Tier 0 of the browser-roadmap encompasses
agent-browser, rendering, daemon-mode, and the WPT/Test262 gates.

The Tier 1 interactive-TUI scope (form-field interaction, focus
management, keyboard input dispatch, history navigation, URL bar,
cookie inspector, Chrome/Firefox cookie import) is governed by
`spec/subspecs/browser-tui.md` and is **active** (per ADR
2026-05-09 entry). Tier 1 closure does not weaken any Tier 0
gate — `spec/subspecs/browser-tui.md §4` requires every existing
gate stays green plus the new corpus areas land.

The rendering scope (real-page render-quality corpus + terminal image
rendering) is governed by `spec/subspecs/rendering.md` and is
**closed** (per ADR 2026-04-30 entry). Track B (corpus harness, 12
fixtures across 11 categories) and Track A (image rendering: Kitty /
iTerm / Sixel / braille encoders, `<picture>` / `srcset` picker, CSS
`background-image` resolve, end-to-end pipeline through `awr render`)
are both green against `spec/subspecs/rendering.md §6`. The corpus
harness is exercised via `zig build test-corpus`; the encoder + picker
test surface via `zig build test-image` (113 tests across 8 modules).

The daemon-mode scope (long-lived `awrd` process + Unix-socket JSON-RPC
IPC + per-cookie-scope state partitioning) is governed by
`spec/subspecs/daemon-mode.md` and is **active** (proposed
2026-05-07). Companion design doc:
`docs/research/2026-05-07-daemon-mode-design.md`. Does not weaken the
in-process MVP closure — daemon mode reuses the same `Client` /
`Page` / `JsEngine` code paths.

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
