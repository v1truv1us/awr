# Render + UX polish — Tier 2 sub-spec

> **Status:** ACTIVE (promoted from DEFERRED to ACTIVE 2026-05-11)
> `spec/MVP.md` is the canonical umbrella spec.
> `spec/subspecs/browser-roadmap.md` is the cross-tier ladder
> authority; this file owns Tier 2 execution detail.

---

## 1. Purpose and authority

Tier 2 closes the polish gap between "AWR works" and "AWR feels
finished." After this tier, a human doing daily reading and form
work in `awr tui` no longer notices the terminal/web mismatch —
form boxes look intentional, code blocks are readable, tables
behave on scroll, frequently-visited pages have shortcuts.

This sub-spec governs:

1. bookmarks (`awr bookmark add` / `awr bookmark list` /
   `awr bookmark rm` + TUI bindings);
2. address-bar history autocomplete (per-shell-session);
3. form-render polish (visible boxes, label association,
   focus highlight uniformity);
4. table rendering improvements (sticky-header heuristic when
   scrolled past the header row);
5. code-block rendering (opt-in syntax highlighting,
   line numbers);
6. diff/patch rendering (GitHub/GitLab PR pages, `text/x-diff`);
7. image rendering polish (caching, decode budget tuning,
   sixel palette quality);
8. cookie inspector column enrichment (per-cookie expiry as
   human-readable, scope/secure/httpOnly visible).

If scope changes, update this file in the same change as
`spec/MVP.md` per `spec/MVP.md §8` and reflect the change in
`spec/subspecs/browser-roadmap.md §3`.

---

## 2. In scope

### 2.1 Bookmarks

CLI surface:

- `awr bookmark add [url] [--title=TITLE]` — adds a row to the
  bookmark store. With no URL, reads from `AWR_BOOKMARK_URL` env or
  errors. `--title` defaults to the URL's `<title>` when AWR can
  fetch it cheaply; falls back to the URL itself.
- `awr bookmark list` — emits one row per bookmark in
  `id<TAB>created_ts<TAB>title<TAB>url` format. Sortable / pipeable.
- `awr bookmark rm <id>` — removes by numeric id (1-based, stable
  per-file).

TUI surface:

- `B` (uppercase) in the page-reading state adds the current page
  to bookmarks; status line confirms.
- `b` is already taken (history back). Discoverable via the welcome
  screen cheat sheet and `awr tui --help`.

Storage: Netscape-style tab-delimited rows in
`$XDG_DATA_HOME/awr/bookmarks.txt` (default `~/.local/share/awr/bookmarks.txt`).
File permissions `0644` (bookmark URLs are not secrets).

### 2.2 URL-bar autocomplete (per-shell-session)

When the user opens the URL bar with `:`, AWR keeps an in-memory
ring buffer of the last N entered URLs and offers them as
completions. Cursor up/down cycles through matches; Enter accepts.
N=20 by default; configurable via `AWR_URL_HISTORY_LEN`. Resets
on `awr tui` exit (per-shell-session per Tier 2 scope; persistent
history is Tier 3 work alongside cross-process URL state).

### 2.3 Form-render polish

Today's renderer emits `[___]` for text inputs and `[x]` /
`(*)` for checked-state. Polish:

- consistent visible borders for `<textarea>` and `<select>`
  (already done as of T-83 but documented here)
- label-for-association: when a `<label for="x">` precedes/follows
  an `<input id="x">`, the label text is rendered next to the
  input in the same line where possible (already partially handled
  by inline text flow; document the contract).
- focus highlight uniformity: every focusable surface (link,
  text input, checkbox, radio, button, select) uses the same
  reverse-video pattern when focused (already true for fields;
  links currently use a separate `›` marker — close the gap).

### 2.4 Table rendering polish

When a `<table>` has more rows than the viewport and the user
scrolls past the header, repeat the header row at the top of the
viewport (sticky-header heuristic). Only applies to tables flagged
as data tables (per the existing `containsLayoutFormControl`
heuristic — layout tables are unaffected).

### 2.5 Code-block rendering

`<pre><code>` blocks render with:

- line numbers in the left gutter when the block is longer than
  N lines (default 5; `--code-line-numbers=N` overrides)
- opt-in syntax highlighting via `--code-style=auto|none|tag`.
  `auto` reads the `class="language-XYZ"` hint and matches against
  a small built-in set (zig, rust, js, ts, python, html, json, sh).
  Highlighter is intentionally simple — keyword + string + comment
  + number — not a full parser.

### 2.6 Diff / patch rendering

When the response Content-Type is `text/x-diff` OR the page body
matches a unified-diff regex (lines starting with `--- `, `+++ `,
`@@ ...`), AWR renders:

- header lines (`--- a/x`, `+++ b/x`, `@@ ...`) bold
- removed lines (`-`) in red
- added lines (`+`) in green
- context lines (` `) unstyled

This activates for the page body AND for any `<pre>` / `<code>`
block whose first line matches the regex (GitHub/GitLab embed
diffs in `<pre>`).

### 2.7 Image rendering polish

Polish on the existing image pipeline (Kitty/iTerm/sixel/braille):

- decode budget: cap per-page decode time at 250 ms wall-clock,
  fall through to alt-text refs if exceeded
- sixel palette: improve dither / quantization on 24-bit→256
  conversions
- response cache: in-process LRU keyed on `(src, viewport_cols)`
  with a 32-entry cap; survives page navigations within one
  `awr tui` session

### 2.8 Cookie inspector enrichment

T-84's inspector shows raw fields. Polish:

