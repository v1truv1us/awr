#!/usr/bin/env bash
set -euo pipefail

AWR_BIN="${AWR_BIN:-./zig-out/bin/awr}"
PORT="${AWR_MOCK_PORT:-7777}"

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "mvp-smoke: jq is required" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_jq

echo "[1/8] AT-1 local tools"
"$AWR_BIN" tools experiments/webmcp_mock.html | jq -e 'map(.name) | index("search_products") and index("get_price") and index("add_to_cart")' >/dev/null

echo "[2/8] AT-2 async tool"
"$AWR_BIN" call experiments/webmcp_mock.html add_to_cart '{"sku":"w-001","qty":2}' | jq -e '.ok == true and .value.total > 0' >/dev/null

echo "[3/8] AT-3 failure envelope + exit code"
set +e
"$AWR_BIN" call experiments/webmcp_mock.html nope '{}' >/tmp/awr_at3.json
code=$?
set -e
[[ "$code" -ne 0 ]]
jq -e '.ok == false and .error == "ToolNotFound"' /tmp/awr_at3.json >/dev/null

echo "[4/8] AT-6 external script fixture"
"$AWR_BIN" tools experiments/external_script.html | jq -e 'map(.name) | index("external_ping")' >/dev/null

echo "[5/8] AT-8 DOM mutation reflection"
"$AWR_BIN" call experiments/dom_mutation_tool.html mutate_and_query '{}' | jq -e '.ok == true and .value.ok == true and .value.text == "hello"' >/dev/null

echo "[6/8] start mock server"
"$AWR_BIN" mock --port "$PORT" >/tmp/awr_mock.log 2>&1 &
MOCK_PID=$!
sleep 1

echo "[7/8] AT-5 mock HTTP round-trip"
"$AWR_BIN" tools "http://127.0.0.1:${PORT}/webmcp_mock.html" | jq -e 'map(.name) | index("search_products") and index("add_to_cart")' >/dev/null

echo "[8/8] AT-7 setTimeout + fetch (mock)"
"$AWR_BIN" call "http://127.0.0.1:${PORT}/async_tool.html" fetch_then_wait '{}' | jq -e '.ok == true and .value.ok == true and .value.length > 10' >/dev/null

# Best-effort external connectivity check (AT-4). Some environments block
# direct outbound sockets for Zig's std.http client.
echo "[extra] AT-4 HTTPS fetch (best-effort)"
set +e
"$AWR_BIN" https://example.com | jq -e '.title == "Example Domain"' >/dev/null
https_code=$?
set -e
if [[ "$https_code" -ne 0 ]]; then
  echo "mvp-smoke: WARNING: AT-4 failed in this environment (see stderr output)." >&2
else
  echo "mvp-smoke: AT-4 passed"
fi

echo "mvp-smoke: core MVP smoke checks passed"
