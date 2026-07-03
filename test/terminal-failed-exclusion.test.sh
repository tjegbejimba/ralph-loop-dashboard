#!/usr/bin/env bash
# Regression test for terminal failed exclusion — verify ralph:failed items are not auto-picked

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
mkdir -p "$TEST_ROOT/.ralph/runs/terminal-test-20260602-120000-abc"
mkdir -p "$TEST_ROOT/.ralph/logs"
mkdir -p "$TEST_ROOT/.ralph/lock"

RUN_ID="terminal-test-20260602-120000-abc"
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
# Group 1 — Terminal failed items are excluded from recovery
# ===========================================================================
echo "=== Group 1: Terminal failed items are excluded from recovery ==="

# Test 1: Issue with exhausted retry budget is marked terminal
next_retry=$(date -u -v+5M +%FT%TZ 2>/dev/null || date -u -d '+5 minutes' +%FT%TZ)
terminal_time=$(date -u +%FT%TZ)

# Record terminal failure in recovery ledger
ledger_record_terminal "70" "terminal" "3" "$terminal_time" "Retry budget exhausted after 3 attempts"

# Terminal items should NOT be recoverable
if ledger_is_recoverable "70"; then
  fail "Terminal failed issue 70 should not be recoverable"
else
  pass "Terminal failed issue is not recoverable"
fi

# Test 2: Terminal reason is preserved in ledger
entry=$(ledger_load_entry "70")
if echo "$entry" | jq -e '.state == "terminal"' >/dev/null; then
  pass "Terminal state is recorded in ledger"
else
  fail "Expected state=terminal in ledger, got: $entry"
fi

if echo "$entry" | jq -e '.terminal_reason' >/dev/null; then
  pass "Terminal reason is preserved in ledger"
else
  fail "Terminal reason should be in ledger"
fi

# Test 3: Attempt counter shows exhausted budget
attempt=$(echo "$entry" | jq -r '.attempt')
if [[ "$attempt" == "3" ]]; then
  pass "Attempt counter shows exhausted budget"
else
  fail "Expected attempt=3 for terminal failure, got: $attempt"
fi

# ===========================================================================
# Group 2 — Terminal failed vs recoverable failed distinction
# ===========================================================================
echo
echo "=== Group 2: Terminal failed vs recoverable failed distinction ==="

# Test 4: Recoverable failure (attempt < budget) is still recoverable
ledger_record_recoverable "71" "500" "slice-71-fix" "1" "$next_retry" "first attempt failed"

if ledger_is_recoverable "71"; then
  pass "Issue with budget remaining is recoverable"
else
  fail "Issue 71 with attempt=1 should be recoverable"
fi

# Test 5: Same issue transitions from recoverable to terminal after budget exhausted
ledger_record_terminal "71" "terminal" "3" "$terminal_time" "Final attempt failed"

if ledger_is_recoverable "71"; then
  fail "Issue 71 should not be recoverable after becoming terminal"
else
  pass "Issue transitions from recoverable to terminal"
fi

# ===========================================================================
# Group 3 — Status file terminal marking
# ===========================================================================
echo
echo "=== Group 3: Status file terminal marking ==="

# Test 6: status.json can record terminal failures
cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "72": {
    "status": "failed",
    "workerId": 1,
    "pid": 12345,
    "logFile": "iter-test-issue-72.log",
    "startedAt": "2026-06-02T12:00:00Z",
    "error": "Retry budget exhausted"
  }
}}
EOF

status=$(status_load_item "72" "status")
if [[ "$status" == "failed" ]]; then
  pass "Terminal failure is recorded in status.json"
else
  fail "Expected status=failed for terminal item"
fi

error=$(status_load_item "72" "error")
if echo "$error" | grep -q "budget exhausted"; then
  pass "Terminal error message indicates exhausted budget"
else
  fail "Error message should indicate budget exhaustion, got: $error"
fi

# ===========================================================================
# Group 4 — Terminal state interacts correctly with state claims
# ===========================================================================
echo
echo "=== Group 4: Terminal state prevents new claims ==="

# Test 7: Terminal items should not have active claims
cat > "$TEST_ROOT/.ralph/state.json" <<'EOF'
{
  "claims": {}
}
EOF

state_init

# Attempt to claim a terminal issue (simulated — in real code, eligibility check would prevent this)
# For this test, we verify the ledger state correctly identifies it as terminal
if ledger_is_terminal "70"; then
  pass "ledger_is_terminal correctly identifies terminal state"
else
  fail "Issue 70 should be identified as terminal"
fi

if ledger_is_terminal "71"; then
  pass "Issue 71 is correctly identified as terminal after transition"
else
  fail "Issue 71 should be terminal after exhausting budget"
fi

# Non-terminal issue should not be identified as terminal
if ledger_is_terminal "999"; then
  fail "Non-existent issue should not be terminal"
else
  pass "Non-existent issue is not terminal"
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
