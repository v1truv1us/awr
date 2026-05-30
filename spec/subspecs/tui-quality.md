# TUI Quality Track — post-Tier-3 UX debt

> **Status:** **CLOSED** 2026-05-30. All 5 items done, all closure gates
> verified: `zig build test` green (1196 tests), `zig build test-corpus` green
> (9 snapshots re-blessed), `h` in `awr tui --help` and welcome screen,
> HN and wikipedia_octopus re-blessed with improved output.
> `spec/MVP.md` is the canonical umbrella spec.
> This track is orthogonal to the tier ladder — it addresses bugs
> and UX gaps discovered through hand-driven testing after Tiers 0–3
> closed. It does NOT reopen any closed tier; it runs as a named
> quality track until all items below are resolved and verified.

---

## 1. Purpose and authority

After Tier 3 closed (2026-05-22), a hand-driven `awr tui` session
against real sites (HN, Wikipedia EN/AR/ZH, YC jobs) exposed five
distinct problems that collectively prevent the TUI from meeting its
"usable as a curl/browser replacement" goal:

1. **Inline link rendering** — rendered prose is hard to read because
   spaces adjacent to `<a>` elements are stripped and link text that
   wraps a line-break places its continuation at the wrong column.
2. **No loading indicator** — navigating to a slow page gives no
   feedback; the TUI appears frozen.
3. **No help modal** — keybindings are not discoverable in-session.
4. **Table-as-layout pages render scrambled** — HN, YC jobs, and
   Wikipedia infoboxes are effectively unreadable because the
   renderer emits table cells positionally rather than as linear
   reading-order flow.
5. **No visual navigation feedback** — after pressing Enter on a link
   the header does not update until the page fully loads, making it
   unclear whether the navigation succeeded.

This file governs the **what** for each fix. Implementation detail
lives in the source files listed per item.

---

## 2. Items

### 2.1 Inline link rendering (P1 — highest impact)

**Problem.** Two bugs in `src/render.zig`'s inline text/link emission:

- Spaces between a text node and an adjacent `<a>` element are
  dropped, causing words to run together: `eight-limbedmollusc[33]`
  instead of `eight-limbed mollusc[33]`.
- When an `<a>` element's text crosses a line boundary, the
  continuation is placed at the right edge of the next line instead
  of wrapping to column 0.

**Observed on:** English Wikipedia article body paragraphs, any
page with inline hyperlinks in prose.

**Acceptance criteria:**
- Adjacent text nodes and `<a>` elements are separated by exactly
  the whitespace present in the source HTML (one space for the common
  `… foo <a>bar</a> baz …` case).
- A linked word that wraps at the right margin continues at column 0
  of the next line, indistinguishable from unwrapped text flow.
- Corpus fixture `wikipedia_octopus` passes with `test-corpus` after
  re-blessing (new snapshot should not show stranded right-edge text).
- `zig build test-render` (inline unit tests in `src/render.zig`)
  includes a test asserting correct word-wrap for a link spanning a
  line boundary.

**Files:** `src/render.zig` (inline link emit logic, word-wrap path).

---

### 2.2 Loading indicator (P2) — DONE 2026-05-30

**Implemented as:** `BrowserSession.loading_url` + `active_terminal`/`active_io`
captured in `runWith`. `beginLoading`/`endLoading` wrap the blocking fetch in
`loadUrl`/`loadPostUrl`; `paintLoadingFrame` draws one frame (via `draw`) before
`page.navigate()` returns. `drawFrame` shows the target URL and a
`⟳ Loading…` header marker while `loading_url != null`. Test `T-Q2.2`.

