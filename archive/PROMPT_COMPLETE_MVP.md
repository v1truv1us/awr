# AWR MVP Completion Prompt for Claude Code

You are completing the AWR project — a CLI-first web browser runtime written in Zig. The codebase is functionally complete with 25 source files (~12K lines), 13 test targets, 170+ test cases all green, verified Chrome 132 TLS fingerprint, and all 7 CLI commands working at the test level. However, the binary does not compile due to 10 Zig 0.16 migration errors, and several quality/coverage gaps remain.

Work through the backlog below in strict priority order. Each section is a self-contained deliverable. Do not skip ahead. Commit at logical checkpoints so every green-test state is a rollback point.

---

## INVARIANT RULES (read once, follow always)

1. **TLS fingerprint is sacred.** Never change cipher suite order, TLS extension order, HTTP/2 SETTINGS values, or JA4 string constants in `src/net/fingerprint.zig`. Run `zig build test-tls` after ANY change to `src/net/`.
2. **Header order is load-bearing.** Headers are `ArrayList` preserving insertion order. Never sort, deduplicate, or reorder them.
3. **BoringSSL is pre-built.** Static libs in `third_party/boringssl/lib/macos-arm64/`. Never attempt to compile BoringSSL from source.
4. **`use_llvm = true`** for any build target linking QuickJS-NG (see `build.zig` pattern).
5. **macOS/arm64 only.** Homebrew paths (`/opt/homebrew/`) are hardcoded.
6. **WPT-first.** Prefer conformance coverage (WPT/Test262) over custom surface area.
7. **Tests co-located** at bottom of each `.zig` file, except `tests/` directory for integration/conformance.
8. **Explicit allocators** everywhere. `errdefer` on all failure paths.
9. **Network tests skip gracefully** — print `"skipping..."` and return, never fail.
10. **One priority block per session.** Do not interleave work across priority blocks.
11. **All 6 test gates must stay green** after every change:
    ```
    zig build test && zig build test-e2e && zig build test-render && zig build test-wpt && zig build test-test262 && zig build test-tls
    ```

---

## P0 — FIX THE BUILD (blocker for everything else)

### Task: Complete Zig 0.16 migration — 10 compilation errors

The test layers all compile and pass. The binary build (`zig build`) has exactly 10 errors. Fix them all.

#### Error 1: `std.http.Client` missing `io` field
- **File:** `src/client.zig:486`
- **Error:** `missing struct field: io`
- **Fix:** `std.http.Client` now requires `io: Io` field. Thread an `Io` instance through from the CLI entry point. See Zig 0.16 `std.http.Client` struct definition — you need to initialize with something like:
  ```zig
  var io = std.Io.init();
  defer io.deinit();
  var std_client = std.http.Client{
      .allocator = self.allocator,
      .read_buffer_size = 64 * 1024,
      .io = &io,
  };
  ```
  The `Io` instance may need to live at a scope that outlives the `std_client`. Check the Zig 0.16 stdlib for the exact API.

#### Error 2-3: `std.time.timestamp()` removed
- **File:** `src/net/cookie.zig:101`, `src/net/cookie.zig:151`, `src/net/cookie.zig:188`
- **Error:** `struct 'time' has no member named 'timestamp'`
- **Fix:** In Zig 0.16, `std.time.timestamp()` and `std.time.milliTimestamp()` no longer exist. Replace with:
  - For epoch seconds: use `std.posix.system.clock_gettime` with `.REALTIME`, or create a small wrapper function
  - Alternatively, check if Zig 0.16 provides `std.time.Instant` or similar. Read the actual Zig 0.16 `std/time.zig` to find the replacement.
  - Recommended: create `src/io_compat.zig` with `pub fn epochSeconds() i64` and `pub fn milliTimestamp() i64` using `std.posix.clock_gettime`, then import it in cookie.zig and pool.zig.

#### Error 4: `std.time.milliTimestamp()` removed
- **File:** `src/net/pool.zig:33` (also check lines 84, 95, 119)
- **Error:** `struct 'time' has no member named 'milliTimestamp'`
- **Fix:** Same as Error 2-3. Use the same `io_compat.zig` helper.

