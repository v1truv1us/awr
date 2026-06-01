# Tier 4 Target-Site Audit — 2026-06-01

> **Status:** Evidence artifact for `docs/adr/0003-tier4-layout-strategy.md`
> §"Required evidence before final Tier 4 decision", item 2 (target-site audit).
> **Read-only research.** No spec/ADR amended, no source behavior changed.

## Method

ADR 0003 requires running the real binary against at least: Hacker News,
Google Search, GitHub, Stack Overflow, a Discourse/Reddit-like page, and a
login flow — and naming the **blocking subsystem** for each (layout / JS API /
cookies-session / anti-bot / network / renderer-heuristic).

Build: `zig build` succeeded on this worktree after symlinking three vendored
path-dependencies (`third_party/libxev`, `third_party/zig-quickjs-ng`,
`third_party/quickjs-ng-quickjs`) from the main checkout — those dirs are
git-ignored and absent in a fresh worktree. The symlinks are untracked and do
not modify `build.zig` or `net/`. Resulting binary: `zig-out/bin/awr` (13.2 MB).

Linkage check (`otool -L`): BoringSSL is statically linked; **lexbor and
nghttp2 are dynamically linked from `/opt/homebrew`** — so the binary is not
fully self-contained today (relevant to the packaging audit).

Commands run per site: `./zig-out/bin/awr <url>` (JSON envelope) and/or
`./zig-out/bin/awr extract <url>` (Markdown). All runs were live network from
the local machine on 2026-06-01. Outcomes recorded honestly, including
challenge/garbage responses.

## Results

| Site | URL | Reached? | HTTP | Output quality | Blocking subsystem |
|---|---|---|---|---|---|
| Hacker News | `https://news.ycombinator.com/` | ✅ yes | 200 | **Excellent** — all 30 stories, points, comments, links render in JSON and Markdown | None (works today) |
| HN login form | `https://news.ycombinator.com/login` | ✅ yes | 200 | **Excellent** — login + create-account forms with username/password fields render | None for render; submit gated by **cookies-session** (not tested live) |
| Google Search | `https://www.google.com/search?q=zig+language` | ⚠️ connected | 200 | **Garbage** — body is binary (undecoded Brotli) | **network/fingerprint** (Brotli), then JS API (Google strips UI in non-Chromium) |
| Google home | `https://www.google.com/` | ⚠️ connected | 200 | **Garbage** — undecoded Brotli | **network/fingerprint** |
| GitHub | `https://github.com/ziglang/zig` | ✅ yes | 200 | **Good** — full title + nav + content (gzip) | None (works today; verbose whitespace is renderer-heuristic) |
| GitHub login | `https://github.com/login` | ✅ yes | 200 | **Good** — "Sign in to GitHub", form present | None for render; submit gated by **cookies-session** + likely **anti-bot** |
| Stack Overflow | `https://stackoverflow.com/questions/tagged/zig` | ✅ yes | 200 | **Good** — title + nav + question list (gzip) | None (works today) |
| Reddit (old) | `https://old.reddit.com/r/zig/` | ✅ yes | 200 | **Excellent** — subreddit nav + listing render cleanly (gzip) | None (works today) |
| Reddit (new) | `https://www.reddit.com/r/zig/` | ⚠️ connected | 200 | **Challenge page** — title `"Reddit - Please wait for verification"` | **anti-bot** |
| Discourse | `https://meta.discourse.org/` | ⚠️ connected | 200 | **Garbage** — undecoded Brotli | **network/fingerprint** (Brotli) |

## Per-site analysis

### Hacker News — works, no Tier 4 demand
HN is table-layout HTML over gzip. AWR's table linearization (TUI Quality Track
§2.4) and extraction produce a clean, readable result. **Layout is not the
blocker; there is no blocker.**