**Problem.** `loadUrl` in `src/browser.zig` calls `page.navigate()`
synchronously (blocking the TUI's draw loop). On pages that take
more than ~300 ms to fetch, the terminal appears frozen with no
feedback.

**Design.** Two-phase approach within the existing synchronous model:

1. **Before fetch**: write a loading status immediately. Since the
   draw loop blocks on the fetch, this requires flushing the terminal
   directly from `loadUrl` before calling `page.navigate()`:
   - Set a `loading_url: ?[]const u8` field on `BrowserSession`.
   - In `drawFrame`, if `loading_url != null`, draw it in the header
     in place of the current URL and append `  [ Loading… ]` in the
     status line.
   - Flush once before entering `page.navigate()`.
2. **After fetch**: `installLoadedPage` clears `loading_url` and
   the normal draw replaces it.

**Acceptance criteria:**
- Navigating to any URL shows the target URL + "Loading…" in the
  header/status bar before the fetch returns.
- The indicator disappears and the real page header appears once
  the page is rendered.
- The `TuiHarness` test suite includes a test that verifies the
  loading frame is emitted before the final render frame.

**Files:** `src/browser.zig` (`BrowserSession`, `loadUrl`,
`drawFrame`).

---

### 2.3 Help modal (`h` key) (P3) — DONE 2026-05-30

**Implemented as:** `BrowserSession.show_help` + `drawHelpOverlay` (mirrors the
select-picker/cookie-inspector overlay pattern). `h` opens from the normal
reading state (`handleNormalChar`); any key dismisses (early branch in
`processKey`). `h` added to the welcome cheat sheet and `awr tui --help`. Test
`T-Q2.3`. NOTE: the documented table below listed `g` for the URL bar; the
actual binding is `o` or `:` (`g` is scroll-to-top). The overlay shows the
**real** bindings.

**Problem.** Keybindings are not discoverable during a session. The
welcome screen shows a cheat sheet on first launch, but once
navigated away from it is gone. The `awr tui --help` text is only
visible outside the TUI.

**Design.** Press `h` in the normal (non-prompt, non-field) state
to open a full-screen overlay listing all current keybindings. Press
any key to dismiss.

The overlay is a static table — keybindings are not configurable in
this track, so hardcoding the table in `drawHelpOverlay` is correct.

**Keybindings to document in the modal:**

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll down / up |
| `b` | Back |
| `f` | Forward |
| `r` | Reload (soft) |
| `R` | Reload (hard) |
| `:` or `g` | Open URL bar |
| `/` | Search |
| `n` | Next search match |
| `Tab` | Next focusable element |
| `Shift-Tab` | Previous focusable element |
| `Enter` / `Space` | Activate focused element |
| `Esc` | Cancel prompt / drop focus |
| `c` | Cookie inspector |
| `B` | Bookmark current page |
| `h` | This help screen |
| `q` | Quit |

**Acceptance criteria:**
- Pressing `h` from the normal reading state opens the overlay.
- The overlay is drawn by `drawFrame` via a new `show_help: bool`
  flag on `BrowserSession`; it replaces the body area (same pattern
  as the cookie inspector and select picker).
- Any keypress dismisses the overlay and returns to normal state.
- The `TuiHarness` test suite includes a test asserting the help
  overlay renders and can be dismissed.
- `h` is listed in the existing welcome cheat sheet and `awr tui --help`.

**Files:** `src/browser.zig` (`BrowserSession`, `drawFrame`,
`processKey`).

---

### 2.4 Table linearization for layout tables (P4) — DONE 2026-05-30

**Implemented as:** `hasThCell` + `renderLayoutTable` in `src/render.zig`. Tables
with no `<th>` element use `renderLayoutTable` (cells in DOM reading order,
`col > 0` row separator). Data tables (`<th>` present) unchanged. `zig build
test-corpus` green; `hacker_news` corpus fixture re-blessed. Two new §2.4 unit
tests (`render §2.4 — no-th table linearizes cells in DOM order`, `render §2.4
— th table keeps columnar layout`). The `at_line_start` / `col` invariant: with
`hang_indent=0`, `at_line_start` is never cleared by `writeByte`, so
`ensureNewline` is always a no-op; `col > 0` is the correct test for "content
was written on this row."



**Problem.** Sites using `<table>` as a layout mechanism (HN, YC
jobs, many news sites) render with cells emitted positionally,
producing scattered text that wraps at column 0 on the left while
other content lands at the far right — effectively unreadable.

**Design.** Classify tables as *data* or *layout* at render time
using the existing `isLayoutTable` heuristic path (or add one):

- **Layout table heuristic**: a table is a layout table if it has
  no `<th>` elements AND none of its cells contain only numeric or
  summary content (i.e., cells look like navigation, names, or prose
  rather than tabular data).
- **Layout rendering**: emit cells in DOM order, separated by a
  single space between inline cells and a newline between rows,
  without attempting column alignment.
- **Data table rendering**: unchanged — existing column/row
  alignment behavior is kept for `<th>`-bearing tables.

Note: full table layout (column-width calculation, alignment) is
Tier 4 work. This item only makes layout tables readable in
reading-order; it does not make them visually correct.

**Acceptance criteria:**
- HN front page renders with story titles, domain, and metadata
  in left-to-right reading order rather than scattered across the
  terminal width.
- A corpus fixture `hacker_news` is added (or the existing one
  re-blessed post-fix) with a `must_contain` assertion on a known
  story domain pattern (e.g. `(ycombinator.com)` or similar).
- Existing data-table fixtures (e.g. `mdn_select` which renders
  summary tables) continue to pass corpus assertions unchanged.
- `zig build test-corpus` green.

**Files:** `src/render.zig` (table render path, layout/data
classification), `tests/corpus_runner.zig` (HN fixture
`must_contain`), `tests/corpus/fixtures/hacker_news.*`.

---

### 2.5 Navigation feedback — immediate header update (P5) — DONE 2026-05-30

**Satisfied by §2.2:** activating a link sets `loading_url` to the resolved
target before the blocking fetch, so `drawFrame` shows the target URL (plus
`⟳ Loading…`) in the header immediately rather than the previous page's URL.


**Problem.** When a user follows a link, the header continues to
show the old URL until the new page fully loads. With the loading
indicator from §2.2, the target URL is shown during load — so this
item may be fully addressed by §2.2. Tracked separately to ensure
the header update is verified explicitly.

**Acceptance criteria:**
- Immediately after `Enter` on a link, the header shows the target
  URL (or "Loading…" + target URL), not the previous page's URL.
- Satisfied by the §2.2 `loading_url` mechanism if implemented
  correctly.

**Files:** See §2.2.

---

## 3. Out of scope for this track

- Full table layout (column widths, cell alignment) — Tier 4.
- Configurable keybindings — future work, not blocked on this track.
- Persistent URL history across sessions — Tier 2 scope, closed.
- Font/glyph-level text shaping — Tier 4.
- Performance optimization of the render path beyond what fixes
  items above naturally produce.

---

## 4. Closure gates

This track closes when **all** of the following are true:

1. `zig build test` green (all existing gates hold).
2. `zig build test-corpus` green with:
   - `wikipedia_octopus` snapshot re-blessed (§2.1 word-wrap fix).
   - `hacker_news` fixture present and passing (§2.4 table fix).
3. At least two new `TuiHarness` tests land:
   - Loading indicator visible before page ready (§2.2).
   - Help overlay renders and dismisses (§2.3).
4. Hand-driven smoke of `awr tui https://news.ycombinator.com`
   shows HN front page in readable left-to-right order.
5. Hand-driven smoke confirms the loading indicator appears when
   navigating to a slow page (Wikipedia qualifies).
6. `h` is listed in `awr tui --help` output.

---

## 5. Implementation order

Recommended order (each item independently shippable):

1. §2.2 Loading indicator — highest UX impact per line of code;
   unblocks §2.5 implicitly.
2. §2.3 Help modal — pure addition, no existing code risk.
3. §2.1 Inline link word-wrap — render.zig surgery; re-bless
   wikipedia_octopus corpus snapshot after.
4. §2.4 Table linearization — requires new heuristic + corpus
   fixture; most code risk; do last to avoid blocking other items.
5. §2.5 Navigation feedback — verify satisfied by §2.2; close if so.