#### Error 5-6: `ArrayList` init `.{}`
- **File:** `src/net/http1.zig:19`, `src/net/pool.zig:43`
- **Error:** `missing struct field: items`, `missing struct field: capacity`
- **Fix:** In Zig 0.16, `ArrayList(T)` default init changed from `.{} ` to `.empty`. Replace:
  - `std.ArrayList(T) = .{}` → `std.ArrayList(T) = .empty`
  - Search ALL source files for this pattern and fix consistently. Use `grep -rn '= \.{}' src/` to find them all.

#### Error 7: `std.net` removed
- **File:** `src/net/tcp.zig:64`
- **Error:** `struct 'std' has no member named 'net'`
- **Fix:** `std.net.Address` is gone in Zig 0.16. Replace with `std.posix` socket address types. Check what `std.posix` provides for sockaddr storage. The tcp.zig file uses `std.net.Address` for `remote_addr` field. You need to:
  1. Read the Zig 0.16 `std/posix.zig` to find the replacement for `std.net.Address`
  2. Replace `remote_addr: std.net.Address` with the correct type
  3. Update `init()` to use the new address resolution API
  4. Update `connect()` to use `std.posix.connect` with the correct sockaddr

#### Error 8-9: libxev uses removed `std.net` and `posix.KEventError`
- **File:** `zig-pkg/libxev-.../src/backend/kqueue.zig:1546`, `kqueue.zig:1652`
- **Error:** `struct 'std' has no member named 'net'`, `struct 'posix' has no member named 'KEventError'`
- **Fix:** This is in the vendored dependency. Two approaches (try in order):
  1. **Update the dependency:** Check if a newer version of libxev supports Zig 0.16. Look at `https://github.com/mitchellh/libxev` for recent commits. Update `build.zig.zon` with the new URL/hash.
  2. **Patch locally:** If no update is available, patch the two files in `zig-pkg/`:
     - Replace `std.net.Address` with the Zig 0.16 equivalent (same as Error 7)
     - Replace `posix.KEventError` — in Zig 0.16, `KEventError` was likely merged into a different error set or removed. Check `std.posix` for the current kevent error handling. It may just need to be removed from the error union if it no longer exists.
  3. **Note:** Since `zig-pkg/` is auto-generated from the zon hash, local patches will be overwritten if the dependency is re-fetched. An upstream update is preferred. If you must patch, document the patches clearly.

#### Error 10: `browser.zig` writer API change
- **File:** `src/browser.zig:433`
- **Error:** `member function expected 2 argument(s), found 1`
- **Fix:** `File.writer()` in Zig 0.16 now requires `(io: Io, buffer: []u8)` arguments. Thread an `Io` instance and buffer through. The call is:
  ```zig
  var stdout_writer = terminal.stdout_file.writer(&stdout_buffer);
  ```
  Needs to become something like:
  ```zig
  var stdout_writer = terminal.stdout_file.writer(io, &stdout_buffer);
  ```
  Check the actual Zig 0.16 `std.Io.File.writer` signature. You may need to create and manage an `Io` instance in `browser.zig`.

#### Recommended approach for the whole task:

1. **Create `src/io_compat.zig`** — a small shim providing:
   - `epochSeconds() i64` — returns Unix epoch seconds
   - `milliTimestamp() i64` — returns milliseconds since some epoch
   - Any other Zig 0.16 compat helpers needed
   Use `std.posix.clock_gettime` or the Zig 0.16 equivalent internally.

2. **Fix `ArrayList` init** — global search-and-replace `.{} ` → `.empty` for ArrayList defaults.

3. **Fix `std.net` removal** — replace with `std.posix` types in tcp.zig (and libxev if needed).

4. **Fix `std.time` removal** — use io_compat.zig in cookie.zig and pool.zig.

5. **Fix Io threading** — add `Io` instances where needed in client.zig and browser.zig.

6. **Fix or update libxev** — check for upstream Zig 0.16 support first.

