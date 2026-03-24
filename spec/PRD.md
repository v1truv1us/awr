# Agentic Web Runtime (AWR) — Product Requirements Document

**Version**: 0.1.0
**Date**: 2026-03-21
**Status**: Draft — Pre-Implementation

---

## Executive Summary

AWR is a CLI-first terminal browser written in Zig, designed to serve both AI agents and human developers. It is the first browser primitive that simultaneously passes modern bot-detection fingerprinting (JA4+/Cloudflare/DataDome) and natively supports the W3C WebMCP standard — exposing website tool schemas as JSON directly to AI agents.

The timing is precise: WebMCP landed in Chrome 146 on March 10, 2026. There are zero production implementations. AWR ships the reference agent browser before any incumbent can pivot.

---

## Problem Statement

### For AI Agents

AI agents need to browse the web. Current solutions fail in two ways:

1. **Bot detection blocks them.** Playwright, Puppeteer, and every CDP-based tool carry detectable TLS fingerprints, H2 SETTINGS anomalies, and CDP artifacts. Modern bot detection (Cloudflare, DataDome, PerimeterX) identifies and blocks them within seconds.

2. **They can't consume WebMCP.** The W3C WebMCP standard lets websites publish structured tool schemas directly to browsers — `navigator.modelContext.registerTool()`. No existing agent framework can read these. Agents scrape HTML instead of consuming typed APIs, leading to brittle prompt engineering and high token cost.

### For Developers

Developers debugging agent web interactions have no terminal-native browser that:
- Shows exactly what an agent sees (not a headless Chrome approximation)
- Runs in CI/CD without a display server
- Has a binary small enough to ship in a Docker layer
- Passes bot detection without maintaining a full Chromium build

### The Gap

| Capability | Playwright MCP | Lightpanda | Browserless | AWR |
|---|---|---|---|---|
| TLS fingerprint spoofing | ✗ | ✗ | ✗ | ✓ |
| Passes Cloudflare | ✗ | ✗ | Partial | ✓ |
| Native WebMCP | ✗ | ✗ | ✗ | ✓ |
| Terminal UI | ✗ | ✗ | ✗ | ✓ |
| Binary < 50MB | ✗ | ✓ | ✗ | ✓ |
| Memory < 100MB | ✗ | ✓ | ✗ | ✓ |

---

## Solution Overview

AWR is a single binary that provides:

1. **A TLS-accurate HTTP client** — Phase 1 uses `std.crypto.tls` (via `std.http.Client`) for HTTPS. Phase 3 replaces this with an owned BoringSSL stack that produces AWR's own stable JA4+ fingerprint, with GREASE injection, X25519MLKEM768 post-quantum key exchange, ALPS, and matching HTTP/2 SETTINGS frames. Not a heuristic approximation — byte-exact.

2. **A JS execution environment** — QuickJS-NG v0.13.0 embedded via mitchellh/zig-quickjs-ng, with 96% of Chrome's Web Platform Tests passing. Executes real-world JS bundles (HN, Reddit) correctly without a full V8 dependency.

3. **A fingerprint synthesis layer** — Pre-recorded device profile database with seeded perturbation for Canvas, WebGL, AudioContext, and screen metrics. Profiles match real hardware; perturbation is deterministic per session seed.

4. **A WebMCP host** — First production implementation of `navigator.modelContext`. When an agent loads a WebMCP-enabled site, AWR exposes the site's registered tools as structured JSON. The agent calls tools by name; AWR executes them and returns typed results.

5. **A TUI** — libvaxis-based terminal interface for human browsing with keyboard navigation, rendered from the same DOM tree the agent sees.

---

## Market Landscape

### Direct Competitors

**Lightpanda** (Zig, beta) — The most technically credible threat. Also Zig, also resource-efficient. They do not have TLS fingerprint spoofing. They do not have WebMCP. Their moat is pure resource efficiency; AWR's moat is anti-bot survival + agent-native interface.

**Playwright MCP** (Microsoft) — A Model Context Protocol wrapper around Chromium via CDP. Works, but carries all of Chromium's detection surface: JA4 fingerprint anomalies, CDP header leakage, DevTools protocol artifacts. Not deployable at scale against modern bot detection. Also not a real WebMCP implementation — it's an MCP server that remote-controls a browser, which is a completely different architecture.

