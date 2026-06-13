# Goal — AWR v0.1 public + contributor readiness

> Executable readiness contract. Turns the 2026-06-11 repo audit
> (`reports/2026-06-11-repo-audit.md`) plus the open readable-browser tasks
> (T7/T8 in `docs/plans/readable-browser-goal.md`) into the ordered set of work
> that must land before AWR is handed to **real public users on the arbitrary
> web AND external code contributors**. One task per iteration, each
> independently verifiable, `main` green at every commit.

**Audience (decided 2026-06-13):** *all of the above* — public users pointing
AWR at hostile/arbitrary sites, and external contributors building/hacking the
codebase. This is the strictest readiness bar short of the Tier-4/5 "real
browser" program, which stays deferred.

**Objective:** Reach a state where (a) no single fetched response can crash or
exhaust AWR, (b) every gate runs automatically on push/PR so the Chrome-132
fingerprint can't regress unnoticed, (c) a fresh clone builds on clean macOS
arm64 *and* Linux x86_64 without hand-editing paths, (d) JS-driven pages render
usable content rather than blank shells, and (e) field failures are
diagnosable, not silently swallowed.

---

## Definition of done

All success criteria below are `[x]`, and on `main`:
- `zig build` green; both `awr` and `awrd` build.
- `zig build test` zero failures.
- `zig build test-tls` + `zig build test-h2` green (Chrome-132 fingerprint
  intact) — **non-negotiable**.
- CI runs the above on every push/PR and red blocks merge.
- A documented build succeeds on clean macOS arm64 and Linux x86_64 with no
  manual path edits.

## Guardrails (apply every iteration)

1. **Fingerprint is sacred.** Never touch `src/net/` header order, cipher order,
   ALPN, or HTTP/2 SETTINGS. `test-tls` + `test-h2` before every commit; revert
   on red. (Resource caps live on the *decode/read* path, never on header
   emission.)
2. **Governance.** Any change to `spec/MVP.md`, `spec/subspecs/*`, or
   `docs/adr/*` scope/authority follows `spec/MVP.md §8` change-control and is
   surfaced for explicit sign-off — not done silently in the loop.
3. **No stubs.** Real implementations only; no TODO placeholders or dead code.
4. **Commit discipline.** Branch off `main` (`feat/`|`fix/`|`chore/<task-id>`),
   implement, add a co-located test that fails before / passes after, run the
   task gate + `test-tls` + `test-h2` with real exit codes, `zig fmt src/`,
   commit (code + tick the box), fast-forward `main`.
5. **Verify, don't assume.** Real exit codes (no pipe-masking). Trust EXIT 0,
   not the benign `failed command:` artifact the build prints on pass.

---

## Open decision needed before Milestone B

**Resource ceilings (audit §6.1):** the concrete `max_decompressed_bytes` and
`max_body_bytes` values. README renders Wikipedia/GitHub/SO today; some are
large. Needs a product number, not a guess. *Proposed defaults pending sign-off:
`max_decompressed_bytes = 64 MiB`, `max_body_bytes = 32 MiB` — large enough for
real target pages, small enough to bound a single hostile response.* B1/B2 are
blocked on confirming or adjusting these.

---

## Tasks (do in order — safety net first, then hostile-input, then the gap)

### Milestone A — Safety net (do first; lowest risk, highest leverage)

#### [ ] A1 — CI workflow (build + full gates on push/PR)
**Why:** ~1330 tests + the fingerprint gates run only when a human remembers
(audit X1). The fingerprint *is* the product; nothing guards it automatically.
**Files:** `.github/workflows/ci.yml` (new).
**Approach:** `macos-14` (arm64) leg: pin Zig 0.16.0 via `mlugg/setup-zig`;
`brew install nghttp2 lexbor cmake ninja go`; run `scripts/bootstrap_deps.sh` +
`scripts/bootstrap_lexbor.sh`; then `zig build test`, `test-tls`, `test-h2`,
`zig fmt --check src/`. Red blocks merge. (Linux leg added in D1, after
de-Homebrewing.)
**Done/verify:** a PR shows the workflow running all gates; an intentionally
unformatted / fingerprint-breaking commit shows red blocking. Keys off exit
codes only.

### Milestone B — Hostile-input resource budgets & correctness

#### [ ] B1 — Decompressed-size budget (zip-bomb defense)
**Why:** `inflateFlateBody`/`inflateZstdBody`/`inflateBrotliBody`
(`src/client.zig:1324/1339/1382`) stream into unbounded buffers; a tiny body can
expand to GBs → one-response remote OOM (audit S1).
**Approach:** add `max_decompressed_bytes` to `ClientOptions`; thread into the
three `inflate*` helpers; after each write, if output exceeds the cap return
`error.DecompressedBodyTooLarge` (free partial via existing `errdefer`). Cap the
*output*, not the window buffers.
**Done/verify:** a fixtures test — a small `.gz`/`.br` that expands past the cap
**errors, not OOMs**; success path byte-identical; `test-client`/`test-net`
green.

#### [ ] B2 — Total-body / chunk caps
**Why:** `readChunkedBody` (`src/net/http1.zig:289`) grows per chunk with no
ceiling; the Content-Length path (`:240`) `alloc`s an attacker-controlled length
up front (audit S2).
**Approach:** reject assembled chunked bodies and up-front Content-Length
allocations over `max_body_bytes` with a typed error before committing memory.
**Done/verify:** test rejecting an oversized Content-Length header and an
over-ceiling chunked assembly; normal bodies unaffected.