#### Verification:
```bash
zig build                    # MUST compile with zero errors
./zig-out/bin/awr --version  # prints version
./zig-out/bin/awr --help     # prints usage
```

Then run the full gate:
```bash
zig build test && zig build test-e2e && zig build test-render && zig build test-wpt && zig build test-test262 && zig build test-tls
```

Then smoke-test the binary:
```bash
./zig-out/bin/awr --no-color --width 80 https://example.com
```

#### Commit: `fix: complete Zig 0.16 migration — binary builds clean`

---

## P0 — GZIP/DECOMPRESSION

### Task: Add gzip/deflate response decompression

Chrome headers (in `src/net/fingerprint.zig`) send `Accept-Encoding: gzip, deflate, br`. Compressed responses arrive but there's no decompression step. Many tests work around this with `use_chrome_headers = false`.

**Steps:**
1. Read `src/client.zig` to find where response bodies are read (the `Response` struct and where raw bytes come in).
2. Check the `Content-Encoding` response header after reading headers.
3. If `gzip` or `deflate`, decompress the body before returning it.
4. Use Zig's `std.compress.gzip` and `std.compress.deflate` from the stdlib — verify they exist in Zig 0.16 first.
5. Do NOT modify the fingerprint headers — keep sending `Accept-Encoding`.
6. Remove or minimize `use_chrome_headers = false` workarounds in tests where the response body was the issue (not all workarounds are compression-related).

**Files to modify:**
- `src/client.zig` — add decompression step in response processing
- Test files that use `use_chrome_headers = false` — evaluate which can now use chrome headers

**Verification:**
```bash
zig build test && zig build test-e2e && zig build test-render
./zig-out/bin/awr --no-color --width 80 https://example.com
./zig-out/bin/awr --no-color --width 80 https://news.ycombinator.com
```

#### Commit: `feat: add gzip/deflate response decompression`

---

## P0 — REFRESH EXPERIMENT LOG

### Task: Rerun fetch matrix and update experiments/README.md

The experiment log at `experiments/README.md` has stale entries. After the build fix and decompression are done, rerun the fetch matrix.

**Steps:**
1. Run each site and capture the result:
   ```bash
   ./zig-out/bin/awr --no-color --width 80 http://example.com
   ./zig-out/bin/awr --no-color --width 80 http://news.ycombinator.com
   ./zig-out/bin/awr --no-color --width 80 https://github.com
   ./zig-out/bin/awr --no-color --width 80 https://x.com
   ```
2. Replace the dated table in `experiments/README.md` with a new dated entry showing current status.
3. Remove stale CRASH/ERROR references if they're resolved.
4. Update the "Changes since" section to reflect all work done.

**Files to modify:**
- `experiments/README.md`

**Verification:** The file should have a clean dated table with current results, no stale entries.

#### Commit: `docs: refresh experiment log with current results`

---

## P1 — GROW WPT CURATED SET

### Task: Expand WPT coverage from 24 to ~40 assertions

Current state: 11 test files in `tests/wpt/`, 24 assertions. Each test file is a `.js` file that uses a `testharness_shim.js` to report `{name, status, message}` results.

**What to add (test files + assertions):**

1. **`document_parentElement.js`** — `element.parentElement` returns parent element, null for document root
2. **`document_childNodes.js`** — `element.childNodes` returns live NodeList, verify length and access
3. **`document_firstChild_nextSibling.js`** — `element.firstChild`, `element.nextSibling` traversal
4. **`element_setAttribute_getAttribute.js`** — `setAttribute` then `getAttribute` roundtrip, verify value matches
5. **`attribute_selector.js`** — `querySelector('[data-x]')` selects elements with matching attribute
6. **`pseudo_first_child.js`** — `querySelector(':first-child')` returns correct first child
7. **`pseudo_nth_child.js`** — `querySelector(':nth-child(2)')` returns correct nth child
8. **`document_getElementsByClassName.js`** — returns collection of elements with given class
9. **`document_getElementsByTagName.js`** — returns collection of elements with given tag

