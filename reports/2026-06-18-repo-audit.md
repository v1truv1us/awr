# AWR — Repository Audit & Improvement Plan

**Date:** 2026-06-18
**Commit audited:** `51c236f` (branch `feat/hb2-cdp-transport`; working tree has one uncommitted WIP change to `src/cdp/client.zig`, +136/−44)
> **Resolution (same session, 2026-06-18):** every actionable finding below was implemented and merged after this audit — QW2/QW6/QW7, W1 (profile flock), W2 (loadEventFired race), T0.1 (hermetic `test` + `test-all`/`test-cdp`), T1.2 (loud-failure logging), T2.1 (dead `ConnectionPool` removed), and Milestone-3 polish (full PKCS7, console.log truncation marker). **T2.2 was deliberately deferred** (the dead-pool half of its theme is done; the `writeJsonStr` "0x7f divergence" emits valid JSON either way, so cross-module consolidation was declined as risky churn for no behavioral gain). Verified: `zig fmt` ✅ · `zig build` ✅ · `zig build test` (now ~20s, was ~12min) ✅ · `test-tls`/`test-h2` (fingerprint) ✅ · `test-cdp`/`test-client`/`test-js`/`test-net` ✅.

**Method:** Four-phase principal-engineer audit, run as a **re-baseline** of the 2026-06-17 audit (`reports/2026-06-17-repo-audit.md`). Every delta claim was verified by reading the actual code and running the repo's own gates. This audit deliberately does **not** re-enumerate the full standing inventory — the 2026-06-17 report (12-agent fan-out, 75 strengths, 35 Low findings) remains the standing catalogue; this report tracks what changed, verifies the fixes, and audits the new WIP.

> **Scope/fail-loud note.** The five commits since the last audit were each verified by reading the cited code, not just the commit message. The active uncommitted CDP work is audited as *pre-commit WIP* (findings are "resolve before committing", not "shipped defect"). The full `zig build test` aggregate (~12 min, non-hermetic — see T0.1) was **not** run end-to-end; the product-critical targeted gates were (`fmt`, `build`, `test-tls`, `test-h2`, `test-client`). `image/` again received only light touch (unchanged since last audit).

---

## 1. Executive Summary

**Overall health grade: B+ (up from B).** The single finding that mattered most — an unbounded decompressed response body (zip-bomb OOM) that survived **two** prior audits as the #1 risk — is now **closed, correctly, with tests** (`client.zig:1364-1380`, commit `51c236f`). All four decoders (gzip/deflate/zstd/brotli) plus the std-TLS fallback now stream through a 64 MiB cap, so AWR's "parses hostile web content" threat model finally holds end-to-end on the body path. Four of the five prior quick wins also landed (stray binaries removed, platform/sqlite3 docs reconciled, router print env-gated, dead TUI field dropped). The correctness/security culture that earned the prior B is intact and now better-defended.

What holds it at B+ rather than A− is unchanged-in-character from last time: **repo hygiene and non-hermetic tooling**, plus a **new concurrency regression in the active CDP WIP**. `zig-pkg/` (239 tracked files, ~3.6 MB) still bloats every clone despite being gitignored; `zig build test` still aggregates network/corpus/daemon steps into the "unit test" command; error handling is still 102 undifferentiated `catch {}`; and the dead second connection pool still ships. None block shipping. The one thing to fix *before* the current branch lands: the WIP swaps per-run temp profiles for a single shared `~/.awr/profile` and unconditionally deletes Chrome's `SingletonLock`, which is unsafe the moment two `awr` processes run in parallel (the agent surface's whole purpose).

**Verification status (actual results):** `zig fmt --check src/` ✅ · `zig build` ✅ (WIP compiles) · `zig build test-tls` ✅ · `zig build test-h2` ✅ · `zig build test-client` ✅ (covers the new H1 caps). Full `test` aggregate not run (slow/non-hermetic — itself finding T0.1).