- expiry rendered as human-readable (`2 hours from now`,
  `1 week ago — expired`, `(session)` for null expiry)
- a column for SameSite (`L`/`S`/`N` for lax/strict/none)
- a footer hint summarizing counts: `3 active · 2 session · 1 expired`

---

## 3. Out of scope (defer to later tiers)

- bookmarks across machines / sync — out of scope
- persistent URL history (Tier 3 alongside daemon-scope URL state)
- new layout (Tier 4 — `getBoundingClientRect`, real flex/grid)
- inline image *zoom* (no pixel surface; we render at whatever
  cells the protocol gives us)

---

## 4. Closure gates

Tier 2 closes when **all** of the following are true:

1. existing Tier 0 + Tier 1 gates remain green;
2. curated WPT corpus extended to cover where applicable:
   - code-block / `<pre>` semantics (text content + whitespace
     preservation)
   - diff content-type recognition (response handling, not the
     rendering — render is a UX concern outside WPT's surface)
3. each Tier 2 slice (bookmarks, autocomplete, form polish,
   table polish, code blocks, diffs, image cache, inspector
   enrichment) has a code-side test (`zig build test`) that
   asserts the externally-observable behavior;
4. `awr tui --help` documents every new key binding (B, etc.);
5. `scripts/browse_smoke.sh` extended with a "bookmark
   round-trip" flow that adds, lists, and removes a bookmark.

---

## 5. Verification gates

The closure record is only valid while the repo can truthfully
claim all of:

1. `zig build test` green;
2. `zig build test-wpt` green and includes the §4.2 areas;
3. `zig build test-integration` green;
4. `zig build smoke` green (including the new bookmark flow);
5. all new TUI bindings appear in the welcome cheat sheet
   AND in `awr tui --help`.

---

## 6. Implementation slices

Indicative slices, smallest-first (B3-track convention so each
slice is independently shippable):

1. **Slice T2.1 — bookmarks.** CLI + TUI binding + on-disk store.
   Smoke flow round-trip. Verifies the on-disk format survives
   daemon mode (i.e. it's not jar-scoped).
2. **Slice T2.2 — URL-bar autocomplete.** In-memory ring buffer,
   arrow keys in URL prompt cycle through matches.
3. **Slice T2.3 — cookie inspector enrichment.** Add SameSite
   column, human-readable expiry, footer summary. Tiny.
4. **Slice T2.4 — code-block line numbers + style.** New
   `--code-style` flag (no syntax highlighting yet; just line
   numbers). Highlighting follows in T2.5.
5. **Slice T2.5 — code-block syntax highlighting.** Built-in
   small highlighter for the 8-language set; class-hint detection.
6. **Slice T2.6 — diff / patch rendering.** Content-Type +
   body-regex detection, +/- coloring.
7. **Slice T2.7 — table sticky-header heuristic.** Repeat header
   row when scrolled past it.
8. **Slice T2.8 — form-render polish.** Label association
   contract documentation + uniform focus highlight.
9. **Slice T2.9 — image pipeline polish.** Decode budget cap,
   in-session LRU cache, palette tuning.

Each slice is independently shippable; landing order is
bottom-up.

---

## 7. Coexistence with existing tracks

| Track | Interaction |
|---|---|
| `spec/subspecs/browser-tui.md` (Tier 1, CLOSED) | Tier 2 adds new bindings (B) and a URL-bar autocomplete layer; no Tier 1 contract changes. |
| `spec/subspecs/rendering.md` | Tier 2 polishes existing renderers; no protocol changes. New `--code-style` CLI flag is purely additive. |
| `spec/subspecs/daemon-mode.md` | Bookmarks are per-user not per-scope; daemon mode doesn't change the bookmark path. URL-bar history is per-TUI-session, so daemon mode doesn't interact here either. |
| `spec/subspecs/agent-browser.md` | Agent surface is unchanged. Diff rendering applies only to the human render path; the agent JSON envelope keeps emitting plain body text. |
| `spec/subspecs/wpt-conformance.md` | Corpus grows per §4.2 (small: a few `<pre>` / Content-Type cases). |
| `spec/subspecs/browser-roadmap.md` | This file is Tier 2 of the roadmap. |

---

## 8. Open questions

These are deferred to slice-plan time:

1. URL-bar autocomplete: should arrow-up first cycle through
   recent URLs (Chrome-ish) or through completions matching
   the typed prefix (zsh-ish)? Likely answer: prefix-match with
   "no-prefix → most-recent" fallback.
2. Code-block highlighting: do we ship a dependency
   (`tree-sitter` would be the obvious choice — a single C lib)
   or write a 200-line keyword-based highlighter? Likely answer:
   the keyword highlighter for Tier 2; tree-sitter belongs in a
   later "real syntax highlighting" Tier 3+ slice.
3. Diff rendering: do we honor `<table class="diff">` (the
   format GitHub uses for split-view PR diffs) or only unified
   diffs? Likely answer: unified for Tier 2; split-view in a
   later polish slice.

If the answers to any of these would change the contract above,
amend this sub-spec in the same change as the slice plan.

---

## 9. Closure record

| Field | Value |
|-------|-------|
| Status | CLOSED |
| Date | 2026-05-13 |
| Final commit | b6dd220 (T-100 — T2.9 image pipeline polish) |
| Gates satisfied | §4.1 Tier 1 gates green ✓ / §4.2 test-image ✓ / §4.3 smoke bookmark ✓ / §4.4 help docs ✓ |
| Sign-off | AWR Dev |