**Implementation pattern:**
- Create new `.js` files in `tests/wpt/` following existing pattern (use `test()` and `assert_equals()` from testharness_shim)
- Add entries to the `curated_cases` array in `tests/wpt_runner.zig`
- Each case provides: filename, html fixture, and script (via `@embedFile`)
- Look at existing files like `tests/wpt/document_querySelector.js` for the pattern

**Files to create/modify:**
- New `.js` files in `tests/wpt/`
- `tests/wpt_runner.zig` — add new cases to `curated_cases`

**Verification:**
```bash
zig build test-wpt
```
Count assertions — should be ~40. All must pass.

Then run full gate:
```bash
zig build test && zig build test-e2e && zig build test-render && zig build test-wpt && zig build test-test262 && zig build test-tls
```

#### Commit: `test: expand WPT curated set to ~40 assertions`

---

## P1 — GROW TEST262 CURATED SET

### Task: Expand Test262 coverage from 7 to ~20 cases

Current state: 7 cases in `tests/test262_runner.zig`. Each case is `{name, source, probe, expected, drain_microtasks}`.

**What to add:**

1. **try/catch/finally** — verify catch block executes on throw, finally always runs
2. **custom Error subclass** — `class MyError extends Error` works
3. **Array.map** — `[1,2,3].map(x => x*2)` returns `[2,4,6]`
4. **Array.filter** — `[1,2,3,4].filter(x => x > 2)` returns `[3,4]`
5. **Array.reduce** — `[1,2,3].reduce((a,b) => a+b, 0)` returns `6`
6. **Array.find** — `[1,2,3].find(x => x > 1)` returns `2`
7. **Array.some** — `[1,2,3].some(x => x > 2)` returns `true`
8. **Array.every** — `[1,2,3].every(x => x > 0)` returns `true`
9. **String.split** — `"a-b-c".split("-")` produces `["a","b","c"]`
10. **String.replace** — both string and regex forms
11. **String.match** — `"abc123".match(/\d+/)` returns match
12. **String.includes** — `"hello world".includes("world")` returns `true`
13. **Regex literal** — `/test/.test("testing")` returns `true`
14. **RegExp constructor** — `new RegExp("\\d+").exec("abc123")` works
15. **Promise.reject + .catch** — rejection propagates to catch handler
16. **async function throw** — async function that throws, error caught
17. **Array.from** — `Array.from({length: 3}, (_, i) => i)` produces `[0,1,2]`
18. **Object.entries** — `Object.entries({a:1, b:2})` returns key-value pairs
19. **Spread operator** — `[...[1,2], ...[3,4]]` produces `[1,2,3,4]`
20. **Default parameters** — `function f(x = 5) { return x; }` works with and without args

**Implementation pattern:**
- Add entries to the `curated_cases` array in `tests/test262_runner.zig`
- Each case writes result to `globalThis.__test_result__`, probed with `String(globalThis.__test_result__)`
- For array/object results, convert to JSON string: `JSON.stringify(result)`
- For async/Promise cases, set `drain_microtasks = true`

**Files to modify:**
- `tests/test262_runner.zig`

**Verification:**
```bash
zig build test-test262
```
Count should be ~20-27. All must pass.

Then full gate.

#### Commit: `test: expand Test262 curated set to ~20 cases`

---

## P2 — MLKEM768 KEY SHARE BYTE-LEVEL ASSERTION

### Task: Add byte-level proof that MLKEM768 key share is correctly positioned

The JA4 fingerprint test proves the fingerprint matches, but there's no byte-level assertion that the X25519MLKEM768 key share is at `named_groups[1]` with a 1216-byte payload.

**Steps:**
1. Read `src/net/tls_conn.zig` — specifically the `connect()` function and the ClientHello construction path.
2. Find where the key shares are built (should reference `fingerprint.zig` constants).
3. Add a test at the bottom of `tls_conn.zig` that:
   - Constructs a ClientHello (or captures the raw bytes from the handshake path)
   - Parses the `key_share` extension
   - Asserts `named_groups[0]` is X25519 (group 0x001d)
   - Asserts `named_groups[1]` is X25519MLKEM768 (group 0x6399 or whatever the code uses)
   - Asserts the MLKEM768 key exchange payload is exactly 1216 bytes