**Top 3 risks**
1. **[NEW, WIP] Shared persistent Chrome profile is not concurrency-safe.** `cdp/client.zig:142-180` replaces the per-PID `/tmp/awr-cdp-<ts>` profile with one shared `~/.awr/profile` and **unconditionally unlinks `SingletonLock`/`SingletonSocket`/`SingletonCookie`** on every run (`:162-180`), justified by "AWR owns this profile exclusively" (`:167`). Nothing enforces single-instance — two parallel `awr <url>` invocations (the agent fan-out case) will defeat Chrome's own concurrency guard and can corrupt the profile. The old temp-dir model was concurrency-safe by construction. **Resolve before committing this branch.**
2. **Repo-hygiene carryover** — `zig-pkg/` (239 files, ~3.6 MB incl. a ~1.8 MB `quickjs.c`) is still tracked **despite** `.gitignore` listing it; the ignore rule is a silent no-op. QW2 from the last audit is the only quick win not yet done. Every clone still pays for it.
3. **Non-hermetic, slow `zig build test`** — the default `test` step still depends on `run_page` (network, `build.zig:552`), `run_wpt` (`:928`), `run_daemon` (`:709`), corpus and test262. The most-reached-for command is neither fast nor offline-deterministic, weakening it as a pre-commit gate. (Granular `test-net`/`test-js`/… steps now exist — good partial progress.)

**Top 3 opportunities**
1. **One ~10-line hygiene commit closes risk #2**: `git rm -r --cached zig-pkg` makes the existing ignore rule take effect and drops clone size ~3.6 MB at zero code risk.
2. **A small CDP-WIP hardening pass closes risk #1**: either give each instance its own profile dir under `~/.awr/profiles/<pid>` (keeps concurrency-safety, loses cross-run trust) or take an `O_EXCL`/`flock` lock on the shared profile and skip-or-queue when held. Pick per the trust-accumulation goal.
3. **Split the `test` step** (T0.1) into fast-offline-unit vs the network/corpus superset; CI keeps the superset. Turns the daily gate from a 12-min network run into a deterministic seconds-long check.

**Delta since 2026-06-17 (verified):**

| Item | Prior severity | Status today | Evidence |
|---|---|---|---|
| H1 — decompressed-body zip-bomb | **High** | ✅ **Fixed** | `client.zig:1364` cap, `:1370` `streamCapped`, all 4 decoders + std-TLS (`:868`); over-cap + boundary tests (`:2438-2450`) |
| QW1 — stray root binaries | High | ✅ Fixed | `git ls-files` shows none; commit `1d2289d` |
| QW3 — platform/build/sqlite3 docs | Medium | ✅ Fixed (name still split) | README now macOS-arm64 throughout (`README.md:53/242/247`), sqlite3 documented (`:248`); **name** still "Agentic Web Runtime" (`README.md:1`) vs "CLI Browser Runtime" (`CLAUDE.md:1`) — Low |
| QW4 — unconditional `[router]` print | Low | ✅ Fixed | now `AWR_ROUTER_LOG`-gated (`page.zig:970-971`); `:885` `timing_on`-gated |
| QW5 — dead `Terminal.stdout_buffer` | Low | ✅ Fixed | commit `bcd248b` |
| QW2 — untrack `zig-pkg/` | Medium | ❌ **Open** | 239 files still in `git ls-files zig-pkg/` |
| T0.1 — hermetic `test` step | Medium | ◐ Partial | granular steps added; default `test` still aggregates network (`build.zig:552/709/928`) |
| T1.2 — loud-failure pass | Medium | ❌ Open | 102 `catch {}`; crypto×3 (`page.zig:438/521/607`) + cookie (`:699`) still silent |
| T1.3 — PKCS7 + console marker | Low | ❌ Open | last-byte-only padding check (`session_import.zig:478`); fixed 4096 B console buffer (`engine.zig:458`) |
| T2.1 — dead `ConnectionPool` | Medium | ❌ Open | defined `pool.zig:131`, `NoopMutex` `:32`; no caller outside its own tests |
| T2.2 — duplicated helpers | Medium | ◐ Partial | `util/time.zig` exists; `nowMs`/`writeJsonStr` still in 8 files |
| CDP busy-spin `readDevToolsUrl` | Low | ❌ Open | `cdp/client.zig:364` `if (n == 0) continue; // spin` |

