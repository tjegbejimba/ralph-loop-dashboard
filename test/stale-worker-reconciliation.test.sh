#!/usr/bin/env bash
# Integration test for stale worker reconciliation — detects and recovers from externally-killed workers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Setup test repo structure with run directory
mkdir -p "$TEST_ROOT/.ralph/runs/20260615-140342-d132e9c8"
mkdir -p "$TEST_ROOT/.ralph/logs"
mkdir -p "$TEST_ROOT/.ralph/lock"

RUN_ID="20260615-140342-d132e9c8"
LOG_DIR="$TEST_ROOT/.ralph/logs"
REPO="test/repo"
export RUN_ID LOG_DIR REPO

# Source the libraries
. "$SCRIPT_DIR/../ralph/lib/state.sh"
. "$SCRIPT_DIR/../ralph/lib/status.sh"

# Test 1: status_reconcile_stale_workers detects dead PIDs and marks them failed
echo "Test 1: Reconcile stale 'running' items with dead PIDs"

# Start a live ralph-like process for comparison
( exec -a "ralph.sh-test" sleep 300 ) &
live_pid=$!
trap 'kill $live_pid 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

# Create status.json with one stale running item and one live item
cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "124": {
    "status": "running",
    "workerId": 1,
    "pid": 99999,
    "logFile": "iter-20260615-140000-w1-issue-124.log",
    "startedAt": "2026-06-15T14:00:00Z",
    "error": null
  },
  "125": {
    "status": "running",
    "workerId": 2,
    "pid": $live_pid,
    "logFile": "iter-20260615-140100-w2-issue-125.log",
    "startedAt": "2026-06-15T14:01:00Z",
    "error": null
  }
}}
EOF

state_init
state_lock
status_reconcile_stale_workers "$RUN_ID"
state_unlock

content=$(cat "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json")

# Dead PID (99999) should be marked failed
if ! echo "$content" | jq -e '.items["124"].status == "failed"' >/dev/null; then
  echo "FAIL: Stale worker #124 should be marked failed, got: $(echo "$content" | jq -r '.items["124"].status')"
  exit 1
fi

if ! echo "$content" | jq -e '.items["124"].error | contains("died")' >/dev/null; then
  echo "FAIL: Stale worker #124 should have 'died' error message"
  exit 1
fi

# Live PID should remain running
if ! echo "$content" | jq -e '.items["125"].status == "running"' >/dev/null; then
  echo "FAIL: Live worker #125 should remain running, got: $(echo "$content" | jq -r '.items["125"].status')"
  exit 1
fi

kill $live_pid 2>/dev/null || true
echo "PASS: status_reconcile_stale_workers detects dead PIDs"

# Test 2: Reconciliation also detects 'claimed' items with dead PIDs
echo ""
echo "Test 2: Reconcile stale 'claimed' items with dead PIDs"

cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "126": {
    "status": "claimed",
    "workerId": 1,
    "pid": 88888,
    "logFile": "iter-20260615-140200-w1-issue-126.log",
    "startedAt": "2026-06-15T14:02:00Z",
    "error": null
  }
}}
EOF

state_lock
status_reconcile_stale_workers "$RUN_ID"
state_unlock

content=$(cat "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json")

if ! echo "$content" | jq -e '.items["126"].status == "failed"' >/dev/null; then
  echo "FAIL: Stale claimed item #126 should be marked failed"
  exit 1
fi

echo "PASS: status_reconcile_stale_workers handles claimed items"

# Test 3: Reconciliation leaves terminal states unchanged
echo ""
echo "Test 3: Terminal states are not modified"

cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "123": {"status": "merged", "workerId": null, "pid": null, "logFile": null, "startedAt": null, "error": null},
  "124": {"status": "failed", "workerId": 1, "pid": 99999, "logFile": "test.log", "startedAt": "2026-06-15T14:00:00Z", "error": "Previous failure"},
  "125": {"status": "skipped", "workerId": null, "pid": null, "logFile": null, "startedAt": null, "error": null},
  "126": {"status": "rejected", "workerId": null, "pid": null, "logFile": null, "startedAt": null, "error": null}
}}
EOF

state_lock
status_reconcile_stale_workers "$RUN_ID"
state_unlock

content=$(cat "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json")

# All terminal states should be unchanged
if ! echo "$content" | jq -e '.items["123"].status == "merged"' >/dev/null; then
  echo "FAIL: Merged item should remain merged"
  exit 1
fi

if ! echo "$content" | jq -e '.items["124"].status == "failed"' >/dev/null; then
  echo "FAIL: Failed item should remain failed"
  exit 1
fi

if ! echo "$content" | jq -e '.items["125"].status == "skipped"' >/dev/null; then
  echo "FAIL: Skipped item should remain skipped"
  exit 1
fi

if ! echo "$content" | jq -e '.items["126"].status == "rejected"' >/dev/null; then
  echo "FAIL: Rejected item should remain rejected"
  exit 1
fi

echo "PASS: Terminal states unchanged"

# Test 4: Direct integration — reconciliation on run status check
echo ""
echo "Test 4: Reconciliation integrated into run operations"

# Use current test root (no new temp dir to avoid trap complexity)
cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<EOF
{"items":{
  "300": {
    "status": "running",
    "workerId": 1,
    "pid": 66666,
    "logFile": "iter-test-w1-issue-300.log",
    "startedAt": "2026-06-15T14:00:00Z",
    "error": null
  }
}}
EOF

# Simulate a run status check with reconciliation
state_lock
status_reconcile_stale_workers "$RUN_ID"
state_unlock

content=$(cat "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json")
if ! echo "$content" | jq -e '.items["300"].status == "failed"' >/dev/null; then
  echo "FAIL: Integrated reconciliation should mark dead PID as failed"
  exit 1
fi

echo "PASS: Integrated reconciliation works"

echo ""
echo "All stale-worker-reconciliation tests passed!"
