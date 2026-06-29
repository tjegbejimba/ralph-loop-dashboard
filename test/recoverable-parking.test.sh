#!/usr/bin/env bash
# Integration test for recoverable work parking — worker exits with PR/branch
# evidence, issue is parked as recoverable with lease, not immediately claimed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

pass() {
  echo "PASS: $*"
}

# Setup test repo
mkdir -p "$TEST_ROOT/main" "$TEST_ROOT/origin.git"
git init -q --bare "$TEST_ROOT/origin.git"
git init -q "$TEST_ROOT/main"
cd "$TEST_ROOT/main"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
git remote add origin "$TEST_ROOT/origin.git"
git push -q -u origin main
printf '%s\n' ".ralph" >> .git/info/exclude

# Install Ralph libraries
mkdir -p .ralph/lib .ralph/runs/test-run .ralph/lock
cp "$REPO_ROOT/ralph/ralph.sh" .ralph/ralph.sh
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
cp "$REPO_ROOT/ralph/lib/recovery-ledger.sh" .ralph/lib/recovery-ledger.sh
chmod +x .ralph/ralph.sh

# Initialize state
LOG_DIR="$TEST_ROOT/main/.ralph/logs"
RUN_ID="test-run"
export LOG_DIR RUN_ID
mkdir -p "$LOG_DIR"

. .ralph/lib/state.sh
. .ralph/lib/status.sh
. .ralph/lib/recovery-ledger.sh

state_init
status_init

# Test scenario: issue 42 has a pushed branch with an open PR, worker exited
# before merge. Should be parked as recoverable with a lease.

pass "Setup complete"

# Simulate worker recording recoverable state after exit
next_retry=$(date -u -v+5M +%FT%TZ 2>/dev/null || date -u -d '+5 minutes' +%FT%TZ)
ledger_record_recoverable "42" "123" "slice-42-foo" "1" "$next_retry" "worker exit before merge"

if [[ ! -f .ralph/recovery-ledger.json ]]; then
  fail "recovery ledger should exist"
fi
pass "Recovery ledger created"

# Check ledger entry
entry=$(ledger_load_entry "42")
if ! echo "$entry" | jq -e '.pr == "123"' >/dev/null; then
  fail "ledger entry should have PR=123"
fi
pass "Ledger entry has correct PR"

# Check recoverable flag
if ! ledger_is_recoverable "42"; then
  fail "issue 42 should be marked recoverable"
fi
pass "Issue marked recoverable"

# Check lease not due yet
if ledger_is_recovery_due "42"; then
  fail "recovery lease should not be due yet"
fi
pass "Recovery lease not expired yet"

# Mark status as recoverable
status_mark_recoverable "42" "open PR #123 exists but worker exited"

# Verify status is not terminal
if status_is_terminal "42"; then
  fail "recoverable status should not be terminal"
fi
pass "Recoverable status is not terminal"

# Verify status contains recoverable state
status=$(status_load_item "42" "status")
if [[ "$status" != "recoverable" ]]; then
  fail "status should be 'recoverable', got: $status"
fi
pass "Status correctly marked recoverable"

echo ""
echo "========================================="
echo "All recoverable parking tests passed!"
echo "========================================="
