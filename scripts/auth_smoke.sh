#!/usr/bin/env bash
# scripts/auth_smoke.sh — Real-world sign-in compatibility survey. T-91.
#
# Loads ~15 representative login pages from the live web and reports
# per-site:
#   - HTTP status of the GET (after redirects)
#   - Page title (from <title>)
#   - Whether AWR detected a form-shaped login affordance in the body
#   - One-line classification (OK / Cloudflare / SPA / blocked / etc.)
#
# The purpose is not to "make these all work" — it's to map AWR's
# current surface against the live web so Tier 3/4/5 prioritization
# is grounded in data, not guesses.
#
# Env knobs:
#   AWR_BIN              — path to the awr binary (default: ./zig-out/bin/awr)
#   AWR_SMOKE_OFFLINE=1  — skip; exit 0 immediately (CI default)
#
# Output: a TSV table to stdout — site\tcategory\tstatus\ttitle\thas_form\tnotes.
# Save to a file with `./scripts/auth_smoke.sh > /tmp/auth_smoke.tsv`.
set -uo pipefail

AWR="${AWR_BIN:-./zig-out/bin/awr}"

if [ ! -x "$AWR" ]; then
  echo "auth_smoke: $AWR not found or not executable" >&2
  exit 1
fi

if [ "${AWR_SMOKE_OFFLINE:-}" = "1" ]; then
  echo "auth_smoke: AWR_SMOKE_OFFLINE=1 — skipping (no network)." >&2
  exit 0
fi

export AWR_DAEMON=0

# Test list. Format per row:
#   category | url | expected_marker_regex | notes
#
# expected_marker_regex is a case-insensitive grep against the body
# that indicates "the login affordance is there." Empty regex means
# "any 200 OK is enough."
SITES=(
  "easy|https://news.ycombinator.com/login|login|HN — server-rendered, no JS gating"
  "easy|https://httpbin.org/forms/post|customer name|httpbin test form"
  "easy|https://example.com/|example domain|baseline sanity"

  "medium|https://github.com/login|sign in to github|GitHub login — server-rendered"
  "medium|https://gitlab.com/users/sign_in|sign in|GitLab login"
  "medium|https://mastodon.social/auth/sign_in|log in|Mastodon"
  "medium|https://meta.sr.ht/login|sr.ht|Sourcehut (small audience, server-rendered)"
  "medium|https://www.codeproject.com/script/Membership/LogOn.aspx|sign in|CodeProject — older .NET form"
  "medium|https://old.reddit.com/login|reddit|old Reddit (server-rendered)"

  "hard|https://www.reddit.com/login/|reddit|new Reddit — likely Cloudflare / React SPA"
  "hard|https://x.com/login|x.com|X.com login — full SPA"
  "hard|https://app.linear.app/login|linear|Linear — SPA"
  "hard|https://login.notion.so/|notion|Notion login"
  "hard|https://accounts.google.com/signin|sign in|Google sign-in (heavy JS)"
  "hard|https://discord.com/login|discord|Discord login (SPA)"
)

# Use jq if available; otherwise fall back to grep.
have_jq=0
if command -v jq >/dev/null 2>&1; then
  have_jq=1
fi

# Header.
printf "%s\t%s\t%s\t%s\t%s\t%s\n" "category" "url" "status" "title" "has_form" "notes"

pass_easy=0; total_easy=0
pass_medium=0; total_medium=0
pass_hard=0; total_hard=0

for row in "${SITES[@]}"; do
  IFS='|' read -r category url marker notes <<< "$row"

  # AWR returns the agent JSON envelope on stdout for `awr <url>`.
  raw="$( timeout 20 "$AWR" "$url" 2>/dev/null )" || true
  if [ -z "$raw" ]; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$category" "$url" "FAIL" "" "no" "fetch failed (timeout or error)"
    case "$category" in
      easy) total_easy=$((total_easy+1));;
      medium) total_medium=$((total_medium+1));;
      hard) total_hard=$((total_hard+1));;
    esac
    continue
  fi

  if [ "$have_jq" = "1" ]; then
    status="$( echo "$raw" | jq -r '.status // "?"' 2>/dev/null )"
    title="$( echo "$raw" | jq -r '.title // ""' 2>/dev/null | tr '\t\n' '  ' )"
    body="$( echo "$raw" | jq -r '.body_text // ""' 2>/dev/null )"
  else
    status="$( echo "$raw" | grep -oE '"status":[0-9]+' | head -1 | cut -d: -f2 )"
    title="$( echo "$raw" | grep -oE '"title":"[^"]*"' | head -1 | sed 's/^"title":"//;s/"$//' )"
    body="$raw"
  fi
  status="${status:-?}"

  # Has form heuristic: body matches the expected marker (case-insensitive),
  # AND we see something form-shaped ([____] or "password" or "email").
  has_form="no"
  marker_pass="no"
  if [ -n "$marker" ] && echo "$body" | grep -iq "$marker"; then
    marker_pass="yes"
  fi
  if echo "$body" | grep -qE '\[___|password|email'; then
    has_form="yes"
  fi

  # Classify: pass if status is 200 AND marker matched AND form detected.
  outcome="OK"
  if [ "$status" != "200" ]; then
    outcome="status=$status"
  elif [ "$marker_pass" != "yes" ]; then
    outcome="page loaded, marker missing"
  elif [ "$has_form" != "yes" ]; then
    outcome="page loaded, no form detected (SPA?)"
  fi

  if [ "$outcome" = "OK" ]; then
    case "$category" in
      easy) pass_easy=$((pass_easy+1));;
      medium) pass_medium=$((pass_medium+1));;
      hard) pass_hard=$((pass_hard+1));;
    esac
  fi
  case "$category" in
    easy) total_easy=$((total_easy+1));;
    medium) total_medium=$((total_medium+1));;
    hard) total_hard=$((total_hard+1));;
  esac

  printf "%s\t%s\t%s\t%s\t%s\t%s — %s\n" \
    "$category" "$url" "$status" "$title" "$has_form" "$outcome" "$notes"
done

echo "" >&2
echo "auth_smoke summary:" >&2
echo "  easy:   $pass_easy/$total_easy" >&2
echo "  medium: $pass_medium/$total_medium" >&2
echo "  hard:   $pass_hard/$total_hard" >&2
echo "  total:  $((pass_easy + pass_medium + pass_hard))/$((total_easy + total_medium + total_hard))" >&2
