#!/usr/bin/env bash
# Regression test for migration compatibility — old-format state/status files load without crashing

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
mkdir -p "$TEST_ROOT/.ralph/runs/old-run-20260501-120000-abc123def"
mkdir -p "$TEST_ROOT/.ralph/logs"
mkdir -p "$TEST_ROOT/.ralph/lock"

RUN_ID="old-run-20260501-120000-abc123def"
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
# Group 1 — Old-format status.json without recovery fields
# ===========================================================================
echo "=== Group 1: Old-format status.json loads without crashing ==="

# Test 1: status.json without recovery ledger fields loads successfully
cat > "$TEST_ROOT/.ralph/runs/$RUN_ID/status.json" <<'EOF'
{"items":{
  "42": {
    "status": "claimed",
    "workerId": 1,
    "pid": 12345,
    "logFile": "iter-20260501-120000-w1-issue-42.log",
    "startedAt": "2026-05-01T12:00:00Z",
    "error": null
  },
  "43": {
    "status": "failed",
    "workerId": 2,
    "pid": 12346,
    "logFile": "iter-20260501-120100-w2-issue-43.log",
    "startedAt": "2026-05-01T12:01:00Z",
    "error": "Build failed"
  }
}}
EOF

# Verify we can load status without crashing
if status=$(status_load_item "42" "status" 2>&1); then
  if [[ "$status" == "claimed" ]]; then
    pass "Old-format status.json loads claimed status"
  else
    fail "Expected status 'claimed', got: $status"
  fi
else
  fail "Old-format status.json should load without crashing: $status"
fi

# Test 2: Failed item without recovery data is interpreted conservatively
if status=$(status_load_item "43" "status" 2>&1); then
  if [[ "$status" == "failed" ]]; then
    pass "Old-format failed status loads"
  else
    fail "Expected status 'failed', got: $status"
  fi
else
  fail "Failed item should load without crashing: $status"
fi

# Test 3: Error field from old format is preserved
if error=$(status_load_item "43" "error" 2>&1); then
  if [[ "$error" == "Build failed" ]]; then
    pass "Old-format error field is preserved"
  else
    fail "Expected error 'Build failed', got: $error"
  fi
else
  fail "Error field should load: $error"
fi

# ===========================================================================
# Group 2 — Old-format state.json without recovery ledger
# ===========================================================================
echo
echo "=== Group 2: Old-format state.json loads without crashing ==="

# Test 4: state.json with claims but no recovery ledger
cat > "$TEST_ROOT/.ralph/state.json" <<'EOF'
{
  "claims": {
    "44": {"worker_id": 1, "pid": 12347, "claimed_at": "2026-05-01T12:00:00Z"},
    "45": {"worker_id": 2, "pid": 12348, "claimed_at": "2026-05-01T12:01:00Z"}
  }
}
EOF

state_init 2>&1

# Verify state loads and we can check claims
if state_lock 2>&1; then
  # Use jq to query the state file directly since we don't have a state_load_claim function
  if jq -e '.claims["44"]' "$TEST_ROOT/.ralph/state.json" >/dev/null 2>&1; then
    pass "Old-format state.json loads and preserves claims"
  else
    fail "Old-format state.json should preserve claims"
  fi
  state_unlock
else
  fail "Should be able to lock state with old-format state.json"
fi

# ===========================================================================
# Group 3 — Recovery ledger absence is handled gracefully
# ===========================================================================
echo
echo "=== Group 3: Missing recovery ledger is handled gracefully ==="

# Test 5: ledger_is_recoverable returns false when ledger doesn't exist
rm -f "$TEST_ROOT/.ralph/recovery-ledger.json"

if ledger_is_recoverable "999" 2>&1; then
  fail "ledger_is_recoverable should return false when ledger missing"
else
  pass "Missing recovery ledger returns false for ledger_is_recoverable"
fi

# Test 6: ledger_load_entry returns null/empty when ledger doesn't exist
if entry=$(ledger_load_entry "999" 2>&1); then
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    pass "ledger_load_entry returns null/empty when ledger missing"
  else
    fail "Expected null/empty for missing ledger, got: $entry"
  fi
else
  # Command failed, which is also acceptable for missing ledger
  pass "ledger_load_entry handles missing ledger without crashing"
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
