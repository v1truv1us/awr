# AWR Dev Notes

## Installing Zig 0.16 in this environment (Linux x86_64)

Per Zig's official Getting Started guide, the reliable approach here is
**direct download + checksum verification** (not `apt`) because this base
image does not provide a `zig` package.

```bash
cd /tmp
curl -L --fail -o zig-x86_64-linux-0.16.0.tar.xz \
  https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
echo '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  zig-x86_64-linux-0.16.0.tar.xz' | sha256sum -c -
tar -xf zig-x86_64-linux-0.16.0.tar.xz
PATH=/tmp/zig-x86_64-linux-0.16.0:$PATH zig version
```

For repeatable local use in this repo, prefix build/test commands with that
PATH, e.g.:

```bash
PATH=/tmp/zig-x86_64-linux-0.16.0:$PATH zig build -Doptimize=ReleaseSafe
```

Notes:

- `apt-get install zig` fails in this environment (`Unable to locate package zig`).
- If `zig build` fails with `invalid HTTP response: HttpConnectionClosing`
  while resolving `build.zig.zon` deps, run `./scripts/bootstrap_deps.sh`.
  The build now reads `libxev` and `zig-quickjs-ng` from local git checkouts
  under `third_party/` to avoid Zig's HTTP fetch path.
- If `liblexbor` is missing on Linux, run `./scripts/bootstrap_lexbor.sh`
  and build with `-Dlexbor-prefix=third_party/lexbor/install`.

## Zig 0.16 migration — patch debt

On 2026-04-18 this tree was migrated from Zig 0.15 to 0.16 to pick up
std.Io / build-system changes. A few patches are *local* and need more
durable follow-up work tracked here so we don't forget them.

### 1. `zig-pkg/quickjs_ng-…/build.zig` — patched in-place

**What:** `lib.linkLibC()`, `lib.addIncludePath(...)`, `lib.addCSourceFiles(...)`
and `tests.linkLibrary(lib)` (all `Compile`-level calls) were moved to the
`Module` level per Zig 0.16's build-system rework.

**Why it's a problem long-term:** the Zig package cache is content-addressed
by hash, and `zig build` will re-fetch the upstream tarball whenever the
entry under `zig-pkg/` is cleared. Any re-fetch wipes the patch.

**Durable fix:**

- **Option A (preferred):** send a PR to `mitchellh/zig-quickjs-ng` that
  updates its `build.zig` to the 0.16 API, then bump the URL hash in
  `build.zig.zon`.
- **Option B:** vendor `quickjs-ng` under `third_party/quickjs-ng/` with our
  own Zig-0.16-compatible `build.zig` and drop the network dependency.

Until either is done, treat `zig-pkg/` as part of the repo for 0.16 builds.

### 2. `build.zig.zon` — libxev hash drift

The `libxev` URL points at `refs/heads/main.tar.gz`, which is a moving
target. Zig 0.16 refused the old hash; we updated it to
`libxev-0.0.0-86vtcwIRFACVrx54GaHsMFFlyC4dTi0tcVh10V7btRUc`.

**Durable fix:** pin to a tagged release (or a commit-specific tarball URL)
so the hash never drifts from under us.

### 3. `src/*.zig` — `std.io` → `std.Io`, new Writer API

0.16 replaces `std.io.fixedBufferStream(&buf)` / `fbs.writer()` /
`fbs.getWritten()` with:

```zig
var w = std.Io.Writer.fixed(&buf);
try w.writeAll("…");
const out = w.buffered();
```

and removes `std.io.GenericReader(…)`. All sites were ported locally. No
upstream cleanup required, but any future merges from older Zig branches
need the same treatment.

### 4. `build.zig` — macOS/Linux platform detection

Hard-coded `/opt/homebrew/opt/{libnghttp2,lexbor}` paths were replaced with
a `is_mac` branch that falls back to Debian/Ubuntu system paths on Linux.
Lexbor is not in apt; on Linux it is built from source into
`/usr/local/{include,lib}` (see `third_party/lexbor/BUILD_NOTES.md` once
the build script is added).

