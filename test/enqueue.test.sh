#!/usr/bin/env bash
# Integration test for launch.sh --enqueue

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/.ralph/lib"

# Copy lib/state.sh so the sourcing on line ~69 of launch.sh doesn't fail.
cp "$REPO_ROOT/ralph/lib/state.sh" "$TEST_ROOT/.ralph/lib/state.sh"

# Helper: run launch.sh --enqueue in the test repo context.
enqueue() {
  RALPH_MAIN_REPO="$TEST_ROOT" "$REPO_ROOT/ralph/launch.sh" --enqueue "$@"
}

# Reference config with all fields we want to verify are preserved.
REFERENCE_CONFIG='{
  "profile": "generic",
  "issue": {
    "titleRegex": "^Slice [0-9]+:",
    "titleNumRegex": "^Slice (?<x>[0-9]+):",
    "issueSearch": "Slice in:title",
    "order": "asc"
  },
  "validation": {
    "commands": [{"name": "Project checks", "command": "npm test"}]
  },
  "stages": [{"id": "merging", "label": "merging", "icon": "✓"}]
}'

# ---------------------------------------------------------------------------
echo "Test 1: --enqueue single issue sets issue.numbers"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
output=$(enqueue 8)
numbers=$(jq -c '.issue.numbers' "$TEST_ROOT/.ralph/config.json")
if [[ "$numbers" != "[8]" ]]; then
  echo "FAIL Test 1: expected [8], got $numbers"
  exit 1
fi
if ! echo "$output" | grep -q "Enqueued"; then
  echo "FAIL Test 1: no summary in output: $output"
  exit 1
fi
echo "PASS Test 1"

# ---------------------------------------------------------------------------
echo "Test 2: --enqueue multiple issues"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
output=$(enqueue 8 9 10)
numbers=$(jq -c '.issue.numbers' "$TEST_ROOT/.ralph/config.json")
if [[ "$numbers" != "[8,9,10]" ]]; then
  echo "FAIL Test 2: expected [8,9,10], got $numbers"
  exit 1
fi
if ! echo "$output" | grep -qE "Enqueued 3|#8.*#9.*#10"; then
  echo "FAIL Test 2: summary missing or wrong: $output"
  exit 1
fi
echo "PASS Test 2"

# ---------------------------------------------------------------------------
echo "Test 3: missing config exits non-zero with actionable error"
rm -f "$TEST_ROOT/.ralph/config.json"
set +e
output=$(enqueue 5 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "FAIL Test 3: expected non-zero exit, got 0"
  exit 1
fi
if ! echo "$output" | grep -qi "config.json"; then
  echo "FAIL Test 3: error should mention config.json: $output"
  exit 1
fi
echo "PASS Test 3"

# ---------------------------------------------------------------------------
echo "Test 4: non-integer argument is rejected"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
set +e
output=$(enqueue "foo" 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "FAIL Test 4: expected non-zero exit for 'foo'"
  exit 1
fi
if ! echo "$output" | grep -qi "foo\|invalid\|integer"; then
  echo "FAIL Test 4: error should mention invalid arg: $output"
  exit 1
fi
echo "PASS Test 4"

# ---------------------------------------------------------------------------
echo "Test 5: negative integer is rejected"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
set +e
output=$(enqueue -- -1 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "FAIL Test 5: expected non-zero exit for -1"
  exit 1
fi
echo "PASS Test 5"

# ---------------------------------------------------------------------------
echo "Test 6: zero is rejected"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
set +e
output=$(enqueue 0 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "FAIL Test 6: expected non-zero exit for 0"
  exit 1
fi
echo "PASS Test 6"

# ---------------------------------------------------------------------------
echo "Test 7: idempotency — second run with same numbers leaves file unchanged"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
enqueue 8 9 > /dev/null
checksum1=$(md5 -q "$TEST_ROOT/.ralph/config.json" 2>/dev/null \
  || md5sum "$TEST_ROOT/.ralph/config.json" | awk '{print $1}')
output=$(enqueue 8 9)
checksum2=$(md5 -q "$TEST_ROOT/.ralph/config.json" 2>/dev/null \
  || md5sum "$TEST_ROOT/.ralph/config.json" | awk '{print $1}')
if [[ "$checksum1" != "$checksum2" ]]; then
  echo "FAIL Test 7: file changed on idempotent re-run"
  exit 1
fi
if ! echo "$output" | grep -qi "no change\|already"; then
  echo "FAIL Test 7: expected 'no change' message: $output"
  exit 1
fi
echo "PASS Test 7"

# ---------------------------------------------------------------------------
echo "Test 8: other fields preserved after enqueue"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
enqueue 42 > /dev/null
profile=$(jq -r '.profile' "$TEST_ROOT/.ralph/config.json")
title_regex=$(jq -r '.issue.titleRegex' "$TEST_ROOT/.ralph/config.json")
issue_search=$(jq -r '.issue.issueSearch' "$TEST_ROOT/.ralph/config.json")
order=$(jq -r '.issue.order' "$TEST_ROOT/.ralph/config.json")
stages_id=$(jq -r '.stages[0].id' "$TEST_ROOT/.ralph/config.json")
if [[ "$profile" != "generic" ]]; then
  echo "FAIL Test 8: profile changed: $profile"; exit 1
fi
if [[ "$title_regex" != "^Slice [0-9]+:" ]]; then
  echo "FAIL Test 8: titleRegex changed: $title_regex"; exit 1
fi
if [[ "$issue_search" != "Slice in:title" ]]; then
  echo "FAIL Test 8: issueSearch changed: $issue_search"; exit 1
fi
if [[ "$order" != "asc" ]]; then
  echo "FAIL Test 8: issue.order changed: $order"; exit 1
fi
if [[ "$stages_id" != "merging" ]]; then
  echo "FAIL Test 8: stages changed: $stages_id"; exit 1
fi
echo "PASS Test 8"

# ---------------------------------------------------------------------------
echo "Test 9: duplicate numbers are rejected"
echo "$REFERENCE_CONFIG" > "$TEST_ROOT/.ralph/config.json"
set +e
output=$(enqueue 8 9 8 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "FAIL Test 9: expected non-zero exit for duplicate 8"
  exit 1
fi
if ! echo "$output" | grep -qi "duplicate\|8"; then
  echo "FAIL Test 9: error should mention duplicate: $output"
  exit 1
fi
echo "PASS Test 9"

# ---------------------------------------------------------------------------
echo "Test 10: --help documents --enqueue"
output=$("$REPO_ROOT/ralph/launch.sh" --help 2>&1 || true)
if ! echo "$output" | grep -q "\-\-enqueue"; then
  echo "FAIL Test 10: --help does not document --enqueue: $output"
  exit 1
fi
echo "PASS Test 10"

echo ""
echo "All enqueue tests passed!"
