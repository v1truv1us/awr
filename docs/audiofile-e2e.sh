#!/usr/bin/env bash
# audiofile.app end-to-end flow via awr
#
# Demonstrates: load homepage → sign in → search → add to wishlist → verify.
#
# Required env vars:
#   AUDIOFILE_EMAIL     — email of a confirmed audiofile.app account
#   AUDIOFILE_PASSWORD  — password for that account
#
# Optional:
#   AWR_COOKIE_JAR      — path for cookie persistence (default: /tmp/awr-e2e-cookies.txt)
#   AWR                 — path to awr binary (default: ./zig-out/bin/awr)

set -euo pipefail

AWR="${AWR:-./zig-out/bin/awr}"
SUPABASE_URL="https://bwzldaesynlruqukbnej.supabase.co"
SUPABASE_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ3emxkYWVzeW5scnVxdWtibmVqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk1OTQzNTYsImV4cCI6MjA5NTE3MDM1Nn0.VElxEGN5cyd8VRBbHBBIM9al_FC4ja3W8i69rkmiFxI"
API="https://audiofile.app/api"

export AWR_COOKIE_JAR="${AWR_COOKIE_JAR:-/tmp/awr-e2e-cookies.txt}"

EMAIL="${AUDIOFILE_EMAIL:?set AUDIOFILE_EMAIL}"
PASS="${AUDIOFILE_PASSWORD:?set AUDIOFILE_PASSWORD}"

pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; exit 1; }
step() { echo; echo "==> $*"; }

# ── Step 1: Load homepage ─────────────────────────────────────────────────────
step "1. Load homepage"
RESULT=$("$AWR" 'https://audiofile.app' 2>/dev/null)
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
[ "$STATUS" = "200" ] && pass "homepage returned $STATUS" || fail "homepage status $STATUS"

# ── Step 2: Sign in (Supabase password flow) ──────────────────────────────────
step "2. Sign in as $EMAIL"
AUTH_BODY="{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"
AUTH_RESP=$("$AWR" post --json \
  "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  "$AUTH_BODY" \
  --header "apikey: $SUPABASE_ANON_KEY" 2>/dev/null)

TOKEN=$(echo "$AUTH_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
body = d['body_text'].strip()
auth = json.loads(body)
print(auth['access_token'])
" 2>/dev/null || echo "")

[ -n "$TOKEN" ] && pass "signed in, token received (${TOKEN:0:20}...)" || {
    echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('  body:', d['body_text'][:200])"
    fail "sign-in failed — check AUDIOFILE_EMAIL / AUDIOFILE_PASSWORD"
}

BEARER="Authorization: Bearer $TOKEN"

# ── Step 3: Search for a record ───────────────────────────────────────────────
step "3. Search for 'OK Computer' by Radiohead"
SEARCH=$("$AWR" "$API/releases/search?q=radiohead+ok+computer" 2>/dev/null)
SEARCH_STATUS=$(echo "$SEARCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
FIRST_TITLE=$(echo "$SEARCH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = json.loads(d['body_text'])
print(results[0]['title'] if results else 'no results')
" 2>/dev/null || echo "")

[ "$SEARCH_STATUS" = "200" ] && pass "search returned $SEARCH_STATUS, first result: '$FIRST_TITLE'" || fail "search status $SEARCH_STATUS"

# Extract first result mbid for wishlist add
RELEASE_ID=$(echo "$SEARCH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = json.loads(d['body_text'])
print(r[0].get('mbid', '') if r else '')
" 2>/dev/null || echo "")

# ── Step 4: Add to wishlist ───────────────────────────────────────────────────
step "4. Add 'OK Computer' to wishlist"
WISHLIST_BODY="{\"title\":\"OK Computer\",\"artist\":\"Radiohead\",\"priority\":1,\"year\":1997,\"label\":\"Parlophone\"}"
ADD_RESP=$("$AWR" post --json \
  "$API/wishlist" \
  "$WISHLIST_BODY" \
  --header "$BEARER" 2>/dev/null)
ADD_STATUS=$(echo "$ADD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")

[ "$ADD_STATUS" = "201" ] && pass "wishlist add returned $ADD_STATUS" || {
    echo "$ADD_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('  status:', d['status'], 'body:', d['body_text'][:200])" 2>/dev/null
    fail "wishlist add failed (status $ADD_STATUS)"
}

ITEM_ID=$(echo "$ADD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
body = json.loads(d['body_text'])
print(body.get('id', ''))
" 2>/dev/null || echo "")

# ── Step 5: Re-fetch wishlist and verify record is present ────────────────────
step "5. Re-fetch wishlist and verify"
LIST_RESP=$("$AWR" "$API/wishlist" --header "$BEARER" 2>/dev/null)
LIST_STATUS=$(echo "$LIST_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
FOUND=$(echo "$LIST_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = json.loads(d['body_text'])
items = items if isinstance(items, list) else items.get('items', [])
titles = [i.get('title','') for i in items]
print('yes' if 'OK Computer' in titles else 'no')
print('titles:', titles[:5])
" 2>/dev/null || echo "no")

[ "$LIST_STATUS" = "200" ] && pass "wishlist returned $LIST_STATUS" || fail "wishlist status $LIST_STATUS"
echo "$FOUND" | grep -q "^yes" && pass "verified: 'OK Computer' found in wishlist" || {
    echo "$FOUND"
    fail "'OK Computer' not found in wishlist"
}

# ── Cleanup: remove the test wishlist item ────────────────────────────────────
if [ -n "$ITEM_ID" ]; then
    step "Cleanup: remove test item $ITEM_ID"
    # awr doesn't support DELETE yet; skip cleanup silently
    echo "  (skip — DELETE not yet in awr; remove '$ITEM_ID' manually via dashboard)"
fi

echo
echo "All steps passed. audiofile.app e2e flow works via awr."
