# AWR — Repository Audit & Improvement Plan

**Date:** 2026-06-17
**Commit audited:** `d2f30cb` (branch `feat/hb2-cdp-transport`; working tree has one uncommitted WIP change to `src/cdp/client.zig`)
**Method:** Four-phase principal-engineer audit. Phase 1–2 combined (a) direct file inspection of the core flow by the orchestrator and (b) a 12-agent parallel deep-dive across every subsystem. All headline (High/Medium) findings were verified by reading the cited code directly.

> **Methodology caveat (fail-loud).** The multi-agent fan-out hit the session usage
> limit mid-run (resets 10:30am America/Denver). 10 of 12 subsystem readers completed;
> the **adversarial verification and completeness-critic phases did not run**. Consequence:
> - **High/Medium findings below were verified by the orchestrator reading the actual code** (citations checked).
> - **Low findings come from single-reader inspection** and are labelled as such — treat them as high-quality leads, not adversarially-confirmed.
> - The `image/` decoder subsystem and a second docs/build reader did not complete; `image/` received **lighter review** (flagged in Open Questions).
> - 75 strengths and 35 Low findings were harvested from the completed readers.

---

## 1. Executive Summary

**Overall health grade: B.** AWR is a disciplined, genuinely well-engineered pre-1.0 product with an unusually strong **correctness and security culture** for its size: ~780 co-located tests plus WPT/Test262 conformance gates and a real-page render corpus; correct TLS chain *and hostname* verification; no shell injection anywhere subprocesses are spawned; bounded QuickJS runtime; a hardened daemon scope/lock design. Since the previous audit (2026-06-11, also grade B) two of its top risks were closed — **CI now exists** (`.github/workflows/ci.yml` + a mirroring pre-push hook) and the **8 KB text-node truncation is fixed** (regression test `render.zig:4847`).

What holds it at B rather than B+/A- is not correctness of the happy path but **resource-safety under hostile input, repo hygiene, and documentation drift**: a decompression zip-bomb OOM remains unfixed across two audits; ~5.4 MB of stray build artifacts and a gitignored-but-tracked package cache now bloat every clone; and the README, CLAUDE.md, and CI disagree on platform, build path, and even the product's name. None block shipping, but each compounds as the project takes external contributors.

**Verification status:** `zig fmt --check` ✅ · `zig build` ✅ · `zig build test-tls` ✅ · `zig build test-h2` ✅ · `zig build test` ✅ (exit 0, but ~12+ min — it pulls in network/integration steps; see M6).

**Top 3 risks**
1. **Unbounded decompressed response body (zip-bomb OOM)** — `client.zig:864/1335/1347/1389`. All four decoders (gzip/zstd/brotli + the std-TLS path) stream into unbounded allocating buffers with no total-size cap, while headers *are* capped (`client.zig:178`). A hostile/compromised server trivially OOMs the process — directly contradicting the documented "parses hostile web content" threat model. **Unfixed across two audits.**
2. **Repo-hygiene regression** — five stray binaries committed to the repo root (`test_io2` is a 1.8 MB Mach-O; `test_io`/`test_reader*` are empties) plus `zig-pkg/` (239 files, ~3.6 MB incl. a 1.8 MB `quickjs.c`) tracked **despite** being listed in `.gitignore`. Both landed in commit `57e4b5f`. Every clone pays for it; it erodes the otherwise-strong discipline signal.
3. **Documentation drift** — README claims a Linux x86_64 build (`README.md:240`) while CI, the vendored libs, and CLAUDE.md say macOS/arm64-only; README and CLAUDE.md give two different lexbor setup paths; the product is named both "Agentic Web Runtime" and "CLI Browser Runtime". The first external contributor following the README on Linux cannot succeed.

**Top 3 opportunities**
1. **One shared decompressed-size budget** threaded through the four decoders closes the entire DoS class with a single small, well-tested change (mirrors the existing `max_response_header_bytes` pattern).
2. **A ~30-minute hygiene + docs sweep** (`git rm` the stray binaries and `zig-pkg/`, reconcile `.gitignore`, fix the three doc contradictions) buys outsized clarity and credibility for trivial effort and risk.
3. **Make `zig build test` hermetic** (split unit tests from the network/integration/corpus steps it currently aggregates) so the suite becomes a fast, deterministic local gate instead of a 12-minute network-bound run.

---

