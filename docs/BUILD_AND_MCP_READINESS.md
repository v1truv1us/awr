# Build, Test, and MCP-Readiness Runbook

This runbook is the operational checklist for taking AWR from a fresh clone to a reproducible local build, test execution, and MCP-readiness verification.

## 1) Prerequisites

### Required toolchain

- **Zig 0.16.0**
- **lexbor v2.5.0** installed on the system include/lib path
- Linux x86_64 or macOS arm64

If Zig is missing in your environment, install it directly from ziglang.org (the `apt` package is commonly unavailable):

```bash
cd /tmp
curl -L --fail -o zig-x86_64-linux-0.16.0.tar.xz \
  https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
tar -xf zig-x86_64-linux-0.16.0.tar.xz
export PATH=/tmp/zig-x86_64-linux-0.16.0:$PATH
zig version
```

For lexbor installation details, follow:

- `third_party/lexbor/BUILD_NOTES.md`

## 2) Build steps

From repository root:

```bash
zig build -Doptimize=ReleaseSafe
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
zig build test
zig build test-net
zig build test-js
zig build test-html
zig build test-dom
zig build test-client
zig build test-h2
zig build test-page
zig build test-tls
zig build test-e2e
```

If running inside a gVisor/v9fs container, expect known Zig 0.16 environment issues described in `DEV_NOTES.md` (#7 and #8).

## 4) Build artifacts and repository hygiene

Build artifacts must remain untracked:

- `.zig-cache/`
- `zig-cache/`
- `zig-out/`
- `zig-pkg/`

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
