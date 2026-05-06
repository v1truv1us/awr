# Agent-Readiness Fixes — body_text + CLI help

## Scope

Two surgical fixes that close the bulk of WebFetch-replacement gaps surfaced
by the 2026-05-06 verification scan:

1. `body_text` in the JSON envelope leaks `<style>` / `<script>` content
   (raw `textContent` per DOM spec).
2. `awr --help` and `awr -h` are parsed as URLs and fail with `error
   fetching --help: file not found`.

Out of scope (separate spec required): a programmatic interaction surface
to compete with Playwright (`awr session step/click/fill/snapshot`). That
crosses into the deferred `browser-tui.md` track and warrants its own
sub-spec.

## Problem statement

### Issue 1 — body_text CSS leak

`src/page.zig:721-724`:
```zig
const body_text: []const u8 = blk: {
    const body = zig_doc.body() orelse break :blk try gpa.dupe(u8, "");
    break :blk body.textContent(gpa) catch try gpa.dupe(u8, "");
};
```

`Element.textContent` (`src/dom/node.zig:107`) is spec-compliant — it
concatenates ALL descendant text node data, including text nodes inside
`<style>` and `<script>` elements. That is correct DOM behaviour and is
asserted by curated WPT cases. **It must not change.**

The agent-facing `body_text` field is a *different concern*: it should
expose readable page text, not embedded CSS / JS source. Measured impact
on real pages:

| URL | body_text size | First prose byte | Junk before prose |
|---|---|---|---|
| MDN `/docs/Web/HTML/Element/select` | 76 677 | 34 661 | 45% |
| Wikipedia `/wiki/Octopus` | 100 786 |  5 678 |  5.6% |
| Hacker News | 3 854 | 0 | 0 |

The MDN case alone wastes ~34 KB per fetch when piped into an LLM context
window. That's the whole reason WebFetch wraps responses in a summarizer.

### Issue 2 — `--help` not recognised

`src/main.zig:167-173` recognises `--version` / `-v` but no help flag.
Argument dispatch falls through to `loadPage(args[1])`, which tries to
fetch `--help` as a path and fails. Trivial CLI ergonomics gap.

## Discovery findings

Already verified during scan:

- `Element.textContent` is the spec-compliant method; do not modify.
- `renderBrowseModel` (`src/page.zig:942`) is the existing Reader-View
  path used by `awr render` and the corpus runner. It already filters
  non-content elements via `chooseContentRoot` in
  `src/browse_heuristics.zig`. The JSON envelope path does not use it.
- The `body_text` field's contract (per `USAGE` text in `src/main.zig:48`)
  promises plain text. The current implementation honours the *DOM*
  contract but not the *user* contract.
- Curated WPT corpus has cases that will break if `Element.textContent`
  itself is changed. The fix must live at the page.zig extraction site
  or a new method, not on `textContent`.

## Tasks

### T1 — Filter `<style>` / `<script>` from body_text extraction

| Field | Value |
|---|---|
| **ID** | T1 |
| **Title** | Strip non-content descendants from body_text textContent |
| **Depends on** | — |
| **Files** | `src/dom/node.zig` (add `textContentForExtract`), `src/page.zig` (call it from body_text block at line 721-724), `src/dom/node.zig` co-located test, `src/page.zig` co-located test |
| **Spec reference** | `spec/MVP.md §5` (closed shipped surface — `body_text` is observable behaviour) |
| **Estimate** | 30–60 min |
| **Complexity** | Low |

**Acceptance criteria:**

1. New method `Element.textContentForExtract(allocator)` on
   `src/dom/node.zig` Element type that mirrors `textContent` but skips
   descendants whose tag is in `{style, script, noscript, template}`
   (case-insensitive ASCII).
2. `Element.textContent` itself is **not** modified — keeps WPT spec
   compliance.
3. `src/page.zig:721-724` body_text extraction calls
   `textContentForExtract` instead of `textContent`.
4. New unit test in `src/dom/node.zig`: HTML
   `<body><style>.x{color:red}</style><p>hi</p><script>alert(1)</script></body>`
   produces `textContentForExtract` output `"hi"` (no CSS, no JS source).
5. New unit test in `src/page.zig`: same fixture round-tripped via
   `processHtml`, asserts `result.body_text` does not contain
   `"color:red"` and does not contain `"alert"`.
6. `zig build test test-wpt test-test262 test-corpus` all green.
7. The existing `Element.textContent` co-located tests at
   `src/dom/node.zig:700+` continue to pass without modification.

### T2 — Recognise `--help` / `-h` / `help`

| Field | Value |
|---|---|
| **ID** | T2 |
| **Title** | Print USAGE on `--help`, `-h`, or bare `help` and exit 0 |
| **Depends on** | — |
| **Files** | `src/main.zig` (insert handler after the `--version` block at line 168-173) |
| **Spec reference** | n/a — CLI ergonomics |
| **Estimate** | 10 min |
| **Complexity** | Trivial |

**Acceptance criteria:**

1. `awr --help` prints `USAGE` to stdout and exits 0.
2. `awr -h` does the same.
3. `awr help` (bare-word subcommand-style, mirrors `git help`) does the
   same.
4. All existing subcommands (`browse`, `render`, `tools`, `call`, `mock`,
   `--version`) continue to work unchanged.
5. Manual smoke covered by adding a `test_e2e` case (or shell smoke in
   `src/test_e2e.zig`-style fixture). At minimum a co-located unit test
   in `src/main.zig` if the help-flag detection is factored into a helper.

### T3 — Doc note in DEV_NOTES

| Field | Value |
|---|---|
| **ID** | T3 |
| **Title** | Document the textContent vs textContentForExtract distinction |
| **Depends on** | T1 |
| **Files** | `DEV_NOTES.md` |
| **Spec reference** | n/a — developer guidance |
| **Estimate** | 5 min |
| **Complexity** | Trivial |

**Acceptance criteria:**

1. New `DEV_NOTES.md` entry explains: `Element.textContent` is
   spec-compliant per DOM and must remain so for WPT;
   `Element.textContentForExtract` is the agent-facing variant that
   filters `<style>`/`<script>`/`<noscript>`/`<template>` and is the
   right choice for `body_text`-style extraction.
2. README is **not** changed — `body_text` user-facing description in
   `src/main.zig:48` `USAGE` already says "JSON {url, status, title,
   body_text, ...}" with no mention of CSS/JS leakage, so post-fix
   behaviour matches the documented contract.

## Dependency graph

```
T1 ─┐
    ├──> T3
T2 ─┘ (independent)
```

T1 and T2 are independent and may land in either order or together.
T3 documents the T1 design decision; lands after T1.

## Parallel-track opportunity

T1 and T2 touch different files (`src/dom/node.zig` + `src/page.zig` vs
`src/main.zig`) and have no shared code paths. Safe to land in one
commit each, in parallel branches if desired. Per the project rule
"One Deliverable Per Session", recommend landing both in a single
session given their tiny size.

## Risk assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| WPT regression from changing `textContent` | High if done wrong, **zero** with the chosen design (new method, not modification) | T1 acceptance criterion 2: `textContent` is not touched |
| Corpus `expected.txt` baselines contain leaked CSS that gets stripped post-fix | Medium — MDN-class fixtures may have inline `<style>` in the captured HTML | Run `test-corpus` after T1; if a fixture's expected.txt diff is mechanical CSS removal, re-bless via the runner's `.actual.txt` workflow |
| Help text behaviour differs from existing `--version` precedent | Low — pattern is identical | Mirror the `--version` block exactly |
| `body_text` consumers downstream rely on the leaked CSS | Negligible — no known consumers; the field is documented as "body text" | None; if reported post-merge, the JSON envelope is versioned by repo, not by API |

## Testing strategy

Pre-implementation baseline (already captured in this scan):

- `zig build test test-wpt test-test262 test-corpus` all green.
- `awr https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select`
  body_text contains `.mdn-search-button{align-items:center;...}`.
- `awr --help` exits with `error fetching --help: file not found`.

Post-implementation:

1. Same suite green (`zig build test test-wpt test-test262 test-corpus`).
2. New unit tests in `src/dom/node.zig` and `src/page.zig` (T1
   acceptance 4, 5).
3. Manual smoke:
   - `awr https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select | python3 -c 'import json,sys; b=json.load(sys.stdin)["body_text"]; assert "{align-items:" not in b; print("PASS")'`
   - `awr --help` prints USAGE and exits 0
   - `awr -h` prints USAGE and exits 0
   - `awr help` prints USAGE and exits 0
4. Cold-vs-cold bench (`bench-cold.mjs`) re-run to verify no
   performance regression. Body_text extraction is in-process and
   adds one tag-name comparison per descendant; expected delta < 1 ms.

## Closure criteria

The plan is closed when **all** of the following are true:

1. T1, T2, T3 acceptance criteria all met.
2. `zig build test test-wpt test-test262 test-corpus` green.
3. MDN smoke (T1 acceptance 5) returns CSS-free body_text.
4. `awr --help`, `awr -h`, `awr help` all print USAGE and exit 0.
5. This file moves to `.opencode/plans/archive/`.

## Out of scope — for a future spec

These were considered and explicitly excluded from this plan:

- **Programmatic interaction surface (`awr session`)** — needed to chase
  the Playwright-replacement story (click, fill, wait-for-element,
  snapshot via JSON commands over stdin). Requires its own sub-spec
  under `spec/subspecs/` and crosses into the deferred
  `browser-tui.md` track. Not bound work.
- **Daemon mode / warm process** — closes the ~95 ms cold-startup gap on
  example.com and would amortise across multi-fetch agent sessions.
  Documented in the `shiny-nebula.md` "What's left" section. Not bound
  work; needs separate plan if pursued.
- **HTTP/2 multiplexing for sub-resources** — closes the github 60+
  scripts gap. nghttp2 is vendored; wiring sub-resources through it is
  a non-trivial pass that touches the JA4 fingerprint surface.
  Documented in `shiny-nebula.md`. Not bound work.

## Open questions

None. The design — new `textContentForExtract` method, leave
`textContent` alone — resolves the only WPT-compliance question. The
help-flag handler exactly mirrors the `--version` precedent.

## Hand-off

Pick this up via `/ai-eng-core:work` against this plan file, or land
T1 and T2 directly as separate commits with the acceptance criteria as
the verification checklist.
