#!/usr/bin/env bash
# Integration test for recovery ledger — parking recoverable Ralph work

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
mkdir -p "$TEST_ROOT/.ralph/lock"
LOG_DIR="$TEST_ROOT/.ralph/logs"
mkdir -p "$LOG_DIR"
export LOG_DIR

# Source the libraries
# shellcheck source=../ralph/lib/state.sh
. "$REPO_ROOT/ralph/lib/state.sh"
# shellcheck source=../ralph/lib/recovery-ledger.sh
. "$REPO_ROOT/ralph/lib/recovery-ledger.sh"

# ===========================================================================
# Group 1 — Recovery ledger record and load
# ===========================================================================
echo "=== Group 1: Recovery ledger record and load ==="

# Test 1: ledger_record_recoverable creates entry
next_retry=$(date -u -v+5M +%FT%TZ 2>/dev/null || date -u -d '+5 minutes' +%FT%TZ)
ledger_record_recoverable "42" "123" "slice-42-foo" "1" "$next_retry" "worker exit before merge"

ledger_file="$TEST_ROOT/.ralph/recovery-ledger.json"
if [[ ! -f "$ledger_file" ]]; then
  fail "ledger_record_recoverable should create recovery-ledger.json"
else
  pass "ledger_record_recoverable creates recovery-ledger.json"
fi

# Test 2: ledger_load_entry retrieves recorded data
entry=$(ledger_load_entry "42")
if echo "$entry" | jq -e '.pr == "123"' >/dev/null; then
  pass "ledger_load_entry retrieves PR"
else
  fail "ledger_load_entry should retrieve PR=123, got: $entry"
fi

if echo "$entry" | jq -e '.branch == "slice-42-foo"' >/dev/null; then
  pass "ledger_load_entry retrieves branch"
else
  fail "ledger_load_entry should retrieve branch=slice-42-foo"
fi

# Test 3: ledger_is_recoverable returns true for recorded issue
if ledger_is_recoverable "42"; then
  pass "ledger_is_recoverable returns true for recorded issue"
else
  fail "ledger_is_recoverable should return true for issue 42"
fi

if ! ledger_is_recoverable "99"; then
  pass "ledger_is_recoverable returns false for non-existent issue"
else
  fail "ledger_is_recoverable should return false for issue 99"
fi

# Test 4: ledger_is_recovery_due checks lease expiry
if ! ledger_is_recovery_due "42"; then
  pass "ledger_is_recovery_due returns false when lease not expired"
else
  fail "ledger_is_recovery_due should return false for fresh entry"
fi

# Manually set nextRetryAt to past
jq '.["42"].nextRetryAt = "2020-01-01T00:00:00Z"' "$ledger_file" > "$ledger_file.tmp"
mv "$ledger_file.tmp" "$ledger_file"

if ledger_is_recovery_due "42"; then
  pass "ledger_is_recovery_due returns true when lease expired"
else
  fail "ledger_is_recovery_due should return true for expired lease"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "========================================="
echo "Passed: $pass_count"
echo "Failed: $fail_count"
echo "========================================="
[[ "$fail_count" == "0" ]]
