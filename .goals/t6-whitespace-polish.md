## Goal

**Objective:** Collapse excess vertical whitespace in AWR's flow rendering so no run of blank lines exceeds 1, in both the streaming (agent) and browse (TUI) profiles, without disturbing `<pre>` verbatim content or T5's reserved image rows.

**Success Criteria:**
- [ ] A whitespace-heavy DOM (nested divs/sections stacking block spacing) renders with no run of 3+ consecutive `\n` in flow output, in BOTH the default profile (`render()`) and `renderBrowseModel`, pinned by a co-located test that fails before and passes after.
- [ ] `<pre>`/`<code>` internal newlines are verbatim (unchanged).
- [ ] T5's rows=4 → +3 lines test passes unchanged (reserved image rows are NOT collapsed).
- [ ] `zig build test` zero failures; corpus fixtures that improve are re-blessed with a one-line justification each (never `wikipedia_octopus`); none reddened without one.
- [ ] `zig build test-tls` + `test-h2` green (fingerprint untouched).

**Verification Evidence:**
- Test names + real exit codes for every gate listed above.
- List of re-blessed corpus fixtures with justifications in the commit message.
- Verified note added to `docs/plans/readable-browser-goal.md` under T6 (same format as T3–T5).

**Scope:**
- **In scope:** newline/block-spacing emission in `src/render.zig`'s flow path.
- **Out of scope:** intra-line whitespace collapsing (already done), `browse_heuristics` content picking, `<pre>` rendering semantics, anything in `src/net/`.

**Constraints:**
- Preserve existing behavior unless the task explicitly changes it.
- The streaming default profile must remain single-pass — do not convert it to a buffered approach.
- Do not leave TODO placeholders or undocumented behavior changes.
- Match existing style: `///` doc comments, co-located tests, explicit allocators, `errdefer`.

**Boundaries:**
- May modify: `src/render.zig` (flow/newline path only), `tests/corpus/fixtures/` (re-bless improved fixtures with justification only).
- Must NOT touch: `src/net/` (fingerprint), `src/browse_heuristics.zig`, `src/image/`, governed specs (`spec/MVP.md`, `spec/subspecs/*`, `docs/adr/*`).

**Iteration Policy:**
- Branch off `main` as `fix/t6-whitespace-polish`.
- Implement, add the fail-before/pass-after test, run all gates with real exit codes, `zig fmt src/`.
- If green: check T6 `[x]` in `docs/plans/readable-browser-goal.md` with a Verified note, commit, fast-forward `main`.
- If a corpus fixture is reddened by a legitimate improvement, re-bless with a one-line justification; if reddened without improvement, revert the change.

**Completion Audit:**
- Map every success criterion above to fresh evidence (test names, exit codes, diff of re-blessed fixtures).
- The goal is not complete if any criterion is unverified or only "probably" satisfied.

**Blocked Stop Condition:**
- If the blank-line cap structurally requires buffering/lookahead that degrades the streaming default profile (it must stay single-pass), stop and surface the trade-off — do not convert the streaming path to buffered unilaterally.
- Report attempted paths, exact blocker, and what decision would unblock.
