# Hybrid rendering backend — active sub-spec

> **Status:** ACTIVE (promoted 2026-06-13 under
> `docs/adr/0004-hybrid-rendering-engine.md`, Accepted; the Path-A choice for
> `spec/subspecs/browser-roadmap.md §3` Tiers 4–5).
> `spec/MVP.md` is canonical; this file owns the execution detail for the
> hybrid backend. Closure records live here, not in browser-roadmap.md.

## 1. Purpose

Give AWR a second rendering backend so client-rendered SPAs, challenge-protected
sites, and interactive app flows (X, the Cloudflare dashboard, GitHub PR-approve,
Google Search) work — by **driving a real engine, not building one**. The
2026-06-13 spike (`reports/2026-06-13-architecture-spike.md`) proved the Zig +
QuickJS reader renders these blank while real Chrome renders them fully.

## 2. Invariants (load-bearing; may not be relaxed without amending ADR 0004)

1. **Fully terminal, headless-only.** The driven engine runs headless. There is
   **zero GUI window in any normal flow**.
2. **The TUI and agent surface are fixed; only the rendering engine is
   pluggable.** Switching backends never changes what the human or agent sees as
   the surface. The Zig render model (`src/render.zig`) and TUI
   (`src/browser.zig`) stay the presentation layer.
3. **Auth is via session / profile reuse**, never an interactive login window:
   drive the author's real, already-logged-in Chrome profile, or import
   logged-in cookies via `awr session import`.
4. **The Zig fast-path stays primary** for server-rendered / light pages and all
   agent JSON / Markdown output. The Chrome backend is the escalation path, not
   the default. The Zig path's Chrome-132 fingerprint discipline
   (`test-tls` / `test-h2` green every commit) is unchanged.

## 3. Architecture

```
URL ─► Router ─┬─ Zig fast-path (fetch → lexbor → QuickJS → render model)
               │     server-rendered / light pages, agent output
               └─ Chrome backend (CDP → headless Chrome → rendered DOM → render model)
                     SPA / challenge / interactive sites
   Router policy: choose per-URL; auto-escalate to Chrome when the Zig render
   returns a blank/empty shell.
   Both backends emit the SAME terminal render model → TUI / agent surface.
```

- **CDP backend:** spawn/attach a headless Chrome, navigate, pull the rendered
  DOM (and accessibility/text where useful) via the DevTools Protocol, map it
  into the existing terminal render model. NOT `src/net/`.
- **TUI↔CDP interaction bridge:** forward TUI actions (Tab/Enter/typing/submit)
  as CDP input events to the live DOM, then re-pull + re-render to the terminal —
  interaction stays in the TUI; Chrome executes underneath.
- **Session reuse:** the headless Chrome inherits the author's logged-in session
  (real profile or imported cookies), so authed sites load already signed-in.

## 4. Tasks (Phase 2 of `.goals/dogfood-daily-driver.md`)

- **HB1 — macOS Keychain session-reuse (load-bearing, first). ✓ Landed
  2026-06-13.** `awr session import chrome|chromium` now decrypts macOS cookies
  (`src/session_import.zig`): Keychain "Safe Storage" password → PBKDF2-HMAC-SHA1
  (saltysalt/1003) → AES-128-CBC (v10, space-IV), stripping the M127+ host-hash
  prefix; safe skip-fallback on failure. Pure Zig std.crypto; 3 TDD tests; full
  suite + `test-tls`/`test-h2` green. (HB2 consumes the imported jar.)
- **HB2 — CDP backend + per-URL router.** Drive headless Chrome via CDP; pull
  the rendered DOM into the render model; router picks Zig vs Chrome per URL and
  auto-escalates on blank/shell.
- **HB3 — TUI↔CDP interaction bridge.** Tab/Enter/typing/submit → CDP events →
  re-pull + re-render.
- **HB4 — Hard sites end-to-end.** Via backend + session reuse: X (view +
  signed-in), Cloudflare-dash (DNS management), GitHub PR-approve, Google Search.
- **HB5 — Closure audit.** Every hard site mapped to fresh evidence on both
  surfaces, fully terminal, no GUI.

## 5. Closure gates

1. Tier 0–3 + the Zig fast-path gates stay green (`test`, `test-tls`,
   `test-h2`).
2. Each HB4 site works end-to-end through the TUI and the agent surface, fully
   terminal (no GUI window), authenticated via session reuse.
3. The router demonstrably keeps server-rendered pages on the Zig fast-path (no
   needless Chrome spawn).
4. Co-located/integration tests cover the router decision, the CDP DOM→render
   mapping, and the interaction bridge.

## 6. Residual edge (documented, per ADR 0004)

A **cold-session interactive CAPTCHA / Turnstile** cannot always be solved in a
pure terminal. Mitigated by driving the established, trusted profile so such
challenges rarely fire — not eliminated.

## 7. Out of scope

- A **native Zig layout engine** (Path B, `docs/adr/0003-tier4-layout-strategy.md`).
- Any **GUI window** in a normal flow.
- The broader in-process Tier-5 API surface (Service Workers, IndexedDB, full
  Web Crypto, Workers) — delivered by driving real Chrome instead of re-built.
- The permanently-out-of-scope items in `spec/subspecs/browser-roadmap.md §5`
  (WebGL/Canvas pixels, media playback, WebRTC).
