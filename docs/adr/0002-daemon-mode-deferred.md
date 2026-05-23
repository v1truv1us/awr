# ADR 0002 — Daemon mode deferred to post-Tier-3 track

## Status

**ACCEPTED** — 2026-05-23

## Context

`spec/subspecs/daemon-mode.md` was proposed on 2026-05-07 and accepted as
a B1 design: a long-lived `awrd` process exposing a Unix-socket JSON-RPC IPC
interface, with per-cookie-scope state partitioning to amortize per-invocation
startup cost across chained agent fetches.

The companion design doc (`docs/research/2026-05-07-daemon-mode-design.md`)
estimated startup savings on the order of 590 ms → <450 ms for a HN fetch.
The performance benefit is real.

However, as of 2026-05-23:

1. Tiers 0–3 of the browser-roadmap are all **closed**. The original framing
   placed daemon mode inside Tier 0 as an amortization mechanism. Tiers 0–3
   closed without daemon mode being required for any gate.
2. No daemon-mode implementation code has shipped. The sub-spec describes the
   desired IPC contract but carries no running implementation.
3. The MVP gates defined in `spec/MVP.md §4` do not mention daemon mode as a
   required gate item.
4. Implementing `awrd` (new binary, Unix-socket server, JSON-RPC 2.0 IPC, IPC
   client shim in the CLI, per-scope cookie partitioning) is non-trivial scope
   that would expand the project after all Tier 3 gates are otherwise satisfied.

## Decision

**Defer daemon mode to a post-Tier-3 follow-on track.**

The deferral is explicit and documented rather than silent:

- `spec/subspecs/daemon-mode.md` status header → **DEFERRED** (pointer to
  this ADR).
- `spec/MVP.md` header note updated to reflect daemon mode is active but not
  an MVP gate.
- The B1 design doc and IPC contract in `daemon-mode.md` are preserved as-is
  for when the track is promoted.

## Consequences

- Startup cost per invocation remains as-is (no amortization) until daemon mode
  is promoted and implemented.
- The `AWR_DAEMON=1` opt-in path described in the spec does not exist yet; code
  that checks this env var would fall through to the in-process path.
- When daemon mode is promoted, it requires an ADR amendment that removes this
  DEFERRED status, sets a concrete implementation milestone, and updates
  `spec/MVP.md §2` accordingly.
- Performance-sensitive agent workflows that chain many fetches should account
  for per-invocation startup cost until daemon mode ships.
