#!/usr/bin/env bash
# bench_daemon.sh — Daemon vs per-process chained-flow benchmark.
#
# Spec/subspecs/daemon-mode.md §4.5 closure gate:
#   "Empirical 5-fetch chained-flow benchmark shows ≥ 30% wall-clock
#    improvement vs per-process baseline (back-of-envelope estimate
#    in the B1 design doc was 42%; 30% is the floor)."
#
# Two modes:
#
#   1. LOCAL (default): hermetic localhost via `awr mock`. Fast, runs
#      in CI, but the speedup is small (~5-15%) because:
#        - TLS handshake / CA bundle parse never fire (HTTP only)
#        - Page reconstruction per fetch is identical in both modes
#          (slice 2 punted on Page-instance caching)
#      So local mode is INFORMATIONAL — it confirms the daemon is
#      no slower and that the harness works. Reported but not gated.
#
#   2. HTTPS (BENCH_HTTPS=https://example.com or any HTTPS URL):
#      gates the spec's 30% floor. The TLS handshake + CA bundle
#      parse (~250 KB Mozilla roots) is the headline savings the
#      daemon amortizes — HTTPS reveals it. Requires network, so
#      not on by default for CI.
#
# Output:
#   Two-block summary (per-process baseline + daemon mode) with
#   median/mean/p95 ms, plus the percentage speedup. Exits 0 unless
#   BENCH_HTTPS is set AND speedup < BENCH_GATE_PCT (default 30) —
#   then exits 1 to fail the closure-gate check.
#
# Env vars:
#   AWR_BIN        — path to the `awr` binary (default zig-out/bin/awr)
#   AWRD_BIN       — path to the `awrd` binary (default zig-out/bin/awrd)
#   BENCH_TRIALS   — how many trials per mode (default 5)
#   BENCH_FETCHES  — fetches per trial (default 5; spec calls for 5)
#   BENCH_HTTPS    — HTTPS URL to use instead of localhost mock; when
#                    set, enables the closure-gate check
#   BENCH_GATE_PCT — minimum speedup required in HTTPS mode (default 30)
#   BENCH_PORT     — port for the local mock server (default 18891)

set -euo pipefail

AWR_BIN=${AWR_BIN:-./zig-out/bin/awr}
AWRD_BIN=${AWRD_BIN:-./zig-out/bin/awrd}
BENCH_TRIALS=${BENCH_TRIALS:-5}
BENCH_FETCHES=${BENCH_FETCHES:-5}
BENCH_GATE_PCT=${BENCH_GATE_PCT:-30}
BENCH_HTTPS=${BENCH_HTTPS:-}
PORT=${BENCH_PORT:-18891}

# Hermetic working dir for the daemon's XDG_RUNTIME_DIR / data dir.
WORKDIR=$(mktemp -d -t awr-bench.XXXXXX)
RUNTIME_DIR="$WORKDIR/runtime"
DATA_DIR="$WORKDIR/data"
mkdir -p "$RUNTIME_DIR" "$DATA_DIR"