## 2. Repo Map

**Purpose.** A dual-surface, CLI-first terminal browser written in Zig: one binary serves a human TUI (`awr browse`) and an agent surface (`awr <url>` / `extract` / `tools` / `call`, emitting JSON / Markdown / WebMCP), sharing one cookie jar, connection pool, and rendered DOM. The differentiating asset is a **byte-stable Chrome-132 TLS/JA4 + HTTP/2 fingerprint**. The active track is a **hybrid rendering backend** (drive real headless Chrome over CDP for SPAs — ADR 0004); a native Zig layout engine is deferred.

**Stack.** Zig 0.16 (pinned, matches installed `0.16.0`). Vendored prebuilt BoringSSL + Brotli (macos-arm64 static libs); lexbor, nghttp2 via Homebrew (or built-from-source per README); QuickJS-NG and libxev as path dependencies bootstrapped by `scripts/bootstrap_deps.sh`. **macOS/arm64 only** (a Linux leg is explicitly deferred). ~40,900 lines of Zig.

**Architecture (key directories).**
| Area | Role |
|---|---|
| `src/main.zig` (2173) | CLI entry + subcommand dispatch + JSON envelope |
| `src/main_daemon.zig` (885) | `awrd` daemon: socket server, scope isolation, pid-lock |
| `src/client.zig` (2394) | HTTP client: TLS + H1/H2 + cookies + redirects + `BoringSslPool` |
| `src/page.zig` (3253) | Orchestrator: fetch → parse → DOM → JS → render; hybrid-backend router |
| `src/render.zig` (4896) | Terminal renderer: ANSI, wrap, tables, CSS pre-filter pipeline |
| `src/browser.zig` (3664) | TUI session: vim keys, focus, forms, cookie inspector |
| `src/dom/bridge.zig` (3955) | JS ↔ DOM bridge — the active conformance surface |
| `src/dom/node.zig` (1344) | DOM tree, selector engine, arena ownership |
| `src/js/engine.zig` (1390) | QuickJS-NG wrapper: console, fetch, timers, eval deadline |
| `src/net/*` | TLS (`tls_conn` + `tls_awr_shim.c`), `http1`, `http2`/`h2session`, `tcp`, `pool`, `cookie`, `fingerprint`, `sse`, `websocket`, `url`, `ca_bundle` |
| `src/cdp/client.zig` (997) | Headless-Chrome CDP transport (active feature; uncommitted WIP) |
| `src/image/*` | Image decode (stb) + terminal protocols (kitty/sixel/iterm/braille) |
| `src/cssom/*` | Starter CSSOM: parser, cascade, computed, style |
| `tests/` | WPT/Test262 runners, render corpus + fixtures, integration runners |
| `spec/` + `docs/adr/` | Canonical specs (20 files) + 4 ADRs (governance, daemon, layout, hybrid) |

**What surprised me (worth a second look).**
- **Two connection-pool implementations.** `net/pool.zig`'s `ConnectionPool` is instantiated on every `Client` (`client.zig:448`) and deinit'd (`:490`) but **none of its methods are ever called** — the live keep-alive path uses `BoringSslPool`. ~333 lines of vestigial code (see M7).
- **`zig build test` is not "unit tests"** despite its label — it depends on `run_page` (network), `run_corpus`, `run_wpt`, `run_test262`, `run_daemon` (see M6).
- **`awr mcp` ships fully operational** even though `mcp_stdio.zig:1` declares the track DEFERRED and the spec requires an amendment to promote it (see M9).
- **`.gitignore` lists `zig-pkg/` (line 25)** yet 239 files under it are tracked — the ignore rule is silently a no-op (see M1).

---

## 3. Audit Report

Severity legend: **High** = serious risk / contradicts the threat model · **Medium** = real maintainability/perf/security-hardening gap · **Low** = polish. `(fact)` = objectively verifiable in code; `(judgment)` = defensible design opinion. No Critical findings (AWR is a client, not a network-exposed server; no RCE class, no hardcoded secrets).

### Security