**Durable fix:** add a `build.zig` option like `-Dlexbor-prefix=…` so CI
and contributors can point to any install layout without patching.

### 5. BoringSSL smoke tests are macOS-only

The vendored BoringSSL under `third_party/boringssl/lib/macos-arm64/` is
macOS/arm64 only. `build.zig` now skips the `test-tls` step entirely on
Linux. Phase 3 fingerprinting work will need Linux/x86_64 static libs
before this gate can run in CI.

### 6. Owned HTTP stack rewrite (client.zig / http1.zig / tcp.zig)

Zig 0.16 removed `std.net.getAddressList`, `std.io.GenericReader`, and the
buffered-reader helpers (`readUntilDelimiter`, `readNoEof`,
`fixedBufferStream(raw).reader()`) that the pre-0.16 owned HTTP/1.1 stack
depended on. As a short-term unblock:

- `src/client.zig::fetchHttp` and `fetchHttpsViaStd` are stubbed and return
  `FetchError.ConnectionFailed` / `FetchError.TlsNotAvailable`. The MVP
  uses `Page.processHtml` with in-memory HTML (and the `file://` CLI path).
- `src/net/http1.zig::readResponse` itself is now dead code in the MVP.
  Its five unit tests are gated behind `error.SkipZigTest`.

**Durable fix:** rewrite the owned HTTP path against `std.Io.Reader` and
`std.Io.File` (requires a top-level `std.Io` handle threaded from `main()`
→ `Page` → `Client`). Tracked as Phase 3 prerequisite alongside BoringSSL
+ JA4+ Chrome 132 fingerprinting.

### 7. gVisor / Zig 0.16 Debug startup — `integer overflow` in PHDR walk

**Root cause (upstream bug in Zig 0.16):**
`lib/std/debug/SelfInfo/Elf.zig` iterates the loaded program headers via
`dl_iterate_phdr`.  Inside the callback, both the `.NOTE` branch (line
460) and the `.GNU_EH_FRAME` branch (line 472) compute
`info.addr + phdr.vaddr` with non-wrapping addition.  The VDSO on
Linux/x86_64 is mapped with `phdr.vaddr = 0xffffffffff700000`, so the
add overflows `usize` and Debug-mode safety checks panic with
`integer overflow`.  The matching `.LOAD` branch already uses
`+%` (line 497) with the comment "Overflowing addition handles VDSOs
having p_vaddr = 0xffffffffff700000" — the two sister branches just
missed the `+%`.

**Where it fires in AWR:**
Any Debug binary that makes an allocation before `main()` runs will
hit this.  Zig's startup (`lib/std/start.zig::callMain`) constructs
the `std.process.Init` bundle by calling
`std.process.Environ.createMap(gpa, …)`, which performs its first
heap allocation through `DebugAllocator.alloc`.  `DebugAllocator`
captures a stack trace on every allocation (`stack_trace_frames = 6`
by default in Debug) which walks PHDRs and trips the overflow.  The
panic therefore lands before any user code, with no stack trace
printed because `std.debug.defaultPanic` then deadlocks on its own
stderr mutex while attempting the trace.

- **Repro:** `./zig-out/bin/awr --version` in a Debug build.
- **Stack trace** (captured under `gdb -ex 'rbreak
  ^debug.FullPanic.*integerOverflow$'`):
  `DlIterContext.callback → posix.dl_iterate_phdr → SelfInfo.Elf.findModule
  → StackIterator.next → captureCurrentStackTrace →
  DebugAllocator.collectStackTrace → DebugAllocator.alloc →
  Environ.createMap → start.callMain`.
- **ReleaseSafe side-steps it** because with `link_libc` it selects
  `std.heap.c_allocator` instead of `DebugAllocator`, so no per-alloc
  stack trace is captured.