cleanup() {
  if [[ -n "${MOCK_PID:-}" ]]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  if [[ -f "$RUNTIME_DIR/awrd-$(id -u).sock" ]]; then
    # Send a shutdown so the daemon persists state cleanly.
    python3 -c "
import socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.5)
    s.connect('$RUNTIME_DIR/awrd-$(id -u).sock')
    body = b'{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"shutdown\"}'
    s.sendall(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    s.recv(1024)
    s.close()
except Exception:
    pass
" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# ── Sanity ──────────────────────────────────────────────────────────
[[ -x "$AWR_BIN" ]] || { echo "bench: $AWR_BIN missing — zig build install" >&2; exit 1; }
[[ -x "$AWRD_BIN" ]] || { echo "bench: $AWRD_BIN missing — zig build install" >&2; exit 1; }

# ── Pick URL: HTTPS env override or local mock ──────────────────────
if [[ -n "$BENCH_HTTPS" ]]; then
  URL="$BENCH_HTTPS"
  MODE="https"
  echo "## Mode: HTTPS (closure-gate enabled, target=$URL)"
else
  # Spawn local mock + probe.
  "$AWR_BIN" mock --port "$PORT" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 100); do
    (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
    sleep 0.02
  done
  if ! (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    echo "bench: mock failed to bind 127.0.0.1:$PORT" >&2; exit 1
  fi
  URL="http://127.0.0.1:$PORT/webmcp_mock.html"
  MODE="local"
  echo "## Mode: LOCAL (informational — set BENCH_HTTPS=<url> to gate)"
fi
echo ""

# ── Helpers ─────────────────────────────────────────────────────────
run_chain() {
  python3 -c '
import subprocess, time, sys, os
n = int(sys.argv[1])
url = sys.argv[2]
awr = sys.argv[3]
t0 = time.monotonic_ns()
for _ in range(n):
    subprocess.run([awr, url], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print((time.monotonic_ns() - t0) // 1_000_000)
' "$BENCH_FETCHES" "$URL" "$AWR_BIN"
}

stats() {
  python3 -c '
import sys
xs = sorted(int(x) for x in sys.stdin.read().split())
n = len(xs)
if n == 0:
    print("0 0 0"); sys.exit(0)
median = xs[n//2] if n % 2 else (xs[n//2-1] + xs[n//2]) // 2
mean = sum(xs) // n
p95_idx = max(0, int(n * 0.95) - 1) if n > 1 else 0
print(f"{median} {mean} {xs[p95_idx]}")
'
}

# Shared env: hermetic XDG dirs.
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_DATA_HOME="$DATA_DIR"

# ── Per-process baseline ────────────────────────────────────────────
unset AWR_DAEMON
echo "## Per-process baseline ($BENCH_TRIALS trials × $BENCH_FETCHES fetches)"
PP_RESULTS=()
for i in $(seq 1 "$BENCH_TRIALS"); do
  ms=$(run_chain)
  PP_RESULTS+=("$ms")
  printf "  trial %d: %d ms\n" "$i" "$ms"
done
read -r PP_MEDIAN PP_MEAN PP_P95 <<<"$(printf '%s\n' "${PP_RESULTS[@]}" | stats)"
printf "  → median=%dms mean=%dms p95=%dms\n" "$PP_MEDIAN" "$PP_MEAN" "$PP_P95"
echo ""

# ── Daemon mode ─────────────────────────────────────────────────────
echo "## Daemon mode ($BENCH_TRIALS trials × $BENCH_FETCHES fetches)"
export AWR_DAEMON=1
export AWR_DAEMON_IDLE_SEC=600

# Warmup: spawn + first fetch (NOT timed). Spawn cost is one-time
# per session; the gate measures steady-state.
echo "  warmup: spawning daemon + first fetch..."
"$AWR_BIN" "$URL" >/dev/null 2>&1

D_RESULTS=()
for i in $(seq 1 "$BENCH_TRIALS"); do
  ms=$(run_chain)
  D_RESULTS+=("$ms")
  printf "  trial %d: %d ms\n" "$i" "$ms"
done
read -r D_MEDIAN D_MEAN D_P95 <<<"$(printf '%s\n' "${D_RESULTS[@]}" | stats)"
printf "  → median=%dms mean=%dms p95=%dms\n" "$D_MEDIAN" "$D_MEAN" "$D_P95"
echo ""

# ── Speedup ─────────────────────────────────────────────────────────
echo "## Result"
SPEEDUP_PCT=$(python3 -c "
pp, d = $PP_MEDIAN, $D_MEDIAN
print(0 if pp == 0 else round((pp - d) * 100 / pp, 1))
")
printf "  per-process median: %d ms\n" "$PP_MEDIAN"
printf "  daemon median:      %d ms\n" "$D_MEDIAN"
if [[ "$MODE" == "https" ]]; then
  printf "  speedup:            %s%%  (gate: %s%%)\n" "$SPEEDUP_PCT" "$BENCH_GATE_PCT"
  GATE_PASS=$(python3 -c "
import sys
sp = float('$SPEEDUP_PCT')
gate = float('$BENCH_GATE_PCT')
sys.exit(0 if sp >= gate else 1)
" && echo yes || echo no)
  if [[ "$GATE_PASS" == "yes" ]]; then
    echo "  ✓ PASS — daemon mode meets the spec §4.5 closure gate"
    exit 0
  else
    echo "  ✗ FAIL — speedup below gate; spec §4.5 not satisfied" >&2
    exit 1
  fi
else
  printf "  speedup:            %s%%  (informational)\n" "$SPEEDUP_PCT"
  echo "  Note: localhost-HTTP scenarios show small speedups because"
  echo "        the dominant startup costs (TLS handshake + CA bundle"
  echo "        parse) don't fire. Re-run with BENCH_HTTPS=<url> to"
  echo "        exercise the spec §4.5 30%-floor gate."
fi