- **[High] (fact) Unbounded decompressed response body — zip-bomb OOM.** `client.zig:864` (std-TLS `streamRemaining` into `body_buf`), `:1335` (`inflateFlateBody`), `:1347` (`inflateZstdBody`), `:1389` (`inflateBrotliBody`). Each streams decompressed output into a growable `std.Io.Writer.Allocating` (or equivalent) with **no total-size cap**; the window buffers (`max_window_len`) bound only the sliding window, not output. Headers are capped at 64 KiB (`client.zig:178`) but bodies are not. A malicious or compromised origin returning a highly compressible body causes unbounded allocation → OOM/crash. *Consequence:* any URL an agent is pointed at can kill the process. **Carryover, unfixed since 2026-06-11.**
- **[Low] (fact) PKCS7 padding validation checks only the last byte** when decrypting Chrome cookie values (AES-128-CBC). `session_import.zig:478-480`. Validates `pad ∈ [1,16]` but not that the prior `pad-1` bytes equal `pad`. Not exploitable today (ciphertext comes from the local Keychain-derived key, not the network), but a corrupted/hand-crafted BLOB yields silent wrong plaintext instead of `error.BadPadding`.
- **[Low] (fact) `console.log` output silently truncated at 4096 B** with no marker. `js/engine.zig:458-494` uses a fixed stack buffer via `std.Io.Writer.fixed`, which clips without error. Hostile-page diagnostics can look complete while clipped mid-token.
- **[Low] (judgment) `appendJsonField` does not escape the field *name*.** `dom/bridge.zig:1441-1445`. Today all callers pass compile-time literals (`"event"`,`"data"`,`"lastEventId"`), so it is latent — but the generic signature accepts any `[]const u8`; wiring a server-controlled SSE event-type as a field name would allow JSON-structure injection. (Field *values* are correctly escaped.)
- **[Low] (fact) TLS read loop can spin forever if no deadline is set.** `tls_awr_shim.c:303-320`: the `SSL_ERROR_WANT_READ` retry is guarded by a deadline check that is skipped when `awr_tls_read_deadline_ms == 0`. Live callers always set a deadline first, but `tls_conn.zig` exposes `readFn` publicly with no contract enforcing it.
- **[Low] (fact) `BIO_new_mem_buf` casts `size_t`→`int`.** `tls_awr_shim.c:186`. Harmless at today's 226 KB bundle; latent truncation/sign-conversion bug for any >2 GB input. Passing `-1` (NUL-terminated) would be safer.

### Code quality

- **[Medium] (fact) Pervasive, undifferentiated `catch {}` (102 sites).** Concentrated in `render.zig` (19), `browser.zig` (16), `js/engine.zig` (15), `page.zig` (14). Many are legitimate best-effort terminal/console writes, but the same syntax also silently swallows *meaningful* failures with no log or counter: `setCryptoBackend(...) catch {}` (triplicated at `page.zig:438/521/607` — WebCrypto silently disappears), `parseSetCookie(...) catch {}` (`page.zig:699`), and CSS-rule `append(...) catch {}` that drops rules on OOM (`render.zig:1331-1342`). *Consequence:* no convention separates "drop is fine" from "should be observable", so real failures are invisible in production.
- **[Medium] (judgment) Cross-module code duplication with divergence risk.** `nowMs` exists in 4 files (`main.zig:17`, `main_daemon.zig:204`, `client.zig:81/616`); `writeJsonStr` in 6 (`main.zig:93`, `main_daemon.zig:539`, `mcp_stdio.zig:437`, `jsonrpc.zig:244`, `js/storage.zig:466`, `dom/bridge.zig:332`); the JSON envelope builder is copy-pasted across `post`/`submit`/default-fetch/`handleFetch`; `ReaderShim`/`WriterShim` duplicated in `main_daemon.zig` and `mcp_stdio.zig`. The duplication is *acknowledged in comments* (module-root constraints), but already diverging: the `bridge.zig` copy of `writeJsonStr` escapes `0x7f` while the others do not. A fix to one copy won't propagate.
- **[Medium] (fact) Dead second connection pool.** `net/pool.zig`'s `ConnectionPool` (~333 lines incl. tests) is init'd/deinit'd on every `Client` but `acquireIdle`/`addNew`/`release`/`evictIdle` are never called in live code — only in its own tests. Real pooling is `BoringSslPool`. Carries a `NoopMutex` placeholder (`pool.zig:32-35`) that would become a silent data race if ever activated for daemon concurrency.
- **[Low] (fact) `Terminal.stdout_buffer` is a dead 4096 B field** (`tui.zig:45`); the real buffer is a local in `browser.zig:1965`.
- **[Low] (fact) DOM handle index grows monotonically, never invalidated.** `dom/bridge.zig:355-361`: detached nodes keep their slot; `handle_to_elem` retains raw pointers to detached nodes and grows unboundedly for churny (virtual-DOM) pages; `@intCast` to `u32` panics (Debug/Safe) or wraps (Fast) at exhaustion.
- **[Low] (judgment) `renderElement` is a 195-line linear tag-dispatch** (`render.zig:1535-1726`) and CLI dispatch is a 14-branch if-else chain in `main.zig` (`:1066-1676`) — dispatch tables masquerading as functions. Manageable now; grows painful per added tag/subcommand.
- **[Low] (judgment) cssom `getPropertyValue`/`setProperty` use different canonicalization** (`style.zig:42-45`), compensated by `eqlIgnoreCase`; a future `eql` refactor silently breaks mixed-case lookups. `parser.zig:82` uses `anyerror` instead of an inferred error set.

