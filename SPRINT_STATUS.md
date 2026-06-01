# Sprint Status

## 2026-06-01

### Deliverable
Status snapshot of where AWR stands against the canonical spec set
(`spec/MVP.md`). No code or spec changes — reconciliation of status docs only.

### Where the project stands
- **Tiers 0–3 CLOSED.** Agent runtime baseline, interactive TUI parity
  (2026-05-11), render + UX polish (2026-05-13), and lightly dynamic site
  support (2026-05-22) are all closed per `spec/subspecs/browser-roadmap.md §3`.
- **Daemon mode CLOSED** (2026-05-23): long-lived `awrd` on a Unix socket,
  JSON-RPC IPC, shared `Client`/pool, per-scope cookie jars.
- **Starter CSSOM CLOSED** (2026-05-27): stylesheet loading, declaration APIs,
  cascade, non-layout `getComputedStyle()`, renderer integration. Post-closure,
  no-layout CSS extensions §2.1–§2.7 landed through 2026-05-31 (UA text
  defaults, compound/combinator/attribute selectors, computed-value
  serialization, compiled-selector cache, structural pseudo-classes, `@media`
  in the cascade, shorthand longhands + CSS-wide keywords, full color
  serialization) — each backed by curated WPT cases.
- **TUI Quality Track CLOSED** (2026-05-30): all five UX items done (inline link
  word-wrap, loading indicator, help modal, table linearization, nav feedback);
  1196 tests green.

### Active frontier
- No-layout CSS extensions remain the live track: continuing to grow CSSOM/WPT
  coverage that does not require a layout engine (the §2.x line of work above).

### Deferred
- **Tier 4 (layout engine) DEFERRED**, gated on the embed-vs-build decision.
  No work starts without an ADR amendment recording the chosen path and the
  supporting evidence in `docs/adr/0003-tier4-layout-strategy.md`.
- **Tier 5 (full SPA parity) DEFERRED** — only sensible after Tier 4.

---

## 2026-05-09

### Deliverable
Documented follow-up on recent AWR problem-log entries and verified whether the prior `drainAll()` / `react.dev` hang still reproduces in the current local checkout.

### Completed
- Triaged `~/.pi/agent/awr-web/problems.jsonl`
- Confirmed only `awr-20260508021000-drain_hang` was a real bug candidate
- Verified the fix is present in source:
  - `src/page.zig`
  - `src/js/event_loop.zig`
- Confirmed relevant local commit:
  - `fb1f2f5 fix(js): deadline-bounded tickOnce so drainAll honors max_ms`
- Re-ran live checks against the built binary:
  - `https://react.dev` now completes successfully
  - `https://x.com` returns challenge content but does not hang
  - `https://www.reddit.com/r/programming` returns verification content but does not hang
- Wrote detailed notes to:
  - `docs/research/2026-05-09-awr-followup.md`

### Current conclusion
- The prior `drainAll()` hang appears fixed in the current local AWR checkout.
- `x.com` and Reddit results look like separate challenge / anti-bot limitations, not the same engine bug.

### Remaining work
- Optional: open a separate tracking item for challenge-page behavior on bot-protected sites.
