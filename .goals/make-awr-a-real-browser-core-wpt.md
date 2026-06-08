# Goal — Make AWR an actual browser (core WPT satisfied)

**Objective:** Turn AWR into a real browser for the readable + interactive web —
proven by passing the **core upstream Web Platform Tests** across the
browser-engine subsystems (HTML parsing, DOM, CSSOM + CSS selectors/cascade/
values, layout, UI/DOM events) **and** the JS language (Test262) — by first
finishing the readable-browser ladder (T4–T7), then wiring AWR against the
**real web-platform-tests corpus** and driving each in-scope subsystem to green,
activating Tier 4 (layout) and Tier 5 (SPA/parity) via ADR amendment. Exotic
device/hardware APIs, GPU/media, service workers, and MCP are explicitly out.

**Strategy (decided 2026-06-05):** destination = real upstream WPT (not just the
curated corpus); method = subsystem deep-dives in dependency order. Pull each
subsystem's upstream WPT directory, run it through an AWR harness, fix AWR until
the area meets its pass bar, update governance, commit, keep `main` green.

## Phases (execution order)

- **Phase 0 — Land T3 (in flight):** commit the completed Brotli-decode work on a
  green `main` (`test-tls`/`test-h2`/full `zig build test` green; mdn_select now
  soft-asserted). Precondition for T4.
- **Phase 1 — Finish the readable-browser ladder (T4–T7)** per
  `docs/plans/readable-browser-goal.md`, each on green `main`:
  - T4 — SVG/undecodable `<img>` → alt-text, never a 1×1 blob.
  - T5 — kitty/iterm images reserve their `r` cell-rows (no overlap).
  - T6 — collapse excess structural whitespace without altering article fixtures.
  - T7 — JS-driven pages render usable content **reproducibly** (includes fixing
    the JS-path layout-dependent DOM-mutation nondeterminism found 2026-06-04:
    QuickJS + pointer-keyed DOM bridge mutate the DOM in address-dependent order).
- **Phase 2 — Real-upstream-WPT harness:** vendor the actual `web-platform-tests`
  corpus (git submodule or a pinned in-tree subset under `third_party/`), with a
  deterministic, offline AWR runner that imports real upstream case files and
  reports **per-directory pass/fail counts**. Keep the curated runner as the fast
  merge gate; the upstream harness is the coverage authority.
- **Phase 3 — Subsystem deep-dives** (dependency order), each driven to its pass
  bar: **JS/Test262 → DOM → CSSOM + CSS (selectors, cascade, values, syntax) →
  HTML parsing → UI/DOM events → layout (Tier 4) → dynamic/SPA (Tier 5).** Per
  subsystem: import the upstream WPT dir, run, fix AWR (real implementation) until
  bar met, update `wpt-conformance.md` corpus + counts, commit, fast-forward.
- **Phase 4 — Governance reconciliation:** activate + close Tier 4 and Tier 5 via
  ADR amendment; update `spec/subspecs/browser-roadmap.md`, `spec/MVP.md`, and
  `spec/subspecs/wpt-conformance.md` in the same changes as the code that earns
  each closure.

**Success Criteria:**
- [ ] T4, T5, T6, T7 each `[x]` on green `main` with their gates (Phase 1).
- [ ] A real upstream-WPT harness runs deterministically offline, imports actual
      web-platform-tests case files, and reports per-area pass/fail (Phase 2),
      documented in `spec/subspecs/wpt-conformance.md`.
- [ ] Every **in-scope core subsystem** meets its pass bar: **100% of the
      imported in-scope upstream cases pass**, with any individual skipped case
      justified in-line as genuinely out-of-scope (never skipped for convenience).
      In-scope subsystems: html (parsing/serialization), dom, domparsing, cssom,
      css-syntax, selectors, css-cascade, css-values, css layout the TUI models
      (block/inline/flexbox/grid/positioning), uievents/dom events, plus Test262
      for the JS language.
- [ ] Tier 4 (layout) and Tier 5 (SPA/parity) **activated via ADR amendment and
      closed per their gates**; roadmap/MVP/wpt-conformance updated accordingly.
- [ ] Chrome-132 fingerprint intact (`test-tls` + `test-h2` green) and full
      `zig build test` green at **every** commit.

**Verification Evidence:**
- Upstream-WPT runner logs per subsystem with pass/total counts; the count rises
  monotonically and reaches the bar for each in-scope area.
