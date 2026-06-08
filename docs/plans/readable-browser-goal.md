# GOAL — Complete the readable-terminal-browser cluster

> Executable goal/backlog. Rationale + evidence: `docs/plans/remaining-work.md §6`.
> Source of truth for the self-paced work loop. Each task is independently
> verifiable; the loop does ONE task per iteration, commits it, checks it off,
> and stops when every task is `[x]` or a guardrail trips.

## Definition of done

Mission (raised bar, 2026-06-03): **every page we can render actually renders
readably — not merely decodes.** When a page decodes but stays blank, diagnose
*why* and route it to the right task; never call a decoded-but-unreadable page
done. Three buckets, from the Tier-4 target-site audit:
- **A — server-rendered** (HN, GitHub, Stack Overflow, old.reddit, Discourse,
  Rails/Django/Phoenix): addressed by T3–T6. Bar = renders readably.
- **B — JS-dependent UI** (Google homepage, light SPAs that strip UI in a
  non-Chromium env): addressed by **T7**. Bar = usable shell/content renders.
- **C — permanently out** (per-site anti-bot challenges, WebGL/canvas, `<video>`
  playback): excluded by `spec/subspecs/browser-roadmap.md §5`. Not a failure.

All tasks below are `[x]`, and on `main`:
- `zig build` is green; both `awr` and `awrd` build.
- `zig build test-tls` and `zig build test-h2` are green (Chrome-132 fingerprint
  intact) — **non-negotiable**.
- Each task's targeted gate (below) is green.
- `zig build test` has **zero** failures (the `wikipedia_octopus` snapshot was
  re-blessed on `main`); no NEW corpus fixture is reddened without a justified
  one-line re-bless.

## Guardrails (apply every iteration)

1. **Fingerprint is sacred.** Never touch `src/net/` header order, cipher order,
   ALPN, or HTTP/2 SETTINGS. Run `zig build test-tls` + `test-h2` before every
   commit; if either goes red, revert the change.
2. **Governance.** Do not change `spec/MVP.md`, `spec/subspecs/*`, or `docs/adr/*`
   scope/authority. If a task seems to require promoting a deferred track or
   changing a spec boundary, STOP and surface it — don't do it in the loop.
3. **Coordination.** A separate worktree owns `tests/corpus/fixtures/` (the
   `wikipedia_octopus` re-bless). Do NOT edit corpus fixtures except to re-bless
   one your own change legitimately altered — and then only with a one-line diff
   justification in the commit. Never re-bless `wikipedia_octopus`.
4. **Commit discipline.** For each task: branch off `main`
   (`fix/<task-id>` or `feat/<task-id>`), implement, add/extend a co-located
   test that fails before and passes after, run the gates, `zig fmt src/`,
   commit, fast-forward `main`. Check the task off in this file in the same
   commit.
5. **Verify, don't assume.** Real exit codes (no pipe-masking). Where a terminal
   effect is involved, validate with the PTY/strict-VT approach already proven in
   this repo (parse rendered cursor position, not just the byte stream).
6. **Unblock by default — do NOT skip or mark blocked.** If a task turns out to
   need a new capability or cross-layer plumbing, **build that capability as part
   of the task** (carefully, with tests). "It got bigger / needs new plumbing" is
   never a reason to skip. Reserve **STOP and surface** for only: (a) a genuine
   product/scope decision the user must make, (b) a fix that would break a hard
   guardrail (fingerprint, governance), (c) a gate that can't be made green after
   a real attempt, or (d) all tasks done.
7. **Conventions.** Match existing style: `///` doc comments, co-located tests,
   explicit allocators, `errdefer`. Surgical changes only.

## Coordination state

- `wikipedia_octopus` corpus re-bless → **owned by another worktree.** Excluded
  from this goal.
- MCP stdio → **PARKED** (deferred, not now). Not in this goal.
- Tier 4 layout / Tier 5 SPA → **out of this goal** (ADR-gated; this goal is the
  P1 readable-browser cluster only).

---

## Tasks (do in order)