4. This is a verification test — the code already produces correct bytes (JA4 proves it). The test just makes the proof explicit.

**Files to modify:**
- `src/net/tls_conn.zig` — add test in the test section at bottom

**Verification:**
```bash
zig build test-tls
```
New test must pass. Existing JA4 test must still pass.

#### Commit: `test: add MLKEM768 key share byte-level assertion`

---

## P2 — CONCURRENT POOL STRESS TEST

### Task: Add stress test for max-6-per-origin connection limit

`src/net/pool.zig` has a basic thread test but doesn't exercise race conditions.

**Steps:**
1. Read the existing thread test in `src/net/pool.zig` test section.
2. Read `src/test_e2e.zig` for the local HTTP test server pattern (spawns a server on localhost with semaphore sync).
3. Create a stress test that:
   - Spawns a local HTTP server on localhost (reuse the pattern from test_e2e.zig)
   - Spawns >6 concurrent goroutines/threads that each acquire a connection to the same origin
   - Asserts that `pool.totalCount()` never exceeds 6 for that origin at any point
   - Tests both the acquire path (blocking when at max) and the release path (recycling)
4. The test should use `std.Thread` to spawn workers, with a shared atomic counter checked by a monitor thread.

**Files to modify:**
- `src/net/pool.zig` — add stress test in test section

**Verification:**
```bash
zig build test-net
```
New test must pass without deadlocks or assertion failures.

Then full gate.

#### Commit: `test: add concurrent pool stress test (max-6-per-origin)`

---

## P3 — DOC CONSOLIDATION

### Task: Collapse phase-named planning docs into canonical files

**Steps:**

1. **Read `archive/PHASE1_EXIT_STATUS.md`** — extract the 10/14 verification status items. Fold the relevant ones (items that are still partial or in-progress) into `MVP_ROADMAP.md` under a new "## Verification Status" section.

2. **Delete these files:**
   - `archive/PHASE1_CLOSURE_PLAN.md`
   - `archive/PHASE2_START_PLAN.md`
   - `archive/TLS_RESUME_PLAN.md`

3. **Keep `spec/Fingerprint-Plan.md`** as a forward-looking spec. Do not delete it.

4. **Update `MVP_BACKLOG.md`** — mark P3.7 as complete. Remove or strike through the completed items.

5. **Check `CLAUDE.md` and `AGENTS.md`** — if they reference any deleted docs, update the references to point to `MVP_PLAN.md` or `MVP_ROADMAP.md` instead.

**Files to modify:**
- `MVP_ROADMAP.md` — add verification status section
- `MVP_BACKLOG.md` — mark P3.7 complete
- `CLAUDE.md` — update references if needed
- `AGENTS.md` — update references if needed
- Delete: `archive/PHASE1_CLOSURE_PLAN.md`, `archive/PHASE2_START_PLAN.md`, `archive/TLS_RESUME_PLAN.md`

**Verification:** `grep -r "PHASE1_CLOSURE\|PHASE2_START\|TLS_RESUME_PLAN" *.md src/` should return no references.

#### Commit: `docs: collapse phase-named planning docs into canonical MVP files`

---

## FINAL VERIFICATION

After ALL backlog items are complete, run the complete verification suite:

```bash
# Build must be clean
zig build

# All 6 test gates must pass
zig build test && zig build test-e2e && zig build test-render && zig build test-wpt && zig build test-test262 && zig build test-tls

# Binary must work on real sites
./zig-out/bin/awr --version
./zig-out/bin/awr --help
./zig-out/bin/awr --no-color --width 80 https://example.com
./zig-out/bin/awr --no-color --width 80 https://news.ycombinator.com | head -40

# All CLI commands must work
./zig-out/bin/awr --json https://example.com
./zig-out/bin/awr eval https://example.com "document.title"
./zig-out/bin/awr --mcp https://example.com
```

