#!/usr/bin/env bash
# Regression test for reset budget requeue — operator can reset terminal failures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0
fail_count=0
fail() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }

# Setup test repo structure
mkdir -p "$TEST_ROOT/.ralph/runs/reset-test-20260603-100000-xyz"
mkdir -p "$TEST_ROOT/.ralph/logs"
mkdir -p "$TEST_ROOT/.ralph/lock"

RUN_ID="reset-test-20260603-100000-xyz"
LOG_DIR="$TEST_ROOT/.ralph/logs"
REPO="test/repo"
export RUN_ID LOG_DIR REPO

# Source the libraries
# shellcheck source=../ralph/lib/state.sh
. "$REPO_ROOT/ralph/lib/state.sh"
# shellcheck source=../ralph/lib/status.sh
. "$REPO_ROOT/ralph/lib/status.sh"
# shellcheck source=../ralph/lib/recovery-ledger.sh
. "$REPO_ROOT/ralph/lib/recovery-ledger.sh"

# ===========================================================================
# Group 1 — Reset clears terminal state and requeues
# ===========================================================================
echo "=== Group 1: Reset clears terminal state and requeues ==="

# Test 1: Create a terminal failed entry
terminal_time=$(date -u +%FT%TZ)
ledger_record_terminal "80" "terminal" "3" "$terminal_time" "Retry budget exhausted"

if ledger_is_terminal "80"; then
  pass "Issue 80 is initially terminal"
else
  fail "Issue 80 should be terminal before reset"
fi

# Test 2: Reset the entry — clears attempt counter and terminal state
ledger_reset_budget "80" "600" "slice-80-retry"

if ledger_is_terminal "80"; then
  fail "Issue 80 should not be terminal after reset"
else
  pass "Reset clears terminal state"
fi

# Test 3: Reset restores recoverability
if ledger_is_recoverable "80"; then
  pass "Issue 80 is recoverable after reset"
else
  fail "Reset should make issue recoverable again"
fi

# Test 4: Reset clears attempt counter
entry=$(ledger_load_entry "80")
attempt=$(echo "$entry" | jq -r '.attempt')
if [[ "$attempt" == "0" || "$attempt" == "null" ]]; then
  pass "Reset clears attempt counter"
else
  fail "Expected attempt=0 or null after reset, got: $attempt"
fi

# Test 5: Reset preserves PR/branch evidence
pr=$(echo "$entry" | jq -r '.pr')
if [[ "$pr" == "600" ]]; then
  pass "Reset preserves PR number"
else
  fail "Expected PR=600 after reset, got: $pr"
fi

branch=$(echo "$entry" | jq -r '.branch')
if [[ "$branch" == "slice-80-retry" ]]; then
  pass "Reset preserves branch name"
else
  fail "Expected branch=slice-80-retry after reset, got: $branch"
fi

# ===========================================================================
# Group 2 — Reset does not delete PR branches or state
# ===========================================================================
echo
echo "=== Group 2: Reset preserves PR/branch evidence ==="

# Test 6: Multiple resets on the same issue preserve PR evidence
ledger_reset_budget "80" "600" "slice-80-retry"
entry=$(ledger_load_entry "80")
pr=$(echo "$entry" | jq -r '.pr')

if [[ "$pr" == "600" ]]; then
  pass "Multiple resets preserve PR evidence"
else
  fail "PR should still be 600 after second reset"
fi

# Test 7: Reset can update PR/branch if provided
ledger_reset_budget "80" "601" "slice-80-retry-v2"
entry=$(ledger_load_entry "80")
pr=$(echo "$entry" | jq -r '.pr')
branch=$(echo "$entry" | jq -r '.branch')

if [[ "$pr" == "601" && "$branch" == "slice-80-retry-v2" ]]; then
  pass "Reset can update PR/branch references"
else
  fail "Expected PR=601 and branch=slice-80-retry-v2 after reset with new values"
fi

# ===========================================================================
# Group 3 — Reset clears terminal reason
# ===========================================================================
echo
echo "=== Group 3: Reset clears terminal reason ==="

# Test 8: Terminal reason is cleared after reset
entry=$(ledger_load_entry "80")
terminal_reason=$(echo "$entry" | jq -r '.terminal_reason // "null"')

if [[ "$terminal_reason" == "null" ]]; then
  pass "Reset clears terminal_reason field"
else
  fail "terminal_reason should be null after reset, got: $terminal_reason"
fi

# Test 9: Status is changed from failed to recoverable
status=$(echo "$entry" | jq -r '.status')
if [[ "$status" == "recoverable" ]]; then
  pass "Reset changes status from failed to recoverable"
else
  fail "Expected status=recoverable after reset, got: $status"
fi

# ===========================================================================
# Group 4 — Reset on non-terminal entries
# ===========================================================================
echo
echo "=== Group 4: Reset on non-terminal entries ==="

# Test 10: Reset on a recoverable entry updates it without error
next_retry=$(date -u -v+5M +%FT%TZ 2>/dev/null || date -u -d '+5 minutes' +%FT%TZ)
ledger_record_recoverable "81" "700" "slice-81-feature" "1" "$next_retry" "first attempt"

ledger_reset_budget "81" "700" "slice-81-feature"

entry=$(ledger_load_entry "81")
attempt=$(echo "$entry" | jq -r '.attempt')

if [[ "$attempt" == "0" || "$attempt" == "null" ]]; then
  pass "Reset on recoverable entry clears attempt counter"
else
  fail "Expected attempt=0 after reset on recoverable, got: $attempt"
fi

# ===========================================================================
# Group 5 — Reset without ledger entry creates new recoverable entry
# ===========================================================================
echo
echo "=== Group 5: Reset creates new entry if missing ==="

# Test 11: Reset on non-existent entry creates new recoverable entry
if entry=$(ledger_load_entry "82" 2>&1) && [[ -n "$entry" ]]; then
  fail "Issue 82 should not have a ledger entry yet"
fi

ledger_reset_budget "82" "800" "slice-82-new"

if ledger_is_recoverable "82"; then
  pass "Reset on non-existent entry creates new recoverable entry"
else
  fail "Issue 82 should be recoverable after reset"
fi

entry=$(ledger_load_entry "82")
pr=$(echo "$entry" | jq -r '.pr')
if [[ "$pr" == "800" ]]; then
  pass "New recoverable entry has correct PR"
else
  fail "Expected PR=800 for new entry, got: $pr"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "========================================="
echo "PASSED: $pass_count"
echo "FAILED: $fail_count"
echo "========================================="

if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