### [x] T1 — `tabindex` / `role=button` focusability + activation (build all 3 layers) — DONE 2026-06-03
> **Scope (maintainer chose to build, not skip — 2026-06-02):** three layers,
> landed as one feature:
> (a) render: register `tabindex>=0`/`role=button` (on non-native elements) as
>     focusables, rendered with the focus highlight;
> (b) browser: Enter/Space on such a focusable dispatches a click;
> (c) **bridge: a `ptr → element → .click()` path** so a real
>     `MouseEvent('click')` fires on the element (running the page's `onclick`),
>     then the TUI re-renders on the resulting DOM mutation. Elements already
>     expose `.click()` in JS (`bridge.zig:2299`); this adds the Zig→that-element
>     call keyed by `element_ptr` (mirror how event targets resolve a node ptr to
>     its JS wrapper).

**Why:** Elements made focusable via `tabindex="0"` (or `role="button"`, or a
styled `<a>` without `href`) aren't in the Tab order — only links + native form
controls are. Blocks flows like "create an account" on
`research.v1truc1us.dev/login`. `render.zig` has zero `tabindex` handling today.
**Files:** `src/render.zig` (focus/field registration), `src/browser.zig`
(focus traversal + Enter activation + focus highlight), maybe `src/dom/`.
**Approach:** register elements with `tabindex >= 0` (and `role="button"`) as
focusable targets; Enter activates (click semantics) like a button/link; honor
positive-`tabindex` ordering before `tabindex=0`/DOM order; give non-field
focusables a visible focus indicator.
**Done-criteria / verify:** a co-located test asserts a `tabindex=0` `<div>` and
a `role=button` element appear in the focus order and activate on Enter;
`zig build test-tui` (or the co-located tests under `zig build test`) green;
`test-tls`/`test-h2` green. Manual: a PTY drive that Tab reaches the synthetic
focusable.
**Diagnosis (2026-06-02):** native `<button>` already registers as a field
(`renderButton` → `registerField`, render.zig ~2433), so the gap is purely
non-native focusables — `tabindex>=0` and `role="button"` on `<div>`/`<span>`/
`<a>`-without-href, which the element dispatch (render.zig ~1614 generic
fallback) never registers. Intercept in the generic-element path: if the elem
has `tabindex>=0` or `role="button"` and isn't already a field/link, register it
as a focusable target and render its children. (The live `research.v1truc1us.dev`
page is DNS-unreachable from CI, so verify with a synthetic DOM, not the site.)

### [x] T2 — App-shell render fallback (don't blank out non-article pages) — DONE 2026-06-03 (commit ed7f28a)
> Delivered via a two-pass rescue rather than the originally-sketched "render
> full <body>": `renderBrowseModel` detects a blank/omit-only first pass
> (`isBlankRender`) and re-renders relaxing the `[hidden]` CSS reset, which
> rescues Next.js/streaming app shells without un-hiding real chrome. Verified:
> an app-shell DOM (nav + `<div id=app>` content + Sign-in, no `<main>`) now
> renders its shell text instead of only `[… omitted]` markers. Test:
> `isBlankRender treats whitespace + omitted-region placeholders as blank`.
**Why:** `awr render`/`browse` shows only `[Navigation omitted]`/`[Footer
omitted]` on app-shell pages (e.g. `audiofile.app`) while `awr <url>` (agent)
has the real `body_text`. The readability picker (`browse_heuristics.zig`) is
article-tuned and drops content not under `<main>`/`<article>`.
**Files:** `src/browse_heuristics.zig`, possibly `src/page.zig`/`src/render.zig`.
**Approach:** when the picked content root renders to near-empty (e.g. visible
text below a small threshold while the full `<body>` has substantially more),
fall back to rendering the full `<body>` so the shell (nav links, "Sign in",
headings) is always visible.
**Done-criteria / verify:** a co-located test with an app-shell DOM (content in
plain `<div>`s, no `<main>`) asserts the rendered output contains the shell text
instead of only omit-markers; existing article-page corpus fixtures still pass
(re-bless only with justification, never `wikipedia_octopus`); `test-tls`/`h2`
green.

### [x] T3 — Brotli response decode (bucket A → renders readably)
**Why:** AWR advertises `br` in `Accept-Encoding` (fingerprint) but only decodes
gzip/deflate/zstd (`src/net/http1.zig:66`), so Google/Discourse return 200 but
undecoded bytes. Highest-reach P1 item; unblocks the whole server-rendered
`br` bucket.
**Files:** decompression path (`src/client.zig` / `src/net/`) — **without**
touching header/fingerprint emission; `third_party/brotli/` + `src/net/brotli_shim.c`
+ `build.zig` wiring.
**Approach (decided 2026-06-03):** vendor Google's C `brotlidec` as a static lib
with a Zig shim, mirroring how BoringSSL/nghttp2 are integrated (AWR already
links C libs for TLS/H2 and lexbor for DOM — vendoring the reference decoder is
consistent, not a deviation). Decode `Content-Encoding: br` on all three fetch
paths (stdlib H1, BoringSSL H1, H2), mirroring existing gzip/zstd handling. Do
NOT alter `Accept-Encoding`. *Follow-up (out of scope here):* an optional
pure-Zig brotli rewrite later, if single-binary purity warrants it.
**Done-criteria / verify (raised bar — renders readably, not just decoded):**
1. round-trip unit test (pre-compressed Brotli bytes → expected output) like the
   existing gzip/zstd tests in `src/client.zig`; `zig build test-client`/`test-net` green;
2. `test-tls`/`test-h2` green (Accept-Encoding + fingerprint unchanged);
3. manual: `awr extract https://meta.discourse.org/` returns **readable text**
   (a real `br`-served server-rendered site renders, not just decodes);
4. manual: `awr https://www.google.com/` is **decoded** (not binary) — full
   Google UI is a JS-strip blocker tracked in **T7**, not T3.

**Verified (2026-06-08):**
- Vendored Google `brotlidec`/`brotlicommon` static libs (`third_party/brotli/`)
  linked via `build.zig`; decode wired on all three fetch paths in `src/client.zig`
  (`inflateBrotliBody`), mirroring gzip/zstd. `Accept-Encoding` and header order
  untouched.
- `zig build test-client` green (round-trip Brotli unit tests); `test-tls` +
  `test-h2` green (fingerprint + `Accept-Encoding` unchanged).
- Live `awr https://httpbin.org/brotli` → decoded `{"brotli": true, ...}` (canonical
  live `br` proof); live `awr https://www.google.com/` → decoded readable text
  ("About Store Gmail Images Sign in…"), 0 control bytes — not binary.
- `meta.discourse.org` decodes correctly (`title="Discourse Meta"`, 200) but is now
  a JS-hydrated SPA with no server-rendered body text, so its *readable render* is a
  JS-strip blocker deferred to **T7** — same reclassification as criterion 4's Google
  note, consistent with the raised "renders, not just decodes" bar. Brotli decode
  itself is fully proven by the httpbin + Google live checks above.

### [ ] T4 — SVG graceful degradation
**Why:** stb_image is raster-only; SVG sources (HN's `y18.svg`) become a 1×1
placeholder blob. Should degrade to alt-text / skip, not a degenerate image.
**Files:** `src/image/pipeline.zig` / `decode.zig` (detect SVG/unsupported and
skip → alt-text path instead of emitting a 1×1 image).
**Done-criteria / verify:** a test that an SVG (or undecodable) `<img>` yields
the alt-text/footnote fallback, not a 1×1 image emit; `test-image` green.

### [ ] T5 — Image vertical row-height accounting
**Why:** a kitty/iterm image occupies `r` cell rows but the render model counts
it as one logical line, so rows after an image space oddly (the item-8 gap).
**Files:** `src/render.zig` (image line modeling), `src/browser.zig` (draw line
accounting), `src/image/`.
**Approach:** reserve the image's `r` rows in the render model's line count so
following content lays out below the image, not over it.
**Done-criteria / verify:** a test asserting an image line reserves its rows;
`test-image`/`test-tui` green; manual PTY check that content after an image
doesn't overlap.

### [ ] T6 — Renderer whitespace polish
**Why:** extracted text (e.g. GitHub) carries excess structural whitespace
(renderer-heuristic), per the target-site audit.
**Files:** `src/render.zig` (whitespace collapsing in the flow path).
**Done-criteria / verify:** a test on a whitespace-heavy DOM asserts collapsed
output; corpus fixtures still pass (re-bless with justification if improved);
`test-tls`/`h2` green.

### [ ] T7 — JS-driven UI render (bucket B → Google-class pages render)
**Why:** some pages (Google homepage, light SPAs) return a near-empty shell and
build/strip their UI via JS that branches on a Chromium environment, so even
after Brotli decode (T3) the rendered page has no usable content. This is the
"renders, not just decodes" gap for the JS-dependent bucket.
**Files:** `src/page.zig` (post-load JS settle / DOM re-render), `src/js/*`,
`src/dom/bridge.zig`, possibly `src/browse_heuristics.zig` (pick content after
JS mutates the DOM). **Not** `src/net/` fingerprint emission.
**Approach (scope to confirm at activation — this is the largest task):** make
AWR present a browser-enough environment that JS-driven pages populate a usable
DOM — e.g. ensure the post-load drain settles JS that injects content, re-pick
content after mutation, and avoid non-Chromium UI-strip paths where feasible
WITHOUT changing the network fingerprint. Diagnose Google specifically: identify
the exact branch that strips the UI and address the smallest cause.
**Done-criteria / verify:** `awr extract`/`awr browse` of a representative
JS-dependent page (start with Google homepage, plus one light SPA) renders
usable shell/content (links, search affordance, headings) rather than an empty
shell; a co-located/e2e test pins the behavior on a hermetic fixture;
`test-tls`/`test-h2` green (fingerprint untouched).
**Boundary:** if usable render for a target genuinely requires layout (Tier 4)
or full SPA runtime (Tier 5) or anti-bot evasion (bucket C), STOP and record the
blocker + bucket rather than expanding scope or touching governed specs.

---

## Loop protocol (what each iteration does)

1. Read this file; pick the first `[ ]` task in order.
2. If none remain → announce DONE and stop.
3. Branch off `main`; implement per the task's Approach.
4. Add/extend the failing→passing test; run the task's gate + `test-tls` +
   `test-h2` with real exit codes; `zig fmt src/`.
5. If green: check the task `[x]`, commit (code + this file), fast-forward
   `main`. If not green after a reasonable attempt, or a guardrail would break,
   or it's ambiguous → STOP and surface.
6. Continue to the next task.