Expected outcomes:
- `zig build` exits 0 with zero errors
- All test gates pass
- `awr example.com` renders readable terminal output
- `awr news.ycombinator.com` shows story titles as discrete lines, wrapped at 80 columns
- No stale phase-named planning docs at repo root
- WPT coverage ~40 assertions, Test262 ~20 cases
- `experiments/README.md` has a fresh dated table

---

## PROJECT ARCHITECTURE (reference)

```
src/main.zig              CLI entry point — 7 commands
src/client.zig            HTTP client (~1200 lines) — wires TLS+H1/H2+cookies+redirects+pooling
src/page.zig              Page orchestrator — fetch → parse → DOM → JS → render
src/render.zig            Terminal renderer (~1600 lines) — ANSI, word wrap, tables, links
src/browser.zig           TUI browser session — vim keys
src/tui.zig               Raw terminal I/O
src/webmcp.zig            navigator.modelContext polyfill
src/mcp_stdio.zig          MCP JSON-RPC 2.0 server
src/browse_heuristics.zig  Content extraction (readability-style)

src/net/
  tls_conn.zig            BoringSSL wrapper — Chrome 132 fingerprint handshake
  tls_smoke_test.zig      BoringSSL link smoke test
  http1.zig               HTTP/1.1 request/response
  http2.zig               HTTP/2 frame layer
  h2session.zig           HTTP/2 session management (nghttp2 C shim)
  tcp.zig                 TCP via libxev
  pool.zig                Connection pooling (keep-alive, ALPN routing)
  url.zig                 URL parser
  cookie.zig              RFC 6265 cookie jar
  fingerprint.zig         JA4 constants (Chrome 132) — DO NOT MODIFY
  tls_awr_shim.c          BoringSSL C interop shim
  h2_shim.c               nghttp2 C interop shim

src/js/engine.zig          QuickJS-NG wrapper — console, fetch(), setTimeout, Promises
src/html/parser.zig        Lexbor HTML parser wrapper
src/dom/node.zig           DOM tree types, querySelector, getElementById
src/dom/bridge.zig         JS ↔ DOM bridge

tests/
  wpt_runner.zig           Curated WPT DOM test harness
  wpt/                     WPT test JS fixtures (11 files)
  test262_runner.zig        Curated Test262 JS test harness

build.zig                  Build configuration (492 lines)
build.zig.zon              Package manifest (libxev, quickjs-ng deps)
```

## KEY RELATIONSHIPS

- `main.zig` → `page.zig` → `client.zig` → `net/*` (full pipeline for CLI)
- `page.zig` → `html/parser.zig` → `dom/node.zig` → `dom/bridge.zig` → `js/engine.zig` (page processing)
- `client.zig` → `net/tls_conn.zig` → `net/tcp.zig` (network path)
- `client.zig` → `net/h2session.zig` → `net/http2.zig` (HTTP/2 path)
- `client.zig` → `net/pool.zig` → `net/tls_conn.zig` + `net/h2session.zig` (connection management)
- `client.zig` → `net/cookie.zig` (cookie jar)
- `render.zig` → `dom/node.zig` (DOM to terminal output)
- `browser.zig` → `page.zig` + `render.zig` + `tui.zig` (interactive browser)

## ZIG VERSION CONTEXT

The project targets Zig 0.16.0 (installed at `/opt/homebrew/Cellar/zig/0.16.0/`). Key API changes from earlier Zig versions that affect this codebase:

- `std.net` module removed → use `std.posix` socket types
- `std.time.timestamp()` / `milliTimestamp()` removed → use `std.posix.clock_gettime` wrapper
- `std.http.Client` requires `io: Io` field
- `std.Io.Writer` replaced the old `std.io.Writer` / `FixedBufferStream` pattern
- `ArrayList` default init is `.empty` not `.{}`
- `std.Thread.Mutex` replaced by `std.atomic.Mutex` (spinlock with `tryLock`/`unlock`)
- `std.process.Init.Minimal` is the new main function signature
- `File.writer()` requires `(io: Io, buffer: []u8)` arguments