**Browserless / Apify** — Cloud services that rotate Chromium instances. Expensive per-call, not embeddable, not local-first, and do not solve the fingerprinting problem — they just rotate detected fingerprints.

**Headless Chrome / Puppeteer** — The baseline. Detected trivially. Included here only to establish why the market exists.

### Market Timing

WebMCP shipped in Chrome 146 on 2026-03-10. That was 11 days ago. No production browser has implemented the WebMCP host API. The first developer tool to implement it becomes the reference implementation. That window is measured in weeks, not months.

---

## Architecture Decisions

All decisions below are settled. They are documented here for rationale, not for debate.

### Language: Zig

Zig provides C-ABI interop without a runtime, deterministic memory control via custom allocators, and comptime for zero-cost DOM handle generation guards. The async model (libxev) fits the I/O-heavy browser event loop better than Go's goroutine overhead. Lightpanda proving Zig is viable for this domain de-risks the language choice.

### Event Loop: libxev

io_uring on Linux, kqueue on macOS, IOCP on Windows — all through a single libxev API. Avoids libuv's Node.js association and its allocation patterns.

### JS Engine: QuickJS-NG v0.13.0

V8 would require shipping a 100MB+ binary. SpiderMonkey has complex build requirements. QuickJS-NG via mitchellh/zig-quickjs-ng provides 96% WPT coverage at ~5MB embedded. The remaining 4% consists of edge cases in WeakRef GC semantics and some TC39 proposal implementations that are not required for the target sites (HN, Reddit, standard SaaS).

### TLS: std.crypto.tls (Phase 1) → owned BoringSSL stack (Phase 3)

**Phase 1 decision**: HTTPS uses `std.http.Client` backed by `std.crypto.tls`. curl-impersonate has no brew formula and requires a full patched-OpenSSL source build — significant friction for a validation phase whose goal is simply to confirm URLs can be fetched. The Phase 1 fingerprint milestone is deferred.

