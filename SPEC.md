# AWR SPEC

This is the entry point for AWR product and engineering scope. If a document conflicts with this map, use the more specific active spec listed here, then update this file and the relevant ADR.

## Canonical spec hierarchy

1. **Umbrella scope / change control**
   - `spec/MVP.md`
   - Defines the shipped MVP surface, active-vs-deferred boundaries, closure gates, and canonical document map.

2. **Cross-tier roadmap**
   - `spec/subspecs/browser-roadmap.md`
   - Defines Tier 0–5 capability progression and when new WPT coverage is required.

3. **Conformance authority**
   - `spec/subspecs/wpt-conformance.md`
   - Defines the curated WPT/Test262 corpus, merge gates, and active/deferred conformance cases.

4. **Active / closed feature specs**
   - `spec/subspecs/agent-browser.md` — agent-browser behavior: POST fetch/XHR, form POST, cookies.
   - `spec/subspecs/browser-tui.md` — interactive terminal browser behavior.
   - `spec/subspecs/rendering.md` — terminal rendering and image protocols.
   - `spec/subspecs/render-polish.md` — render/UX polish.
   - `spec/subspecs/daemon-mode.md` — long-lived daemon and IPC.
   - `spec/subspecs/browser-history.md` — History API subset.
   - `spec/subspecs/browser-storage.md` — Web Storage.
   - `spec/subspecs/browser-realtime.md` — SSE and WebSocket.
   - `spec/subspecs/browser-events.md` — events, timers, `matchMedia`.
   - `spec/subspecs/cssom.md` — starter non-layout CSSOM track.
   - `spec/subspecs/tui-quality.md` — TUI UX quality track (inline link word-wrap, loading indicator, help modal, table linearization). CLOSED 2026-05-30.

5. **Deferred strategy docs**
   - `spec/subspecs/mcp-stdio.md` — native MCP stdio server track.
   - `spec/Fingerprint-Plan.md` / `spec/FINGERPRINT.md` — fingerprinting strategy.
   - Tier 4 layout strategy is tracked in `docs/adr/0003-tier4-layout-strategy.md` until promoted into a dedicated sub-spec.

6. **Background only**
   - `spec/PRD.md`
   - `spec/MVP-Review.md`
   - `MVP_PLAN.md`
   - `MVP_BACKLOG.md`

## ADRs

Architecture Decision Records live in `docs/adr/` and explain **what was decided** and **why**. Update or add an ADR whenever a decision changes scope, architecture, canonical document authority, or a deferred/active boundary.

Current ADRs:

- `docs/adr/0001-spec-governance.md` — why the spec hierarchy exists and how authority changes are recorded.
- `docs/adr/0002-daemon-mode-deferred.md` — daemon-mode decision history.
- `docs/adr/0003-tier4-layout-strategy.md` — Tier 4 layout strategy, evidence requirements, and embed-vs-native decision log.

## Rule for future changes

When making a decision that matters later:

1. Update the narrowest relevant spec.
2. Update `spec/MVP.md` if the shipped/deferred boundary changes.
3. Update this `SPEC.md` if the document map changes.
4. Update or create an ADR with:
   - decision made;
   - reason / evidence;
   - alternatives considered;
   - consequences;
   - documents/code affected.
