# AWR Dev Notes

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