### Google Search / Google home — network/fingerprint, NOT layout
Status is 200 but the body is binary noise. Root cause confirmed in source:
`src/net/http1.zig:66-68` advertises Chrome 132's full
`accept-encoding: gzip, deflate, br, zstd` (required to keep the fingerprint
Chrome-shaped) but the decoder only handles `gzip, deflate, zstd` ("no brotli
yet"). Google elected Brotli, so AWR cannot read the response at all. Even with
Brotli decoded, `awr --help` documents that Google's homepage JS strips its own
UI in a non-Chromium env (`--no-js` escape hatch exists). **So Google's first
blocker is content-encoding (network/fingerprint), its second is a JS-API
detection issue — layout is nowhere on the path.**

### GitHub — works (gzip); whitespace is a renderer concern
Full page content returns. The JSON `body_text` carries a lot of structural
whitespace, which is a **renderer-heuristic** cleanup opportunity, not a layout
gap. Login page renders the sign-in form. Actually completing a login is a
**cookies-session** + likely **anti-bot** concern, not layout.

### Stack Overflow — works (gzip)
Title and question list render. No layout blocker.

### Reddit — split outcome
`old.reddit.com` (server-rendered, gzip) works excellently. `www.reddit.com`
(new) returns an explicit **anti-bot** challenge ("Please wait for
verification"). This is the canonical Discourse/Reddit-like row: the *readable*
variant already works; the *modern* variant is blocked by **bot detection**,
which `browser-roadmap.md §5` explicitly declines to fight per-site, **not** by
layout.

### Discourse (meta.discourse.org) — network/fingerprint
Same Brotli garbage as Google. A Brotli decoder would likely make Discourse
readable (it is largely server-rendered Ember with SSR content). **Not layout.**

### Login flow
HN and GitHub login *forms* render and are fillable (Tier 1 closed). The
outstanding risk on submission is **cookies-session** persistence and, for
GitHub, **anti-bot**. None of the six login-relevant observations point at
layout.

## Blocking-subsystem tally

| Blocking subsystem | Sites |
|---|---|
| None — works today | HN, GitHub, Stack Overflow, old.reddit |
| network/fingerprint (Brotli) | Google ×2, Discourse |
| anti-bot | reddit (new); GitHub-login (likely on submit) |
| cookies-session | login submission (HN, GitHub) — not layout |
| **layout** | **none observed** |

## What the site audit says about Tier 4

1. **Not a single one of the six required sites is blocked by layout.** The
   readable web AWR targets (HN, SO, GitHub, old.reddit, Discourse-SSR) is
   server-rendered and already works or would work with a **Brotli decoder**.

2. **The highest-leverage fix is Brotli, not layout.** Three of the ten runs
   (Google ×2, Discourse) fail purely because AWR advertises `br` to preserve
   its Chrome fingerprint but cannot decode it. This is a bounded networking
   task and is independent of the Tier 4 decision. It should arguably be
   sequenced *before* any layout investment, because it currently masquerades
   as a "site doesn't work" failure that could be mis-attributed to rendering.

3. **Anti-bot is a deliberate non-goal.** `www.reddit.com`'s challenge page is
   exactly the per-site arms race `browser-roadmap.md §5` refuses to enter. No
   Tier 4 path changes this.

4. **Layout's real payoff is elsewhere.** Since target sites don't need it,
   layout's value would be in (a) pixel-accurate geometry APIs for
   script-heavy pages and (b) better visual fidelity for CSS-positioned
   content — a smaller, more speculative payoff than "make the top sites work,"
   which is already largely achieved.

## Sites I could and could not reach

- **Reached and readable:** HN, HN-login, GitHub, GitHub-login, Stack Overflow,
  old.reddit.
- **Connected (HTTP 200) but unreadable:** Google search, Google home,
  meta.discourse.org — all undecoded Brotli (network/fingerprint).
- **Connected but challenged:** www.reddit.com — anti-bot verification page.
- **Could not test live:** actual credentialed login submission (no test
  accounts); recorded as a cookies-session/anti-bot risk rather than guessed.

## Recommendation input (not a decision)

The site audit argues **against** an expensive layout engine as the next
priority: the target readable web is already served by AWR's heuristic
renderer, and the visible failures are encoding/anti-bot. If Tier 4 proceeds at
all, the evidence supports the cheapest viable seam (adapter + optional
external oracle for the few pages that truly need pixel geometry), not a
Servo/Chromium embed that would re-solve fetch/DOM/JS that already work.
