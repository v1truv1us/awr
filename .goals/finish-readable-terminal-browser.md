# Goal — Finish the readable-terminal-browser cluster

**Objective:** Make every page AWR *can* render actually render readably (not
merely decode) by landing tasks T1–T7 merged on a fully green `main`, executing
in order from T3 (Brotli decode via vendored C `brotlidec`), per the execution
ledger `docs/plans/readable-browser-goal.md`.

**Success Criteria:**
- [x] T1 — tabindex/role=button focus + activation (on `main` `36034e2`)
- [x] T2 — app-shell render rescue (on `main` `ed7f28a`)
- [ ] T3 — `Content-Encoding: br` decodes on all 3 fetch paths; a real `br`-served
      server-rendered site (Discourse) **renders readably**; Google **decoded**
      (not binary); `Accept-Encoding`/fingerprint unchanged
- [ ] T4 — SVG/undecodable `<img>` degrades to alt-text, never a 1×1 blob
- [ ] T5 — kitty/iterm image reserves its `r` cell-rows; following lines don't overlap
- [ ] T6 — excess structural whitespace collapsed without altering article fixtures
- [ ] T7 — a JS-dependent page (Google homepage + one light SPA) renders usable
      shell/content rather than an empty shell
- [ ] Every task `[x]` in `docs/plans/readable-browser-goal.md` with its gate green

**Verification Evidence:**
- `zig build` EXIT 0 (`awr` + `awrd`); `zig build test` EXIT 0 with **zero**
  failing fixtures.
- `zig build test-tls` + `zig build test-h2` green on every commit (Chrome-132
  fingerprint intact) — non-negotiable.
- Per task: a co-located/round-trip test that fails before and passes after.
- T3: `awr extract https://meta.discourse.org/` → readable text; `awr
  https://www.google.com/` → decoded, not binary.
- T7: `awr extract`/`browse` of Google homepage + a light SPA → usable content;
  hermetic fixture test pins it.
- Real exit codes (no pipe-masking); terminal effects verified via the
  PTY/strict-VT method proven in this repo.

**Scope:**
- **In scope:** T3–T7 implementation + tests; vendoring Google `brotlidec`
  (static lib + `src/net/brotli_shim.c` + `build.zig`); keeping the ledger
  current. Bar = "renders readably," not "decodes."
- **Out of scope (bucket C — impossible by design, not failures):** per-site
  anti-bot (Cloudflare / new-reddit challenges), WebGL/canvas, `<video>`/audio
  playback. Also: Tier 4 layout engine, Tier 5 full-SPA runtime, MCP stdio
  promotion, a pure-Zig brotli rewrite (future follow-up). Changing
  `Accept-Encoding` or any fingerprint surface.

**Constraints:**
- Never touch `src/net/` header order, cipher order, ALPN, or HTTP/2 SETTINGS;
  revert anything that reddens test-tls/test-h2.
- No governance/spec scope changes (`spec/MVP.md`, `spec/subspecs/*`,
  `docs/adr/*`).
- No stubs, TODO placeholders, dead code, or undocumented behavior changes; the
  brotli decoder must really decode. Do not discard the parallel worktree's work.

**Boundaries:**
- **May modify:** `src/client.zig`, `src/net/*` (decompression only, not header
  emission), `src/render.zig`, `src/image/*`, `src/page.zig`, `src/js/*`,
  `src/dom/bridge.zig`, `src/browse_heuristics.zig`, `build.zig`,
  `third_party/brotli/`, `tests/`, `docs/plans/readable-browser-goal.md`.
- **Must NOT modify:** `spec/`, `docs/adr/`, fingerprint emission;
  `tests/corpus/fixtures/*` except a justified one-line re-bless of a fixture the
  change legitimately altered.

**Iteration Policy:**
- One task per iteration: branch off `main`, implement, add failing→passing test,
  run task gate + test-tls + test-h2, `zig fmt src/`, commit (code + check the
  box), fast-forward `main`, continue.
- When a page decodes but stays blank, diagnose *why* and route to the right
  task/bucket — never call a decoded-but-unreadable page done.
- On gate failure, root-cause and fix (recall the bufPrintZ lesson: read the real
  error before theorizing), don't report partial completion.

**Completion Audit:**
- Map each of T3–T7 to fresh evidence (test output, build-gate summary, live
  spot-check). Not complete if any task is unverified, narrowed, or only
  "probably" working, or if any non-justified fixture is red.
- For each audit site that still doesn't render, its blocker must be tagged to a
  bucket (A/B fix task, or C permanently-out) — nothing left unexplained-blank.

**Blocked Stop Condition:**
- Stop without marking complete if: vendoring brotli can't wire without breaking
  build/fingerprint after a real attempt; a task needs a governance/spec change;
  a target's usable render genuinely requires Tier 4/5 or anti-bot evasion; or a
  live-site gate is unreachable (record the offline outcome, fall back to the
  hermetic unit gate). Report attempted paths, evidence, exact blocker, and what
  would unblock.
