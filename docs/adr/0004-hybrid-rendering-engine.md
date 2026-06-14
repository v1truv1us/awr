# ADR 0004 — Hybrid rendering engine (drive a real engine, don't build one)

- Status: Proposed (awaiting `spec/MVP.md §8` sign-off, 2026-06-13) — NOT yet Accepted
- Date: 2026-06-13
- Owners: AWR maintainers
- Related specs: `spec/MVP.md`, `spec/subspecs/browser-roadmap.md`, `docs/adr/0003-tier4-layout-strategy.md`, `.goals/dogfood-daily-driver.md`, `.goals/make-awr-a-real-browser-core-wpt.md`

## Context

The dogfood goal (`.goals/dogfood-daily-driver.md`, decided 2026-06-13) makes
full Chrome replacement a **hard requirement** for a confirmed site list that
includes app-grade SPAs — X, the Cloudflare dashboard, and GitHub PR-approve.
The goal states the architecture is negotiable but the outcome is not, and
requires that a feasibility spike *characterize the exact failure mode* rather
than just pass/fail.

That spike ran: `reports/2026-06-13-architecture-spike.md`. It found a
**structural ceiling** in the current Zig + QuickJS + lexbor reader:

- **X (`x.com`) renders BLANK** — `awr render` produces **1 visible char**. The
  page is a client-rendered SPA; QuickJS plus the pointer-keyed DOM bridge do
  not supply enough browser environment for the app to build its DOM.
- **Cloudflare dashboard (`dash.cloudflare.com`) renders BLANK** — same failure,
  **1 visible char** from an empty client-rendered shell.
- **Google Search returns a bot-detection CAPTCHA** — the Chrome-132 TLS/JA4
  fingerprint clears the *network* gate (status 200, not blocked), but Google's
  anti-bot flags the non-Chrome *behavioral/JS-environment* signature.
  Impersonating Chrome at the wire is not being Chrome.
- **Real headless Chrome 149 clears the ceiling** — it rendered X at
  **~337,922 visible chars** (full app DOM, fonts, inputs) where AWR produced 1.
- **Server-rendered sites render perfectly today** — Hacker News yields full
  content (~13k visible chars), confirming the lean Zig path is the right tool
  for that class of page.

Both failure modes are structural, not fixable gaps. Deepening the Zig engine to
render SPAs is a multi-year browser-engine build, and even then the Google-class
behavioral detection would still flag it because it still is not real Chrome.

This decision changes AWR's product thesis: from *a Chrome-impersonating reader*
to *a terminal-UX + agent-friendly front-end to the real web, with two pluggable
backends*.

## Decisions made

| Decision | What was decided | Why |
|---|---|---|
| Pivot to a hybrid rendering architecture | We **drive** a real engine; we do **not build** one. Weeks, not years; de-risked. | The spike proved real Chrome clears the ceiling that a Zig engine cannot, and the goal demands those sites work. |
| Keep the Zig fast-path + agent surface | The Zig fetch/render path stays for server-rendered / light-JS pages and for all agent JSON / Markdown outputs. | Booting Chrome to extract an article for an LLM is the wrong tool; HN-class pages already render perfectly. |
| Add a CDP-driven Chrome backend | A backend drives a real Chrome via the Chrome DevTools Protocol for SPA / challenge / interactive sites. CDP also yields a clean rendered DOM that feeds the agent surface. | Real-Chrome behavior beats behavioral bot-detection for free and builds the SPA DOM the Zig reader cannot. |
| Per-URL router with auto-escalation | The router chooses a backend per URL, or auto-escalates to Chrome when the Zig render returns a blank/shell. | Keeps the lean path default and reserves the heavy backend for pages that need it. |
| Headless-only, fully-terminal invariant | The engine runs **headless-only**: zero GUI window in any normal flow. See the invariant section below. | "Fully terminal based" is a hard author requirement (2026-06-13); a GUI window breaks the product. |
| Session/profile reuse for auth | Authentication is via session/profile reuse — drive the author's real Chrome profile or import logged-in cookies via `awr session import`. Never an interactive login window. | Preserves the terminal invariant and lets established trust clear challenges that fire on cold sessions. |

## Decision policy

Until this ADR is Accepted under `spec/MVP.md §8` and amended into the canonical
specs, Phase 2 of the dogfood goal (the CDP backend) does not start. The
fully-terminal / headless-only invariant and the session-reuse auth model are
load-bearing and may not be relaxed without amending this ADR.

## Hard invariant — fully terminal, headless-only

Author requirement, 2026-06-13: **AWR is fully terminal based.**

- The driven engine runs **headless-only**. There is **zero GUI window** in any
  normal flow.
- The **TUI and the agent surface are FIXED**; only the *rendering engine* is
  pluggable behind them. Switching backends never changes what the human or the
  agent sees as the surface.
- **Authentication is via session / profile reuse**: drive the author's real,
  already-logged-in Chrome profile, or import logged-in cookies through the
  existing `awr session import`. There is **never** an interactive login window.

## Consequences

### Positive

- **Un-defers Tier-4/5, reframed.** The blocked Tier-4/5 program
  (`docs/adr/0003-tier4-layout-strategy.md`, `spec/subspecs/browser-roadmap.md §3`,
  `.goals/make-awr-a-real-browser-core-wpt.md`) becomes reachable — but as
  *drive an engine*, not *build a Zig layout engine*. This realizes ADR 0003's
  Option A (embedded layout/rendering oracle via CDP) as the chosen direction
  rather than a deferred POC.
