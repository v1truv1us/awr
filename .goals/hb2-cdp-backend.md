# Goal — HB2: CDP backend + per-URL router

> Phase-2 task HB2 of `.goals/dogfood-daily-driver.md`, governed by
> `docs/adr/0004-hybrid-rendering-engine.md` (Accepted) and
> `spec/subspecs/hybrid-backend.md`. HB1 (`8749c82`) landed; this is next.

**Objective:** Add a second rendering backend that drives a real **headless**
Chrome via the DevTools Protocol and feeds the *existing* terminal render model,
plus a per-URL router that uses the Zig fast-path by default and auto-escalates
to Chrome when the Zig render comes back blank/shell — so client-rendered SPAs
(X, Cloudflare-dash, Google) render in the TUI and agent surface where they were
blank before. Fully terminal, no GUI.

## Success Criteria (pass/fail)
- [ ] A headless Chrome is spawned (`--headless=new --remote-debugging-port=0`)
      and driven over CDP; **no GUI window ever appears**. If Chrome isn't
      installed/launchable, the router falls back to the Zig path with a clear
      message — never crashes.
- [ ] The Chrome backend produces a **non-blank** render model for a
      client-rendered SPA where the Zig path produces a blank/shell. Proven on a
      hermetic SPA fixture AND live: `awr render https://x.com` (with the
      HB1-imported session) shows real content vs the prior 1 char.
- [ ] The **per-URL router** keeps server-rendered pages on the Zig fast-path
      (e.g. `news.ycombinator.com` renders with **no Chrome spawn**) and
      escalates to Chrome only on a blank/shell. The decision is observable
      (log/flag), not guessed.
- [ ] **Session reuse works headlessly:** the driven Chrome uses the author's
      session (inject the HB1-imported cookies via CDP `Network.setCookies`, or
      drive the real profile) so authed pages load signed-in — no login window.
- [ ] **The TUI and agent surface are unchanged** — both backends emit the same
      render model; no caller of `render` / `renderBrowseModel` / the JSON
      envelope is modified to special-case the backend.
- [ ] Gates green: `zig build`, `zig build test`, `zig build test-tls`,
      `zig build test-h2` all exit 0.

## Verification Evidence (required before any [x])
- Transcripts: `awr render https://x.com` (real content via Chrome) and
  `awr render https://news.ycombinator.com/` (via Zig, no Chrome spawn), with
  real exit codes.
- Co-located/integration tests for: (a) the router's blank/shell-detection →
  escalate decision, (b) the CDP-DOM → render-model mapping against a hermetic
  fixture (no live network), (c) the no-Chrome graceful-fallback path.
- Full suite + fingerprint gates green (real exit codes; trust EXIT 0, not the
  benign `failed command:` artifact).

## Scope
- **In:** CDP transport (reuse AWR's existing WebSocket impl from Tier 3 for the
  CDP socket); spawn/attach + navigate + settle (load/networkIdle or a bounded
  delay); pull the settled page (recommended: `Runtime.evaluate`
  `document.documentElement.outerHTML` → feed into AWR's **existing**
  lexbor→DOM→render path with JS disabled, so Chrome does the JS and AWR reuses
  its renderer); per-URL router + auto-escalation; cookie/session injection;
  graceful degradation when Chrome is absent.
- **Out:** TUI↔CDP *interaction* (typing/clicking/submitting → that's HB3); the
  hard-site closure audit (HB4/HB5); bundled Chromium (Path-B fallback only);
  native Zig layout engine; any GUI; **any change to `src/net/`**.

## Constraints
- Preserve existing behavior on the Zig fast-path; the Chrome backend is additive.
- **Never touch `src/net/`** header/cipher/ALPN order or HTTP/2 SETTINGS
  (fingerprint). `test-tls` + `test-h2` before every commit; revert on red.
- No stubs, no TODO placeholders, no dead code. Real implementation only.
- Honor the ADR 0004 invariants: headless-only, fixed surfaces, session-reuse
  auth (no interactive login window).

## Boundaries
- May add: a new `src/cdp/` (or similar) backend module, router wiring in
  `src/page.zig` / `src/main.zig`, tests. May reuse `src/net/` WebSocket code
  read-only and the existing `src/render.zig` model.
- Must NOT modify: `src/net/` emission, the render-model shape consumed by the
  TUI/agent surface, the fingerprint constants.

## Iteration Policy
- One task per iteration, `main` green at every commit, branch off `main`, a
  co-located test that fails-before/passes-after where feasible. Suggested order:
  (1) CDP transport + spawn/navigate/pull a page's HTML; (2) map settled HTML →
  render model via the existing path; (3) router + auto-escalation; (4) session
  injection; (5) graceful no-Chrome fallback.

## Completion Audit
- Map every success criterion to fresh evidence (test names + real exit codes,
  the two transcripts, the router-decision log). Not complete if any SPA still
  renders blank via the backend, the router needlessly spawns Chrome for
  server-rendered pages, a GUI window appears, or any gate is red.

## Blocked Stop Condition
- Stop and surface (don't loop past) if: a headless Chrome can't be driven on
  macOS arm64 within the 8 GB envelope after a real attempt; session injection
  can't authenticate X without a GUI step; or the render-model contract can't be
  met without changing the TUI/agent surface. Report attempted paths, evidence,
  the exact blocker, and what would unblock — escalating to ADR 0004 if the
  invariant itself is in tension.

## Key design notes (from the repo)
- AWR already has a **WebSocket** implementation (Tier 3, `browser-realtime.md`)
  — reuse it as the CDP transport rather than adding a dependency.
- The cleanest DOM→model mapping: let Chrome run the JS, grab the **settled
  outerHTML**, and run AWR's *existing* HTML→DOM→render pipeline with JS off.
  Chrome replaces QuickJS+lexbor-as-renderer-of-blank-shells; the renderer and
  surfaces stay identical.
- HB1 (`8749c82`) already imports the macOS session into AWR's jar — HB2 feeds
  that jar into Chrome.
