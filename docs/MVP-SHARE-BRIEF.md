# AWR MVP Share Brief

AWR is a dual-surface, CLI-first terminal browser written in Zig. One binary serves humans through an interactive TUI and agents through JSON, Markdown, and WebMCP commands. Both surfaces use the same fetch, DOM, JavaScript, render, cookie, and connection pipeline.

## What the MVP is

The current MVP is **not Chrome in a terminal**. It is a WPT-gated browser/runtime slice aimed at pages that can be meaningfully fetched, scripted, extracted, rendered, and interacted with from a terminal.

Shipped surfaces:

- Human TUI: `awr tui` / `awr browse` for reading pages, following links, filling forms, history, URL bar, cookie inspection, and browser-cookie import.
- Agent CLI: `awr <url>`, `awr render`, `awr extract`, `awr submit`, `awr tools`, and `awr call`. All fetch commands accept `--header "Name: Value"` for custom request headers (Bearer tokens, API keys, etc.).
- Shared session/runtime: real HTTP(S), cookies, HTML parsing, DOM, JavaScript execution, forms, history, storage, events, SSE, WebSocket, terminal rendering, images, and a long-lived daemon mode.
- Starter CSSOM: loads `<style>` and `<link rel="stylesheet">`, exposes inline `element.style`, and supports simple non-layout `getComputedStyle()` values such as `display` and `visibility`.

## Real-site verification (as of 2026-05-27)

AWR handles the following publicly accessible sites under 30 seconds:

| Site | Time | Notes |
|------|------|-------|
| Hacker News | ~1.2s | Full front page, all 30 stories |
| Wikipedia | ~0.9s | Full article text |
| GitHub | ~2.3s | Repo page with all metadata |
| Stack Overflow | ~4s | Questions listing |
| old.reddit.com | ~1.8s | Reddit via the non-JS path |
| audiofile.app | ~0.9s | SPA shell; authenticated API flow via `docs/audiofile-e2e.sh` |

Reddit's www.reddit.com is blocked by Cloudflare's JS challenge; `old.reddit.com` returns real content. Chrome 132 JA4 fingerprint (`awr_ja4_h2`) is unchanged.

## What the MVP deliberately is not

Deferred until Tier 4/5:

- Full CSS cascade/layout, box model, flexbox, grid, text shaping, and scroll-driven layout.
- Geometry-backed `IntersectionObserver` / `ResizeObserver` semantics.
- Full SPA parity for sites that depend on browser layout, Service Workers, IndexedDB, canvas/WebGL/audio fingerprinting, or multi-tab browser behavior.

## Correctness model

AWR grows by curated Web Platform Tests and Test262 coverage. A feature is not considered shipped until it is exercised by the in-repo WPT/Test262 harness or an explicit smoke/corpus gate. The canonical scope lives in `spec/MVP.md`; the tier ladder lives in `spec/subspecs/browser-roadmap.md`; the current conformance map lives in `spec/subspecs/wpt-conformance.md`.

## Path from here

The next strategically important decision is Tier 4: whether AWR builds a Zig-native layout engine or embeds/shells out to an existing browser layout component. That decision is tracked in `docs/adr/0003-tier4-layout-strategy.md` and should be updated as audits/prototypes change the recommendation. Until that ADR selects a path, CSS work should stay in the starter CSSOM lane: stylesheet loading, simple computed style, and WPT cases that do not require real layout.