---

## 2. Repo Map (delta only)

The 2026-06-17 Repo Map is still accurate (purpose, stack, ~40.9k LoC Zig, macOS-arm64-only, Chrome-132 fingerprint as the differentiating asset, hybrid-Chrome-over-CDP as the active track). Re-confirmed largest files: `render.zig` 4896, `dom/bridge.zig` 3955, `browser.zig` 3664, `page.zig` 3253, `client.zig` 2459, `main.zig` 2173.

**What changed since last map:**
- `client.zig` grew (2394 → 2459) for the H1 cap (`streamCapped` + cap constant + 3 new tests).
- `cdp/client.zig` (997 → ~1090 in the working tree) is mid-rewrite of its profile + navigation-timeout strategy (uncommitted).
- `src/util/` now holds 7 path/time helpers (`time.zig`, `cookie_path.zig`, `storage_path.zig`, …) — a real shared-util seam exists, but the `nowMs`/`writeJsonStr` duplication T2.2 targeted has not been folded into it.

**Still surprising (unchanged):** the dead second `ConnectionPool`; `zig build test` is not "unit tests"; `awr mcp` ships though `mcp_stdio.zig` declares the track DEFERRED; `.gitignore` lists `zig-pkg/` yet 239 files under it are tracked.

---

## 3. Audit Report

Severity: **High** = serious risk / contradicts the threat model · **Medium** = real maintainability/perf/hardening gap · **Low** = polish. `(fact)` = verifiable in code · `(judgment)` = defensible opinion. No Critical findings (client, not a network-exposed server; no RCE class, no hardcoded secrets — re-confirmed).

### New findings — the active CDP WIP (`src/cdp/client.zig`, uncommitted)

- **[Medium] (fact) Shared persistent profile + unconditional Singleton-lock deletion is unsafe under concurrency.** `cdp/client.zig:142-180`. The fetch path now uses one shared `~/.awr/profile` (or `$AWR_PROFILE`) instead of a per-PID temp dir, and unconditionally `unlink`s `SingletonLock`/`SingletonSocket`/`SingletonCookie` (`:162-180`) on entry. The comment "AWR owns this profile exclusively, so unconditional unlink is safe" (`:167`) is true only for strictly serialized single-instance use — but the agent surface explicitly invites parallel `awr <url>` processes, and `AWR_DAEMON=1` adds a long-lived server. Two instances racing the same profile defeat Chrome's own `SingletonLock` guard, risking profile corruption / "profile in use" failures / one process killing the lock another's Chrome holds. There is **no `flock`/`O_EXCL`/single-instance guard** anywhere in the CDP path (grep-confirmed). *Consequence:* a feature meant to *improve* reliability (trust accumulation) introduces a new intermittent-failure class for the concurrency pattern AWR is built around. *Was* concurrency-safe before this change.
- **[Medium] (judgment) The CDP path now pays a fixed ~4.5 s settle on every escalation, with no early exit.** `cdp/client.zig:540-560`. The code deliberately stops awaiting `Page.loadEventFired` (sound — SPA/challenge pages may never fire it) and instead sleeps a fixed `min(nav_timeout_ms, settle_ms + 3_000)` = `min(20000, 4500)` = **4500 ms by default**, regardless of how fast the page actually rendered. The previous code returned as soon as `loadEventFired` + `settle_ms` (~load + 1.5 s). A page that hydrates in 200 ms now still blocks the full 4.5 s before `outerHTML` capture. *Consequence:* every Chrome escalation is ≥4.5 s slower than necessary on fast pages — a real latency regression traded for hang-safety. *Mitigation exists:* race `loadEventFired` against the timeout (return early on the event, cap on the timeout) to keep both properties.
- **[Low] (judgment) `~/.awr/profile` grows unbounded.** `cdp/client.zig:327` ("Profile persists across runs; no cleanup."). Intentional for trust accumulation, but Chrome's cache/cookies/state accrue with no size cap or eviction; long-lived installs will see the profile balloon. Worth a documented size budget or periodic prune.

