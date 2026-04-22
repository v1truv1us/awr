# Build, Test, and MCP-Readiness Runbook

This runbook is the operational checklist for taking AWR from a fresh clone to a reproducible local build, test execution, and MCP-readiness verification.

## 1) Prerequisites

### Required toolchain

- **Zig 0.16.0** (installed from the official Zig downloads page)
- **lexbor v2.5.0** installed on the system include/lib path
- Linux x86_64 or macOS arm64

If Zig is missing, follow Zig's official Getting Started flow (download prebuilt archive, verify checksum, add `zig` to `PATH`). On Linux x86_64 in this repo's environment:

```bash
mkdir -p "$HOME/.local/opt" "$HOME/.local/bin"
cd /tmp
curl -L --fail -o zig-x86_64-linux-0.16.0.tar.xz \
  https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
echo '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  zig-x86_64-linux-0.16.0.tar.xz' | sha256sum -c -
tar -xf zig-x86_64-linux-0.16.0.tar.xz
mv zig-x86_64-linux-0.16.0 "$HOME/.local/opt/zig-0.16.0"
ln -sf "$HOME/.local/opt/zig-0.16.0/zig" "$HOME/.local/bin/zig"
export PATH="$HOME/.local/bin:$PATH"
zig version
```

Persist PATH for future shells:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Important hygiene note: install Zig under `/tmp` or `$HOME/.local`, **not** in the repository root. This avoids committing toolchain archives/directories and keeps diffs small.

Bootstrap lexbor locally (no `/usr/local` install required):

```bash
./scripts/bootstrap_lexbor.sh
```

By default this installs lexbor v2.5.0 under:

- `third_party/lexbor/install`

### Dependency bootstrap (required before first build)

This repo now uses **path dependencies** for `libxev` and `zig-quickjs-ng`
to avoid Zig HTTP fetch failures seen in constrained environments.
Bootstrap them once:

```bash
./scripts/bootstrap_deps.sh
```

This script clones pinned commits into:

- `third_party/libxev/`
- `third_party/zig-quickjs-ng/`
- `third_party/quickjs-ng-quickjs/`

It also patches `third_party/zig-quickjs-ng/build.zig.zon` to use the local
`quickjs-ng-quickjs` checkout so Zig does not need to fetch nested tarballs.
All of these directories are intentionally gitignored.

## 2) Build steps

From repository root:

```bash
./scripts/bootstrap_deps.sh
./scripts/bootstrap_lexbor.sh
PATH="$HOME/.local/bin:$PATH" zig build -Doptimize=ReleaseSafe \
  -Dlexbor-prefix=third_party/lexbor/install
```

Expected artifact:

- `zig-out/bin/awr`

Quick sanity checks:

```bash
./zig-out/bin/awr --version
./zig-out/bin/awr tools experiments/webmcp_mock.html
./zig-out/bin/awr call experiments/webmcp_mock.html get_price '{"sku":"w-001"}'
```

## 3) Test steps

Run the primary suites explicitly:

```bash
PATH="$HOME/.local/bin:$PATH" zig build test
PATH="$HOME/.local/bin:$PATH" zig build test-net
PATH="$HOME/.local/bin:$PATH" zig build test-js
PATH="$HOME/.local/bin:$PATH" zig build test-html
PATH="$HOME/.local/bin:$PATH" zig build test-dom
PATH="$HOME/.local/bin:$PATH" zig build test-client
PATH="$HOME/.local/bin:$PATH" zig build test-h2
PATH="$HOME/.local/bin:$PATH" zig build test-page
PATH="$HOME/.local/bin:$PATH" zig build test-tls
PATH="$HOME/.local/bin:$PATH" zig build test-e2e
```

If running inside a gVisor/v9fs container, expect known Zig 0.16 environment issues described in `DEV_NOTES.md` (#7 and #8).

For a fast operational MVP verification (fixtures + local mock server):

```bash
./scripts/mvp_smoke.sh
```

This script hard-checks AT-1/2/3/5/6/7/8 and runs AT-4 (`https://example.com`)
as best-effort (warning only in environments where Zig outbound networking is restricted).

## 4) Build artifacts and repository hygiene

Build artifacts must remain untracked:

- `.zig-cache/`
- `zig-cache/`
- `zig-out/`
- `zig-pkg/`
- `third_party/libxev/`
- `third_party/zig-quickjs-ng/`
- `third_party/quickjs-ng-quickjs/`
- `third_party/lexbor/src/`
- `third_party/lexbor/build/`
- `third_party/lexbor/install/`

These are intentionally ignored in `.gitignore` to keep the repository clean across local and CI builds.

## 5) MVP -> MCP readiness checklist

Use this checklist before declaring "MCP-ready" for agent integration:

1. **Build completeness**
   - `zig build -Doptimize=ReleaseSafe` succeeds.
2. **CLI contract stability**
   - `awr --version`, `awr <url>`, `awr tools <url>`, and `awr call <url> <tool> <json>` behave per `spec/MVP.md` FR-5.
3. **WebMCP contract correctness**
   - Tool discovery + invocation + error envelopes match `spec/MVP.md` FR-4.
4. **Acceptance validation**
   - Execute acceptance scenarios in `spec/MVP.md` §3 (AT-1 through AT-11, respecting current MVP vs MVP+1 gating notes in that spec).
5. **Agent integration readiness**
   - Verify shell-based tool bridge in `docs/agent-integration.md` end-to-end using `experiments/webmcp_mock.html`.
6. **Stub-closure tracking**
   - Reconcile open items in `spec/MVP.md` §5 and `DEV_NOTES.md` before claiming production readiness.

## 6) Current status note

As of April 21, 2026, WebMCP is implemented and usable through CLI flows, while several broader runtime items (notably fully-owned HTTP/HTTPS paths and some web API stubs) are tracked in the MVP/MVP+1 documentation for continued closure.