**Phase 3 plan**: Replace with an owned BoringSSL stack. AWR will produce its own stable JA4+ fingerprint (not Chrome's) — the same path any new legitimate browser takes. curl-impersonate is available as an opt-in build backend (`-Dtls-backend=curl_impersonate`) for teams that need fingerprint validation before Phase 3 ships, but it is not the default and will be removed before any public release.

### HTTP/2: nghttp2 with custom SETTINGS

Chrome's H2 SETTINGS frame is fingerprinted as aggressively as TLS. nghttp2's C-ABI lets us inject custom SETTINGS values and control pseudo-header ordering (`:method, :authority, :scheme, :path`). No other Zig HTTP library exposes this level of control.

### HTML Parser: Lexbor

Pure C, zero dependencies, fast, permissive license. Produces a DOM tree AWR owns and can extend with WebMCP properties.

### Canvas Fingerprinting: Pre-recorded profiles + seeded perturbation

Generating realistic Canvas noise at runtime requires either a real GPU or software rendering that produces identifiable patterns. Pre-recorded profiles from real hardware are indistinguishable from the originating device. Seeded perturbation (deterministic per session UUID) prevents profile re-identification across sessions while maintaining per-session consistency. Pixman noise was evaluated and rejected because software-rendered noise is distinguishable from hardware GPU variance.

### DOM: Custom zigdom with Tiered Allocators + DOMHandle generation guards

`document.createElement()` allocation patterns are fingerprinted. Tiered allocators (arena for page lifetime, pool for ephemeral nodes) produce allocation signatures matching real browser behavior. DOMHandle generation guards (comptime-generated per handle type) prevent use-after-free bugs that would be silent in a C implementation.

### TUI: libvaxis

libvaxis is the canonical Zig terminal library. Provides sixel graphics support (for future image rendering), mouse event handling, and proper unicode column width calculation.

---

## Phase Plan

### Phase 1 — Networking & TLS (Weeks 1–4) ✅ COMPLETE

**Goal**: Make an HTTP and HTTPS request through a complete Phase 1 networking stack.

**Achieved milestone**: `zig build test` → 259/260 passing (1 correctly skipped). `zig build test-e2e` → 89/91 passing (2 correctly skipped — curl_impersonate-gated). Live HTTPS fetch of `https://example.com` returns 200 + "Example Domain" via `std.crypto.tls`. JA4+ fingerprint milestone moved to Phase 3.

**Deliverables** (all shipped):
- TCP connection manager via libxev
- HTTPS via `std.http.Client` / `std.crypto.tls` (Phase 1 pragmatic choice)
- `tls.zig` stub with opt-in `curl_impersonate` backend (`-Dtls-backend=curl_impersonate`)
- nghttp2 integration with custom SETTINGS frames
- HTTP/1.1 implementation
- Connection pooling (per-origin, max 6)
- Cookie jar (RFC 6265)
- Redirect following
- Basic DNS resolution
- JS engine (QuickJS-NG), HTML parser (Lexbor), DOM modules

### Phase 2 — JS Environment (Weeks 5–8)

**Goal**: Execute real-world JS bundles correctly.

**Milestone**: HN and Reddit homepages fetch, parse, and execute JS without errors. DOM mutations from JS are reflected in the node tree.

**Deliverables**:
- QuickJS-NG integration via zig-quickjs-ng
- Web API surface: fetch, setTimeout/setInterval, console, URL, URLSearchParams
- DOM bindings: querySelector, addEventListener, createElement, innerHTML, dataset
- HTML/CSS parsing pipeline (Lexbor → zigdom)
- Resource loading (inline scripts, external script tags)
- Basic CSS cascade (enough for layout metrics)

### Phase 3 — Fingerprint Synthesis & TUI (Weeks 9–12)

**Goal**: Pass behavioral bot detection. A human can browse in the terminal.

**Milestone**: DataDome bypass confirmed on 3 target sites. libvaxis TUI renders pages with keyboard navigation.

**Deliverables**:
- Navigator object: userAgent, platform, languages, hardwareConcurrency, deviceMemory
- Canvas fingerprint injection (pre-recorded profiles + seeded perturbation)
- WebGL stub (profile-matched renderer/vendor strings)
- AudioContext fingerprint (pre-recorded oscillator output)
- Screen and window metrics from profile
- Mouse/keyboard event timing model
- libvaxis TUI renderer
- Keyboard navigation (Tab, arrows, Enter, search)
- Status bar, link previews, error display

### Phase 4 — Agent Interface & WebMCP (Weeks 13–16)

**Goal**: An AI agent navigates a WebMCP-enabled site via tool calls.

**Milestone**: Claude Code and Aider, pointed at a WebMCP mock server, successfully discover tools via `navigator.modelContext.getTools()` and execute them. Results are returned as typed JSON.

**Deliverables**:
- `navigator.modelContext` implementation
- `registerTool()` / `getTools()` / `callTool()` JS API
- WebMCP tool schema serialization (JSON Schema)
- Agent API: stdin/stdout JSON protocol for headless agent use
- MCP server mode: AWR as a tool server for Claude Code / agent frameworks
- WebMCP mock server (standalone test target)
- Documentation: agent integration guide

---

## MVP Definition

**WebMCP Mock Server Demo** — a self-contained demo showing:

1. A local web server serving a page that calls `navigator.modelContext.registerTool()` with 2–3 tools (e.g., `search_products`, `add_to_cart`, `get_price`)
2. AWR loads the page, discovers the tools, and exposes them to the agent
3. Claude Code (or Aider, via MCP) receives the tool list, calls a tool, and gets a typed JSON response
4. The interaction is logged to a shareable terminal session

This demo requires no real bot detection, no real TUI, no real fingerprinting — just the WebMCP plumbing working end-to-end. It is the proof that the architecture is correct before we invest in the hard parts.

MVP is achievable within the Phase 4 timeline. It is not a separate track.

---

## Success Metrics

### Technical (Hard Pass/Fail)

- [ ] JA4+ fingerprint matches Chrome 132 exactly: `t13d1517h2_8daaf6152771_b6f405a00624`
- [ ] Passes Cloudflare bot check without CAPTCHA solve on 5 test URLs
- [ ] Passes DataDome detection on 3 target sites
- [ ] Binary size < 50MB (stripped release build)
- [ ] Peak memory usage < 100MB for a typical page load (HN homepage baseline)
- [ ] P99 TTFB < 500ms on a 50Mbps connection (networking overhead only, no render)

### Product (16-Week Targets)

- [ ] MVP WebMCP demo works with Claude Code and Aider
- [ ] GitHub repository reaches 100+ stars within 2 weeks of launch, OR 50+ developer signups to waitlist/newsletter
- [ ] At least one external contributor submits a PR

### Developer Experience

- [ ] `zig build` produces a working binary from a clean checkout in < 2 minutes on an M-series Mac
- [ ] `awr fetch https://example.com` returns the page body with no setup beyond installation
- [ ] Agent JSON protocol documented with at least one working example

---

## Risks & Mitigations

### R1: curl-impersonate linked library build complexity

**Risk**: curl-impersonate requires patching OpenSSL/BoringSSL and curl. The Zig build system integration may be fragile across platforms.
**Likelihood**: High — **RESOLVED for Phase 1**. curl-impersonate has no brew formula and requires a full patched-OpenSSL source build. Phase 1 avoids this entirely by using `std.crypto.tls`. curl-impersonate is isolated behind `tls.zig`'s C-ABI shim and selectable via `-Dtls-backend=curl_impersonate`, but is not built by default.
**Phase 3 mitigation**: The owned BoringSSL stack replaces curl-impersonate entirely. Pre-built static libraries for macOS/arm64, macOS/x86_64, and Linux/x86_64 can be committed to `third_party/` as a build-time fallback during Phase 3 development.

### R2: QuickJS-NG compatibility gaps

**Risk**: The 4% WPT gap may include APIs required by target sites not yet identified.
**Likelihood**: Medium
**Mitigation**: Phase 2 milestone (HN + Reddit) is specifically designed to surface gaps early. QuickJS-NG has an active development community; missing APIs can be polyfilled in JS or patched upstream.

### R3: WebMCP spec instability

**Risk**: The WebMCP spec shipped in Chrome 146 11 days ago. It may change in Chrome 147+.
**Likelihood**: Low-Medium
**Mitigation**: Implement against the shipped Chrome 146 spec, not the working draft. Document the spec version AWR implements. Track the WICG/WebMCP repo.

### R4: Bot detection arms race

**Risk**: Cloudflare or DataDome updates detection between Phase 1 completion and Phase 3 testing.
**Likelihood**: Medium
**Mitigation**: The detection surface AWR addresses (TLS fingerprint, H2 SETTINGS, HTTP header order) is stable on 6-12 month cycles. The Canvas/AudioContext layer adds depth. No single detection layer is a single point of failure.

### R5: Single-person implementation velocity

**Risk**: Zig, nghttp2, QuickJS-NG, libvaxis — integrating four C library integrations in Zig is a significant implementation surface. (curl-impersonate deferred to Phase 3 opt-in; Phase 1 uses std.crypto.tls.)
**Likelihood**: High
**Mitigation**: Phase 1 is the riskiest phase (three C library integrations). Phases 2-4 build on a stable foundation. Phase 1 milestone is conservative (4 weeks for networking only). If Phase 1 slips, Phase 4 (WebMCP, the core differentiator) is the priority to protect.

### R6: Lightpanda adds TLS spoofing

**Risk**: Lightpanda is already Zig and already fast. If they add TLS fingerprint spoofing (e.g. via curl-impersonate or BoringSSL), they narrow AWR's Phase 3 moat. AWR's Phase 1 moat is now validated networking stack + JS + DOM; the fingerprint moat is Phase 3.
**Likelihood**: Low (not on their public roadmap)
**Mitigation**: AWR's secondary moat is WebMCP. Even if Lightpanda ships TLS spoofing, they have no agent-native interface. Ship WebMCP demo fast.

---

## Out of Scope

The following are explicitly not in AWR's scope for the 16-week plan:

- **CSS layout engine**: AWR does not compute visual layout. TUI rendering uses text extraction, not box model positioning.
- **WebRTC, WebSockets (v1)**: Real-time protocols are deferred post-MVP.
- **PDF rendering**: Not relevant to the agent use case.
- **Extension support**: No browser extension API.
- **Mobile browser profiles**: Phase 1-3 targets Chrome 132 desktop only.
- **Full WPT compliance**: AWR is not trying to be a standards-compliant browser. It is trying to be a useful agent tool that passes bot detection.
- **GUI mode**: AWR is terminal-only. No Electron wrapper, no window system integration.
- **Authentication flows (OAuth, SSO)**: Basic form login is in scope for Phase 3; OAuth redirect flows are deferred.
- **Proxy support**: Deferred post-MVP.
- **JavaScript source maps / DevTools**: AWR is not a developer browser in the Chromium sense.

---

*AWR is not a replacement for Chrome. It is the first browser primitive built from the ground up for the agentic web.*
