#!/usr/bin/env bash
# Integration test for recovery lease claiming — bounded retries across runs

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

ledger_file=$(ledger_file)

# ===========================================================================
# Group 1 — Lease acquisition and release
# ===========================================================================
echo "=== Group 1: Lease acquisition and release ==="

# Test 1: Record a due recoverable item
past_retry=$(date -u -d '-1 minute' +%FT%TZ 2>/dev/null || date -u -v-1M +%FT%TZ)
ledger_record_recoverable "50" "200" "slice-50-auth" "0" "$past_retry" "worker exit before merge"

if ledger_is_recovery_due "50"; then
  pass "Recoverable item 50 is due for retry"
else
  fail "Item 50 should be due (nextRetryAt in past)"
fi

# Test 2: Claim a due recovery lease
if ledger_try_claim_recovery "50" "worker-1" "12345"; then
  pass "ledger_try_claim_recovery claims due recovery"
else
  fail "Should be able to claim due recovery for issue 50"
fi

# Verify lease data
entry=$(ledger_load_entry "50")
leased_by=$(echo "$entry" | jq -r '.leasedBy // empty')
lease_pid=$(echo "$entry" | jq -r '.leasePid // empty')

if [[ "$leased_by" == "worker-1" ]]; then
  pass "Lease records worker ID"
else
  fail "Expected leasedBy=worker-1, got: $leased_by"
fi

if [[ "$lease_pid" == "12345" ]]; then
  pass "Lease records PID"
else
  fail "Expected leasePid=12345, got: $lease_pid"
fi

# Test 3: Cannot double-claim while lease active
if ! ledger_try_claim_recovery "50" "worker-2" "99999"; then
  pass "ledger_try_claim_recovery prevents double-claim"
else
  fail "Should not allow second worker to claim active lease"
fi

# Test 4: Release recovery lease
ledger_release_recovery "50"
entry=$(ledger_load_entry "50")
leased_by=$(echo "$entry" | jq -r '.leasedBy // empty')

if [[ -z "$leased_by" || "$leased_by" == "null" ]]; then
  pass "ledger_release_recovery clears lease"
else
  fail "Expected leasedBy to be cleared, got: $leased_by"
fi

# Test 5: Can reclaim after release
if ledger_try_claim_recovery "50" "worker-3" "77777"; then
  pass "Can claim recovery after release"
else
  fail "Should be able to claim after lease released"
fi

# ===========================================================================
# Group 2 — Retry budget enforcement
# ===========================================================================
echo ""
echo "=== Group 2: Retry budget enforcement ==="

# Setup: fresh recoverable with attempt=0
ledger_release_recovery "50"
next_retry=$(date -u -d '-1 minute' +%FT%TZ 2>/dev/null || date -u -v-1M +%FT%TZ)
ledger_record_recoverable "60" "300" "slice-60-feat" "0" "$next_retry" "first attempt failed"

# Test 6: Increment attempt count
if ledger_increment_attempt "60"; then
  pass "ledger_increment_attempt increments to 1"
else
  fail "ledger_increment_attempt should succeed for attempt 0→1"
fi

entry=$(ledger_load_entry "60")
attempt=$(echo "$entry" | jq -r '.attempt')
if [[ "$attempt" == "1" ]]; then
  pass "Attempt counter is 1"
else
  fail "Expected attempt=1, got: $attempt"
fi

# Verify 5-minute cooldown set
next_retry_updated=$(echo "$entry" | jq -r '.nextRetryAt')
now_ts=$(date -u +%s)
retry_ts=$(date -u -d "$next_retry_updated" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$next_retry_updated" +%s)
cooldown_seconds=$((retry_ts - now_ts))

if [[ $cooldown_seconds -ge 240 && $cooldown_seconds -le 360 ]]; then
  pass "Cooldown set to ~5 minutes"
else
  fail "Expected cooldown ~300s, got: ${cooldown_seconds}s"
fi

# Test 7: Second increment (attempt 1→2, still within budget)
if ledger_increment_attempt "60"; then
  pass "ledger_increment_attempt increments to 2"
else
  fail "ledger_increment_attempt should succeed for attempt 1→2"
fi

entry=$(ledger_load_entry "60")
attempt=$(echo "$entry" | jq -r '.attempt')
if [[ "$attempt" == "2" ]]; then
  pass "Attempt counter is 2"
else
  fail "Expected attempt=2, got: $attempt"
fi

# Test 8: Third increment exhausts budget (default 2 attempts)
if ! ledger_increment_attempt "60"; then
  pass "ledger_increment_attempt returns false when budget exhausted"
else
  fail "Should not allow increment beyond retry budget"
fi

entry=$(ledger_load_entry "60")
status=$(echo "$entry" | jq -r '.status')
if [[ "$status" == "failed" ]]; then
  pass "Status transitions to 'failed' when budget exhausted"
else
  fail "Expected status=failed, got: $status"
fi

# ===========================================================================
# Group 3 — Terminal failure marking
# ===========================================================================
echo ""
echo "=== Group 3: Terminal failure marking ==="

# Test 9: Explicit terminal failure
ledger_record_recoverable "70" "400" "slice-70-api" "1" "$next_retry" "spec contradiction"
ledger_mark_terminal_failed "70" "blocker: spec contradiction in #172"

entry=$(ledger_load_entry "70")
status=$(echo "$entry" | jq -r '.status')
reason=$(echo "$entry" | jq -r '.failureReason')

if [[ "$status" == "failed" ]]; then
  pass "ledger_mark_terminal_failed sets status=failed"
else
  fail "Expected status=failed, got: $status"
fi

if echo "$reason" | grep -q "blocker"; then
  pass "Failure reason recorded"
else
  fail "Expected failure reason with 'blocker', got: $reason"
fi

# ===========================================================================
# Group 4 — Lease expiry (stale worker cleanup)
# ===========================================================================
echo ""
echo "=== Group 4: Lease expiry ==="

# Test 10: Stale lease can be reclaimed
past_lease=$(date -u -d '-35 minutes' +%FT%TZ 2>/dev/null || date -u -v-35M +%FT%TZ)
ledger_record_recoverable "80" "500" "slice-80-ui" "0" "$past_retry" "test stale lease"
# Manually inject stale lease
jq --arg issue "80" --arg leased_at "$past_lease" '
  .[$issue].leasedBy = "worker-stale"
  | .[$issue].leasePid = "99999"
  | .[$issue].leasedAt = $leased_at
' "$ledger_file" > "$ledger_file.tmp"
mv "$ledger_file.tmp" "$ledger_file"

if ledger_try_claim_recovery "80" "worker-fresh" "88888"; then
  pass "Stale lease (>30 min) can be reclaimed"
else
  fail "Should reclaim stale lease for issue 80"
fi

entry=$(ledger_load_entry "80")
leased_by=$(echo "$entry" | jq -r '.leasedBy')
if [[ "$leased_by" == "worker-fresh" ]]; then
  pass "Fresh worker now holds the lease"
else
  fail "Expected leasedBy=worker-fresh, got: $leased_by"
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
