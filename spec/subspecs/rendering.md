# Rendering — active sub-spec

> **Status:** ACTIVE
> `spec/MVP.md` is the canonical umbrella spec. This file is the
> authority for two coordinated tracks:
>
> - **Track A — Image rendering** *(deferred-within-active, not started)*:
>   terminal graphics protocols (Kitty, iTerm2, Sixel) and text/braille
>   fallback for `<img>`, `<picture>`, `srcset`, and CSS
>   `background-image`. Code has not landed; this track activates next.
> - **Track B — Real-page render-quality corpus** *(complete pending
>   Track A's gate 3)*: a fixture corpus of real production HTML plus
>   a snapshot-based test harness that proves `renderBrowseModel`
>   output stays useful as the renderer evolves. As of 2026-04-29, the
>   corpus has 12 fixtures across 11 distinct render categories
>   (§4.1); only the search-results category remains deferred (DDG
>   blocks curl). All Track-B-specific §6 closure gates are green.
>
> The tracks share closure gates because the corpus fixtures are also the
> integration tests that prove image rendering works on real pages. They
> ship together, in the order documented in §7.

---

## 1. Purpose and authority

Today AWR's render pipeline is gated by:

- **65 curated WPT cases** (`spec/subspecs/wpt-conformance.md`) — synthetic
  HTML fixtures that prove DOM/event/form/storage APIs behave per spec;
- **29 Test262 cases** — embedded JS runtime correctness;
- **Inline Zig unit tests** — `chooseContentRoot`, `shouldSkipForBrowse`,
  individual renderer helpers.

Those layers cover *correctness*. They do not cover **render quality on
real production HTML** (line-wrap on long URLs, escape-sequence safety
around emoji + ANSI, heuristics behavior on actual marketing copy,
malformed DOM trees, non-Latin scripts) and they do not cover
**terminal-graphics output for images** at all (today images render as
`[alt-text][N]` text references via `src/render.zig:renderImage`).

This sub-spec governs both gaps. When promoted to ACTIVE, update
`spec/MVP.md §5` and §7 in the same change set per `spec/MVP.md §8`.

---

## 2. Render-quality definition

A "good" `awr render <url>` or `awr browse <url>` output meets all of:

- **Substance present**: visible text reaches the user without being
  pruned by heuristics — i.e. no "blank screen" regression on a page
  that has SSR content.
- **No escape-sequence garbage in non-TTY output**: `awr render | tee`
  contains no `\x1b[…m` bytes; `[alt][N]` image refs survive.
- **Correct cell-width math**: CJK / emoji / wide chars do not corrupt
  line-wrap or push the footer off-screen.
- **Stable footnote numbering**: link `[N]` references resolve to the
  N-th entry of the link footer, in document order.
- **No crash on malformed input**: missing close tags, double `<title>`,
  arbitrary depth nesting all parse and render without error.
- **Image rendering** (Track A): when the terminal supports a graphics
  protocol, `<img>` displays the actual decoded image; otherwise the
  `[alt][N]` text fallback applies.

Closure gates in §6 enforce these via fixtures + per-fixture assertions.

---

## 3. Track A — Image rendering

### 3.1 In scope

- **Protocol auto-detect with explicit override.** CLI flag
  `--images=auto|kitty|iterm|sixel|braille|none`; default `auto`. `none`
  matches today's `[alt][N]` text behavior.
  - Detection signals: `$KITTY_WINDOW_ID`, `$TERM_PROGRAM`, `$LC_TERMINAL`,
    `$TERM`, plus a one-shot CSI query (`\x1b[c`) for Sixel-capable
    terminals (50 ms timeout).
  - On non-TTY stdout (`awr render | tee`), force text fallback regardless
    of `--images=…` so piped output stays grep-friendly.
- **Decoder pipeline** for `image/png`, `image/jpeg`, `image/gif` (first
  frame only), and `image/webp` (still frames only) via stb_image
  embedded as `third_party/stb/stb_image.h`. WebP gated by Homebrew
  `libwebp` and a `enable_webp` build option, default true on macOS.
- **Sizing**: honor `<img width=…>` / `<img height=…>` when present;
  otherwise size to `min(image_natural_w, viewport_cells_w * cell_px_w
  * 0.6)` so a single image cannot push text out of view. Maintain
  aspect ratio.
- **Layout integration**: `renderImage` reserves N cell-rows in the
  text model; `src/browser.zig:draw` emits the protocol bytes at draw
  time. The model layer stays text-only — keeps Track B snapshots
  deterministic.
- **`<picture>` / `srcset`**: pick smallest `w`-descriptor source `≥`
  render-target width; fall back to `<img src>`. Media queries
  (`min-width` / `max-width`) evaluate against terminal-cell-derived
  viewport width only; other features (`orientation`,
  `prefers-color-scheme`, `hover`) evaluate to false.
- **CSS `background-image`** for `<header>` / `<section>` / `<figure>`
  that the browse-render pipeline already treats as content-bearing.
  Decorative backgrounds inside collapsed regions are skipped.
- **Memory + caching**: in-process LRU keyed by absolute URL, capped at
  32 MB resident decoded bytes; per-image hard cap 4 MB encoded /
  16 megapixels decoded. Beyond cap → text fallback + status message.
- **Per-page fetch budget**: 32 images max; surplus images render as
  text alt-refs.

### 3.2 Out of scope

- SVG rendering (text-fallback only for `image/svg+xml`).
- Animated GIF / WebP playback (first frame only).
- `<video>` / `<audio>` streaming. Poster frames fall through `<img>`.
- Canvas / WebGL / WebGPU (per `spec/MVP.md §5`).
- CSS gradients, masks, filters, blend modes; only single `url(…)`
  background values resolve.
- Image maps (`<map>`), `<input type="image">` click coordinates.
- DPR / Retina / 2× source preference.
- Persistent disk image cache (cookies persist; image bytes do not).
- HTTP cache semantics (`Cache-Control`, `etag`).

### 3.3 Architecture

```
src/image/
  protocol.zig    — capability detection, encoder dispatch
  decode.zig      — stb_image wrapper for PNG/JPEG/GIF/WebP
  cache.zig       — in-process LRU keyed by absolute URL
  kitty.zig       — \x1b_G... \x1b\\
  iterm.zig       — \x1b]1337;File=... \x07
  sixel.zig       — \x1bPq...\x1b\\
  braille.zig     — block / braille fallback (no protocol)
```

Existing modules touched: `src/render.zig` (placeholder cell-row
reservation in `renderImage`), `src/browser.zig` (draw-time protocol
emit), `src/main.zig` (`--images=…` flag), `src/client.zig` (no
changes — image fetches use existing `fetchRequest`, same JA4
fingerprint).

---

## 4. Track B — Real-page render-quality corpus

### 4.1 In scope

- **Frozen HTML snapshots** of real production pages, version-controlled
  in `tests/corpus/fixtures/<name>.html`, captured at known dates.
- **Snapshot-based output assertions**: each fixture carries an
  `<name>.expected.txt` file containing `renderBrowseModel` output;
  the runner diffs against it on every test run.
- **Per-fixture soft assertions** layered on top of the snapshot diff
  (`min_text_bytes`, expected link count window, must-contain /
  must-not-contain string sets) so regressions surface as clear
  category failures even when a benign render-pipeline tweak diff-bombs
  the snapshots.
- **Fixture categories** (seed corpus, ~12-15 fixtures):
  1. Static baseline (e.g., `example.com`)
  2. Long-form article / semantic HTML5 (e.g., Wikipedia featured)
  3. News investigation (e.g., ProPublica long-read)
  4. Documentation site (e.g., MDN element page)
  5. Code-host SSR + CSR (e.g., GitHub README)
  6. App shell with SSR card grid (e.g., NVIDIA models — proves the
     `<main>` escape hatch landed in `adad620`)
  7. Heavy SPA with mostly empty SSR (e.g., login page) — proves the
     "no terminal-friendly content" status path
  8. Discussion / threading (e.g., Hacker News)
  9. Search-result page (e.g., DuckDuckGo SERP)
  10. Form-heavy page (e.g., `httpbin.org/forms/post`) — round-trips
      through the agent-browser POST pipeline
  11. International CJK (e.g., Chinese Wikipedia featured)
  12. International RTL (e.g., Arabic Wikipedia article) — assertion is
      "does not crash; text preserved"
  13. Malformed / edge custom fixture (missing close tags, double
      `<title>`, deep nesting)
  14. Hacker News-style table layout
  15. Tables-heavy infobox page (e.g., Wikipedia "Apple Inc.")
- **Update workflow**: `scripts/update-corpus.sh <fixture-name>` (or
  `awr corpus update <name>`) refetches the URL from
  `tests/corpus/manifest.json`, saves the HTML, renders with the
  current binary to `<name>.expected.txt`, and emits a `git diff` for
  human review before commit.
- **Live canary mode** (deferred *within* this deferred sub-spec — does
  not block §6 closure): `zig build test-corpus-live` fetches all
  manifest URLs fresh, runs through renderer, asserts only soft
  properties (no crash, text > min_bytes). Intended to run weekly via
  a scheduled remote agent; auto-opens a snapshot rebuild PR when
  output drifts beyond tolerance.

### 4.2 Out of scope

- **Authenticated pages.** Corpus fixtures are public URLs only — no
  cookies, no session tokens, no captures behind login walls.
- **JS-driven fixture mutation.** The harness uses `processHtml` (no
  network), but the captured HTML may include inline scripts; the
  harness runs them via the existing `Page` pipeline so JS-rendered
  changes are part of the snapshot. Pages that *only* render under
  full-browser JS (Twitter feed timeline) capture as the SSR shell;
  that *is* the assertion (we render the shell, not the feed).
- **Network-flake tolerance in the frozen corpus.** Frozen mode is
  100% deterministic — all input is on-disk. Live canary handles the
  flaky reality.
- **Visual regression for terminal graphics output.** Per Track A,
  protocol bytes are emitted at draw time, not in the model. The
  corpus harness asserts the text model, plus emitted-protocol
  unit tests (kitty/iterm/sixel encoder snapshot tests in
  `tests/image_*.zig`) cover the graphics layer. Wiring those to the
  corpus is out of scope; they are independent test targets.
- **Fuzzing** (random HTML mutation). A separate later track if needed.

### 4.3 Architecture

```
tests/corpus/
  manifest.json                    # URL + capture date + category per fixture
  fixtures/
    example_com.html               # raw HTML snapshot, verbatim from network
    example_com.expected.txt       # renderBrowseModel output snapshot
    nvidia_models.html
    nvidia_models.expected.txt
    ...
  README.md                        # how to add, update, review

tests/corpus_runner.zig            # iterates fixtures/, processHtml each .html,
                                   # diffs renderBrowseModel output vs .expected.txt,
                                   # plus per-fixture soft assertions

scripts/update-corpus.sh           # refetch URL → save .html → render → save
                                   # .expected.txt → git diff for review

build.zig                          # test-corpus step + corpus_runner module wiring
```

Per-fixture metadata struct (informational sketch):

```zig
const Fixture = struct {
    name: []const u8,
    category: Category,
    html_path: []const u8,
    expected_path: []const u8,
    min_text_bytes: usize,            // catches "blank screen" regressions
    expected_link_count: ?usize,      // null = skip assertion
    must_contain: []const []const u8,
    must_not_contain: []const []const u8, // e.g., "[object Object]" tokens
};
```

---

## 5. Risks and constraints

- **TLS fingerprint discipline.** Image fetches must use the existing
  `Client.fetchRequest` path with no per-request header tweaks. Mirror
  `agent-browser.md §6`. Verify with `zig build test-tls` on every
  code-touching session.
- **Header order** is load-bearing everywhere. Do not insert new
  headers (e.g., `Accept: image/*`) anywhere that perturbs request
  fingerprint.
- **Terminal cell-pixel ratios are not standardized.** Kitty exposes
  via `CSI 14 t / 16 t`; iTerm via OSC 1337 `ReportCellSize`; others
  may not. Default to 7×14 estimate when probing fails; document the
  visual artifact.
- **stb_image is C with its own memory model.** Wrap allocations
  through a C shim with a fixed-size arena per decode; free on
  `cache.evict()`. Match the BoringSSL shim discipline.
- **Snapshot diff-bomb risk.** Render-pipeline tweaks rebake every
  snapshot at once and reviewers stop reading the diff. Mitigations:
  small fixtures (≤ 200 lines rendered), soft per-fixture assertions
  surface category failures clearly, and the `update-corpus.sh`
  script makes intentional rebakes a one-command operation.
- **Live canary flakiness.** Real pages change daily; auto-opened
  snapshot rebuild PRs need human review before merge. Live mode is
  always opt-in (`--gate=ENABLE_LIVE`).
- **Authenticated / paywalled pages.** Out of scope (§4.2). Public
  URLs only; no captures behind auth walls.
- **Memory budget for the harness.** Rendering 15 fixtures with images
  enabled must not exceed 64 MB peak RSS during `zig build
  test-corpus`. Track A cache cap of 32 MB plus harness overhead is
  the design target.
- **Fullscreen-mode image lifetime.** Kitty graphics IDs persist
  across redraw; clear or replace them when scrolling so the TUI
  does not leak ghosts. Cleanup on `terminal.leaveFullscreen()`.

---

## 6. Closure gates

This sub-spec is closed when all of the following are true:

1. `zig build test` is green on the default developer path.
2. `zig build test-wpt` is green; the curated corpus is unchanged.
   There is no WPT case for terminal graphics protocols (out of WPT
   scope by design).
3. **Track A:** `zig build test-image` is green and includes:
   - decoder smoke tests for PNG / JPEG / GIF first-frame / WebP-still;
   - per-protocol encoder snapshot tests (golden bytes in
     `tests/image_fixtures/`);
   - cache LRU eviction + hit/miss accounting;
   - oversize-image fallback to text alt-ref;
   - non-TTY stdout falls back to `[alt-text][N]` regardless of
     `--images=…`.
4. **Track B:** `zig build test-corpus` is green and includes the
   ≥12 seed fixtures from §4.1. Each fixture has both a snapshot
   match AND its category-appropriate soft assertions pass.
5. `zig build test-tls` is green; JA4 fingerprint unchanged from the
   pre-amendment baseline.
6. `zig build test-h2` is green; HTTP/2 SETTINGS frame unchanged.
7. Each behavior in §3.1 and §4.1 is real per `spec/MVP.md §6`
   no-stubs rule. Stubs that emit empty escape sequences, no-op
   encoders, or trivially-passing fixture assertions are not
   acceptable.
8. `awr render <url> > out.txt` continues to produce text-only output
   (no escape garbage) with `[alt][N]` refs intact for grep workflows,
   regardless of `--images=…` setting.
9. Memory regression: rendering the corpus with images enabled does
   not exceed **128 MB** peak RSS during `zig build test-corpus`.
   Empirical baseline (Track B with 12 fixtures, no images): 83 MB.
   The 128 MB ceiling leaves headroom for ~20-25 fixtures and the
   future Track A image cache (32 MB cap). The original 64 MB ceiling
   in the first draft of this spec was set without measurement; it
   was raised after the 12th fixture landed and we measured the real
   number.
10. `spec/MVP.md §5` and §7 are amended in the same change set as the
    first code in either track lands.

---

## 7. Landing order

The tracks land in this order to keep the corpus harness signal clean:

1. **Spec amendment** (this file → ACTIVE + `spec/MVP.md §5,§7` +
   `docs/adr/0001-spec-governance.md`).
2. **Track B harness skeleton**: `tests/corpus/`, `corpus_runner.zig`,
   `build.zig` wiring, `update-corpus.sh`, plus 3-5 starter fixtures
   covering the simplest categories (static, article, app-shell).
   `test-corpus` lands green here.
3. **Track B fixture expansion** to the full ≥12 seed corpus in §4.1.
4. **Track A — decoder + cache + protocol detection + non-TTY
   fallback** (`src/image/*`); `test-image` target lands here.
   Fixtures still text-only; corpus snapshots unchanged.
5. **Track A — Kitty encoder** + `src/browser.zig:draw` integration;
   first visible images. Co-land a corpus fixture-update PR adding
   image-bearing fixtures (Wikipedia featured article, ProPublica
   long-read).
6. **Track A — iTerm2 encoder**.
7. **Track A — Sixel encoder**.
8. **Track A — braille fallback** for unknown terminals.
9. **Track A — `<picture>` / `srcset` picker** in `src/render.zig`.
10. **Track A — CSS `background-image` resolve**. Last because the
    integration with the heuristics is the trickiest.

Each step lands with the relevant test fixtures and runs the §6
gates. Steps 4-10 may interleave by encoder priority; steps 1-3 are
sequential.

---

## 8. References

- Kitty graphics protocol: <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
- iTerm2 inline images: <https://iterm2.com/documentation-images.html>
- Sixel format: <https://en.wikipedia.org/wiki/Sixel>
- Existing image surface: `src/render.zig:renderImage` (lines 841-858).
- Existing fetch surface: `src/client.zig:Client.fetchRequest`.
- Existing snapshot pattern (closest analog): `src/test_e2e.zig` (E2E
  golden output assertions).
- TLS / fingerprint discipline: `spec/MVP.md §3`,
  `spec/subspecs/agent-browser.md §6`, `AGENTS.md §src/net/`.
- Corpus precedent: Servo's WPT `dom/nodes/`, Ladybird's
  `Tests/LibWeb/Layout/` reference renders.
