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

### [x] T4 — SVG graceful degradation
**Why:** stb_image is raster-only; SVG sources (HN's `y18.svg`) become a 1×1
placeholder blob. Should degrade to alt-text / skip, not a degenerate image.
**Files:** `src/image/pipeline.zig` / `decode.zig` (detect SVG/unsupported and
skip → alt-text path instead of emitting a 1×1 image).
**Done-criteria / verify:** a test that an SVG (or undecodable) `<img>` yields
the alt-text/footnote fallback, not a 1×1 image emit; `test-image` green.

**Verified (2026-06-08):**
- `src/image/decode.zig`: added an explicit `looksLikeSvg` sniff (skips UTF-8
  BOM + leading whitespace, matches `<svg`/`<?xml` case-insensitively) that
  returns `UnsupportedFormat` before stb_image runs. Previously SVG was
  rejected only by accident (markup's 2nd byte fails stb_image's TGA
  colormap-type validation); the sniff makes the rejection intentional and
  robust to stb_image changes. The sniff is precise — it does not false-match a
  valid TGA whose id-length first byte is `0x3c` (`<`).
- Chain to alt-text is intact: `pipeline.build()` already drops images whose
  decode fails (`pl.failed += 1`, never stored), so the renderer's lookup
  misses and emits the `[alt][N]` footnote (existing test "render —
  image_lookup miss falls back to alt-ref").
- New tests in `decode.zig`: SVG (bare `<svg>`, `<?xml>`-prefixed, leading
  whitespace, UTF-8 BOM) → `UnsupportedFormat`; `looksLikeSvg` precision (no
  TGA `0x3c` false-match). `zig build test-image` green (image_decode 7/7).

### [x] T5 — Image vertical row-height accounting
**Why:** a kitty/iterm image occupies `r` cell rows but the render model counts
it as one logical line, so rows after an image space oddly (the item-8 gap).
**Files:** `src/render.zig` (image line modeling), `src/browser.zig` (draw line
accounting), `src/image/`.
**Approach:** reserve the image's `r` rows in the render model's line count so
following content lays out below the image, not over it.
**Done-criteria / verify:** a test asserting an image line reserves its rows;
`test-image`/`test-tui` green; manual PTY check that content after an image
doesn't overlap.

**Verified (2026-06-10):**
- `src/image/pipeline.zig`: cache stores `Entry{ bytes, rows }` and exposes the
  row count through a new optional `ImageLookup.rowsFn` (default `null`, so all
  existing lookup sites keep their behavior).
- `src/render.zig`: `reserveImageRows` emits `rows - 1` blank model lines after
  a single-blob (kitty/iterm/sixel) image in the **browse profile only**, so
  `ScreenModel.lines` accounts for every terminal row the image paints and the
  TUI lays following content below it. Skipped for the streaming default
  profile (terminal cursor advances as it paints) and braille (bytes already
  carry one model line per row).
- Tests: "image line reserves its cell rows in the model" (rows=4 → exactly 3
  extra newlines vs a rows-less baseline) and "default profile and braille do
  not reserve image rows". `zig build test` zero failures; `test-image` +
  `test-tui` + `test-tls` + `test-h2` green.

### [x] T6 — Renderer whitespace polish
**Why:** extracted text (e.g. GitHub) carries excess structural whitespace
(renderer-heuristic), per the target-site audit. Intra-line collapsing already
exists (`collapseWhitespace`, render.zig ~3382); the gap is **vertical** —
stacked block-spacing newlines produce runs of blank lines.
**Files:** `src/render.zig` (block-spacing / newline emission in the flow path).

**Bar (locked 2026-06-10):** at most **1 blank line** between blocks (the
lynx/w3m convention), applied in the **shared flow path** so both profiles —
streaming `awr render`/extract (agent surface) and the browse model (TUI) —
benefit.

**Success criteria (all pass/fail):**
- [x] A whitespace-heavy DOM (nested divs/sections stacking block spacing)
      renders with no run of 3+ consecutive `\n` in flow output, in BOTH the
      default profile and `renderBrowseModel`, pinned by a co-located test
      that fails before and passes after.
- [x] Exemptions hold, pinned by tests: `<pre>`/`<code>` blocks keep their
      verbatim internal newlines; T5 reserved image rows are NOT collapsed
      (the rows=4 → +3 lines test keeps passing unchanged).
- [x] `zig build test` zero failures; corpus fixtures that improve are
      re-blessed with a one-line justification each (`wikipedia_octopus`
      included — owner explicitly approved the gold-fixture re-bless,
      2026-06-10); none reddened without one.
- [x] `test-tls` + `test-h2` green (no `src/net/` contact).

**Verification evidence required:** test names + real exit codes; list of
re-blessed fixtures with justifications in the commit message; Verified note
in this file (T3–T5 format).

**Scope:**
- **In:** newline/block-spacing emission in `src/render.zig`'s flow path.
- **Out:** intra-line whitespace (already done), `browse_heuristics` content
  picking, `<pre>` rendering semantics, anything in `src/net/`.

**Blocked stop condition:** if capping blank lines structurally requires
buffering/lookahead that degrades the streaming default profile (it must stay
single-pass), STOP and surface the trade-off rather than converting the
streaming path to a buffered one unilaterally.

**Verified (2026-06-11):**
- `src/render.zig`: blank-line cap in the shared flow path. `BufferWriter`
  tracks the trailing `\n` run (constant-space counter — the streaming default
  profile stays single-pass, no buffering/lookahead); `RenderState.newline` /
  `writeByte` suppress a third consecutive `\n` when outside `<pre>`
  (`pre_depth == 0`) and not reserving image rows (`bypass_blank_cap`, set
  only inside `reserveImageRows` so T5's deliberate footprint survives).
- Tests: "T6 — stacked block spacing collapses to at most one blank line
  (both profiles)" — fail-before verified (cap disabled → page suite 453
  pass / 1 fail, only this test); "T6 — `<pre>` blank-line runs are verbatim,
  exempt from the cap" (3 blank lines inside `<pre>` survive byte-for-byte in
  both profiles while surrounding flow runs collapse); T5's rows=4 → +3 lines
  test passes unchanged.
- Gates (real exit codes): `zig build test` = 0 (zero failures, both new T6
  tests green); `test-tls` = 0; `test-h2` = 0; `test-corpus` = 0.
- Corpus re-bless — 7 fixtures, every diff pure blank-line deletions
  (non-blank content verified byte-identical before each bless):
  github_zig (−4), malformed_edge (−7), nvidia_models (−3),
  propublica_irs (−6), wiki_ar_octopus (−2), wiki_zh_octopus (−2),
  wikipedia_octopus (−1 — a single 3-`\n` run between two
  `[Header omitted]` placeholders; the gold-fixture "never re-bless" rule
  was explicitly overridden by owner decision on 2026-06-10 for this
  verified 1-byte whitespace-only collapse).

### [ ] T7 — JS-driven UI render (bucket B → Google-class pages render)
**Why:** some pages (Google homepage, light SPAs) return a near-empty shell and
build/strip their UI via JS that branches on a Chromium environment, so even
after Brotli decode (T3) the rendered page has no usable content. This is the
"renders, not just decodes" gap for the JS-dependent bucket.
**Files:** `src/page.zig` (post-load JS settle / DOM re-render), `src/js/*`,
`src/dom/bridge.zig`, possibly `src/browse_heuristics.zig` (pick content after
JS mutates the DOM). **Not** `src/net/` fingerprint emission.
**Approach (scope locked 2026-06-10 — this is the largest task):** make AWR
present a browser-enough environment that JS-driven pages populate a usable
DOM, in two diagnosed slices:
1. **Google homepage (UI-strip branch).** Diagnose the exact JS branch that
   strips/withholds the UI in a non-Chromium env and address the *smallest*
   cause (env/API surface the branch probes — never the network fingerprint).
2. **Light SPA (JS-injected content).** Ensure the post-load drain settles
   JS that injects content (timers/promises/microtasks that build the DOM),
   then re-pick the content root after mutation
   (`browse_heuristics`) so injected content — not the empty pre-JS shell —
   is what renders.

**Success criteria (all pass/fail):**
- [ ] Hermetic Google-class fixture: a fixture reproducing the diagnosed
      UI-strip branch renders usable shell (search affordance + links), pinned
      by a co-located/e2e test that fails before and passes after.
- [ ] Hermetic light-SPA fixture: a fixture whose body is empty until JS
      injects content renders the injected content (headings/links), pinned by
      a test; content re-pick after mutation is exercised by that test.
- [ ] Live evidence (manual, not a CI gate): `awr extract https://www.google.com/`
      shows usable shell text; one live light SPA (e.g. `meta.discourse.org`)
      shows readable content or is explicitly re-bucketed with evidence.
- [ ] `zig build test` zero failures; no new corpus fixture reddened without a
      justified one-line re-bless (never `wikipedia_octopus`).
- [ ] `test-tls` + `test-h2` green — fingerprint byte-identical.

**Verification evidence required:** test names + real exit codes for every gate;
the live-check transcript (or the re-bucket rationale) recorded in this file's
Verified note, same format as T3–T5.

**Scope:**
- **In:** `src/page.zig` (post-load JS settle / re-render), `src/js/*`,
  `src/dom/bridge.zig`, `src/browse_heuristics.zig` (re-pick after mutation).
- **Out:** `src/net/` emission (fingerprint), Tier 4 layout, Tier 5 SPA
  runtime, anti-bot evasion (bucket C), any governed-spec change.

**Blocked stop condition:** if usable render for a target genuinely requires
layout (Tier 4), full SPA runtime (Tier 5), or anti-bot evasion (bucket C),
STOP and record: attempted paths, the exact branch/capability that blocks, the
bucket it belongs to, and what decision would unblock — rather than expanding
scope or touching governed specs. A re-bucketed target with evidence counts as
a valid T7 outcome for that target; an unverified "probably works" does not.

### [ ] T8 — Goal closure audit (definition-of-done, made executable)
**Why:** the Definition of done at the top of this file is a completion
contract; closing the goal requires mapping every clause to fresh evidence,
not assuming it from memory of earlier tasks.
**Done-criteria / verify (run all on `main`, record real exit codes):**
- [ ] Every task T1–T7 is `[x]` with a Verified note in this file.
- [ ] `zig build` green; both `awr` and `awrd` build.
- [ ] `zig build test` zero failures.
- [ ] `zig build test-tls` and `test-h2` green (fingerprint intact).
- [ ] Each task's targeted gate re-run green (`test-image`, `test-tui`,
      `test-client`, plus T6/T7 gates).
- [ ] Local `main` pushed; no unmerged feature branches (drift check:
      `git branch --no-merged main` is empty).
- [ ] A closing Verified note in this file maps each Definition-of-done clause
      to its evidence. Phrases like "good enough" or "probably fine" are not
      evidence; if any clause is unverified, the goal stays open.

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
