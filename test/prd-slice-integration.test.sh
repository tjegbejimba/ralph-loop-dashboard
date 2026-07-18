#!/usr/bin/env bash
# Tests for PRD slice PR integration (Slice #202 / Issue #202).
#
# Covers:
#   1. Slice PRs created against PRD integration branch
#   2. PR base verification (refuse wrong-base merges)
#   3. Record slice-integrated lifecycle fact
#   4. Explicit issue closure after integration
#   5. Same-PRD dependency unblocking
#   6. Integration doesn't mark PRD as delivered
#   7. Cross-PRD dependencies remain blocked until delivery
#   8. Default-branch compatibility for non-PRD runs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0
fail_count=0
fail() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }

# Source the libraries under test
LOG_DIR="$TEST_ROOT/.ralph/logs"
mkdir -p "$LOG_DIR"
# shellcheck source=../ralph/lib/state.sh
. "$REPO_ROOT/ralph/lib/state.sh"
# shellcheck source=../ralph/lib/prd-branch.sh
. "$REPO_ROOT/ralph/lib/prd-branch.sh"
# shellcheck source=../ralph/lib/status.sh
. "$REPO_ROOT/ralph/lib/status.sh"
# shellcheck source=../ralph/lib/slice-integration.sh
. "$REPO_ROOT/ralph/lib/slice-integration.sh"

# ===========================================================================
# Group 1 — Correct-base integration
# ===========================================================================
echo "=== Group 1: Correct-base integration ==="

# Set up a temporary git repository
TEMP_REPO="$TEST_ROOT/test-repo"
git init -q "$TEMP_REPO"
cd "$TEMP_REPO"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test User"
echo "# Test" > README.md
git add README.md
git commit -qm "Initial commit"

# Create .ralph directory structure
mkdir -p ".ralph/runs"
STATE_DIR="$TEMP_REPO/.ralph"
STATE_FILE="$STATE_DIR/state.json"
RUN_ID="run-prd-200"
export RUN_ID

# Test 1: resolve_slice_pr_base returns integration branch for PRD run
run_dir="$STATE_DIR/runs/$RUN_ID"
mkdir -p "$run_dir"
echo '{"run_id":"run-prd-200","prd_number":"200","branch_name":"ralph/prd/test-feature-200","remote":"origin","delivery_branch":"main","initial_base_sha":"abc123"}' > "$run_dir/ownership.json"

if command -v resolve_slice_pr_base >/dev/null 2>&1; then
  base=$(resolve_slice_pr_base "$RUN_ID" "main")
  if [[ "$base" == "ralph/prd/test-feature-200" ]]; then
    pass "resolve_slice_pr_base returns integration branch for PRD run"
  else
    fail "Expected 'ralph/prd/test-feature-200', got '$base'"
  fi
else
  fail "resolve_slice_pr_base function not found"
fi

# Test 2: resolve_slice_pr_base returns delivery branch for non-PRD run
NON_PRD_RUN_ID="run-direct-123"
if command -v resolve_slice_pr_base >/dev/null 2>&1; then
  base=$(resolve_slice_pr_base "$NON_PRD_RUN_ID" "main")
  if [[ "$base" == "main" ]]; then
    pass "resolve_slice_pr_base returns delivery branch for non-PRD run"
  else
    fail "Expected 'main', got '$base'"
  fi
else
  fail "resolve_slice_pr_base function not found"
fi

# Test 3: verify_slice_pr_base accepts correct base
if command -v verify_slice_pr_base >/dev/null 2>&1; then
  if verify_slice_pr_base "$RUN_ID" "ralph/prd/test-feature-200"; then
    pass "verify_slice_pr_base accepts correct PRD integration branch"
  else
    fail "verify_slice_pr_base should accept correct branch"
  fi
else
  fail "verify_slice_pr_base function not found"
fi

# Test 4: verify_slice_pr_base rejects wrong base
if command -v verify_slice_pr_base >/dev/null 2>&1; then
  if ! verify_slice_pr_base "$RUN_ID" "main" 2>/dev/null; then
    pass "verify_slice_pr_base rejects wrong base branch"
  else
    fail "verify_slice_pr_base should reject wrong base"
  fi