#### [ ] B3 — Fix silent 8 KB text-node truncation
**Why:** `renderTextNode` uses `var buf: [8192]u8` and `normalizeWhitespace`
stops at `buf.len` (`src/render.zig:2806,3428`); a text node >8 KB is **silently
truncated** in both surfaces — real content vanishes (audit Q3).
**Approach:** handle `raw.len > 8192` (heap-grow with `defer free`, or chunked
normalize through `flowWord`), preserving `pending_space` cross-node semantics
and the `<pre>` exemption.
**Done/verify:** a >8 KB single-text-node test asserts the tail survives in both
the default and browse profiles.

#### [ ] B4 — Daemon socket owner-only perms
**Why:** `resolveRuntimePath` falls back to `/tmp/awrd-$UID.sock` (no
`XDG_RUNTIME_DIR` on macOS); the daemon shares one authenticated cookie jar
across clients (audit S3). On a shared host another local user may drive the
session.
**Approach:** verify the socket's actual mode; enforce owner-only (socket mode
and/or a `0700` per-UID parent dir), matching the pidfile's existing `0o600`.
**Done/verify:** a test/assert that the socket path is not group/world
accessible.

### Milestone C — Functional reader gap (the last "renders, not just decodes")

#### [ ] C1 — T7: JS-driven pages render usable content
**Why:** Google-class pages / light SPAs return a near-empty shell and build UI
via JS that branches on a Chromium env; even after Brotli decode they render
blank (`docs/plans/readable-browser-goal.md` T7). Includes the JS-path
DOM-mutation nondeterminism noted 2026-06-04 (QuickJS + pointer-keyed bridge
mutate in address-dependent order).
**Files:** `src/page.zig` (post-load JS settle / re-render), `src/js/*`,
`src/dom/bridge.zig`, `src/browse_heuristics.zig` (re-pick after mutation).
**NOT** `src/net/` emission.
**Done/verify:** per the locked T7 contract in the ledger — a hermetic
Google-class fixture renders usable shell; a hermetic light-SPA fixture renders
JS-injected content (content re-pick exercised); live `awr extract
https://www.google.com/` shows usable shell text; `test` zero failures;
`test-tls`/`h2` green. Mirror the Verified-note format of T3–T6.

#### [ ] C2 — T8: readable-browser closure audit
**Why:** close `docs/plans/readable-browser-goal.md` against fresh evidence, not
memory.
**Done/verify:** every clause of that ledger's Definition-of-done mapped to a
re-run gate with a real exit code; `git branch --no-merged main` empty;
Verified note recorded.

### Milestone D — Contributor & public hardening

#### [ ] D1 — De-Homebrew the build + Linux CI leg
**Why:** `build.zig:47–57` hardcodes `/opt/homebrew` for nghttp2 + lexbor; a
Linux/non-Homebrew contributor can't build without editing it (audit D2).
**Approach:** resolve nghttp2/lexbor via `pkg-config` (or vendored prefix) with
the Homebrew path as a fallback, not a hardcode; add the Linux x86_64 CI leg
once it builds clean.
**Done/verify:** documented clean build on macOS arm64 *and* Linux x86_64 with
no manual path edits; both CI legs green.

#### [ ] D2 — Audit the 97 `catch {}` swallow sites
**Why:** silent swallows (19 in `render.zig`, 16 `browser.zig`, 15
`js/engine.zig`, 14 `page.zig`) hide real failures (audit Q1).
**Approach:** each either logs or carries a one-line justification; surface the
JS/page-path swallows. Track the count.
**Done/verify:** count tracked to ~0 unjustified; representative
previously-swallowed failure now observable in a test.

#### [ ] D3 — `[JS error]` context
**Why:** `src/js/engine.zig:134` emits `[JS error] {}` with empty payload —
floods stderr, buries real errors (audit X3).
**Done/verify:** error includes message + source location; no empty `{}`; test
asserts a thrown JS error surfaces its message.

#### [ ] D4 — Triage `unreachable` / `@panic` (23 non-test sites)
**Why:** if any is reachable from hostile input, the browser aborts (audit Q2).
**Done/verify:** each classified invariant-guaranteed vs input-reachable;
reachable ones converted to typed errors with a test.

#### [ ] D5 — Dependency provenance & cadence
**Why:** BoringSSL pinned by bare commit (no date/CVE signal); CA bundle ~4 mo
old (audit D1/D3).
**Done/verify:** `third_party/boringssl/COMMIT_HASH` gains a date + upstream tag;
a documented BoringSSL + CA-bundle refresh cadence note.

---

## Explicitly out of scope (not v0.1 blockers)

- **God-file split** (`render.zig` 4835 LOC etc., audit A1/3.1) — the audit
  itself says do not refactor god files before CI exists; defer until after A1,
  and only behind the corpus byte-identical check.
- **The "real browser" WPT program** (`.goals/make-awr-a-real-browser-core-wpt.md`)
  — upstream-WPT harness + Tier 4 layout + Tier 5 SPA via ADR. A vision track,
  not a release gate. README already scopes AWR as a reader, not Chrome.
- **MCP stdio promotion**, later fingerprint identity work — deferred per
  `spec/MVP.md §7`.

## Completion audit

Map every `[x]` task to fresh evidence (test names + real exit codes, CI run
links, the clean-build transcript on both platforms). Not complete if any task
is unverified, narrowed, or only "probably" working, or if any gate is red.

## Blocked stop condition

Stop and surface (don't loop past) if: a resource cap can't be added without
perturbing the fingerprint/success path after a real attempt; de-Homebrewing
can't produce a clean Linux build without a governance/dependency decision; or a
task needs a `spec/MVP.md §8` change-control sign-off. Report attempted paths,
evidence, the exact blocker, and what input would unblock.
