# Research — Agent-Browser Feasibility within AWR's WPT-Gated MVP

> **Phase 1 of Spec-Driven Workflow**: Research → Specify → Plan → Work → Verify → Review
> **Date**: 2026-04-26
> **Author**: Claude Code (Opus 4.7) under `/ai-eng-core:research`
> **Confidence**: High on current-state evidence; Medium on Session 3 effort estimates.

---

## 1. Question

Can AWR be turned into a **CLI-first agent-usable web browser** — link navigation, form filling, search, cookies/cache for logged-in sites — while remaining inside its existing WPT-gated MVP discipline? And what is the smallest correct path to start (the immediate trigger being a render-width bug on an iOS↔SSH↔tmux session)?

## 2. Triggering observation

`AWR.png` shows `awr browse https://example.com` rendered with a clear "line wider than terminal" pattern on a portrait-oriented iOS terminal in tmux:

- Body text "This domain is for use in documentation examples without needing permission. Avoid use in operations." displays with bouncing leading whitespace and mid-word breaks (`permi`/`ssion`).
- The AWR footer `link 1/1: https://iana.org/domains/example | https://example.com/` wraps with the same pattern.
- The footer is supposed to be clipped by `writeClippedLine(stdout, size.cols, footer)` at `src/browser.zig:688`. That it overflows means `size.cols` is larger than the visible terminal width.

The smoking gun is footer overflow: the renderer thinks `cols` is wider than the iOS terminal can actually display.

## 3. Current capability (evidence from code + specs)

### 3.1 What ships today

| Capability | Status | Evidence |
|---|---|---|
| HTTP/1.1 + HTTP/2 + JA4-stable TLS | Shipped | `src/net/`, `src/client.zig`, `spec/MVP.md` §3 |
| HTML parse → DOM → JS bridge → render | Shipped | `src/page.zig:541`, `src/render.zig`, `src/dom/bridge.zig` |
| Cookies (RFC 6265, in-memory) | Shipped | `src/net/cookie.zig` (no `save`/`load`/file refs found) |
| Redirects, ALPN routing, conn pooling | Shipped | `src/net/pool.zig` |
| TUI `awr browse <url>`: scroll, link nav, search, fields | Shipped | `src/browser.zig:545-659` |
| Form submit (GET-only, query string) | Shipped | `src/browser.zig:242-267` |
| WebMCP `tools` / `call` | Shipped | `src/main.zig:191-227`, `src/webmcp.zig` |
| WPT runner (`zig build test-wpt`) | Shipped | `tests/wpt_runner.zig`, `spec/subspecs/wpt-conformance.md` |
| Test262 runner (`zig build test-test262`) | Shipped | `tests/test262_runner.zig` |

### 3.2 What is *intentionally* missing per canonical spec

`spec/MVP.md` §5 narrows the closed MVP surface:

- **§5.4 — `fetch()` and `XMLHttpRequest` are async GET-only.** No POST.
- **§5.5 — `history` limited to same-origin `pushState`/`replaceState` + `length`/`state`.** No back/forward navigation traversal.
- **§5.6 — `IntersectionObserver` / `ResizeObserver` not part of MVP.**
- **§7 — Browser/TUI product-track expansion deferred** to `spec/subspecs/browser-tui.md`.

`spec/subspecs/browser-tui.md` (verbatim):

> **Status: DEFERRED**. Not part of the active work queue.
> Scope for later includes: `browse` / `browser.zig` / `tui.zig` usability and stability; readable terminal navigation, scrolling, link following, and search; renderer polish.

### 3.3 What's not persisted

- `src/net/cookie.zig` has no save/load path — cookie jar dies with the process. "Stay logged in" is impossible without code changes.
- No on-disk cache (HTTP cache layer is not present in the source tree).
- Form values entered in `awr browse` (`BrowserSession.field_values`) are session-local.

## 4. Gap analysis vs. user goal

User goal: **agent-usable browser** = forms + link nav + search + persistent login (cookies/cache).

| Sub-goal | Gap | Spec status |
|---|---|---|
| Link click → navigate | Works (`browser.zig:162-170`) | ✅ in scope |
| Render correctly on small/mobile/SSH terminals | **Bug** (footer overflows, no SIGWINCH) | Already-shipped surface — fix is a regression repair, not new scope |
| Page-internal search | Works (`browser.zig:493-512`) | ✅ in scope |
| GET-form fill + submit | Works (query-string GET) | ✅ in scope per §5.4 |
| **POST-form login** (most real auth flows) | Not implemented; explicitly out per §5.4 | ❌ **Spec amendment required** |
| **Cookie persistence across runs** | In-memory only | ❌ Not in MVP closure list — spec amendment required |
| Search-engine submission | Works for GET-form engines (DuckDuckGo HTML-only mode); fails for any POST-only search | Partial — depends on target site's form method |
| Back/forward across origins | Limited per §5.5 | ❌ Spec amendment required for full traversal |
| HTTP cache (etag, ttl) | Not implemented | ❌ Not in MVP — would be new sub-spec |

### 4.1 Sites the user likely cares about

