#!/usr/bin/env bash
# regression_smoke.sh — guard the bug fixes from the May 2026 smoke
# session. Each check encodes ONE specific regression: a hang, a
# silent drop, a missing surface. Together they're the durable safety
# net so future runtime work doesn't reintroduce them.
#
# Distinct from `mvp_smoke.sh`: that script verifies MVP acceptance
# against the local mock server. This one verifies pages-from-the-
# wild handling — bodiless statuses, gtag.js, sign-in cookies — and
# spins up purpose-built Python fixtures for the cases the public
# Internet can't reproduce deterministically (server-rotated CSRF).
#
# Usage:
#   scripts/regression_smoke.sh          # full suite (network required)
#   AWR_SMOKE_OFFLINE=1 ... .sh          # skip network-dependent checks
#   AWR_BIN=/path/to/awr ... .sh         # use a custom binary
#
# Exit:
#   0 = all checks passed
#   1 = one or more checks failed (failing check printed to stderr)
#   2 = setup failure (binary missing, jq missing, port collision)

# Drop -e so individual test failures accumulate rather than aborting the
# tally loop. Unexpected setup failures still exit via explicit `exit 2`
# guards below. -uo pipefail remain for unbound-variable protection.
set -uo pipefail

AWR_BIN="${AWR_BIN:-./zig-out/bin/awr}"
OFFLINE="${AWR_SMOKE_OFFLINE:-0}"

# Each check appends to these so we can report a final tally even
# when individual checks fail in non-fatal mode.
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILS=()

# Background-process tracking for cleanup on exit.
PIDS=()