### Performance

- **[Medium] (judgment) TCP layer is synchronous thread-per-op, not the shared libxev loop.** `tcp.zig:10/112/154/166/204/329` (`TODO(libxev-phase2)`): each op spawns a thread + `loop.run(.until_done)`. The async event loop is present but unwired from the hot path, capping daemon concurrency and adding thread-spawn overhead under load. Deliberate/known, but the single biggest scalability ceiling.
- **[Low] (judgment) 64 KB stack buffer declared *inside* the header-parse loop** (`http1.zig:167`) — re-pushed per header line; hoisting it bounds the same max-line length with one allocation.
- **[Low] (judgment) TCP connect timeout is 1 s** (`tcp.zig:76`) — aggressive for intercontinental/cellular RTT; 3–5 s is browser-typical.
- **[Low] (judgment) `localStorage` flushes synchronously on every `setItem`/`removeItem`/`clear`** (`js/storage.zig:403-408`) — full-map JSON serialize + temp-file + rename per mutation; the dirty flag already exists to defer to quiescence.
- **[Low] (judgment) `extractBodyTextCssAware` ignores its `css_sheets` param** (`page.zig:2274`, `_ = css_sheets;`) — agents reading `body_text` see class-`display:none` content the renderer correctly hides; doc-comment promises stylesheet matching it doesn't do.
- **[Low] (judgment) `readDevToolsUrl` busy-spins on zero-byte reads** (`cdp/client.zig:364`) — up to 100% of one core for up to 10 s while Chrome starts.

### Testing

- **[Medium] (fact) `zig build test` is non-hermetic and slow.** `build.zig` wires the default `test` step to `run_page` (`:552`, "requires network"), `run_corpus` (`:990`), `run_wpt` (`:928`), `run_test262` (`:1195`), and `run_daemon` (`:709`) — despite the step description "Run all *unit* tests". Locally it ran ~12+ min and stalled at the corpus runner before completing (exit 0 eventually). *Consequence:* the most-reached-for command is neither fast nor reliable offline, weakening it as a pre-commit gate. (CI passes because the runner has network.)
- **[Low] (fact) A CSSOM test leaks Rule internals** under `std.testing.allocator` (`cssom/computed.zig:141-144`) — frees the originals but not the in-sheet copies' selectors/declarations, risking spurious leak reports that mask real ones.
- **[Strength, see §3 Strengths]** Otherwise the test culture is excellent — named regression guards for most behaviors, conformance corpora with a bless workflow.

### DevEx & operations

- **[High] (fact) Stray binaries committed to repo root.** `test_io2` (1.8 MB Mach-O arm64), `test_io`/`test_reader`/`test_reader2`/`test_reader3` (empties), tracked since `57e4b5f`, not gitignored. Bloat + confusion + risk of running a stale artifact.
- **[Medium] (fact) `zig-pkg/` tracked despite `.gitignore:25`.** 239 files / ~3.6 MB (incl. `quickjs.c` ~1.8 MB) are in the index even though the path is ignored — the rule is a silent no-op because the files were added (also in `57e4b5f`) before/around the ignore. Intent and reality contradict.
- **[Medium] (judgment) CI is single-platform with no security/coverage gate.** `ci.yml` runs build + fmt + TLS/H2 fingerprint gates + full test on macOS-14 only — strong for the fingerprint, but no Linux leg (deferred, fine), no dependency/CVE scan, no coverage signal. Good baseline; room to grow.
- **[Low] (judgment) `awr` advertises different `Accept-Encoding` on its two TLS paths** — BoringSSL path includes `br`, std.http fallback omits it (`http1.zig`); a brotli-only origin hit via the fallback returns an undecodable body.
- **[Low] (fact) Stray unconditional `std.debug.print` in a production path** — `page.zig:971` prints `[router] … escalating to Chrome` to stderr on every escalation (most other debug prints are flag-gated behind `timing_on`/`enabled_print`).