### Carryover — still open (verified present)

- **[Medium] (fact) `zig-pkg/` tracked despite `.gitignore` (QW2).** 239 files / ~3.6 MB in the index under an ignored path. The only un-actioned quick win from last audit. *Consequence:* clone bloat + the contradiction between stated and actual ignore intent.
- **[Medium] (fact) `zig build test` non-hermetic & slow (T0.1, partial).** Default `test` step still `dependOn`s `run_page` (`build.zig:552`, "requires network"), `run_wpt` (`:928`), `run_daemon` (`:709`), corpus, test262. Granular per-module steps now exist (`test-net`, `test-js`, `test-dom`, …) — good — but the headline command is still the slow superset. *Consequence:* weak local pre-commit gate; offline runs stall.
- **[Medium] (fact) Undifferentiated `catch {}` (T1.2).** Still 102 sites. The meaningful swallows the last audit named persist: `setCryptoBackend(...) catch {}` triplicated (`page.zig:438/521/607` — WebCrypto silently disappears) and `parseSetCookie(...) catch {}` (`:699`). *Consequence:* no convention separates "drop is fine" from "should be observable".
- **[Medium] (fact) Dead second `ConnectionPool` (T2.1).** `net/pool.zig:131` (+ `NoopMutex` placeholder `:32`) is init/deinit'd per `Client` but `acquireIdle`/`addNew` have no caller outside `pool.zig`'s own tests (grep-confirmed). Live pooling is `BoringSslPool`. ~333 lines of vestigial code carrying a would-be data race if ever activated.
- **[Low] (fact) PKCS7 padding validates only the last byte (T1.3).** `session_import.zig:478`: checks `pad ∈ [1,16]` and `pad ≤ len` but not that the prior `pad−1` bytes equal `pad`. Not exploitable (local Keychain-derived key), but a corrupt BLOB yields silent wrong plaintext instead of `error.BadPadding`.
- **[Low] (fact) `console.log` truncates at 4096 B with no marker.** `js/engine.zig:458-459` (`[4096]u8` + `Writer.fixed`). Hostile-page diagnostics can look complete while clipped.
- **[Low] (fact) CDP `readDevToolsUrl` busy-spins on zero-byte reads.** `cdp/client.zig:364` (`if (n == 0) continue; // spin`). Up to ~100% of one core for up to 10 s while Chrome starts. Untouched by the WIP (which fixed the *post-load* hang, a different spot).
- **[Low] (fact) Product name still split.** `README.md:1` "Agentic Web Runtime" vs `CLAUDE.md:1` "CLI Browser Runtime"; both subtitle correctly as "dual-surface CLI-first terminal browser". QW3 reconciled platform/build/sqlite3 but not the title. Cosmetic.
- Other standing Low items (header-buffer hoist `http1.zig:167`, connect timeout `tcp.zig:76`, localStorage sync flush, DOM-handle non-invalidation, `extractBodyTextCssAware` ignoring `css_sheets`, cssom canonicalization) are unchanged — see 2026-06-17 §3.

### Strengths (re-confirmed + new)

