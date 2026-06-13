# AWR — Repository Audit & Improvement Plan

**Date:** 2026-06-11
**Auditor:** principal-engineer audit (four-phase, evidence-based)
**Commit audited:** `effde7a` (main, green: `zig build test`/`test-tls`/`test-h2`/`test-corpus` all exit 0)

> **Review-depth note.** The multi-agent fan-out for this audit hit the session
> usage limit mid-run, so Phases 1–2 were completed single-threaded by direct
> file inspection. Core flow (`main`, `client`, `net/http1`, `page`, `render`,
> `main_daemon`) received deep review. Lighter review: `dom/bridge.zig` (3955
> LOC), `js/engine.zig` internals, `image/` pipeline, `cssom/` cascade. Findings
> below are what I verified by reading the cited code; speculative items are
> labelled **judgment** and flagged for follow-up rather than asserted.

---

## 1. Executive Summary

**Overall health grade: B.** AWR is a disciplined, working pre-1.0 product with
an unusually strong correctness culture for its size — ~1330 co-located tests
plus WPT/Test262 conformance gates and a snapshot corpus with a bless workflow.
The architecture is coherent and the memory/`errdefer` conventions are applied
consistently. What holds it back from an A is **operational and resource-safety
maturity**, not correctness: there is no CI, hostile-input resource budgets are
missing, and a handful of files have grown into god-objects that raise the cost
of every change. None of these block shipping today, but each compounds as the
project grows or takes external contributors.

**Top 3 risks**

1. **No CI** (`.github/workflows` absent) — ~1330 tests and the fingerprint
   gates run only when a human remembers to. The TLS/JA4 fingerprint *is the
   product*, and nothing automatically guards it on push/PR.
2. **No decompressed-size cap** — gzip/zstd/brotli decoders stream into
   unbounded buffers (`src/client.zig:1324/1339/1382`). A zip-bomb from any
   fetched server is a trivial remote OOM/DoS, directly contradicting the
   "parses hostile web content" threat model.
3. **God files** — `render.zig` (4835), `dom/bridge.zig` (3955),
   `browser.zig` (3664), `page.zig` (3119) concentrate many responsibilities,
   raising merge-conflict surface and onboarding cost.

**Top 3 opportunities**

1. A ~40-line CI workflow turns the existing test wealth into an enforced gate
   (highest leverage in the repo).
2. A shared decompressed-size budget (one helper, threaded through 3 decoders +
   the chunked/content-length paths) closes the DoS class with one small change.
3. Loud-failure pass: audit the 97 `catch {}` sites and fix the silent 8 KB
   text-node truncation so the renderer degrades visibly, not quietly.

---

## 2. Repo Map

**Purpose.** A dual-surface CLI-first terminal browser in Zig: one binary serving
a human TUI (`awr browse`) and an agent surface (`awr <url>` / `extract` / `tools`
/ `call`, JSON/Markdown/WebMCP). Core differentiator: a Chrome-132 TLS/JA4
fingerprint + HTTP/2 SETTINGS that must stay byte-stable.

**Stack.** Zig 0.16 (pinned, matches installed). Vendored: BoringSSL (prebuilt
static, macOS/arm64), Brotli, stb_image, libxev + zig-quickjs-ng (local paths in
`build.zig.zon`), Mozilla CA bundle. Homebrew-coupled: nghttp2, lexbor. macOS/arm64
primary; Linux paths present but secondary.

**Architecture sketch.** `main.zig` (CLI entry, arg parse, daemon handshake) →
`client.zig` (TLS + H1/H2 + cookies + redirects + pooling) → `page.zig`
(fetch→parse→DOM→JS→render orchestration) → `render.zig` (terminal renderer) /
`browser.zig` (TUI session). `dom/` (tree + JS bridge), `js/` (QuickJS wrapper),
`html/` (lexbor wrapper), `net/` (TLS/H1/H2/TCP/pool/cookie/url — the fingerprint
zone), `cssom/` (starter cascade), `image/` (decode + kitty/iterm/sixel/braille).
Daemon (`main_daemon.zig`) amortizes session over a Unix socket.

**Key directories.** `src/` 39,458 LOC across 60+ files; `spec/` (MVP + PRD + 15
subspecs) and `docs/adr/` (3 ADRs) hold execution authority; `tests/` (corpus,
WPT, Test262, integration, bench runners); `third_party/` (vendored deps with
`BUILD_NOTES.md`); `scripts/` (bootstrap + smoke harnesses).