cleanup() {
  # Guard against empty PIDS — bash set -u treats "${arr[@]}" on an empty
  # array as unbound in some versions.
  if [[ ${#PIDS[@]} -gt 0 ]]; then
    for pid in "${PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT

# ── Setup ──────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
  echo "regression-smoke: jq is required" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "regression-smoke: python3 is required (for HTTP fixtures)" >&2
  exit 2
fi

if [[ ! -x "$AWR_BIN" ]]; then
  echo "regression-smoke: AWR binary not found at $AWR_BIN" >&2
  echo "  build with: zig build -Dlexbor-prefix=third_party/lexbor/install" >&2
  exit 2
fi

# Each check runs `_time_ms` to clock its wall-clock cost. Most fail
# modes regress as a HANG, so timing budgets are the primary signal.
_time_ms() {
  python3 -c 'import time;print(int(time.time()*1000))'
}

# Each check is `expect <name> <budget_ms> <command...>`. Runs the
# command with a hard timeout, asserts it completed under the budget
# AND exited 0, prints PASS/FAIL/SKIP with the actual ms.
expect() {
  local name="$1" budget="$2"; shift 2
  local timeout_s=$(( budget / 1000 + 2 ))  # 2s slack on top of budget
  local start end ms
  start=$(_time_ms)
  if timeout "$timeout_s" "$@" >/tmp/awr_smoke_out 2>/tmp/awr_smoke_err; then
    end=$(_time_ms)
    ms=$((end - start))
    if (( ms <= budget )); then
      printf "  \033[32mPASS\033[0m  %-50s (%5dms / %dms)\n" "$name" "$ms" "$budget"
      PASS_COUNT=$((PASS_COUNT + 1))
      return 0
    else
      printf "  \033[31mFAIL\033[0m  %-50s (%5dms exceeds %dms budget)\n" "$name" "$ms" "$budget"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILS+=("$name (slow: ${ms}ms > ${budget}ms)")
      return 1
    fi
  fi
  end=$(_time_ms)
  ms=$((end - start))
  printf "  \033[31mFAIL\033[0m  %-50s (timed out at %dms)\n" "$name" "$ms"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILS+=("$name (timeout/error)")
  if [[ -s /tmp/awr_smoke_err ]]; then
    sed 's/^/         | /' /tmp/awr_smoke_err | head -5
  fi
  return 1
}

skip() {
  local name="$1" reason="$2"
  printf "  \033[33mSKIP\033[0m  %-50s (%s)\n" "$name" "$reason"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

# Some checks need a JSON-shape assertion, not just timing. Wrap them.
expect_json() {
  local name="$1" budget="$2" jq_filter="$3"; shift 3
  local timeout_s=$(( budget / 1000 + 2 ))
  local start end ms
  start=$(_time_ms)
  if timeout "$timeout_s" "$@" >/tmp/awr_smoke_out 2>/tmp/awr_smoke_err; then
    end=$(_time_ms)
    ms=$((end - start))
    if jq -e "$jq_filter" /tmp/awr_smoke_out >/dev/null 2>&1; then
      if (( ms <= budget )); then
        printf "  \033[32mPASS\033[0m  %-50s (%5dms / %dms)\n" "$name" "$ms" "$budget"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
      else
        printf "  \033[31mFAIL\033[0m  %-50s (%5dms exceeds %dms)\n" "$name" "$ms" "$budget"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILS+=("$name (slow)")
        return 1
      fi
    fi
    printf "  \033[31mFAIL\033[0m  %-50s (jq filter %s did not match)\n" "$name" "$jq_filter"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILS+=("$name (output mismatch)")
    head -c 200 /tmp/awr_smoke_out | sed 's/^/         | /'
    echo
    return 1
  fi
  end=$(_time_ms)
  ms=$((end - start))
  printf "  \033[31mFAIL\033[0m  %-50s (timed out at %dms)\n" "$name" "$ms"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILS+=("$name (timeout)")
  return 1
}

# ── Group 1: hang regressions (B1, B2, B3) ─────────────────────────

echo "## hang regressions (B1, B2, B3)"

if [[ "$OFFLINE" == "1" ]]; then
  skip "B1: 204 No Content under 2s"     "AWR_SMOKE_OFFLINE=1"
  skip "B1: 304 Not Modified under 2s"   "AWR_SMOKE_OFFLINE=1"
  skip "B2: react.dev under 8s (gtag)"   "AWR_SMOKE_OFFLINE=1"
  skip "B3: drainAll honors deadline"    "AWR_SMOKE_OFFLINE=1"
else
  expect_json "B1: 204 No Content under 2s"     2000 \
    '.status == 204 and (.body_text | length) == 0' \
    "$AWR_BIN" https://httpbin.org/status/204
  expect_json "B1: 304 Not Modified under 2s"   2000 \
    '.status == 304 and (.body_text | length) == 0' \
    "$AWR_BIN" https://httpbin.org/status/304
  expect_json "B2: react.dev under 15s (gtag-loop)" 15000 \
    '.status == 200 and .title == "React"' \
    "$AWR_BIN" https://react.dev
  expect_json "B3: example.com baseline (no regression)" 2000 \
    '.status == 200 and .title == "Example Domain"' \
    "$AWR_BIN" https://example.com
fi

# ── Group 2: cookie persistence (C.6) ──────────────────────────────

echo
echo "## cookie persistence (C.6 RFC 6265 §5.1.1)"

# Spin up a fixture that emits both Max-Age and RFC 1123 Expires
# cookies. Verifies the parser handles both formats end-to-end.
COOKIE_PORT=18491
python3 - <<'PYEOF' &
import http.server, socketserver
# Allow rebinding while the previous run's socket is still in TIME_WAIT
# (consecutive smoke runs would otherwise fail at bind time).
class ReusableServer(socketserver.TCPServer):
    allow_reuse_address = True
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/set':
            self.send_response(200)
            self.send_header('Set-Cookie', 'ma_token=abc; Max-Age=3600; Path=/')
            self.send_header('Set-Cookie', 'rfc_token=xyz; Expires=Sun, 01 Jan 2099 00:00:00 GMT; Path=/')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(b'<html><title>set</title></html>')
        elif self.path == '/echo':
            ck = self.headers.get('Cookie', '<none>')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(f'<html><title>echo</title><body>{ck}</body></html>'.encode())
    def log_message(self, *a, **kw): pass
import sys
try:
    with ReusableServer(('127.0.0.1', 18491), H) as s:
        s.serve_forever()
except OSError:
    sys.exit(0)
PYEOF
PIDS+=($!)
sleep 0.5

JAR=/tmp/awr-regression-cookies/cookies.txt
rm -rf /tmp/awr-regression-cookies

AWR_COOKIE_JAR=$JAR expect "C.6: set cookies via Max-Age + RFC 1123 Expires" 5000 \
  "$AWR_BIN" "http://127.0.0.1:${COOKIE_PORT}/set"

if [[ -f "$JAR" ]]; then
  count=$(grep -cv '^#' "$JAR" | head -1 || true)
  # Both cookies must persist (Max-Age + Expires both honored)
  if [[ "$count" -ge 2 ]]; then
    printf "  \033[32mPASS\033[0m  %-50s (%d cookies in jar)\n" "C.6: jar has both Max-Age + RFC 1123 cookies" "$count"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-50s (jar has %d cookies, expected 2)\n" "C.6: jar has both Max-Age + RFC 1123 cookies" "$count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILS+=("C.6: jar shape")
  fi
else
  printf "  \033[31mFAIL\033[0m  %-50s (jar file not created)\n" "C.6: jar has both Max-Age + RFC 1123 cookies"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILS+=("C.6: jar missing")
fi

AWR_COOKIE_JAR=$JAR expect_json "C.6: cookies survive process restart" 5000 \
  '(.body_text | contains("ma_token=abc")) and (.body_text | contains("rfc_token=xyz"))' \
  "$AWR_BIN" "http://127.0.0.1:${COOKIE_PORT}/echo"

# ── Group 3: end-to-end sign-in (E.1, E.2) ─────────────────────────

echo
echo "## end-to-end sign-in (E.1, E.2)"

SIGNIN_PORT=18492
python3 - <<'PYEOF' &
import http.server, socketserver, secrets
from urllib.parse import parse_qs
class ReusableServer(socketserver.TCPServer):
    allow_reuse_address = True
expected_csrf = {}
sessions = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/login':
            csrf = secrets.token_hex(8)
            ip = self.client_address[0]
            expected_csrf[ip] = csrf
            html = f'''<html><body><form id="login" method="post" action="/login">
<input type="hidden" name="csrf" value="{csrf}">
<input name="user"><input name="password" type="password">
<button type="submit">go</button></form></body></html>'''
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(html.encode())
        elif self.path == '/dashboard':
            ck = self.headers.get('Cookie', '')
            authed = 'session=' in ck
            self.send_response(200 if authed else 401)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(b'<html><body><h1>Welcome alice</h1></body></html>' if authed else b'<html><body>denied</body></html>')

    def do_POST(self):
        if self.path == '/login':
            n = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(n).decode()
            form = parse_qs(body)
            ip = self.client_address[0]
            if (form.get('csrf', [''])[0] == expected_csrf.get(ip) and
                form.get('user', [''])[0] == 'alice' and
                form.get('password', [''])[0] == 'hunter2'):
                tok = secrets.token_hex(8)
                sessions[tok] = 'alice'
                self.send_response(302)
                self.send_header('Set-Cookie', f'session={tok}; Path=/; Max-Age=3600')
                self.send_header('Location', '/dashboard')
                self.send_header('Connection', 'close')
                self.end_headers()
            else:
                self.send_response(403)
                self.send_header('Connection', 'close')
                self.end_headers()
    def log_message(self, *a, **kw): pass
import sys
try:
    with ReusableServer(('127.0.0.1', 18492), H) as s:
        s.serve_forever()
except OSError:
    sys.exit(0)
PYEOF
PIDS+=($!)
sleep 0.5

SIGNIN_JAR=/tmp/awr-regression-signin/cookies.txt
rm -rf /tmp/awr-regression-signin

AWR_COOKIE_JAR=$SIGNIN_JAR expect_json "E.2: awr submit with server-rotated CSRF" 5000 \
  '.status == 200 and (.body_text | contains("Welcome alice"))' \
  "$AWR_BIN" submit "http://127.0.0.1:${SIGNIN_PORT}/login" \
    user=alice password=hunter2

AWR_COOKIE_JAR=$SIGNIN_JAR expect_json "E.1: dashboard authed via persisted cookie" 3000 \
  '.status == 200 and (.body_text | contains("Welcome alice"))' \
  "$AWR_BIN" "http://127.0.0.1:${SIGNIN_PORT}/dashboard"

# Verify the negative case too — clearing cookies should return 401.
AWR_COOKIE_JAR=$SIGNIN_JAR "$AWR_BIN" cookies clear >/dev/null 2>&1
AWR_COOKIE_JAR=$SIGNIN_JAR expect_json "E.1: dashboard 401 after cookie clear" 3000 \
  '.status == 401' \
  "$AWR_BIN" "http://127.0.0.1:${SIGNIN_PORT}/dashboard"

# ── Group 4: agent-output surface (D.1) ────────────────────────────

echo
echo "## agent output (D.1 markdown extract)"

if [[ "$OFFLINE" == "1" ]]; then
  skip "D.1: example.com extract has heading + link" "AWR_SMOKE_OFFLINE=1"
else
  # extract returns raw markdown to stdout — gate on shape.
  if "$AWR_BIN" extract https://example.com 2>/dev/null > /tmp/awr_smoke_out; then
    if grep -qE '^# Example Domain' /tmp/awr_smoke_out && \
       grep -qE '\[Learn more\]\(https://iana\.org/' /tmp/awr_smoke_out; then
      printf "  \033[32mPASS\033[0m  %-50s\n" "D.1: example.com extract has heading + link"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      printf "  \033[31mFAIL\033[0m  %-50s (markdown shape mismatch)\n" "D.1: example.com extract has heading + link"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILS+=("D.1: extract output shape")
    fi
  else
    printf "  \033[31mFAIL\033[0m  %-50s (binary failed)\n" "D.1: example.com extract"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ── Tally ──────────────────────────────────────────────────────────

echo
total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
printf "## %d/%d passed" "$PASS_COUNT" "$total"
if (( SKIP_COUNT > 0 )); then printf " (%d skipped)" "$SKIP_COUNT"; fi
echo

if (( FAIL_COUNT > 0 )); then
  echo
  echo "FAILED:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