**Fix in-repo (src/main.zig):**
`pub fn main` now accepts `std.process.Init.Minimal` instead of the
full `std.process.Init`.  Zig's `callMain` branches on the parameter
type and, for `Minimal`, skips the `DebugAllocator` wiring entirely.
We build `gpa = std.heap.c_allocator`, `ArenaAllocator`, and
`std.Io.Threaded` ourselves from `minimal.args` / `minimal.environ`,
matching what `callMain` does for `Init` but without the buggy
allocator.  Trade-off: Debug builds no longer get `DebugAllocator`'s
leak detection for the CLI entry point; tests continue to use it via
their own harness.

**Durable fix:** upstream a Zig PR that changes the two sites to
`info.addr +% phdr.vaddr`, then the `Init.Minimal` workaround in
`src/main.zig` can be lifted.  The matching test-runner panic (see
below) also goes away at the same time.

**Test runner still blocked here:** `zig build test-*` invokes the
stock Zig test binary, whose `std.Progress.start` hits the same PHDR
walk via a Debug allocation during startup.  Tests compile cleanly —
they just can't be driven in this container.  No test-side workaround
yet; move to native x86_64 CI or wait for the upstream fix.

### 8. `zig build install` fails on v9fs (environment-only)

The default install step uses `std.Build.Step.Options.atomic_file.link`,
which calls `renameat2(..., RENAME_NOREPLACE)`. v9fs (the gVisor 9p
filesystem) rejects that flag with `EINVAL`. Specific build steps
(`test-page`, `test-dom`, …) work fine since they skip the options-file
install path.

**Durable fix:** same environment caveat as #7 — disappears off v9fs.

### 9. JS_Eval input must be null-terminated

QuickJS-NG's `JS_Eval(ctx, input, input_len, …)` reads `input[input_len]`
during UTF-8 validation and will throw `SyntaxError: invalid UTF-8 sequence`
if that byte is not `0`, even when `input_len` is correct. Slices produced
by `std.mem.trim`, `bufPrint` into an uninitialised stack buffer, or any
view over a larger buffer do *not* guarantee that property.

Inside AWR this bit us in two places (both fixed):

- `src/page.zig::executeScriptsInElement` — the trimmed script source is
  now copied into `allocSentinel(u8, …, 0)` before `js.eval`.
- `src/page.zig::callTool` — `resolve_buf` is now `std.mem.zeroes([128]u8)`
  so the byte after the formatted expression is 0.

**Durable fix:** expose a `evalOwned(source: [:0]const u8, …)` helper in
`src/js/engine.zig` so the type system enforces the sentinel, and migrate
all callers. Until then, any new caller that `eval`s a sliced buffer needs
to zero-init or copy to a sentinel slice.

### 10. `querySelector`/`querySelectorAll` supports descendant combinator

`src/dom/node.zig::matchesSelector` originally only handled
`tag`/`#id`/`.class`/`tag#id`/`tag.class`. The WebMCP mock uses
`document.querySelectorAll('#catalog li')`, which requires the descendant
combinator. `Document.querySelectorAll` now detects whitespace in the
selector string and delegates to `collectCompound`, which splits on
whitespace and applies each term to children of the previous match-set.

**Limitations:** attribute selectors, `:not()`, `~`/`+`/`>` combinators,
and multi-class selectors (`li.foo.bar`) are still unsupported. A durable
fix is to swap in a real CSS-selector parser (e.g. call into lexbor's own
selector engine) once Phase 3 work on the DOM layer lands.

## HTTP fetch architecture — keep-alive on two paths

AWR has *two* HTTP fetch paths and you need to keep them straight when
debugging perf or correctness:

1. **`fetchOnceStd`** — uses `std.http.Client` (Zig's pure-Zig TLS +
   HTTP/1.1). Fast for sites whose TLS handshake the std stack can
   complete (example.com, Wikipedia, MDN). Does **not** carry AWR's
   Chrome-style JA4 fingerprint.