**Conventions (already in use — recommendations should fit these).** `///` file
doc-comments; co-located `test "..."` blocks; explicit `Allocator` params;
`errdefer` on failure paths; `ArrayList` (not Unmanaged) header storage to
preserve order for fingerprinting. These are followed consistently.

**Surprises.**
- `render.zig`'s render functions take `w: anytype` but are *always* instantiated
  with the internal `BufferWriter` — genericity without a second caller.
- The renderer carries a full mini-CSS cascade (color→ANSI mapping, specificity,
  `!important`) — more than a "terminal text formatter" implies.
- Despite the test wealth, there is **zero** CI configuration.

---

## 3. Audit Report

Severity: **Critical / High / Medium / Low**. Each finding tagged **fact**
(verifiable at the citation) or **judgment**.

### Security — threat model is "parse hostile web content"

- **S1 — No decompressed-size cap (zip-bomb DoS).** **High / fact.**
  `inflateFlateBody` (`src/client.zig:1324`), `inflateZstdBody`
  (`src/client.zig:1339`), `inflateBrotliBody` (`src/client.zig:1382`) each
  `streamRemaining`/loop into an unbounded `std.Io.Writer.Allocating`. A tiny
  compressed body can expand to GBs. *Consequence:* any server AWR fetches can
  force OOM/crash — a one-response remote DoS. No `max_decompressed_bytes` guard
  exists.
- **S2 — No total-body / chunk-count cap on reads.** **Medium / fact.**
  `readChunkedBody` (`src/net/http1.zig:289`) `buf.resize`s per chunk with no
  ceiling on assembled size or chunk count; the Content-Length path
  (`src/net/http1.zig:240`) does `allocator.alloc(u8, cl)` up front from an
  attacker-controlled `Content-Length` (a 4 GB header → 4 GB allocation attempt
  before any bytes arrive). *Consequence:* same DoS family as S1, on the
  un-compressed path.
- **S3 — Daemon socket falls back to world-readable `/tmp`.** **Medium /
  judgment.** `resolveRuntimePath` (`src/main_daemon.zig:682`) uses
  `${XDG_RUNTIME_DIR:-/tmp}`; macOS does not set `XDG_RUNTIME_DIR` by default, so
  the socket lands at `/tmp/awrd-${UID}.sock`, created via `ua.listen(io, .{})`
  with no explicit mode. The daemon shares one cookie jar/session across clients.
  The *pidfile* is `0o600` (`src/main_daemon.zig:734`) but that does not constrain
  the socket. *Consequence (unverified):* on a shared host another local user may
  connect and drive authenticated fetches through the shared session. **Action:**
  verify the socket's actual permissions; if not `0700`/owner-only, set mode and/or
  place it under a `0700` per-UID dir.

### DevEx & Operations

- **X1 — No CI.** **High / fact.** No `.github/workflows`, GitLab, Woodpecker, or
  Jenkins config exists. ~1330 tests + `test-tls`/`test-h2`/`test-wpt`/`test262`/
  `test-corpus` gates are defined in `build.zig` but never run automatically.
  *Consequence:* green-main is a manual ritual; fingerprint/behaviour regressions
  can land unnoticed. This is the single highest-leverage gap in the repo.
- **X2 — `zig fmt` not enforced.** **Medium / fact.** Formatting is a manual step
  in `CLAUDE.md`; without CI or a pre-commit hook, drift is inevitable.