- **H1 fix is exemplary.** `streamCapped` (`client.zig:1370`) reads fixed 64 KiB chunks and aborts at the cap, so peak allocation is `cap + one chunk` — not the full decompressed size. Threaded through every decoder *and* the std-TLS path, with round-trip + over-cap + exact-boundary tests (`:2438-2450`). This is exactly how the prior audit sketched it (mirrors `max_response_header_bytes`).
- **The CDP navigation-timeout rework is good defensive engineering** *aside from* the profile concern: dropping the open-ended `waitForEvent(loadEventFired)` for a bounded budget + `SO_RCVTIMEO` + absolute `deadline_ms` checked on each `readFrame` error (`cdp/client.zig:272-305, 645-655`) closes a genuine indefinite-hang risk on challenge pages. The `NavTimeout` → fall-back-to-Zig-render contract is clean.
- The standing strengths inventory (correct TLS hostname verification, pure-constant fingerprint with end-to-end order tests, no shell injection, bounded QuickJS, hardened daemon scope/lock, RFC-correct cookie/SSE/WebSocket, arena-owned DOM with integer-handle isolation, ~780 co-located tests + WPT/Test262 + render corpus, CI + pre-push hook) is unchanged — see 2026-06-17 §3 Strengths.

---

## 4. Improvement Strategy

The five themes from 2026-06-17 still explain the standing findings; three are materially advanced. Updated view:

**Theme A — Resource safety under hostile input.** *Now substantially done.* The headline gap (decompressed body) is closed and tested; headers, frames, daemon bodies, and JS runtime were already bounded. *Remaining:* console.log truncation marker, event-loop OOM path — both Low. *Done-signal met for the High class.*

**Theme B — Repo hygiene.** *One step from done.* Stray binaries gone; only `zig-pkg/` untracking (QW2) remains. *Done when:* `git ls-files | grep zig-pkg` is empty and clone size drops ~3.6 MB.

**Theme C — Documentation single-source.** *Mostly done.* Platform/build/sqlite3 reconciled; only the README/CLAUDE title split remains (Low). *Done when:* one canonical name (or an explicit "AWR = Agentic Web Runtime, a CLI-first terminal browser" gloss in both).

**Theme D — Differentiated error handling.** *Unstarted.* Still 102 `catch {}` blending ignorable with should-be-observable. *Target:* a `std.log` seam + convention (best-effort writes silent; meaningful failures log/count). *Done when:* the ~6 meaningful swallows (crypto×3, cookie, CSS-rule) log.

**Theme E — Vestigial/duplicated code.** *Partially scaffolded.* A `util/` seam exists but the dead `ConnectionPool` and the `nowMs`/`writeJsonStr` duplication remain. *Done when:* `ConnectionPool` is deleted-or-wired and the helpers live in `util/`.

**New Theme F — The hybrid-Chrome profile model needs a concurrency contract.** The WIP's move to a shared persistent profile is the right strategic direction (the `awr-hybrid-bot-challenge-limit` mitigation), but it changes a safety invariant: the runtime went from "isolated per run" to "one shared mutable profile" without an instance-coordination story. *Target:* an explicit single-instance lock (skip/queue when held) **or** per-instance profile dirs with optional periodic trust-profile sync. *Principle:* shared mutable state across processes needs a lock or an owner; "we assume exclusivity" is not a mechanism. *Done when:* two concurrent `awr <url>` escalations cannot corrupt the profile (a test or a documented lock).

**Explicit non-goals (unchanged):** don't split `dom/bridge.zig`/`render.zig` for size alone; don't rewrite `tcp.zig` to full async yet; don't chase all 102 `catch {}`; don't add a Linux port (make docs say macOS-only — now done).

---

## 5. Task Plan

Effort: **S** <2h · **M** half-day · **L** 1–2 days · **XL** needs breakdown.

### Quick wins (high impact, S — do immediately)
| # | Task | Files | Effort |
|---|---|---|---|
| QW2 ⬅ carryover | `git rm -r --cached zig-pkg` so the existing ignore takes effect; confirm `scripts/bootstrap_deps.sh` regenerates it on a clean clone | `zig-pkg/`, `.gitignore` | S |
| QW6 | Reconcile the product name (README title vs CLAUDE.md) — pick one gloss | `README.md:1`, `CLAUDE.md:1` | S |
| QW7 | Gate or remove the CDP `readDevToolsUrl` busy-spin — sleep ~5–10 ms on `n == 0` | `cdp/client.zig:364` | S |