2. **`fetchOnceBoringSslHttp1`** — uses BoringSSL via the
   `tls_awr_shim.c` C interop, with the curated cipher/extension order
   that produces the JA4. Falls back to here when std throws
   `TlsNotAvailable`. This is the path that ships AWR's product value.

Both paths now keep connections alive across same-origin requests, but
via different mechanisms — and there are two non-obvious bugs that took
the *originally landed* P1 commit (`7cdba9f`) from "expected 40-60%
reduction" to "no measurable improvement on real sites." Document both
so the next refactor doesn't re-introduce them.

### Bug 1: chunked + gzip leaves the std reader off `.ready`

`std.http.Client.Request.deinit` only releases a connection back to the
pool when `r.reader.state == .ready`. For chunked transfer encoding,
`.ready` is reached only when the chunked terminator (`0\r\n\r\n`) has
been parsed.

When the server responds with **chunked + gzip** (Wikipedia, MDN, HN —
basically every modern origin), `streamRemaining` on a *decompressing*
reader stops at the gzip trailer, before the chunked terminator. The
underlying transfer reader stays in `.body_remaining_chunk_len`, so
`Request.deinit` falls into the `else => true` branch, marks
`connection.closing = true`, and the pool destroys the connection.

**Fix in `fetchOnceStd`:** after `streamRemaining`, if the underlying
reader's state is still `.body_remaining_*`, call
`req.reader.interface.discardRemaining()` to drain the chunked
terminator (or any leftover content-length bytes). State advances to
`.ready` and the pool keeps the connection. See `src/client.zig`
following `streamRemaining`.

### Bug 2: every BoringSSL fetch was paying a doomed std attempt

`fetchOnce` always tries `fetchOnceStd` first, falling back on
`TlsNotAvailable`. For hosts that *will never* succeed with std (HN
throws `TlsInitializationFailed` on every attempt), this costs ~100-160
ms per request — a fresh TCP+TLS handshake before std gives up. That
overhead alone wiped out most of the BoringSSL keep-alive savings.

**Fix:** `Client.std_tls_failed_hosts` records hosts where std's TLS
init has failed. `fetchOnce` checks the cache before attempting std and
goes straight to BoringSSL on a hit. Cache lives for the Client's
lifetime; never invalidated (a session is short enough that origins
don't change TLS posture mid-flight).

### BoringSSL pool design notes

`BoringSslPool` (in `src/client.zig`, gated on `boringssl_fallback`)
keeps `(host, port) -> *Entry` mappings, with each entry owning its
`TcpConn + TlsCtx + TlsConn + TlsBufferedReader`.

Why the reader lives **inside** the entry rather than being recreated
per request: `TlsBufferedReader.readUntilDelimiter` can over-read past
the line it's parsing (it pulls up to 8KB into its internal buffer at a
time). Those buffered bytes belong to the next response's framing — if
we drop the reader between requests, we lose them and the next response
fails to parse. Keep the reader alive with the connection.