### Dependencies

- Healthy overall: deps are pinned (BoringSSL/Brotli vendored as prebuilt static libs; QuickJS-NG/libxev path-pinned; CA bundle `@embedFile`'d at compile time). `build.zig.zon` pins `minimum_zig_version = 0.16.0`. No lockfile rot in the Zig sense.
- **[Low] (fact) Undocumented runtime dependency on the `sqlite3` CLI** — browser-cookie import shells out to it (`session_import.zig:178`); absent from README/CLAUDE dependency sections, so the feature fails silently without it on PATH.

### Documentation

- **[Medium] (fact) README contradicts the real platform.** `README.md:240` advertises "~9.9 MB ReleaseSafe **Linux x86_64**"; CI, vendored macos-arm64 libs, and CLAUDE.md constraint #2 say macOS/arm64-only.
- **[Medium] (fact) Two conflicting lexbor build paths.** README (`:51-54`) builds lexbor from source via `bootstrap_lexbor.sh` + `-Dlexbor-prefix`; CLAUDE.md (`:66`) and CI use Homebrew. A fresh clone may fail depending on which doc it follows.
- **[Low] (fact) Product name inconsistent** — "Agentic Web Runtime" (`README.md:1`) vs "CLI Browser Runtime" (`CLAUDE.md:1`) vs the canonical "dual-surface CLI-first terminal browser".
- **[Low] (judgment) `awr mcp` reachable despite DEFERRED status** (`main.zig:1397-1403`; `mcp_stdio.zig:1`) — consumers may depend on an un-blessed contract before the spec's change-control allows it.

### Architecture

- **[Low/Medium] (judgment) Large central files concentrate complexity** — `render.zig` 4896, `dom/bridge.zig` 3955 (partly justified as the conformance surface), `browser.zig` 3664, `page.zig` 3253. Raises merge-conflict surface and onboarding cost; not a crisis at pre-1.0.

### Strengths (what to preserve)

Security & fingerprint
- **TLS verification is fully correct** — `SSL_set1_host` (CN/SAN match) *and* `SSL_VERIFY_PEER` both set (`tls_awr_shim.c:148/168/224`); the common "VERIFY_PEER but no hostname check" mistake is avoided.
- **`fingerprint.zig` is pure constants** (no I/O, no mutable global) and the JA4 cipher/extension order is validated end-to-end (`tls_conn.zig:304-627`); H2 pseudo-header order is hardcoded and tested (`h2_shim.c:72-87`). The fingerprint is structurally hard to regress.
- **No shell injection anywhere** — `sqlite3`, `security`, and Chrome are all spawned via argv arrays through `posix_spawn/execve`, never a shell string; the sqlite query is a static literal.
- **CDP path is well-hardened** — cookie fields JSON-escaped (`cdp/client.zig:797-810`), DevTools forced to `127.0.0.1` regardless of advertised host (confused-deputy defense), cleanup via `errdefer child.kill` on every path, websocket 16 MiB frame cap.
- **Browser-cookie decryption handles secrets carefully** — Keychain password freed immediately (`session_import.zig:387`), never logged; temp DB always `defer`-deleted.
- **Daemon is hardened** — tight `isValidScopeName` path-traversal guard (`main_daemon.zig:658-666`), `flock`-based pid-lock with kernel auto-release, 1 MiB body cap + 4 KiB header-line cap in `jsonrpc.zig`.
- **QuickJS is bounded before first eval** — 128 MB runtime cap + 4 MB stack (`engine.zig:248-249`), 2 s wall-clock eval deadline with a regression test, and a `fetch` init-key allowlist limiting page-script reach.

Correctness & networking
- Redirect cap (10) with `TooManyRedirects`; correct POST→GET demotion on 301/302/303 and method/body preservation on 307/308; RFC 9112 bodiless-status handling on both TLS paths.
- `BoringSslPool` keep-alive checks idle-timeout (30 s) + request-cap (100) + per-origin cap (6), all tested; single staleness retry on `HttpConnectionClosing`.
- `cookie.zig` implements RFC 6265 domain-match (incl. the suffix-confusion guard), Secure-flag enforcement, and a full cookie-date parser; `sse.zig` matches WHATWG SSE; `websocket.zig` validates RSV bits, Sec-WebSocket-Accept, and masking.
- DOM uses an **arena allocator** (atomic teardown — eliminates a UAF class) and an **integer-handle isolation boundary** so JS never receives raw pointers; JSON escaping covers the full U+0000–U+001F range.

Process
- Strong co-located test suite (~780 tests) with named regression guards, plus WPT/Test262 + render-corpus gates with a bless workflow.
- **CI now exists** (`ci.yml`) + a mirroring pre-push hook — both correctly key off exit codes (per the "benign `failed command:`" artifact). Closes the previous audit's #1 risk.
- The CSS pre-filter pipeline (`hide_rules`/`ws_rules`/`text_rules` with compiled selectors + MediaWiki-scale fallback) and the hidden-rescue two-pass render are well-engineered solutions to real-world page shapes.

---

## 4. Improvement Strategy

Five themes explain most findings.

**Theme A — Resource safety under hostile input is incomplete.** Headers, websocket frames, daemon bodies, and the JS runtime are all bounded — but the decompressed HTTP body is not (H1), and a few smaller buffers truncate/leak silently (console.log, event-loop OOM). *Target state:* every allocation whose size is influenced by remote data has an explicit, tested cap; the threat model holds end-to-end. *Principle:* in a tool that parses hostile content, "bounded by default" is a correctness property, not a nicety. *Done when:* a decompressed-body cap exists and is tested with a zip-bomb fixture; no remote-sized buffer is unbounded.

**Theme B — Repo hygiene & artifact discipline slipped.** Build artifacts and a package cache leaked into version control, and `.gitignore` is out of sync with the index. *Target state:* `git ls-files` contains zero build outputs; ignore rules match reality. *Principle:* the index is a curated source of truth, not a scratch dir. *Done when:* the stray binaries and `zig-pkg/` are removed from tracking, `.gitignore` is reconciled, and clone size drops by ~5.4 MB.

**Theme C — The documentation set drifts because it has many overlapping surfaces.** README, CLAUDE.md, AGENTS.md, STATUS.md, DEV_NOTES.md, and `spec/` (+ a stray `specs/`) each describe setup/platform/identity, and they now disagree. *Target state:* one canonical source per fact (platform, build path, name), with the others pointing to it. *Principle:* single source of truth; docs are tested against reality where cheap. *Done when:* README/CLAUDE/CI agree on platform and build path, the name is consistent, and `sqlite3` is documented.

**Theme D — Error handling is best-effort and undifferentiated.** 102 `catch {}` blend "ignorable" with "should-be-observable", and a few OOM paths leak/skip with only a comment. *Target state:* a logging seam (`std.log`) and a convention — best-effort writes stay silent; meaningful failures log or count. *Principle:* fail loud, or at least fail visible. *Done when:* the ~6 meaningful swallows (crypto/cookie/CSS-rule) log, and CI advises on new bare `catch {}` outside write contexts.

**Theme E — Vestigial and duplicated code is accumulating.** A dead second pool, duplicated `nowMs`/`writeJsonStr`/shims/envelope-builder, dead struct fields. *Target state:* one implementation per concept; module-root constraints solved with shared `util/` modules rather than copies. *Principle:* code is liability; delete or unify. *Done when:* `ConnectionPool` is removed or wired, and the 0x7f-divergent `writeJsonStr` copies are unified.

**Explicit non-goals (do NOT fix now — effort/risk vs payoff):**
- **Don't split `dom/bridge.zig` or `render.zig` for size alone.** They are the conformance/render hot paths; churn risks WPT/render-corpus regressions for little gain. Refactor only when a feature forces it.
- **Don't rewrite `tcp.zig` to full async (libxev-phase2) yet.** Large change adjacent to the fingerprint-critical path; only worth it if daemon throughput becomes a real, measured target. The thread-per-op model is *correct*, just not maximally concurrent.
- **Don't chase all 102 `catch {}`.** Most are legitimate terminal writes; triage only the meaningful ones.
- **Don't add a Linux port.** Explicitly deferred until the build is de-Homebrewed; the fix for Theme C is to make the docs *say* macOS-only, not to build Linux.

---

## 5. Task Plan

Effort: **S** <2h · **M** half-day · **L** 1–2 days · **XL** needs breakdown.

### Quick wins (high impact, S — do immediately)
| # | Task | Files | Effort |
|---|---|---|---|
| QW1 | `git rm --cached` the 5 stray root binaries; add a guard glob to `.gitignore` | `test_io*`, `test_reader*`, `.gitignore` | S |
| QW2 | Untrack `zig-pkg/` (`git rm -r --cached zig-pkg`) so the existing ignore rule takes effect; confirm bootstrap still regenerates it | `zig-pkg/`, `.gitignore` | S |
| QW3 | Fix README platform line + product name; pick one lexbor path and make README/CLAUDE/CI agree; add `sqlite3` to documented deps | `README.md`, `CLAUDE.md` | S |
| QW4 | Gate the `[router]` print behind the timing flag; sweep other unconditional `std.debug.print` in prod paths | `page.zig:971` (+ grep) | S |
| QW5 | Remove dead `Terminal.stdout_buffer` field | `tui.zig:45` | S |

### Milestone 0 — Safety net (before larger refactors)
| # | Task | Description | Files | Effort | Risk |
|---|---|---|---|---|---|
| T0.1 | **Hermetic `test` step** | Split `zig build test` into pure-unit (default, offline, fast) vs `test-integration`/`test-net`/`test-corpus` (network). Keep CI running the superset. | `build.zig` | M | Low |
| T0.2 | Zip-bomb test fixture | Add a highly-compressible gzip/zstd/brotli fixture + a test asserting the decoder errors at the cap (drives T1.1). | `tests/`, `client.zig` tests | S | Low |

### Milestone 1 — Correctness & resource safety
| # | Task | Description | Files | Effort | Risk |
|---|---|---|---|---|---|
| T1.1 | **Decompressed-size budget (H1)** | One `max_response_body_bytes` constant threaded into the 4 decoders; abort with a typed error past the cap. | `client.zig:864/1335/1347/1389` | M | Med (touches all fetch paths — guard the fingerprint with `test-tls`/`test-h2`) |
| T1.2 | Loud-failure pass (Theme D) | Introduce `std.log` seam; convert the ~6 meaningful `catch {}` (crypto×3, cookie, CSS-rule) to log/count. | `page.zig:438/521/607/699`, `render.zig:1331-1342` | S | Low |
| T1.3 | Complete PKCS7 + console.log marker | Full padding loop; append a truncation marker / heap-grow console buffer. | `session_import.zig:478`, `engine.zig:458` | S | Low |

### Milestone 2 — High-leverage (make future work easier)
| # | Task | Description | Files | Effort | Risk |
|---|---|---|---|---|---|
| T2.1 | Remove or wire the dead pool (M7) | Decide `ConnectionPool`'s fate; if dead, delete (~333 lines) and its tests; if intended, wire it and upgrade `NoopMutex`. | `net/pool.zig`, `client.zig:399/448/490` | M | Low |
| T2.2 | Unify duplicated helpers (Theme E) | Shared `util/time.zig` + `util/json.zig`; collapse the 4×`nowMs`/6×`writeJsonStr` (fix the 0x7f divergence) + `ReaderShim`/`WriterShim` + JSON envelope builder. | many | M | Med (module-root wiring) |
| T2.3 | Doc single-source pass (Theme C) | One canonical platform/build/name fact; cross-link the rest; optional doc-consistency check in CI. | docs | S | Low |

### Milestone 3 — Quality & polish
Per-finding Low items: header-buffer hoist (`http1.zig:167`), connect-timeout bump (`tcp.zig:76`), localStorage deferred flush (`storage.zig:403`), DOM handle invalidation (`bridge.zig:355`), event-loop OOM leak (`event_loop.zig:102`), `extractBodyTextCssAware` honor-or-rename (`page.zig:2274`), CDP busy-spin sleep (`cdp/client.zig:364`), cssom canonicalization unify (`style.zig:42`), `parseRuleBlock` error set (`parser.zig:82`), dispatch-table refactors for `renderElement`/`main` (only if a feature forces it). Group as one **M** sweep.

### Implementation sketches — top 3

**T1.1 — Decompressed-size budget (the headline fix).**
- *Approach:* mirror `max_response_header_bytes`. Add `const max_response_body_bytes: usize = 64 * 1024 * 1024;` (or make it a `Client` field). Wrap each decoder's output so it errors past the cap rather than growing unbounded.
- *Key steps:* (1) for the std-TLS path (`:864`), bound `body_buf` — use a limited writer or check `body_buf.items.len` in the stream loop and return `error.ResponseTooLarge`. (2) for `inflateFlateBody`/`inflateZstdBody`/`inflateBrotliBody` (`:1335/1347/1389`), replace the bare `streamRemaining(&out.writer)` with a capped writer (or a manual chunk loop that checks total against the cap — the brotli path already loops in 64 KB chunks, so add the check there). (3) add `ResponseTooLarge` to the fetch error set + `mapFetchError`. (4) T0.2 fixture proves it.
- *Gotchas:* the cap must apply to **decompressed** size, not compressed length. Do **not** alter `Accept-Encoding` or header order — run `test-tls`/`test-h2` after. Keep the cap generous enough for legitimate large pages (Wikipedia ≈ a few MB).

**QW1+QW2 — Hygiene purge.**
- *Approach:* `git rm --cached test_io test_io2 test_reader test_reader2 test_reader3 && git rm -r --cached zig-pkg`. Add `/test_io*`, `/test_reader*` to `.gitignore` (root-anchored). `zig-pkg/` is already ignored — untracking is the whole fix.
- *Key steps:* confirm `scripts/bootstrap_deps.sh` regenerates `zig-pkg/` from scratch on a clean clone (DEV_NOTES.md #1 describes the patched `quickjs_ng/build.zig` that lives there — verify the bootstrap re-applies it, else document the manual step). Commit; verify `git ls-files | grep -E 'test_io|zig-pkg'` is empty.
- *Gotchas:* history still carries the blobs (size stays in `.git`); a full purge needs `git filter-repo`, which rewrites history — out of scope unless the user wants it. Removing from tracking is the safe 90% win.

**T0.1 — Hermetic test step.**
- *Approach:* in `build.zig`, stop wiring network/integration runs into `test_step`. Create `test-unit` (default-fast) and leave `test` as the full superset, OR keep `test` as the fast default and introduce `test-all` for CI.
- *Key steps:* identify the `test_step.dependOn(&run_{page,corpus,wpt,test262,daemon}.step)` lines (`build.zig:552/990/928/1195/709`); move them to dedicated steps; update CI (`ci.yml`) to call the superset so coverage is unchanged; update CLAUDE.md's "Build & Test" so the documented command matches reality.
- *Gotchas:* `test-page`/`test-e2e` "skip gracefully" without network but still compile + spawn servers; ensure the fast path truly avoids them. Don't drop any test from CI — only re-route.

---

## 6. Open Questions (need a human decision)

1. **History rewrite?** Untracking `test_io2`/`zig-pkg` (QW1/QW2) stops new bloat but leaves ~5.4 MB in `.git` history. Do you want a `git filter-repo` purge (rewrites history, disrupts any clones/PRs) or is untracking enough?
2. **`zig-pkg/` intent.** Is the tracked `zig-pkg/` an *intentional* vendored copy (the patched `quickjs_ng/build.zig` per DEV_NOTES.md #1) that should be moved under `third_party/` and documented — or purely accidental? That decides whether QW2 is "untrack" or "relocate + document".
3. **`ConnectionPool` fate (T2.1).** Delete the dead pool, or is it scaffolding for an imminent daemon-concurrency feature that should be wired instead?
4. **Decompressed-body cap value (T1.1).** What's the largest legitimate page AWR must render? That sets the cap (suggest 64 MiB unless you have a target).
5. **`awr mcp` status (M9).** Promote MCP stdio out of DEFERRED (spec amendment) and support it, or gate it behind a build flag / hidden flag until then?
6. **`image/` re-review.** The image-decoder reader (stb_image integer-overflow / malformed-image handling) did not complete due to the session limit — schedule a focused pass before relying on image decode against hostile sources?

---

*Prior audits for delta tracking: `reports/2026-06-11-repo-audit.md` (grade B; #1 "no CI" → fixed, #2 "decompression DoS" → still open as H1, "8 KB truncation" → fixed). This audit re-confirms the open DoS and adds the new hygiene/doc-drift regressions.*
