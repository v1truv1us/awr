# Architecture-feasibility spike — 2026-06-13

**Question (per the dogfood goal):** can the current Zig + QuickJS + lexbor
architecture reach the author's full daily-driver list (incl. X, Cloudflare
dashboard), or must the architecture pivot? Run because the author directed:
"if the architecture isn't feasible for what I want, pivot to a better browser
architecture."

**Verdict: GO — pivot to a HYBRID architecture. Keep the Zig reader + agent
surface for server-rendered/light pages; add a real-Chrome backend (driven via
the DevTools Protocol) for client-rendered SPAs and bot-challenged sites. We
*drive* an engine, we don't *build* one — weeks, not years, and de-risked.**

## Evidence — current architecture (stale `zig-out/bin/awr`, arch-representative)

| Site | `awr <url>` | `awr render` | Failure mode |
|------|-------------|--------------|--------------|
| news.ycombinator.com (control) | 200, full content | 13,123 visible chars, perfect | none — server-rendered works great |
| google.com/search | 200, "unusual traffic" | CAPTCHA interstitial ("checks if it's really you, not a robot") | adversarial bot-detection — TLS passed, *behavior* flagged |
| x.com | 200, "Something went wrong…" | **1 char (blank)** | SPA shell never initializes |
| dash.cloudflare.com | 200, empty `<div>` soup | **1 char (blank)** | empty client-rendered SPA shell |

Two distinct failure modes, both structural:
1. **SPA shells (X, CF-dash):** the app builds its UI client-side; QuickJS + the
   pointer-keyed DOM bridge don't provide enough browser environment, so the DOM
   never builds → blank.
2. **Behavioral bot-detection (Google):** the Chrome-132 TLS/JA4 fingerprint
   clears the *network* gate (status 200, not blocked), but Google's anti-bot
   flags the non-Chrome *behavioral/JS-environment* signature. Impersonating
   Chrome at the wire ≠ being Chrome.

Neither is a fixable gap: deepening the Zig engine to render SPAs is a multi-year
browser-engine build, and even then the Google-class behavioral detection would
still flag it because it still isn't real Chrome.

## Evidence — real engine clears the ceiling (Chrome 149, `--headless=new --dump-dom`)

| Site | real-Chrome DOM | vs awr |
|------|-----------------|--------|
| x.com | **386,822 bytes / ~337,922 visible chars** (real app DOM, fonts, inputs) | awr: blank (1 char) |
| dash.cloudflare.com | 31,935 bytes — but "Just a moment…" (Cloudflare's *own* challenge hits cold headless too) | awr: blank (1 char) |

Real Chrome renders X fully. Cloudflare-dash challenges even headless Chrome —
solvable by driving the author's **real, logged-in, headful** Chrome profile
(the session they already use to manage DNS daily), not a cold headless one.

## Recommended architecture — Hybrid, CDP-driven Chrome

- **Keep** the Zig fetch/render fast-path + agent surface for server-rendered /
  light-JS pages (HN, AudioFile, GitHub-read) and for the agent JSON/Markdown
  outputs — booting Chrome to extract an article for an LLM is the wrong tool.
- **Add** a real-Chrome backend driven via the **Chrome DevTools Protocol (CDP)**
  for SPA-class / challenge-protected / interactive sites. Reuses the Chrome the
  author already runs; real-Chrome behavior beats bot-detection for free; CDP
  also yields a clean rendered DOM for the agent surface. Support a persistent /
  headful profile for challenge sites (Cloudflare, X login).
- **Router:** choose backend per-URL, or escalate automatically when the Zig
  render returns a blank/shell.
- **Engine choice:** CDP-drive installed Chrome (leanest; 8 GB-friendly — one
  page at a time). Fallback if a self-contained binary is later required:
  bundled Chromium, Carbonyl-style (renders framebuffer to terminal). NOT a
  custom Zig engine (years + still loses to bot-detection); NOT WebKit/Servo
  (wrong fingerprint / immature).

## Implications for the plan
- **T7 / P1.2 (hand-rolled SPA rendering in QuickJS) is superseded** by the
  Chrome backend — cancel it; that's the throwaway work the spike was meant to
  prevent. Big save.
- The **hand-built TLS/JA4 fingerprint relaxes from "THE product" to "the lean
  path"** — still valuable for fast server-rendered + agent fetches that don't
  need a full browser, but no longer the route to X/CF/Google. This is the
  product-thesis shift the ADR must record: from *building a Chrome-impersonating
  reader* to *a terminal-UX + agent-friendly front-end to the real web*.
- **New Phase 2 = the CDP backend + per-URL router** (weeks, de-risked), not a
  Zig Tier-4/5 layout engine (years, risky). The ADR un-defers Tier-4/5 but
  reframed as *drive an engine*, not *build one*.

## Incidental bugs found (not in spike scope; flagged)
1. **The shippable `awr` executable does not currently build** —
   `src/image/pipeline.zig:392:40` type error (`expected pipeline.Entry, found
   []u8`) via `browser.zig:rerenderCurrent`. Pre-existing, unrelated to P1.1.
   `zig-out/bin/awr` is stale from before the breakage.
2. **CI gap:** the A1 workflow runs `test`/`test-tls`/`test-h2`/`fmt` but never a
   bare `zig build` of the executables, so it would not catch bug #1. Add an
   executable-build step to CI.