- The hard-requirement sites (X, Cloudflare dashboard, GitHub PR-approve) become
  reachable on a weeks-scale path instead of a years-scale one.
- CDP's rendered DOM feeds the agent surface, so SPA pages also become
  extractable for LLM/tool consumers.

### Tradeoffs and costs

- **T7 / Phase-1 P1.2 is SUPERSEDED / CANCELLED.** Hand-rolling SPA rendering in
  QuickJS (post-load JS settle / re-render to un-blank Google, AudioFile, light
  SPAs) is exactly the throwaway work the spike was meant to prevent. The Chrome
  backend replaces it.
- **The Chrome-132 TLS/JA4 fingerprint RELAXES from "THE product" to "the lean
  path."** It stays valuable for fast server-rendered and agent fetches that do
  not need a full browser, but it is no longer the route to the dynamic web. The
  fingerprint discipline (`test-tls` / `test-h2` green every commit) still holds
  for the Zig path.
- **New dependency: a real Chrome + CDP control.** AWR now depends on an
  installed Chrome and a CDP client, which it did not before.
- **macOS Chrome encrypted-cookie import is load-bearing and unfinished.** The
  CLI currently skips Keychain integration ("Keychain integration deferred" per
  `awr session import` help). It must be finished so headless session-reuse works
  on macOS — the author's primary platform.

### Residual edge (honest)

- A **cold-session interactive CAPTCHA / Turnstile** cannot always be solved in a
  pure terminal. Mitigated by driving the established, trusted profile so such
  challenges rarely fire — but not eliminated. This is documented, not hidden.

## Alternatives considered

### Option A — Deepen the Zig engine to a real Tier-4/5 browser

Build full CSS layout, MutationObserver-driven re-render, and the rest of the
SPA runtime natively in Zig.

- Rejected. Multi-year effort, and it **still loses to behavioral bot-detection**
  because the result is not real Chrome — the spike's Google CAPTCHA proves the
  network-fingerprint win does not extend to the JS/behavioral layer.

### Option B — Bundle Chromium (Carbonyl-style framebuffer-to-terminal)

Ship a self-contained Chromium that renders its framebuffer to the terminal.

- **Kept as FALLBACK** if a self-contained single binary is later required.
  Heavier packaging than driving an installed Chrome; deferred unless the
  installed-Chrome dependency becomes unacceptable.

### Option C — WebKit / Servo

Drive or embed a non-Chromium engine.

- Rejected. Wrong fingerprint (does not match the Chrome the author already runs,
  so it would not inherit profile trust) and immature for this use.

## Required evidence before final activation

Before this ADR moves Proposed → Accepted and Phase 2 begins, the
`spec/MVP.md §8` sign-off must confirm:

1. The author authorizes the product-thesis shift and the new Chrome/CDP
   dependency.
2. The macOS Keychain encrypted-cookie import path is scoped as the first
   load-bearing task (headless session-reuse depends on it).
3. The router contract (per-URL choice + blank/shell auto-escalation) and the
   TUI↔CDP interaction bridge (forward Tab/Enter/typing as CDP events; re-pull
   and re-render the DOM to the terminal) are recorded in the affected sub-specs
   alongside this ADR.

## References

- `reports/2026-06-13-architecture-spike.md` — the spike: X/CF blank (1 char),
  Google bot-detection CAPTCHA, real Chrome 149 at ~337,922 chars on X.
- `docs/adr/0003-tier4-layout-strategy.md` — Tier 4 layout strategy; this ADR
  selects its Option A (CDP layout/rendering oracle) as the chosen direction.
- `spec/subspecs/browser-roadmap.md §3` — the tier ladder this pivot un-defers.
- `.goals/make-awr-a-real-browser-core-wpt.md` — the existing real-browser
  vision track now activated, reframed.
- `.goals/dogfood-daily-driver.md` — the goal whose hard requirements forced the
  spike and this decision.

## Decision log

### 2026-06-13 — Hybrid pivot proposed (drive an engine, not build one)

Decision: Pivot to a hybrid rendering architecture — keep the Zig fast-path +
agent surface, add a CDP-driven headless Chrome backend behind a per-URL router,
with a fixed TUI / agent surface, headless-only operation, and session/profile
reuse for auth. Status Proposed pending `spec/MVP.md §8` sign-off.

Reason: The 2026-06-13 spike proved the current architecture has a structural
ceiling (X / CF blank; Google behavioral block) that the dogfood goal's hard
requirements cannot tolerate, and that real Chrome clears it. Driving an engine
is weeks and de-risked; building one is years and still loses to bot-detection.

## Amendment rule

Update this ADR whenever:

- the Proposed → Accepted transition happens (record the §8 sign-off date);
- the backend choice changes (e.g., the bundled-Chromium fallback is adopted);
- the router contract or TUI↔CDP interaction bridge changes materially;
- the fully-terminal / headless-only invariant or the session-reuse auth model
  is challenged or relaxed;
- the relationship between the Zig fast-path and the Chrome backend changes
  (e.g., the Zig path is narrowed further or retired).

### Template for future amendments

- Date:
- Change:
- Reason:
- Documents updated:
