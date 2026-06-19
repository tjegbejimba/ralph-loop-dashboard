#!/usr/bin/env bash
# Tests for pre-launch rejection handling.
#
# Regression guard for incident #132: when a bounded-queue candidate is found
# not runnable BEFORE any work starts (unresolved blocker, non-canonical state),
# ralph.sh MUST NOT apply ralph:failed — that label means "Ralph attempted work
# but human recovery is required." Pre-launch rejections should leave the issue's
# state label unchanged (it stays ralph:ready and self-defers).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Set up required directories and variables for state.sh
export STATE_DIR="$TEST_ROOT/state"
export LOG_DIR="$TEST_ROOT/logs"
mkdir -p "$STATE_DIR" "$LOG_DIR"

# shellcheck source=/dev/null
source "$REPO_ROOT/ralph/lib/state.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/ralph/lib/status.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Test 1: status_mark_rejected writes "rejected" status (not "failed")
TEST_RUN_ID="test-run-$(date +%s)"
mkdir -p "$STATE_DIR/runs/$TEST_RUN_ID"

status_mark_rejected 123 "unresolved_blocker(#122)" "$TEST_RUN_ID"
status_file="$STATE_DIR/runs/${TEST_RUN_ID}/status.json"
[[ -f "$status_file" ]] || { fail "status_mark_rejected creates status file"; exit 1; }

status=$(jq -r '.items["123"].status' "$status_file")
reason=$(jq -r '.items["123"].reason' "$status_file")

[[ "$status" == "rejected" ]] && pass "status_mark_rejected sets status=rejected" \
  || fail "status_mark_rejected sets status=rejected (got '$status')"

[[ "$reason" == "unresolved_blocker(#122)" ]] && pass "status_mark_rejected records rejection reason" \
  || fail "status_mark_rejected records rejection reason (got '$reason')"

# Test 2: rejected items have null worker metadata (no claim)
worker_id=$(jq -r '.items["123"].workerId // "null"' "$status_file")
pid=$(jq -r '.items["123"].pid // "null"' "$status_file")

[[ "$worker_id" == "null" ]] && pass "rejected item has null workerId" \
  || fail "rejected item has null workerId (got '$worker_id')"

[[ "$pid" == "null" ]] && pass "rejected item has null pid" \
  || fail "rejected item has null pid (got '$pid')"

# Test 3: status_mark_rejected is idempotent
status_mark_rejected 123 "still blocked" "$TEST_RUN_ID"
status_after=$(jq -r '.items["123"].status' "$status_file")
reason_after=$(jq -r '.items["123"].reason' "$status_file")

[[ "$status_after" == "rejected" ]] && pass "status_mark_rejected is idempotent (status)" \
  || fail "status_mark_rejected is idempotent (status) (got '$status_after')"

[[ "$reason_after" == "still blocked" ]] && pass "status_mark_rejected updates reason" \
  || fail "status_mark_rejected updates reason (got '$reason_after')"

# Test 4: verify status_mark_failed still exists and behaves differently
status_mark_failed 456 "Copilot exited non-zero" "$TEST_RUN_ID"
failed_status=$(jq -r '.items["456"].status' "$status_file")
failed_error=$(jq -r '.items["456"].error' "$status_file")

[[ "$failed_status" == "failed" ]] && pass "status_mark_failed sets status=failed" \
  || fail "status_mark_failed sets status=failed (got '$failed_status')"

[[ "$failed_error" == "Copilot exited non-zero" ]] && pass "status_mark_failed records error" \
  || fail "status_mark_failed records error (got '$failed_error')"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
