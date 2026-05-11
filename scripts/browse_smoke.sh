#!/usr/bin/env bash
# scripts/browse_smoke.sh — Tier 1 end-to-end smoke flows. T-86 / slice T1.11.
#
# Exercises the same cookie / form-submit / multi-fetch path the TUI uses
# against the real network. Two flows per spec/subspecs/browser-tui.md §4.3:
#
#   1. Google search round-trip (no auth required)
#   2. HN sign-in flow (requires AWR_HN_USER + AWR_HN_PASS env)
#
# Both flows use AWR's non-interactive `submit` / fetch surface. The TUI
# subprocess + key-synthesis variant lives in the in-process harness
# (T-80, src/browser.zig tests); this script verifies the underlying
# Page / Client / CookieJar stack works against real servers.
#
# Env knobs:
#   AWR_BIN              — path to the awr binary (default: ./zig-out/bin/awr)
#   AWR_SMOKE_OFFLINE=1  — skip every real-network flow; exit 0. CI default.
#   AWR_HN_USER          — HN account name for flow 2 (skipped if unset)
#   AWR_HN_PASS          — HN account password for flow 2
set -euo pipefail

AWR="${AWR_BIN:-./zig-out/bin/awr}"

if [ ! -x "$AWR" ]; then
  echo "browse_smoke: $AWR not found or not executable" >&2
  echo "  Run \`zig build\` first." >&2
  exit 1
fi

if [ "${AWR_SMOKE_OFFLINE:-}" = "1" ]; then
  echo "browse_smoke: AWR_SMOKE_OFFLINE=1 — skipping real-network flows."
  exit 0
fi

# Ensure daemon is OFF so each invocation gets a fresh cookie jar
# unless we set AWR_COOKIE_JAR explicitly. Daemon mode is a separate
# code path (its own smoke gate in scripts/regression_smoke.sh).
export AWR_DAEMON=0

# ── Flow 1: Google search round-trip ────────────────────────────────
echo "→ Flow 1: Google search (no auth)"
# Submit Google's homepage form with a query. AWR's `submit` finds
# the form, merges hidden inputs (the request-id / CSRF tokens
# Google sets), POSTs (or GETs — Google's main form is GET) to the
# resolved action URL, and follows redirects to the results page.
GOOGLE_OUT="$( "$AWR" submit "https://www.google.com/" q="hello world" 2>&1 )" || {
  echo "FAIL: google submit returned non-zero" >&2
  echo "$GOOGLE_OUT" | head -20 >&2
  exit 1
}
# The envelope should describe a Google results page (status 200 with
# "Search" / "Results" markers or the query echoed back). We grep
# loosely because Google's HTML changes frequently — we just want a
# load that wasn't blocked.
if ! echo "$GOOGLE_OUT" | grep -qE '"status":200'; then
  echo "FAIL: google did not return 200" >&2
  echo "$GOOGLE_OUT" | head -10 >&2
  exit 1
fi
if ! echo "$GOOGLE_OUT" | grep -qiE 'hello|world|search|google'; then
  echo "FAIL: google results body did not look like a search page" >&2
  echo "$GOOGLE_OUT" | head -10 >&2
  exit 1
fi
echo "  ok"

# ── Flow 2: bookmark round-trip ─────────────────────────────────────
# Tier 2 / T-89 closure gate: `awr bookmark add/list/rm` round-trips
# through the on-disk store without network access.
echo "→ Flow 2: bookmark round-trip (no auth)"
BM="$(mktemp "${TMPDIR:-/tmp}/awr-bookmarks-XXXXXX.txt")"
AWR_BOOKMARKS="$BM" "$AWR" bookmark add "https://example.com/" --title="Example Domain" > /dev/null || {
  echo "FAIL: bookmark add" >&2
  rm -f "$BM"; exit 1
}
LIST="$( AWR_BOOKMARKS="$BM" "$AWR" bookmark list )" || {
  echo "FAIL: bookmark list" >&2
  rm -f "$BM"; exit 1
}
if ! echo "$LIST" | grep -q "https://example.com/"; then
  echo "FAIL: list missing example.com" >&2
  rm -f "$BM"; exit 1
fi
AWR_BOOKMARKS="$BM" "$AWR" bookmark rm 1 > /dev/null || {
  echo "FAIL: bookmark rm" >&2
  rm -f "$BM"; exit 1
}
EMPTY="$( AWR_BOOKMARKS="$BM" "$AWR" bookmark list )"
if ! echo "$EMPTY" | grep -q "no bookmarks"; then
  echo "FAIL: store not empty after rm" >&2
  echo "$EMPTY" >&2
  rm -f "$BM"; exit 1
fi
rm -f "$BM"
echo "  ok"

# ── Flow 3: HN sign-in flow ─────────────────────────────────────────
if [ -z "${AWR_HN_USER:-}" ] || [ -z "${AWR_HN_PASS:-}" ]; then
  echo "→ Flow 3: HN sign-in — skipped (set AWR_HN_USER + AWR_HN_PASS to run)"
  echo "browse_smoke: 2/3 flows ok (HN skipped — no creds)"
  exit 0
fi

JAR="$(mktemp "${TMPDIR:-/tmp}/awr-hn-jar-XXXXXX.txt")"
trap "rm -f \"$JAR\"" EXIT

echo "→ Flow 3: HN sign-in (auth)"
# Step 1: POST credentials to /login. The login form on HN is a
# straight POST with `acct` and `pw` fields — no CSRF token, no
# hidden inputs. After login, HN sets a `user` cookie containing
# the username + a hashed session token; we persist it via the jar.
AWR_COOKIE_JAR="$JAR" "$AWR" submit "https://news.ycombinator.com/login" \
  acct="$AWR_HN_USER" pw="$AWR_HN_PASS" > /dev/null || {
  echo "FAIL: HN login submit failed" >&2
  exit 1
}

if [ ! -s "$JAR" ] || ! grep -q user "$JAR"; then
  echo "FAIL: cookie jar empty or missing 'user' cookie after HN login" >&2
  echo "(may indicate wrong credentials, or HN changed their cookie scheme)" >&2
  cat "$JAR" >&2
  exit 1
fi

# Step 2: Hit /threads?id=<user> using the persisted cookie jar.
# Logged-out users get a permission error; logged-in users see
# their own thread list (with their username visible in the page).
THREADS_OUT="$( AWR_COOKIE_JAR="$JAR" "$AWR" \
  "https://news.ycombinator.com/threads?id=$AWR_HN_USER" --format=md 2>&1 )" || {
  echo "FAIL: HN threads fetch failed" >&2
  exit 1
}

# Confirm the response is a real HN page and shows our username.
if ! echo "$THREADS_OUT" | grep -qE '"status":200'; then
  echo "FAIL: HN /threads did not return 200" >&2
  echo "$THREADS_OUT" | head -10 >&2
  exit 1
fi
if ! echo "$THREADS_OUT" | grep -qi "$AWR_HN_USER"; then
  echo "FAIL: HN /threads body does not reference the user — likely not logged in" >&2
  echo "$THREADS_OUT" | head -20 >&2
  exit 1
fi
echo "  ok"

echo "browse_smoke: 3/3 flows ok"