- `zig build test`, `test-tls`, `test-h2` EXIT 0 (real exit codes, no
  pipe-masking) on each commit; targeted gates (`test-dom`, `test-cssom`,
  `test-js`/`test262`, `test-wpt`, `test-render`, `test-html`) per subsystem.
- Per-subsystem failing→passing case diffs; governance doc diffs; ADR records for
  Tier 4/5 activation + closure.
- Live spot-checks: representative real pages in each area render usably via
  `awr browse` / `awr extract` (PTY/strict-VT method for terminal effects).

**Scope:**
- **In scope:** T4–T7; the real upstream-WPT harness; the core browser-engine
  subsystems + Test262 above; Tier 4 layout engine and Tier 5 SPA/parity
  implementation; vendoring upstream WPT + any required decoders/libs; all
  governance/ADR/spec updates needed to legitimately grow scope and close tiers.
- **Out of scope (NOT failures — excluded by design or deferral):** GPU/WebGL/
  WebGPU, canvas pixel readback, `<video>`/`<audio>` media playback, WebRTC,
  service workers / Cache API / push, Web Bluetooth/USB/Serial/HID/NFC, generic
  sensors, Payment Request, File System Access, and all `browser-roadmap.md §5`
  items; **MCP stdio promotion** (deferred long-term); non-macOS/arm64 platforms;
  per-site anti-bot evasion (Cloudflare/etc.); changing `Accept-Encoding` or any
  network-fingerprint surface.

**Constraints:**
- Never touch `src/net/` header order, cipher order, ALPN, or HTTP/2 SETTINGS;
  revert anything that reddens `test-tls`/`test-h2`.
- Real implementations only — no stubs, TODO placeholders, dead code, faked
  passes, or harness shortcuts that mark an upstream case "pass" without the
  behavior actually working. The decoder/engine must really do the work.
- Preserve existing behavior unless a task explicitly changes it. Do not discard
  the parallel worktree's work or any user changes.
- `main` stays green at every commit; one coherent deliverable per commit.

**Boundaries:**
- **May modify:** `src/**` (engine: dom, cssom, css, html, js, render, page,
  bridge, events, layout), `build.zig`, `tests/**` (runners + corpora),
  `third_party/**` (vendor upstream WPT + libs), and — **authorized for this
  goal** — `spec/**` and `docs/adr/**` (conformance scope, tier contracts, ADRs).
- **Must NOT modify:** network fingerprint emission; excluded-subsystem code
  paths (don't implement WebGL/media/SW/device APIs); corpus fixtures except a
  justified one-line re-bless of a fixture a change legitimately altered (never
  `wikipedia_octopus`).

**Iteration Policy:**
- One subsystem/task per iteration: branch off `main`, implement, add
  failing→passing tests (real upstream cases where applicable), run the area gate
  + `test-tls` + `test-h2` with real exit codes, `zig fmt src/`, commit (code +
  tick the box / bump counts), fast-forward `main`, continue.
- **Unblock, don't skip:** when an area needs a capability AWR lacks, build the
  capability (per `[[prefer-unblocking-over-skipping]]`); only stop for a genuine
  product/ADR decision or a guardrail break.
- When a page decodes/loads but renders blank or wrong, diagnose *why* and route
  it to the right subsystem fix — never call a decoded-but-unreadable page done.
- On gate failure, root-cause and fix (recall the `bufPrintZ` lesson: read the
  real error before theorizing); don't report partial completion.

**Completion Audit:**
- Map every in-scope subsystem and tier to fresh upstream-WPT pass evidence,
  build-gate output, and a live render spot-check. Not complete if any in-scope
  area is unverified, narrowed, deferred, or only "probably" passing, or if any
  non-justified fixture/case is red.
- Tier 4 and Tier 5 are not "closed" until their roadmap gates are met and
  recorded via ADR. "Good enough"/"out of scope for now" is invalid completion
  evidence unless this contract explicitly excludes that area above.

**Blocked Stop Condition:**
- Stop without marking complete if: an in-scope area genuinely requires an
  excluded capability (GPU/media/SW) to pass core cases; a tier activation needs
  a product decision only the user can make; vendoring upstream WPT can't be made
  deterministic/offline after a real attempt; or a fingerprint-safe path to an
  area is impossible. Report attempted paths, evidence, the exact blocker, the
  remaining unmet criteria, and what input would unblock.

---

*Supersedes/extends `.goals/finish-readable-terminal-browser.md` (T1–T7), which
becomes Phase 0–1 of this program. Ledger of record for T4–T7 stays
`docs/plans/readable-browser-goal.md`.*
