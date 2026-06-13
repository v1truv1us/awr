# Goal — Dogfood-ready: fully replace Chrome (real-browser scope)

> Completion contract. Make the project good enough that **the author retires
> Chrome entirely** — every site on the confirmed list below works on both
> surfaces, including app-grade SPAs. Per the author's 2026-06-13 decision,
> **no site is best-effort; all are hard requirements** ("if they aren't
> working I can't move away from Chrome"). This is a *maximal* goal: it
> supersets dogfooding and **activates the deferred Tier-4/5 real-browser
> program**.

## Decided 2026-06-13
- **Bar:** full interaction, **all listed sites are hard requirements** —
  including the app-grade SPAs (Cloudflare dashboard, X). Dogfooding only counts
  if Chrome can be fully retired.
- **Governance consequence (must be honored):** making Cloudflare-dash + X +
  GitHub-PR-approve work requires Tier-4/5 capabilities (dynamic layout,
  History API, MutationObserver, WebSocket, continuous SPA re-render). Those are
  **deferred pending an ADR amendment** (`CLAUDE.md`; `spec/subspecs/browser-roadmap.md §3`;
  governed by `spec/MVP.md §8`). **Phase 2 below cannot start until that ADR
  amendment is authorized.** This is the existing vision track
  `.goals/make-awr-a-real-browser-core-wpt.md`, now activated rather than newly
  invented.
- **Name:** **`descry`** (chosen 2026-06-13; daemon `descryd`) — clean namespace
  verified across 3 research rounds; fits "discern a remote page". Applied last
  (Phase 3); gates nothing until then.
- **Sequencing:** Phase 1 (achievable core, *active scope*, launchable now) →
  Phase 2 (Tier-4/5 SPA program, *ADR-gated*) → Phase 3 (rename + closure).
- **Architecture is negotiable; the outcome is not (decided 2026-06-13).** The
  invariant is a terminal-UX browser that *fully replaces Chrome* for the sites
  below. The current Zig + QuickJS + lexbor reader (which *fakes* Chrome at the
  TLS/H2 layer) is the default means, not a constraint. If the X feasibility
  spike (P2.0) shows that architecture has a ceiling below this goal, that
  triggers an **architecture-pivot evaluation** — a documented ADR comparing
  (A) deepen the Zig engine, (B) embed/drive a real web engine and render it to
  the terminal (the Browsh/Carbonyl approach; makes the hand-built fingerprint
  moot because you *are* Chrome), or (C) a hybrid (Zig fast-path + real-engine
  fallback for hard SPAs). The pivot is NOT abandonment of the goal, and the
  spike must therefore *characterize the exact failure mode*, not just pass/fail.
- **vs the public plan:** hostile-input hardening (B1/B2/B4), Linux/contributor
  work (D1), swallow/panic audits (D2–D5) stay deferred to
  `.goals/v0_1-public-readiness.md`. CI (A1) is done and guards every commit.

## Objective
Reach a state where, on the author's confirmed site list, the runtime renders
usable content, persists logins, and completes the real interactive workflow on
**every** site — such that Chrome can be fully retired — and ships under a new
name with the Chrome-132 fingerprint and all gates intact.

---

## Acceptance backbone — confirmed daily-driver site list (all hard requirements)

| # | Site | Workflow that must succeed | Phase | Difficulty |
|---|------|----------------------------|-------|------------|
| 1 | news.ycombinator.com | read all; search; open + read linked articles; **post an article** (form POST + auth) | P1 | low–med |
| 2 | AudioFile.app | renders + supplies properly (SSR confirmed; JS-settle for the "Loading…" sections) | P1 | low–med |
| 3 | github.com | log in (session persists); navigate; **view PRs** | P1 | med |
| 3b| github.com | **approve a PR** (JS-driven review-submit) | P2 | hard |
| 4 | google.com | **search actually works** — render is T7; live bot-detection is the wildcard | P1 render / P2 if live-walled | hard |
| 5 | dash.cloudflare.com | **manage DNS** (authenticated React SPA) | P2 | very hard |
| 6 | x.com | **view tweets; sign in** (React SPA + adversarial anti-automation) | P2 | highest risk |
| — | homepage site | project landing page — separate, deferred decision; not a daily-driver blocker | later | n/a |

## Success criteria
- [ ] Every row above works on both surfaces it's exercised on — no blank
      shells, no silent truncation, login/session persists, the named
      interactive action returns the expected rendered result.
- [ ] Phase 2 ADR amendment authorized + recorded (`spec/MVP.md §8`) before any
      Tier-4/5 implementation.
- [ ] New name chosen and applied everywhere (binary, daemon, CLI, repo, docs,
      `spec/*`); fingerprint byte-identical.
- [ ] Closure audit maps every row to fresh evidence with a real exit code.

## Verification evidence (before any `[x]`)
- Per-site transcripts (live `<cmd> …` / `<cmd> browse …` or a hermetic fixture
  of the site's shape) showing the workflow completing, real exit codes.
- Co-located tests for each capability gap closed (T7 render, content-loss,
  form-POST, session persistence, and the Phase-2 SPA-engine pieces).
- `zig build test` zero failures; `test-tls` + `test-h2` green every commit
  (Chrome-132 intact) — **non-negotiable**.
- CI green on `main` per landed change.

---

## Phase 1 — Achievable daily-driver core (ACTIVE SCOPE — launchable now)
Delivers real daily-driver value in weeks; within active Tier-1/T7 scope.
- **P1.1 — Content-loss fix (B3).** Kill the silent >8 KB text-node truncation
  (`src/render.zig:2806,3428`); >8 KB node survives in both profiles; `<pre>`
  + `pending_space` semantics preserved. **✓ Landed 2026-06-13** — stack/heap
  split in `renderTextNode`; co-located 9 KB-node test (fails-before/passes-
  after) asserts the tail survives in both profiles; `test-page`/`test-tls`/
  `test-h2` exit 0; `src/net/` untouched.
- **P1.2 — T7: JS-driven pages render usable content.** Post-load JS settle /
  re-render so Google results, AudioFile's dynamic sections, and a hermetic
  light-SPA fixture render content not blank shells; fix the pointer-keyed-bridge
  mutation-ordering nondeterminism (2026-06-04). Files: `src/page.zig`,
  `src/js/*`, `src/dom/bridge.zig`, `src/browse_heuristics.zig`. **NOT** `src/net/`.
- **P1.3 — Forms + POST + session persistence.** Audit existing coverage
  (agent-browser spec scopes `fetch`/XHR POST, `<form method=post>`, cookie
  persistence) against HN-post + GitHub-login, then fill gaps. Transcript shows
  login persisting + a form action returning the expected page.
- **P1.4 — TUI interaction parity.** The read→navigate→fill→submit→follow loop
  works from `<cmd> browse`, not only the agent surface (`src/browser.zig`,
  `src/tui.zig`).
- **P1.5 — Phase-1 closure audit.** HN, AudioFile, GitHub-read, Google-render
  each mapped to fresh evidence; Verified note in the T3–T6 ledger format.

## Phase 2 — Tier-4/5 real-browser program (ADR-GATED — DO NOT START W/O §8 SIGN-OFF)
- **P2.0 — Governance (decided 2026-06-13: spike-first).** **X feasibility spike
  FIRST** — confirm whether an authenticated X session is even reachable for this
  architecture (the load-bearing risk) — then a formal go/no-go on the full
  Phase-2 build after Phase 1 lands. Draft the ADR amendment un-deferring
  Tiers 4-5 (references `.goals/make-awr-a-real-browser-core-wpt.md`) in parallel
  so it's ready; land it per `spec/MVP.md §8` only on a "go" decision.
- **P2.1 — Dynamic-SPA engine foundations.** History API, MutationObserver,
  WebSocket, continuous JS-driven re-render — the shared capability behind
  CF-dash, X, and GitHub-approve. (May force touching `render.zig`; coordinate
  with the still-deferred god-file split.)
- **P2.2 — Cloudflare dashboard:** authenticated DNS management end-to-end.
- **P2.3 — GitHub PR approve:** the JS review-submit flow.
- **P2.4 — X: view tweets + sign in.** HIGHEST STRUCTURAL RISK — adversarial
  anti-automation built to defeat non-Chrome clients (Arkose/JS challenges,
  behavioral fingerprinting) that flags even real headless Chrome. Treated as a
  hard requirement, but with an explicit **Blocked-Stop** if proven structurally
  infeasible after real attempts — documented with evidence, never silently
  dropped.
- **P2.5 — Phase-2 closure audit.**

## Phase 3 — Rename + final closure
- **P3.1 — Rename.** Apply the chosen name everywhere (binary `awr`/`awrd`, CLI,
  `build.zig` artifacts, repo refs, `README.md`/`CLAUDE.md`/`AGENTS.md`,
  `spec/*`). **Never touch `src/net/` order or HTTP/2 SETTINGS** — fingerprint is
  name-independent. Governed docs follow `spec/MVP.md §8`.
- **P3.2 — Full closure audit** across all sites + both surfaces.

---

## Guardrails (every iteration)
1. **Fingerprint sacred.** Never touch `src/net/` header/cipher/ALPN order or
   HTTP/2 SETTINGS. `test-tls` + `test-h2` before every commit; revert on red.
2. **Governance.** Tier-4/5 (Phase 2) and any `spec/MVP.md`/`spec/subspecs/*`/
   `docs/adr/*` scope change follows `spec/MVP.md §8` and explicit sign-off — not
   done silently in the loop. **Phase 2 is blocked until P2.0 lands.**
3. **No stubs.** Real implementations only.
4. **Commit discipline.** Branch off `main`; co-located test fails-before/
   passes-after; task gate + `test-tls` + `test-h2` with real exit codes;
   `zig fmt src/`; commit (code + tick); fast-forward `main`.
5. **Verify, don't assume.** Real exit codes; trust EXIT 0, not the benign
   `failed command:` artifact.
6. **Tiered model routing.** haiku = read/search/test, sonnet = code, session
   model = planning/synthesis.

## Out of scope (deferred to the public-readiness plan, not this goal)
- Hostile-input resource budgets (B1/B2/B4), Linux/contributor de-Homebrewing
  (D1), swallow/panic/provenance audits (D2–D5).
- God-file split — deferred, but Phase 2 engine work may force coordinated
  touches to `render.zig`; flag if so.

## Risks / honest uncertainties
- **X-authenticated may be structurally infeasible.** Adversarial anti-automation
  targets exactly this; even real headless Chrome is flagged. Biggest risk; a
  feasibility spike (P2.0) should precede the full Phase-2 commitment.
- **Phase 2 is months-scale**, not weeks — it's a real browser engine, not a few
  milestones. Phase 1 is the near-term value.
- **Google live bot-detection** may wall a perfect Chrome-132 client; render
  (T7) and detection are separate problems.
- **T7 nondeterminism** must be fixed, not papered over.

## Completion audit
Map every success-criterion checkbox and every site row to fresh evidence (test
names + real exit codes, per-site transcripts, CI links, the rename build
transcript, the landed ADR amendment). Not complete if any row is unverified,
narrowed without the author agreeing, or only "probably" working, or if any gate
is red, or if Phase 2 ran without the ADR.

## Blocked stop condition
Stop and surface (don't loop past) if: the Phase-2 ADR amendment isn't
authorized (Phase 2 cannot start); a requirement can't be met without perturbing
the fingerprint; or any governed change needs a §8 sign-off not yet given.
**If X-authenticated (or any hard requirement) proves infeasible in the current
architecture after real attempts, that is NOT a terminal stop — it triggers the
architecture-pivot evaluation above:** characterize the exact failure mode (TLS?
empty JS shell? DOM never builds? adversarial challenge?), then decide
deepen-vs-embed-vs-hybrid via ADR. Report attempted paths, evidence, the exact
blocker, and which pivot the failure mode points to.
