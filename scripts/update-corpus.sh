#!/bin/sh
# update-corpus.sh — refresh a corpus fixture's HTML capture.
#
# Usage:
#   scripts/update-corpus.sh <fixture-name> <url>
#
# Captures the URL with curl into tests/corpus/fixtures/<name>.html, then
# clears the corresponding .expected.txt to its bootstrap state. The next
# `zig build test-corpus` run reseeds the expected snapshot from the
# current renderer output. Review the resulting `git diff` before commit.
#
# This script does NOT call awr — the renderer is exercised by the test
# runner so the bless step always reflects the binary that's about to ship.

set -e

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <fixture-name> <url>" >&2
    echo "  e.g.: $0 example_com https://example.com/" >&2
    exit 64
fi

NAME="$1"
URL="$2"
FIXTURE_DIR="tests/corpus/fixtures"
HTML_PATH="$FIXTURE_DIR/$NAME.html"
EXPECTED_PATH="$FIXTURE_DIR/$NAME.expected.txt"

if [ ! -d "$FIXTURE_DIR" ]; then
    echo "error: $FIXTURE_DIR not found — run from repo root" >&2
    exit 66
fi

echo "fetching: $URL"
curl -sL --fail --max-time 30 "$URL" -o "$HTML_PATH"
SIZE=$(wc -c < "$HTML_PATH" | tr -d ' ')
echo "  -> wrote $HTML_PATH ($SIZE bytes)"

# Clear expected to bootstrap state. Runner reseeds on next test run.
: > "$EXPECTED_PATH"
echo "  -> cleared $EXPECTED_PATH (will reseed on next test run)"

echo ""
echo "next steps:"
echo "  1. ensure tests/corpus_runner.zig has a Fixture{} entry for \"$NAME\""
echo "  2. zig build test-corpus    # reseeds .expected.txt"
echo "  3. git diff $EXPECTED_PATH  # review the seeded snapshot"
echo "  4. git add $HTML_PATH $EXPECTED_PATH && git commit"