Why HTTP/1.1 (vs the original HTTP/1.0): keep-alive is the implicit
default in 1.1. We deliberately **omit** the `Connection: close` header
and trust the server to leave the connection open. If the server
responds with `Connection: close` we discard the entry instead of
releasing it. Same behavior on hitting `MAX_REQUESTS_PER_CONN` (100,
matching Chrome's published limit).

Why per-Client (not global): no thread-safety story today, and a
session-scoped pool is the right abstraction for a CLI browser. The
pool is destroyed in `Client.deinit`, which closes every entry's TLS
and TCP cleanly.

### Bench-driven debug recipe

`AWR_TIMING=1` on any `awr <url>` invocation prints per-phase wall-clock
(probe in `src/page.zig`). Phases:

  - `js_reset` / `parse` / `bridge` — pre-script setup
  - `prefetch` — total time inside `prefetchExternalScripts` (worker pool)
  - `scripts` — total time inside `executeScriptsInElement`
  - `  ext_cache` — per-script body served from prefetch cache (≈0ms)
  - `  ext_fetch` — per-script body fetched on the main Client (cache miss)
  - `  ext_run`   — per-external-script QuickJS eval
  - `drain_interactive` / `drain_load` — drainAll budgets
  - `extract` — title/body/window-data extraction
  - `total`   — sum from start of processHtml

If `ext_fetch` for a same-origin sub-resource is much higher than what
`curl --next` produces against the same URL, the connection pool is not
reusing — check both bugs above.

If `prefetch` is high but every `ext_cache` shows 0ms, that's the
expected pattern: the worker pool paid the network cost up front so
the main thread can stream-eval scripts in document order without
blocking on I/O.

## Parallel script prefetch — `ScriptPrefetchCache`

For pages with many same-origin `<script src>` tags (github, go.dev),
serial fetching dominates total time even with keep-alive: 60 scripts
× ~25ms RTT = 1.5s of pure round-trips. The prefetch subsystem
(`src/page.zig`) walks the DOM up front, collects unique URLs in
document order, and fans them out to a small worker pool that fills a
shared cache. `runExternalScript` reads from the cache and falls back
to a direct fetch on miss — preserving document-order eval semantics
while overlapping the network.

### Why per-worker `std.Io.Threaded`

The first cut shared one `Io` capability (`Page.io`) across worker
threads. That panicked inside `std.Io.Threaded.posixConnect` with
`syscall error: ISCONN` — `groupAsync`'s happy-eyeballs DNS scheduler
holds shared task state and isn't reentrant from multiple OS threads.
The fix: each worker calls `std.Io.Threaded.init(allocator, .{})` and
gets its own `Io`. Threaded's `argv0`/`environ` defaults of `.empty`
are fine — those only matter for `processSpawn` and OpenBSD/Haiku
`processExecutablePath`.

### Why a `SpinLock` instead of `std.Thread.Mutex`

Workers process disjoint URL strides, so cache contention is rare —
typically just `StringHashMap`'s rehash-on-growth. With ~6 workers and
microsecond-scale critical sections, a syscall-free atomic spin lock
beats a Mutex's wakeup overhead. Plus: `std.Thread.Mutex` doesn't
exist in Zig 0.16 (moved to `std.Io.Mutex`, which would need an `Io`
capability we don't want to thread through). The `SpinLock` is 9
lines, uses `std.atomic.Value(u8).cmpxchgWeak`, and is correct under
the workload (no priority inversion, no long holds).

### Cookie limitation

Each worker has its own `Client` and therefore its own cookie jar.
`Set-Cookie` headers from script responses do **not** propagate to the
main `Client`. Workers also have `persist_cookies = false` forced —
concurrent file writes to one jar would race. Acceptable for static
page rendering; revisit if a real auth-gated subresource scenario
appears.

## body_text extraction — `textContent` vs `textContentForExtract`

Two near-identical methods on `dom.Element`, intentionally:

- **`textContent`** is the DOM-spec-compliant version. It concatenates
  every descendant text node, including the source code inside
  `<style>`, `<script>`, `<noscript>`, and `<template>` elements. The
  curated WPT corpus asserts this exact behaviour. Do **not** filter
  here.
- **`textContentForExtract`** is the agent-facing variant. It walks the
  same tree but skips descendants of opaque-content tags
  (`<style>`, `<script>`, `<noscript>`, `<template>`). The JSON
  envelope's `body_text` field uses this method
  (`src/page.zig` body_text block).

Why both exist: the JSON envelope promises "page text" to consumers
(LLMs, scripts), but the DOM contract requires source code to be
visible via `textContent`. Splitting the two preserves WPT compliance
without leaking ~30 KB of CSS into agent context windows on
MDN-class pages. Verified pre/post on
`https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select`:
body_text shrank from 76 677 → 32 879 chars (45 CSS blocks → 0).

If a future caller needs an even more aggressive Reader-View extract
(omit nav/header/footer chrome, not just opaque content), use
`page.renderBrowseModel(...)` instead — that is what `awr render`
emits and what the corpus runner snapshots.
