# ADR 0001: Spec and documentation governance

- Status: Accepted
- Date: 2026-04-22

## Context

AWR had multiple planning and spec documents with overlapping authority. That made
it too easy for active scope, deferred work, and historical context to drift or
be misread.

The repo now has a clearer split:

- `spec/MVP.md` is the canonical umbrella spec.
- `spec/subspecs/mvp-remainder.md` is the active MVP completion track.
- `spec/subspecs/wpt-conformance.md` is the active conformance authority for
  curated WPT/Test262 work.
- `spec/subspecs/mcp-stdio.md`, `spec/subspecs/browser-tui.md`, and
  `spec/Fingerprint-Plan.md` are deferred tracks.
- `MVP_PLAN.md`, `MVP_BACKLOG.md`, and `spec/PRD.md` are historical/background
  references and are not execution authority.

That governance decision needs a durable historical record and a single place to
append future governance changes.

## Decision

We standardize spec/documentation authority as follows:

1. `spec/MVP.md` is the top-level canonical spec and change-control point.
2. `spec/subspecs/mvp-remainder.md` defines the active MVP completion work.
3. `spec/subspecs/wpt-conformance.md` defines the conformance runner/corpus
   authority for that work.
4. Deferred tracks must stay documented in their own files, but they do not
   control current execution priority unless `spec/MVP.md` is updated.
5. Historical/background documents may preserve rationale or prior plans, but
   they are non-canonical.
6. This ADR is the historical record for spec-boundary and documentation-
   authority decisions.
7. Any future change to canonical spec boundaries, document authority, or
   governance rules must update both the affected document and this ADR.

## Consequences

### Positive

- The repo has one clear authority chain for active work.
- Deferred work stays visible without competing with active execution.
- Historical docs remain useful without being mistaken for current direction.
- Future governance changes have an explicit audit trail.

### Tradeoffs

- Governance changes now require touching multiple docs.
- This ADR is intentionally living documentation, so it must be maintained when
  governance changes are made.

## Current status

Accepted and in force.

At the time of acceptance:

- Canonical umbrella spec: `spec/MVP.md`
- Active MVP completion track: `spec/subspecs/mvp-remainder.md`
- Active conformance authority: `spec/subspecs/wpt-conformance.md`
- Deferred tracks: `spec/subspecs/mcp-stdio.md`,
  `spec/subspecs/browser-tui.md`, `spec/Fingerprint-Plan.md`
- Non-canonical historical/background docs: `MVP_PLAN.md`, `MVP_BACKLOG.md`,
  `spec/PRD.md`

## Amendment log for future governance decisions

Use this section for later updates to spec boundaries, document authority, or
documentation governance.

### 2026-04-22 — Initial governance consolidation

- Recorded `spec/MVP.md` as the canonical umbrella spec.
- Recorded `spec/subspecs/mvp-remainder.md` as the active execution spec.
- Recorded MCP stdio, browser/TUI, and fingerprint planning docs as deferred.
- Recorded `MVP_PLAN.md`, `MVP_BACKLOG.md`, and `spec/PRD.md` as historical or
  background only.

### 2026-04-23 — MVP closure and conformance authority update

- Reframed `spec/MVP.md` so MVP closure is gated by curated WPT/Test262,
  a green default test baseline, and the no-stubs rule.
- Reframed `spec/subspecs/mvp-remainder.md` from closure record to active MVP
  completion track.
- Added `spec/subspecs/wpt-conformance.md` as the canonical conformance
  authority for curated WPT/Test262 work.
- Recorded that README and agent-facing guidance files must be updated when the
  canonical execution boundary changes.

### 2026-04-23 — Closed MVP surface narrowing

- Recorded the closed shipped MVP surface as a narrower browser-runtime subset
  rather than a generic browser API.
- Removed `IntersectionObserver` and `ResizeObserver` from the shipped MVP
  surface until real render-backed semantics exist.
- Narrowed `history` to same-origin `pushState` / `replaceState` plus `length`
  and `state`.
- Narrowed `fetch()` and `XMLHttpRequest` to explicit async GET-only semantics.
- Updated README and canonical specs together so the closure claim matches the
  runtime and curated WPT corpus.

### Template for future amendments

- Date:
- Change:
- Reason:
- Documents updated:
