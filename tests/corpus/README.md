# Real-page render-quality corpus

This directory holds frozen snapshots of real production HTML plus their
rendered-output expectations. The harness in `tests/corpus_runner.zig`
runs `Page.processHtml` over each captured `.html`, calls
`Page.renderBrowseModel`, and asserts the resulting text matches the
recorded `.expected.txt` plus per-fixture soft assertions.

This corpus is the **render-quality regression layer**, complementing the
synthetic API-correctness layer in `tests/wpt/`. Spec authority:
`spec/subspecs/rendering.md` Track B.

## Layout

```
tests/corpus/
  README.md                  ← this file
  fixtures/
    <name>.html              ← raw HTML snapshot, verbatim from network
    <name>.expected.txt      ← renderBrowseModel output snapshot
    <name>.actual.txt        ← (transient) written on snapshot mismatch
                                for `git diff`-driven review
```

## Adding a fixture

1. Capture the HTML:
   ```bash
   curl -sL "<url>" -o tests/corpus/fixtures/<name>.html
   ```
2. Add a `Fixture{}` entry to the `fixtures` array in
   `tests/corpus_runner.zig`. Set the URL exactly as captured (relative
   URLs in the HTML resolve against this), choose `min_text_bytes`
   conservatively (catches "blank screen" regressions), and pick 1–3
   `must_contain` / `must_not_contain` strings that uniquely identify
   the page's category.
3. Create an empty `.expected.txt`:
   ```bash
   touch tests/corpus/fixtures/<name>.expected.txt
   ```
4. Run `zig build test-corpus`. The runner detects the empty expected,
   seeds it from the current render output, and prints `SEEDED ...` —
   this is the bootstrap path, NOT silent rebake.
5. Review with `git diff tests/corpus/fixtures/<name>.expected.txt` and
   commit when satisfied.

## Updating an existing fixture

When a render-pipeline change intentionally shifts output:

1. `zig build test-corpus` fails with a snapshot mismatch and writes
   `<name>.actual.txt` next to `.expected.txt`.
2. Inspect the diff:
   ```bash
   diff tests/corpus/fixtures/<name>.expected.txt \
        tests/corpus/fixtures/<name>.actual.txt
   ```
3. If the change is intentional, bless it:
   ```bash
   mv tests/corpus/fixtures/<name>.actual.txt \
      tests/corpus/fixtures/<name>.expected.txt
   ```
   (Or `cp`, then delete `.actual.txt`. The `.actual.txt` files are in
   `.gitignore`-equivalent territory — do not commit them.)
4. Commit the new `.expected.txt`.

The runner never silently overwrites a non-empty expected. Bless steps
are always explicit so review is forced.

## CI mode

Set `AWR_CORPUS_STRICT=1` in CI to disable bootstrap seeding. Empty
`.expected.txt` files become hard failures — every fixture must be
blessed before merge.

## What kinds of fixtures belong here

Per `spec/subspecs/rendering.md §4.1`, the seed corpus targets these
categories:

1. Static baseline (e.g., `example.com`) — `example_com.html` ✓
2. Long-form article / semantic HTML5 (e.g., Wikipedia featured)
3. News investigation (e.g., ProPublica long-read)
4. Documentation site (e.g., MDN element page)
5. Code-host SSR + CSR (e.g., GitHub README)
6. App shell with SSR card grid (e.g., NVIDIA models)
7. Heavy SPA with mostly empty SSR (e.g., login page)
8. Discussion / threading (e.g., Hacker News)
9. Search-result page (e.g., DuckDuckGo SERP)
10. Form-heavy page (e.g., `httpbin.org/forms/post`)
11. International CJK (e.g., Chinese Wikipedia featured)
12. International RTL (e.g., Arabic Wikipedia article)
13. Malformed / edge custom fixture
14. Hacker News-style table layout
15. Tables-heavy infobox page (e.g., Wikipedia "Apple Inc.")

Each fixture should exercise a distinct code path through
`chooseContentRoot` / `shouldSkipForBrowse` / `renderBrowseModel`.
Adding a 4th news article doesn't teach the harness anything new;
adding a malformed fixture does.

## What does NOT belong here

- Authenticated / paywalled pages — public URLs only.
- HTML pulled from non-public sources (proprietary intranets, etc.).
- Fixtures > 1 MB raw HTML — capture a representative sub-page.
- Pages whose rendered output exceeds 200 lines — fragment the fixture
  or pick a smaller representative.

See `spec/subspecs/rendering.md §4.2` for the complete out-of-scope list.