- **X3 — Diagnostic noise: `[JS error] {}`.** **Low / fact.**
  `src/js/engine.zig:134` emits `[JS error] ` with an empty/contextless payload;
  it floods corpus/test stderr (seen repeatedly in this audit's runs) and would
  bury a real JS error in the field. *Consequence:* poor observability.

### Architecture & Design

- **A1 — God files.** **Medium / fact.** Files over 2000 LOC: `render.zig` 4835,
  `dom/bridge.zig` 3955, `browser.zig` 3664, `page.zig` 3119, `client.zig` 2394,
  `main.zig` 2173. `render.zig` alone mixes flow rendering, a CSS cascade +
  color→ANSI mapping, table layout, code syntax-highlighting, image emission, and
  ScreenModel construction. *Consequence:* high merge-conflict surface, hard
  unit isolation, slow onboarding. (Calibrated: acceptable for a solo pre-1.0,
  but the trend line is the concern.)
- **A2 — `anytype` writer with a single instantiation.** **Low / judgment.**
  Render functions are generic over `w: anytype` yet only ever receive
  `BufferWriter` (`src/render.zig`). The genericity adds reading cost (you must
  prove the concrete type to reason about `w.trailing_newlines`, as T6 required)
  without buying a second backend.

### Code Quality

- **Q1 — 97 empty `catch {}` swallow sites.** **Medium / fact.** Concentrated in
  `render.zig` (19), `browser.zig` (16), `js/engine.zig` (15), `page.zig` (14).
  Some are legitimately best-effort (rendering a glyph), but blanket swallowing in
  the JS/page path hides real failures. *Consequence:* silent degradation that is
  hard to diagnose from the field.
- **Q2 — 23 `unreachable`/`@panic` in non-test code.** **Low / fact / needs
  triage.** Not yet traced to wire-reachable paths. *Consequence:* if any is
  reachable from hostile input, the browser aborts. **Action:** classify each as
  invariant-guaranteed vs input-reachable.
- **Q3 — Silent 8 KB text-node truncation.** **Medium / fact.** `renderTextNode`
  uses `var buf: [8192]u8` (`src/render.zig:2806`) and `normalizeWhitespace`
  stops writing at `buf.len` (`src/render.zig:3428`, `if (i < buf.len)`). A single
  DOM text node longer than 8192 bytes (common: long paragraphs, minified inline
  text) is **silently truncated** in both surfaces. *Consequence:* real content
  vanishes mid-node with no error — a correctness bug, not just perf.

### Testing — a genuine strength

- **Healthy.** ~1330 tests; 65 in `render.zig`, 48 `net/cookie.zig`, 46
  `page.zig`, 39 `client.zig`, plus WPT/Test262/corpus snapshot gates and graceful
  network-skip. Tests assert behaviour, not just execution (e.g. the T6 fail-
  before/pass-after pinning added this session).
- **T1 — Thin coverage on the entry point.** **Medium / fact.** `main.zig` has 3
  test blocks for 2173 LOC — arg parsing, command dispatch, and daemon handshake
  are under-tested relative to their role as the sole CLI surface. *Consequence:*
  flag/routing regressions can slip past the suite.

### Performance

- **P1 — Per-element CSS matching, already mitigated.** **Low / fact.** Prior
  O(elements×rules) hot path is cut via pre-filtered rule lists and a complex-
  selector cap (`exact_complex_selectors = compiled.count() <= 48`, `render.zig`).
  Invariant holds in code; watch when adding text properties.
- **P2 — Fixed 8 KB whitespace buffer.** **Low / fact (cross-ref Q3).** Avoids a
  per-text-node heap alloc, but the fixed cap trades a silent correctness bug for
  the saved allocation — wrong tradeoff.

### Dependencies

- **D1 — BoringSSL pinned by bare commit, no date.** **Medium / fact.**
  `third_party/boringssl/COMMIT_HASH` = `664a985…`, prebuilt static libs, manual
  multi-step refresh (`BUILD_NOTES.md`). No signal for whether the pinned rev
  carries known CVEs. *Consequence:* a security-critical TLS lib can silently age.
- **D2 — Homebrew paths hardcoded.** **Medium / fact.** nghttp2
  (`build.zig:47/51` → `/opt/homebrew/opt/libnghttp2`) and lexbor default prefix
  (`build.zig:57`). *Consequence:* non-Homebrew/Linux contributors must override
  flags to build; onboarding friction and a reproducibility gap.
- **D3 — CA bundle freshness.** **Low / fact.** `third_party/ca-bundle/cacert.pem`
  Mozilla data "last updated Wed Feb 11 2026" (~4 months old) — currently fine;
  needs a documented refresh cadence.
- **Strength.** App-level deps are minimal and path-pinned (libxev, quickjs-ng).

### Documentation — a strength

- **Healthy.** `spec/MVP.md` (244), PRD (329), 15 subspecs, 3 ADRs, plans, `.goals`,
  `AGENTS.md`, `CLAUDE.md`. The execution-authority chain (ADR 0001 + CLAUDE.md) is
  explicit and unusually disciplined.
- **DOC1 — `--version` claim is accurate (verified, not a finding).** README's
  `0.0.<git-hash>` matches runtime behaviour (`build_opts.git_hash`,
  `src/main.zig:517-520`); the `version = "0.1.0"` in `build.zig.zon` is a separate
  manifest field. Verified to avoid a false positive.
- **DOC2 — Governance ceremony vs project size.** **Low / judgment.** spec + ADR +
  plans + `.goals` + two AGENT files is heavy for a solo project. *Trade-off, not a
  defect:* justified IF fingerprint-stability discipline demands the paper trail;
  worth a conscious "keep" decision rather than drift.

### Strengths to preserve

Consistent `errdefer`/allocator discipline; co-located test culture; WPT/Test262
conformance gates; snapshot corpus + bless workflow; explicit header-order
preservation for the fingerprint; single-pass streaming renderer; clear spec
governance.

---

## 4. Improvement Strategy

**Themes that explain most findings:**

1. **Enforcement is manual (X1, X2).** *Target:* every gate runs on push/PR.
   *Principle:* a test that doesn't run automatically is a test you don't have.
2. **No resource budgets on hostile input (S1, S2).** *Target:* bounded memory
   for any single response regardless of server behaviour. *Principle:* a content-
   parsing client must treat every upstream byte as adversarial.
3. **Silent failure modes (Q1, Q3, X3).** *Target:* failures are logged or
   surfaced, never swallowed; no silent truncation. *Principle:* fail loud (the
   repo's own `CLAUDE.md` Rule 12).
4. **Concentration in god files (A1).** *Target:* no single file owns >~3 distinct
   subsystems; `render.zig`'s CSS/color and table/highlight concerns split out.
   *Principle:* one reason to change per module.
5. **Platform/supply-chain coupling (D1, D2).** *Target:* a documented, ideally
   scripted, build on a clean macOS *and* Linux box without hand-editing paths;
   a dated BoringSSL provenance record. *Principle:* reproducible, auditable deps.

**Explicitly NOT recommending (trade-offs):**

- Don't dismantle the spec/ADR governance (DOC2) — for a fingerprint-critical
  product the paper trail is earning its keep; just make the "keep" deliberate.
- Don't refactor god files speculatively before CI exists (Milestone 0 first) —
  refactoring without an automated safety net is how the fingerprint breaks.
- Don't replace the `anytype` writer (A2) — cosmetic; not worth the churn.

**"Done" signals (measurable):**

- CI runs `zig build test` + `test-tls` + `test-h2` + `zig fmt --check` on every
  push and PR; red CI blocks merge.
- A `max_decompressed_bytes` (and total-body) budget enforced on all four read/
  decode paths, with tests proving a bomb is rejected, not absorbed.
- Zero silent truncation: text nodes of any length render fully (Q3 fixed + test).
- `catch {}` sites either log or carry a one-line justification comment; count
  tracked.
- A documented build that succeeds on clean macOS arm64 and Linux x86_64 without
  manual path edits.

---

## 5. Task Plan

Effort: **S** <2h · **M** half-day · **L** 1–2 days · **XL** needs breakdown.

### Milestone 0 — Safety net (do first)

| # | Task | Files | Acceptance | Effort | Risk |
|---|------|-------|-----------|--------|------|
| 0.1 | **Add CI workflow** | `.github/workflows/ci.yml` (new) | Push/PR runs build + `test` + `test-tls` + `test-h2` + `zig fmt --check`; red blocks merge | M | Low |
| 0.2 | **`zig fmt --check` in CI** | same workflow | CI fails on unformatted code | S | Low |

### Milestone 1 — Critical fixes (security & correctness)

| # | Task | Files | Acceptance | Effort | Risk |
|---|------|-------|-----------|--------|------|
| 1.1 | **Decompressed-size budget** | `src/client.zig:1324/1339/1382` + a shared cap | Each decoder aborts with a typed error past `max_decompressed_bytes`; test with a bomb fixture | M | Med (don't perturb success path) |
| 1.2 | **Body/chunk caps** | `src/net/http1.zig:240/289` | Reject Content-Length and assembled chunked bodies over a ceiling; test | S–M | Low |
| 1.3 | **Fix silent text-node truncation** | `src/render.zig:2806,3428` | Text node >8 KB renders fully (heap-grow or chunked normalize); pinned test | S | Low |
| 1.4 | **Verify + harden daemon socket perms** | `src/main_daemon.zig:682,73` | Socket is owner-only (mode and/or `0700` parent dir); test/asserts path perms | S | Low |

### Milestone 2 — High-leverage

| # | Task | Files | Acceptance | Effort | Risk |
|---|------|-------|-----------|--------|------|
| 2.1 | **Audit the 97 `catch {}`** | repo-wide | Each logs or carries a justification; JS/page-path swallows surfaced | M | Low |
| 2.2 | **Triage `unreachable`/`@panic`** | repo-wide (23) | Each classified invariant vs input-reachable; reachable ones become typed errors | M | Med |
| 2.3 | **De-Homebrew the build** | `build.zig:47–57` | Clean macOS + Linux build with no manual path edits (pkg-config or vendored) | M–L | Med |
| 2.4 | **`main.zig` CLI test coverage** | `src/main.zig` + tests | Arg parse + command dispatch covered (happy + error) | M | Low |

### Milestone 3 — Quality & polish

| # | Task | Files | Acceptance | Effort | Risk |
|---|------|-------|-----------|--------|------|
| 3.1 | **Split `render.zig`** | `src/render*.zig` | CSS/color + table + highlight extracted to modules; no behaviour change (corpus byte-identical) | L | Med |
| 3.2 | **`[JS error]` context** | `src/js/engine.zig:134` | Error includes message + source location; no empty `{}` | S | Low |
| 3.3 | **BoringSSL provenance + CA cadence** | `third_party/boringssl/`, `ca-bundle/` | COMMIT_HASH gains a date + upstream tag; documented refresh cadence | S | Low |

### Quick wins (high impact, S effort — do immediately)

- **0.1/0.2 CI + fmt-check** — converts existing test wealth into enforcement.
- **1.2 body/chunk caps** and **1.3 truncation fix** — small, well-bounded.
- **3.2 `[JS error]` context** — instant observability gain.

### Top-3 implementation sketches

**1.1 Decompressed-size budget.** Add `max_decompressed_bytes: usize` to
`ClientOptions` (default e.g. 64 MB). Thread it into the three `inflate*` helpers;
in each loop, after `out.writer.writeAll(...)`, check `out` length and return
`error.DecompressedBodyTooLarge` once exceeded (free the partial via the existing
`errdefer out.deinit()`). *Gotcha:* the Brotli/zstd window buffers are separate
allocations — cap the *output*, not the window. Add a fixtures test: a small
`.gz`/`.br` that expands beyond the cap must error, not OOM.

**0.1 CI workflow.** `.github/workflows/ci.yml`: matrix start with
`macos-14` (arm64); `brew install nghttp2 lexbor cmake ninja go`; run
`scripts/bootstrap_deps.sh`; `zig build test`, `test-tls`, `test-h2`,
`zig fmt --check src/`. *Gotcha:* BoringSSL is vendored (no build step) but lexbor
needs `bootstrap_lexbor.sh` + `-Dlexbor-prefix`; pin the Zig version to 0.16.0 via
`mlugg/setup-zig`. Linux is Milestone-2.3 (needs de-Homebrewing first).

**1.3 Text-node truncation.** Replace the fixed `[8192]u8` in `renderTextNode`
with a path that handles `raw.len > 8192`: either grow a heap buffer
(`allocator.alloc(raw.len)` + `defer free`) or normalize in streamed chunks
through `flowWord`. *Gotcha:* preserve the `pending_space` cross-node semantics
and `<pre>` exemption; add a test with a >8 KB single text node asserting the
tail survives in both profiles.

---

## 6. Open Questions (need a human decision)

1. **Resource ceilings** — what `max_decompressed_bytes` / `max_body_bytes` fit
   AWR's real targets (Wikipedia/GitHub render in the README; some pages are
   large)? Needs a product number, not a guess.
2. **Linux as a supported target** — is first-class Linux support a goal (drives
   Milestone-2.3 priority and CI matrix), or is macOS/arm64 authoritative for now?
3. **Daemon multi-user model** — is the daemon ever expected to run on a shared
   host? The answer sets whether S3 is "harden now" or "document single-user".
4. **Governance cadence** — keep the full spec/ADR/plans/.goals ceremony, or
   consolidate now that the MVP surface is closing?
5. **god-file split appetite** — is a behaviour-preserving `render.zig` split
   (3.1) worth an L-effort change pre-1.0, given the corpus makes it verifiable?