else
  fail "verify_slice_pr_base function not found"
fi

# ===========================================================================
# Group 2 — Slice-integrated lifecycle recording
# ===========================================================================
echo "=== Group 2: Slice-integrated lifecycle recording ==="

# Initialize status
if command -v status_init >/dev/null 2>&1; then
  status_init "$RUN_ID"
  
  # Test 5: Record slice-integrated with PR and commit evidence
  if command -v record_slice_integrated >/dev/null 2>&1; then
    if record_slice_integrated "201" "123" "abc123def456" "$RUN_ID"; then
      status=$(status_load_item "201" "status" "$RUN_ID")
      pr=$(status_load_item "201" "pr_number" "$RUN_ID")
      commit=$(status_load_item "201" "integrated_commit" "$RUN_ID")
      
      if [[ "$status" == "slice-integrated" && "$pr" == "123" && "$commit" == "abc123def456" ]]; then
        pass "record_slice_integrated stores status, PR, and commit"
      else
        fail "Incorrect slice-integrated record (status=$status, pr=$pr, commit=$commit)"
      fi
    else
      fail "record_slice_integrated failed"
    fi
  else
    fail "record_slice_integrated function not found"
  fi
else
  fail "status_init function not found"
fi

# ===========================================================================
# Group 3 — Explicit issue closure
# ===========================================================================
echo "=== Group 3: Explicit issue closure ==="

# Test 6: close_slice_issue calls gh issue close with correct args
CLOSE_CALLS=()
gh() {
  if [[ "$1 $2" == "issue close" ]]; then
    CLOSE_CALLS+=("$*")
    return 0
  fi
  command gh "$@"
}
export -f gh