### Milestone 0 — Before this branch lands (WIP gate)
| # | Task | Description | Files | Effort | Risk |
|---|---|---|---|---|---|
| W1 | **CDP profile single-instance lock (risk #1)** — *decision: single-instance lock* | Take a `flock(LOCK_EX)` on the shared `~/.awr/profile` before spawning Chrome; concurrent runs wait for the lock (or fall back to a per-PID profile rather than block indefinitely). Move the Singleton-unlink to run **only** while the lock is held; release on exit via `defer`. This keeps trust accumulation and serializes escalations. | `cdp/client.zig:142-180` | M | Med (touches the active escalation path — guard with a manual two-process test) |
| W2 | **Race `loadEventFired` against the timeout (perf)** — *decision: race* | Return as soon as `Page.loadEventFired` arrives, capping at `nav_timeout_ms`. Restores ~load+settle latency for fast pages while keeping the bounded budget's hang-safety on SPA/challenge pages. Re-introduce the event wait (removed in the WIP) but bound it — don't go back to the open-ended `waitForEvent`. | `cdp/client.zig:540-560` | M | Low |

### Milestone 1 — Tooling & hygiene (make daily work cheaper)
| # | Task | Description | Files | Effort | Risk |
|---|---|---|---|---|---|
| T0.1 | **Hermetic `test` step** | Stop wiring `run_page`/`run_wpt`/`run_daemon`/corpus/test262 into the default `test`; make `test` fast-offline-unit and add `test-all` (= current behavior) for CI. Update CLAUDE.md "Build & Test". | `build.zig:552/709/928/990/1195`, `ci.yml`, `CLAUDE.md` | M | Low |
| T1.2 | **Loud-failure pass (Theme D)** | `std.log` seam + convention; convert the ~6 meaningful `catch {}` (crypto×3, cookie, CSS-rule) to log/count; optional CI advisory on new bare `catch {}` outside write contexts. | `page.zig:438/521/607/699`, `render.zig` | S | Low |

### Milestone 2 — High-leverage cleanup
| # | Task | Description | Files | Effort | Risk |
|---|---|---|---|---|---|
| T2.1 | Delete or wire the dead pool | Decide `ConnectionPool`'s fate; if dead, remove ~333 lines + its tests; if intended for daemon concurrency, wire it and replace `NoopMutex`. | `net/pool.zig`, `client.zig` | M | Low |
| T2.2 | Fold duplicated helpers into `util/` | Move `nowMs` → `util/time.zig` (exists), add `util/json.zig` for `writeJsonStr` (fix the known `0x7f` divergence) + `ReaderShim`/`WriterShim`. | many | M | Med (module-root wiring) |

### Milestone 3 — Quality & polish
Group the standing Low items as one **M** sweep: PKCS7 full loop (`session_import.zig:478`), console.log truncation marker (`engine.zig:458`), header-buffer hoist (`http1.zig:167`), connect-timeout bump (`tcp.zig:76`), localStorage deferred flush, DOM-handle invalidation (`bridge.zig`), `extractBodyTextCssAware` honor-or-rename (`page.zig`), `~/.awr/profile` size budget. Only do the `renderElement`/`main` dispatch-table refactors if a feature forces them.

### Implementation sketches — top 3

**W1 — CDP profile concurrency lock (the pre-commit blocker).**
- *Approach:* before spawning Chrome, attempt to create `~/.awr/profile/.awr-instance.lock` with `O_CREAT|O_EXCL` (or `flock(LOCK_EX|LOCK_NB)`). If acquired: proceed, and only then clean stale Singletons; release (and unlink) on exit via `defer`/`errdefer`. If *not* acquired: a live AWR-driven Chrome already owns the profile — fall back to a per-PID profile (`~/.awr/profiles/<pid>`, temp-style) for this run so concurrent agents still work, just without shared trust that run.
- *Key steps:* (1) open/lock; (2) move the Singleton-unlink block to run **only** on successful lock; (3) `defer` release+unlink; (4) wire the fallback profile path; (5) add a test or a documented two-process manual check.
- *Gotchas:* `flock` auto-releases on process death (good — handles SIGKILL orphans without the unconditional unlink). Don't `O_EXCL`-leak the lockfile on crash — prefer `flock` on a persistent file over an `O_EXCL` sentinel you must remember to delete. Keep `$AWR_PROFILE` override honored.

**QW2 — Untrack `zig-pkg/`.**
- *Approach:* `git rm -r --cached zig-pkg` (already in `.gitignore:25`, so no edit needed); commit.
- *Key steps:* confirm `scripts/bootstrap_deps.sh` regenerates `zig-pkg/` from scratch on a clean clone (DEV_NOTES.md #1 documents a patched `quickjs_ng/build.zig` that lives there — verify the bootstrap re-applies the patch, else document the manual step). Verify `git ls-files | grep zig-pkg` is empty.
- *Gotchas:* history still carries the ~3.6 MB blobs; a full purge needs `git filter-repo` (rewrites history — out of scope unless requested). Untracking is the safe 90% win, same trade-off as last audit's Open Question #1.

**T0.1 — Hermetic `test` step.**
- *Approach:* in `build.zig`, drop the network/corpus `dependOn`s from `test_step`; add `test-all` that re-aggregates them for CI.
- *Key steps:* find `test_step.dependOn(&run_{page,corpus,wpt,test262,daemon}.step)` (`:552/990/928/1195/709`); route them to a new `test-all`; point `ci.yml` at `test-all`; update CLAUDE.md so the documented command matches reality.
- *Gotchas:* `test-page`/`test-e2e` "skip gracefully" offline but still compile + spawn servers — ensure the fast `test` truly avoids them. Drop nothing from CI; only re-route.

---

## 6. Open Questions (need a human decision)

1. ~~**Profile model (W1).**~~ **RESOLVED 2026-06-18 → single-instance lock.** Shared `~/.awr/profile`, accessed by one AWR-driven Chrome at a time via `flock(LOCK_EX)`; concurrent runs wait (or fall back to a per-PID profile). See W1.
2. ~~**Settle strategy (W2).**~~ **RESOLVED 2026-06-18 → race `loadEventFired`.** Return early on the load event, capped at `nav_timeout_ms`. See W2.
3. **`zig-pkg/` intent (QW2).** Intentional vendored copy (patched `quickjs_ng/build.zig` per DEV_NOTES #1) that should move under `third_party/` and be documented — or purely accidental and safe to untrack? Carryover from 2026-06-17 Open Q#2.
4. **History rewrite?** Untracking `zig-pkg/` stops new bloat but leaves ~3.6 MB in `.git`. `git filter-repo` purge (rewrites history) or is untracking enough? Carryover.
5. **`ConnectionPool` fate (T2.1).** Delete the dead pool, or is it scaffolding for an imminent daemon-concurrency feature to wire instead? Carryover.
6. **`image/` re-review.** The stb_image integer-overflow / malformed-image path has now gone two audits with only light review — schedule a focused pass before relying on image decode against hostile sources?

---

*Delta tracking: `reports/2026-06-11-repo-audit.md` (B), `reports/2026-06-17-repo-audit.md` (B). This audit (B+) confirms the long-standing decompression-DoS (H1) is finally **closed with tests**, 4/5 prior quick wins landed, and adds Theme F + two Medium WIP findings for the in-flight CDP profile rework. Net trajectory: improving; the remaining work is hygiene, tooling, and a pre-commit concurrency fix — no Critical/High shipped defects.*