- **GitHub login**: POST-form, OAuth flow → blocked without POST support.
- **Google search**: technically GET (`?q=…`); JS-heavy results page — partial works today.
- **Hacker News login**: POST-form → blocked.
- **Generic SaaS dashboards behind login**: POST + cookie persistence → blocked on both.

This is the honest scope-of-real-utility answer: **today's `awr browse` is already useful for read-only public pages** (which the WPT-gated MVP correctly targets). Becoming useful for the *agent* use case ("log into my account, then do X") requires the §5.4/§5.5 amendments.

## 5. Render bug — root cause analysis

### 5.1 Findings

1. `tui.Terminal.size()` calls `c.ioctl(stdout, TIOCGWINSZ, ...)` once per keypress (`src/tui.zig:75-81`).
2. `BrowserSession.run()` polls `terminal.size()` in the main loop (`src/browser.zig:556`) but only re-checks after the previous `readKey()` returns. Between keystrokes AWR is blind to size changes.
3. `grep -rn "SIGWINCH\|sigwinch" src/` returns nothing — there is no signal handler.
4. `browserRenderWidth(cols)` returns `max(20, cols-2)` with no upper clamp (`src/browser.zig:730-732`).
5. `writeClippedLine` correctly skips ANSI escapes when counting visible width (`src/browser.zig:697-717`) — that path is not the bug.

### 5.2 Most likely causes (ranked)

1. **TIOCGWINSZ stale through iOS↔SSH↔tmux chain** *(P ≈ 0.7)*
   When iOS connects to a tmux session previously sized on the Mac display, tmux may not propagate SIGWINCH cleanly. The pty inside tmux still reports old/wider geometry. Without an AWR-side SIGWINCH handler, the size only refreshes when a key is pressed. If the user observed the screenshot mid-session without keying, they saw stale geometry.

2. **Initial size queried before iOS terminal settled** *(P ≈ 0.2)*
   `setViewportSize` is called before `navigateTo` in `run()` (line 552). If `ioctl` returns the fallback 80×24 because the iOS connection hadn't finished negotiating, the page is laid out for 80 cols and `setViewportSize`'s early-return on equal dims (line 104) prevents re-layout until cols changes again.

3. **Terminal app font-fit / auto-zoom lying about cols** *(P ≈ 0.1)*
   Some iOS terminals (Termius, Blink) silently change rendered cell width without re-emitting SIGWINCH. AWR can defend by clamping `max_width` to a sane ceiling.

### 5.3 Confidence

High (P ≥ 0.9) that **adding SIGWINCH + per-draw size requery + a max_width clamp in `browser.zig` resolves the rendering bug** without spec amendment, because:

- The fix lives entirely in `src/browser.zig` (and a tiny addition in `src/tui.zig` for the signal handler).
- It does not add new browser-runtime surface — it repairs an already-shipped surface (`browse` subcommand).
- `spec/subspecs/browser-tui.md` already lists "stability" as in-scope-when-activated; this is a regression fix that arguably falls under the existing shipped surface's reliability obligation.

## 6. Spec-governance impact

`spec/MVP.md` §8:

> No document becomes canonical by implication.
> Any scope, authority, or closure-boundary change must (1) edit `spec/MVP.md` first; (2) update affected sub-specs in the same change; (3) update `docs/adr/0001-spec-governance.md` if document authority changed; (4) update README and agent-facing guidance.

| Proposed change | Triggers governance? |
|---|---|
| Render-width / SIGWINCH fix in `browser.zig` | **No** — bug-fix on already-shipped surface |
| `max_width` clamp policy (`<= 200` cols) | **No** — defensive coding, no API surface change |
| POST request support in `fetch`/`XHR`/forms | **Yes** — widens §5.4 |
| Cookie-jar disk persistence | **Yes** — new sub-spec or addendum to MVP §5 |
| Form `method="post"` honoring | **Yes** — depends on POST being in scope |
| WPT corpus widening to `html/forms/`, `html/browsers/history/` | **Yes** — `wpt-conformance.md` §3 lists scope |
| Promote `browser-tui.md` from deferred to active | **Yes** — explicit MVP §7 status change |

## 7. WPT-first execution path

Per `spec/subspecs/wpt-conformance.md` §3 inclusion rules:

> Include a WPT case only when it: (1) validates real shipped behavior on the CLI/browser path; (2) would fail without the implementation being added or fixed; (3) is deterministic in the repo's supported test environment; (4) does not require upstream browser subsystems that AWR does not claim to ship for MVP.

Implication: each agent-browser feature must be paired with a curated WPT case. Suggested pairings for Session 3+:

| Feature | Curated WPT directory |
|---|---|
| POST `fetch` | `fetch/api/request/request-init-002` (subset) |
| Form `method="post"` submission | `html/semantics/forms/form-submission-0/` (subset) |
| Cookie write-then-read across navigation | `cookies/` (subset, document-cookie cases) |
| `<a target>` / link navigation history | `html/browsers/history/the-history-interface/` (same-origin subset) |

This widens corpora declared by `spec/subspecs/wpt-conformance.md` §3, so that file must be edited as part of Session 2.

