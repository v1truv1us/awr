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

### 7. gVisor / Zig 0.16 test runner blocker (environment-only)

On the gVisor-backed Linux container used in CI, Zig 0.16's test runner
panics with `integer overflow` during `std.Progress.start` (stack trace
via `mainTerminal`). The panic is environmental — a tiny reproducer
(`test "x" {}`) works in a plain Linux container — and blocks only
running the test binaries, not compiling them. `zig build test-page` and
`zig build test-dom` both compile cleanly; the runner simply can't be
driven here.

**Durable fix:** confirm on native x86_64 Linux in CI (no gVisor). No
code change required.

### 8. `zig build install` fails on v9fs (environment-only)

The default install step uses `std.Build.Step.Options.atomic_file.link`,
which calls `renameat2(..., RENAME_NOREPLACE)`. v9fs (the gVisor 9p
filesystem) rejects that flag with `EINVAL`. Specific build steps
(`test-page`, `test-dom`, …) work fine since they skip the options-file
install path.

**Durable fix:** same environment caveat as #7 — disappears off v9fs.