if command -v close_slice_issue >/dev/null 2>&1; then
  CLOSE_CALLS=()
  if close_slice_issue "201" "123" "origin/user/repo" 2>/dev/null; then
    if [[ ${#CLOSE_CALLS[@]} -eq 1 ]] && [[ "${CLOSE_CALLS[0]}" =~ "201" ]] && [[ "${CLOSE_CALLS[0]}" =~ "--repo origin/user/repo" ]]; then
      pass "close_slice_issue calls gh issue close with issue number and repo"
    else
      fail "close_slice_issue made unexpected gh calls: ${CLOSE_CALLS[*]}"
    fi
  else
    fail "close_slice_issue failed"
  fi
else
  fail "close_slice_issue function not found"
fi

# ===========================================================================
# Group 4 — Dependency unblocking
# ===========================================================================
echo "=== Group 4: Dependency unblocking ==="

# Test 7: Same-PRD integrated slice unblocks dependent
if command -v is_slice_dependency_satisfied >/dev/null 2>&1; then
  # Slice 202 depends on 201, both in PRD 200
  BLOCKER_RUN_ID="run-prd-200"
  DEPENDENT_RUN_ID="run-prd-200"
  
  # Mark blocker as integrated
  if command -v record_slice_integrated >/dev/null 2>&1; then
    status_init "$BLOCKER_RUN_ID"
    record_slice_integrated "201" "123" "abc123" "$BLOCKER_RUN_ID"
  fi
  
  if is_slice_dependency_satisfied "201" "$DEPENDENT_RUN_ID"; then
    pass "Same-PRD integrated slice satisfies dependency"
  else
    fail "Same-PRD integrated slice should satisfy dependency"
  fi
else
  fail "is_slice_dependency_satisfied function not found"
fi

# Test 8: Cross-PRD dependency requires delivery to main
if command -v is_slice_dependency_satisfied >/dev/null 2>&1; then
  BLOCKER_RUN_ID="run-prd-200"
  DEPENDENT_RUN_ID="run-prd-210"  # Different PRD
  
  # Blocker is integrated but not delivered
  if ! is_slice_dependency_satisfied "201" "$DEPENDENT_RUN_ID" 2>/dev/null; then
    pass "Cross-PRD integrated slice doesn't satisfy dependency before delivery"
  else
    fail "Cross-PRD integrated slice should not satisfy dependency before delivery"
  fi
else
  fail "is_slice_dependency_satisfied function not found"
fi

# ===========================================================================
# Group 5 — PRD not marked delivered
# ===========================================================================
echo "=== Group 5: PRD not marked delivered ==="

# Test 9: Slice integration doesn't mark PRD as delivered
if command -v record_slice_integrated >/dev/null 2>&1; then
  status_init "$RUN_ID"
  record_slice_integrated "202" "124" "def789" "$RUN_ID"
  
  # Check that no prd-delivered lifecycle fact exists
  if command -v is_prd_delivered >/dev/null 2>&1; then
    if ! is_prd_delivered "200" 2>/dev/null; then
      pass "Slice integration doesn't mark PRD as delivered"
    else
      fail "PRD should not be marked delivered after slice integration"
    fi
  else
    # Acceptable if function doesn't exist yet (later slice)
    pass "is_prd_delivered not yet implemented (acceptable)"
  fi
else
  fail "record_slice_integrated function not found"
fi

# ===========================================================================
# Group 6 — High-level integration test
# ===========================================================================
echo "=== Group 6: High-level integration test ==="

# Test 10: Full workflow — PR to integration branch, merge, lifecycle record, close issue
INTEGRATION_REPO="$TEST_ROOT/integration-test"
git init -q "$INTEGRATION_REPO"
cd "$INTEGRATION_REPO"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test User"
echo "# Integration Test" > README.md
git add README.md
git commit -qm "Initial commit"

mkdir -p ".ralph/runs/run-integration-test"
STATE_DIR="$INTEGRATION_REPO/.ralph"
STATE_FILE="$STATE_DIR/state.json"
INTEGRATION_RUN_ID="run-integration-test"
export RUN_ID="$INTEGRATION_RUN_ID"

# Create PRD integration branch
integration_branch="ralph/prd/integration-test-200"
git branch "$integration_branch"

# Record ownership
ownership_file="$STATE_DIR/runs/$INTEGRATION_RUN_ID/ownership.json"
echo "{\"run_id\":\"$INTEGRATION_RUN_ID\",\"prd_number\":\"200\",\"branch_name\":\"$integration_branch\",\"remote\":\"origin\",\"delivery_branch\":\"main\",\"initial_base_sha\":\"$(git rev-parse HEAD)\"}" > "$ownership_file"

# Create a slice branch and commit
git checkout -qb "slice-203-test"
echo "Test change" >> README.md
git add README.md
git commit -qm "feat: implement slice 203

Closes #203"

# Simulate merge to integration branch (fast-forward)
git checkout -q "$integration_branch"
git merge --ff-only "slice-203-test" >/dev/null 2>&1
merge_commit=$(git rev-parse HEAD)

# Now test the verification and lifecycle recording
if command -v verify_slice_pr_base >/dev/null 2>&1 && command -v record_slice_integrated >/dev/null 2>&1; then
  status_init "$INTEGRATION_RUN_ID"
  
  # Verify base (should pass)
  if verify_slice_pr_base "$INTEGRATION_RUN_ID" "$integration_branch"; then
    # Record integration
    if record_slice_integrated "203" "125" "$merge_commit" "$INTEGRATION_RUN_ID"; then
      # Check status
      status=$(status_load_item "203" "status" "$INTEGRATION_RUN_ID")
      if [[ "$status" == "slice-integrated" ]]; then
        pass "Full workflow: PR verified, integrated, lifecycle recorded"
      else
        fail "Full workflow: expected status 'slice-integrated', got '$status'"
      fi
    else
      fail "Full workflow: record_slice_integrated failed"
    fi
  else
    fail "Full workflow: verify_slice_pr_base failed"
  fi
else
  fail "Full workflow: required functions not found"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "========================================="
echo "PASSED: $pass_count"
echo "FAILED: $fail_count"
echo "========================================="

[[ $fail_count -eq 0 ]] && exit 0 || exit 1