## 8. Recommendation

### Three-session ladder, smallest correct steps

#### Session 1 — Render-width / SIGWINCH fix *(this thread, after review)*
- **Files**: `src/browser.zig` (~25 LOC), `src/tui.zig` (~15 LOC for SIGWINCH installer).
- **Spec**: none — bug-fix on shipped surface.
- **Tests**: add a `BrowserSession` test that simulates a size change (via direct `setViewportSize` calls of different dims) and asserts the `ScreenModel` re-wraps. Real SIGWINCH is hard to test in unit-land; the policy of "re-query on every draw" makes the signal handler an optimization, not a correctness requirement.
- **User-shaped decision** (learning-mode contribution): the size-policy in `browserRenderWidth()` — hard ceiling value, behavior when cols drops below 20, whether to debounce repeated requeries.

#### Session 2 — Spec amendment *(docs-only)*
Two paths:
- **2a — Promote `browser-tui.md`** with a *narrowed* active scope (forms, cookie persistence, navigation), not full TUI polish. Pro: simpler doc surgery. Con: muddies the "TUI deferred" boundary.
- **2b — New sub-spec `agent-browser.md`** that only enumerates POST + cookie persistence + form-method honoring + curated WPT additions. Pro: clean boundary, keeps TUI deferred. Con: another doc.

Either way, edit `spec/MVP.md` §5–§7, edit `wpt-conformance.md` §3, add an ADR entry, update `AGENTS.md` and `CLAUDE.md` if the agent-facing scope changes.

#### Session 3+ — Implementation under WPT discipline
Land in this order, each with curated WPT cases:
1. POST in `src/net/http1.zig` + `src/net/http2.zig` (request body wiring).
2. POST in `fetch()` / `XMLHttpRequest` JS bridge (`src/dom/bridge.zig`).
3. Form `method="post"` submit in `src/browser.zig:submitForm` (currently GET-only).
4. Cookie-jar disk persistence (Netscape format at `~/.local/state/awr/cookies.txt`, opt-in via flag or env var).
5. Same-origin navigation history beyond current `pushState`/`replaceState` if needed by curated cases.

Each step is a separate session per CLAUDE.md "One Deliverable Per Session" rule.

## 9. Feasibility verdict

| Question | Verdict |
|---|---|
| Fix the render bug shown in `AWR.png` | **Feasible immediately.** ~30 LOC in one file, no spec change. |
| Make AWR an agent-usable browser | **Feasible with discipline.** Requires `spec/MVP.md` amendment first (Session 2). Implementation cleanly decomposes into 4–5 surgical sessions, each landing with WPT cases. |
| Stay WPT-gated throughout | **Yes.** `wpt-conformance.md` §3 already provides the inclusion rules; corpus needs widening, not the runner. |
| Avoid breaking the JA4 fingerprint | **Yes.** None of the proposed changes touch `src/net/tls_conn.zig`, `src/net/fingerprint.zig`, or header ordering — POST adds a body, but request-line and header-list semantics stay intact. Verify with `zig build test-tls` after Session 3. |

## 10. Risks and unknowns

- **Tmux/iOS interaction**: I have not actually reproduced the bug. The hypothesis is strong (footer overflow proves stale `cols`), but environment-specific causes (iOS app font auto-zoom, tmux `aggressive-resize` setting) may need adjustment in the user's environment, not AWR.
- **POST + JA4**: BoringSSL handshake is independent of HTTP method. The risk is in HTTP/2 SETTINGS frame ordering (fingerprint constants in `src/net/fingerprint.zig`) — POST alone shouldn't perturb it, but `test-tls` and `test-h2` must remain green.
- **Cookie persistence + privacy**: persisted cookies from one run leak into the next. Should be opt-in with explicit flag (`--persist-cookies` or `AWR_COOKIE_JAR=/path`).
- **Effort estimate accuracy**: Session 3 sub-tasks are sized at "one session each" but POST in HTTP/1+2 + WPT pairing could spill to two sessions if request-body framing has rough edges in the existing transport.

## 11. References (in-repo)

- `spec/MVP.md` — canonical umbrella spec
- `spec/subspecs/mvp-remainder.md` — closure record
- `spec/subspecs/wpt-conformance.md` — corpus authority
- `spec/subspecs/browser-tui.md` — deferred TUI track (status: DEFERRED)
- `src/browser.zig:75-76, 101-109, 242-267, 545-659, 688, 697-717, 730-732` — TUI session, form submit, render-width policy
- `src/tui.zig:31-141` — terminal raw mode + size query
- `src/render.zig:31-37, 1116, 1334` — render options, wrap logic
- `src/net/cookie.zig` — in-memory RFC 6265 jar
- `src/main.zig:182-189` — `awr browse` entry point

---

**Confidence rating**: High on current-state evidence and Session 1/2 plan; Medium on Session 3 effort decomposition (POST+H2 framing + curated WPT pairing has real complexity).

**Next step**: User reviews this document, confirms Session-2 amendment path (2a vs 2b), and authorizes Session 1 implementation. No code changes have been made.
