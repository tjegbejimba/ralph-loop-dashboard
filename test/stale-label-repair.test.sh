#!/usr/bin/env bash
# Regression test for stale-label repair — reconcile stale ralph:running with recoverable PR/branch evidence

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
mkdir -p "$TEST_ROOT/.ralph/runs/stale-run-20260601-100000-xyz789"
mkdir -p "$TEST_ROOT/.ralph/logs"
mkdir -p "$TEST_ROOT/.ralph/lock"

RUN_ID="stale-run-20260601-100000-xyz789"
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
# Group 1 — Stale ralph:running with recoverable PR/branch evidence
# ===========================================================================
echo "=== Group 1: Stale ralph:running with recoverable PR/branch evidence ==="

# Test 1: Worker died with status=running, but has PR evidence in recovery ledger
cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "50": {
    "status": "running",
    "workerId": 1,
    "pid": 77777,
    "logFile": "iter-20260601-100000-w1-issue-50.log",
    "startedAt": "2026-06-01T10:00:00Z",
    "error": null
  }
}}
EOF

# Record recovery evidence BEFORE worker died
next_retry=$(date -u -v+5M +%FT%TZ 2>/dev/null || date -u -d '+5 minutes' +%FT%TZ)
ledger_record_recoverable "50" "234" "slice-50-auth" "1" "$next_retry" "worker died before merge"

# Now reconcile the stale worker
state_lock
status_reconcile_stale_workers "$RUN_ID"
state_unlock

# The worker should be marked failed since the PID is dead
content=$(cat "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json")
if echo "$content" | jq -e '.items["50"].status == "failed"' >/dev/null; then
  pass "Stale worker with dead PID is marked failed"
else
  fail "Expected status 'failed' for dead PID 77777, got: $(echo "$content" | jq -r '.items["50"].status')"
fi

# But the recovery ledger should still show it's recoverable
if ledger_is_recoverable "50"; then
  pass "Recovery ledger still marks issue 50 as recoverable"
else
  fail "Issue 50 should still be recoverable via ledger after worker death"
fi

# Test 2: Recovery ledger preserves PR/branch evidence after worker reconciliation
entry=$(ledger_load_entry "50")
if echo "$entry" | jq -e '.pr == "234"' >/dev/null; then
  pass "Recovery ledger preserves PR number after reconciliation"
else
  fail "Expected PR=234 in ledger, got: $entry"
fi

if echo "$entry" | jq -e '.branch == "slice-50-auth"' >/dev/null; then
  pass "Recovery ledger preserves branch name after reconciliation"
else
  fail "Expected branch=slice-50-auth in ledger"
fi

# Test 3: Attempt counter is preserved (not reset) after stale worker reconciliation
attempt=$(echo "$entry" | jq -r '.attempt')
if [[ "$attempt" == "1" ]]; then
  pass "Recovery ledger preserves attempt counter"
else
  fail "Expected attempt=1 in ledger, got: $attempt"
fi

# ===========================================================================
# Group 2 — Stale worker without recovery evidence stays failed
# ===========================================================================
echo
echo "=== Group 2: Stale worker without recovery evidence stays failed ==="

# Test 4: Worker died without PR/branch evidence — should be terminal failed
cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "51": {
    "status": "running",
    "workerId": 2,
    "pid": 88888,
    "logFile": "iter-20260601-100100-w2-issue-51.log",
    "startedAt": "2026-06-01T10:01:00Z",
    "error": null
  }
}}
EOF

# No recovery ledger entry for issue 51
state_lock
status_reconcile_stale_workers "$RUN_ID"
state_unlock

content=$(cat "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json")
if echo "$content" | jq -e '.items["51"].status == "failed"' >/dev/null; then
  pass "Worker without recovery evidence is marked failed"
else
  fail "Expected status 'failed' for issue 51 without recovery evidence"
fi

# It should NOT be recoverable
if ledger_is_recoverable "51"; then
  fail "Issue 51 without PR evidence should NOT be recoverable"
else
  pass "Issue 51 without recovery evidence is not recoverable"
fi

# ===========================================================================
# Group 3 — Multiple stale workers with mixed recovery evidence
# ===========================================================================
echo
echo "=== Group 3: Multiple stale workers with mixed recovery evidence ==="

# Test 5: Reconcile multiple workers — some with recovery evidence, some without
cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "60": {
    "status": "running",
    "workerId": 1,
    "pid": 11111,
    "logFile": "iter-w1-issue-60.log",
    "startedAt": "2026-06-01T10:00:00Z",
    "error": null
  },
  "61": {
    "status": "running",
    "workerId": 2,
    "pid": 22222,
    "logFile": "iter-w2-issue-61.log",
    "startedAt": "2026-06-01T10:01:00Z",
    "error": null
  },
  "62": {
    "status": "running",
    "workerId": 3,
    "pid": 33333,
    "logFile": "iter-w3-issue-62.log",
    "startedAt": "2026-06-01T10:02:00Z",
    "error": null
  }
}}
EOF

# Only issues 60 and 62 have recovery evidence
ledger_record_recoverable "60" "300" "slice-60-fix" "1" "$next_retry" "worker died"
ledger_record_recoverable "62" "302" "slice-62-feature" "2" "$next_retry" "worker crashed"

state_lock
status_reconcile_stale_workers "$RUN_ID"
state_unlock

content=$(cat "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json")

# All should be marked failed (PID check)
for issue in 60 61 62; do
  if echo "$content" | jq -e ".items[\"$issue\"].status == \"failed\"" >/dev/null; then
    pass "Issue $issue marked failed after reconciliation"
  else
    fail "Issue $issue should be failed"
  fi
done

# But only 60 and 62 should be recoverable
if ledger_is_recoverable "60" && ledger_is_recoverable "62"; then
  pass "Issues 60 and 62 are recoverable via ledger"
else
  fail "Issues 60 and 62 should be recoverable"
fi

if ledger_is_recoverable "61"; then
  fail "Issue 61 without recovery evidence should not be recoverable"
else
  pass "Issue 61 without recovery evidence is not recoverable"
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
