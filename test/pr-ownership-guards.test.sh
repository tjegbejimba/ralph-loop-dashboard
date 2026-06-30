#!/usr/bin/env bash
# Tests for PR ownership guards (Slice 3 / Issue #176).
#
# Covers:
#   1. Recovery entry requires Ralph workflow intent (labels) + PR/branch ownership proof
#   2. Draft PRs are recoverable only when Ralph-owned and no human evidence exists
#   3. Human review comments/changes pause recovery → ralph:hitl
#   4. Approved-but-red PRs may receive CI repair commits
#   5. Approved-green PRs may use merge fallback through normal paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0
fail_count=0
fail() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }

# Source the libraries
LOG_DIR="$TEST_ROOT/.ralph/logs"
mkdir -p "$LOG_DIR"
# shellcheck source=../ralph/lib/state.sh
. "$REPO_ROOT/ralph/lib/state.sh"
# shellcheck source=../ralph/lib/resume.sh
. "$REPO_ROOT/ralph/lib/resume.sh"

# ===========================================================================
# Group 1 — Draft PR recovery guards
# ===========================================================================
echo "=== Group 1: Draft PR recovery guards ==="

# Test helper: create mock PR JSON with specified fields
mock_pr_json() {
  local issue="$1" head_branch="$2" base_branch="$3" repo="$4" is_draft="$5" \
        review_decision="$6" latest_reviews="$7" check_count="$8" non_green_count="$9"
  
  local checks="[]"
  if [[ "$check_count" -gt 0 ]]; then
    # Create check_count checks, with non_green_count failures
    local i failing_checks=()
    for ((i=0; i<non_green_count; i++)); do
      failing_checks+=('{"conclusion":"FAILURE"}')
    done
    for ((i=non_green_count; i<check_count; i++)); do
      failing_checks+=('{"conclusion":"SUCCESS"}')
    done
    checks="[$(IFS=,; echo "${failing_checks[*]}")]"
  fi
  
  local review_decision_value="null"
  [[ "$review_decision" != "null" ]] && review_decision_value="\"$review_decision\""
  
  cat <<EOF
{
  "number": 1,
  "headRefName": "$head_branch",
  "baseRefName": "$base_branch",
  "headRepository": {"nameWithOwner": "$repo"},
  "isDraft": $is_draft,
  "reviewDecision": $review_decision_value,
  "latestReviews": $latest_reviews,
  "closingIssuesReferences": [{"number": $issue}],
  "statusCheckRollup": $checks,
  "body": "Closes #$issue"
}
EOF
}

# Test 1: Draft PR with Ralph ownership proof (no human comments) should allow recovery
# This tests the NEW behavior: draft PRs CAN be recovered if Ralph-owned
echo "Test 1: Draft PR with Ralph ownership, no human comments"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "owner/repo" "true" "null" "[]" 1 1)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -z "$reason" ]]; then
  pass "Draft PR with Ralph ownership allows recovery"
else
  fail "Draft PR with Ralph ownership should allow recovery (got: $reason)"
fi

# Test 2: Draft PR with human comments should block recovery
echo "Test 2: Draft PR with human COMMENTED review"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "owner/repo" "true" "null" '[{"state":"COMMENTED"}]' 1 1)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"review"* ]]; then
  pass "Draft PR with human comments blocks recovery"
else
  fail "Draft PR with human comments should block recovery (got: $reason)"
fi

# Test 3: Draft PR with CHANGES_REQUESTED should block recovery
echo "Test 3: Draft PR with CHANGES_REQUESTED"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "owner/repo" "true" "CHANGES_REQUESTED" '[{"state":"CHANGES_REQUESTED"}]' 1 1)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"review"* ]]; then
  pass "Draft PR with CHANGES_REQUESTED blocks recovery"
else
  fail "Draft PR with CHANGES_REQUESTED should block recovery (got: $reason)"
fi

# ===========================================================================
# Group 2 — Approved PR handling
# ===========================================================================
echo "=== Group 2: Approved PR handling ==="

# Test 4: Approved PR with red checks allows CI repair
echo "Test 4: Approved PR with failing checks (approved-but-red)"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "owner/repo" "false" "APPROVED" '[{"state":"APPROVED"}]' 2 2)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
# For approved-but-red, we want to ALLOW repair, so the function should return empty (no block reason)
# BUT the current implementation blocks on APPROVED. This test will FAIL initially (RED phase)
if [[ -z "$reason" ]]; then
  pass "Approved PR with failing checks allows CI repair"
else
  fail "Approved PR with failing checks should allow CI repair (got: $reason)"
fi

# Test 5: Approved PR with green checks should allow merge fallback
echo "Test 5: Approved PR with passing checks (approved-green)"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "owner/repo" "false" "APPROVED" '[{"state":"APPROVED"}]' 2 0)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
# For approved-green, we need a special signal that this can be merged
# The function should return a specific reason or code that indicates "ready to merge"
# For now, let's check that it doesn't block with the old "has human review decision" error
if [[ -n "$reason" && "$reason" == *"ready to merge"* ]]; then
  pass "Approved PR with passing checks signals merge-ready"
else
  fail "Approved PR with passing checks should signal merge-ready (got: $reason)"
fi

# ===========================================================================
# Group 3 — PR ownership proof
# ===========================================================================
echo "=== Group 3: PR ownership proof ==="

# Test 6: PR with wrong head branch should block
echo "Test 6: PR with wrong head branch"
pr_json=$(mock_pr_json 42 "different-branch" "main" "owner/repo" "false" "null" "[]" 1 1)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"does not match resume branch"* ]]; then
  pass "PR with wrong head branch blocks recovery"
else
  fail "PR with wrong head branch should block recovery (got: $reason)"
fi

# Test 7: PR with wrong base branch should block
echo "Test 7: PR with wrong base branch"
pr_json=$(mock_pr_json 42 "slice-42-test" "develop" "owner/repo" "false" "null" "[]" 1 1)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"does not match expected base"* ]]; then
  pass "PR with wrong base branch blocks recovery"
else
  fail "PR with wrong base branch should block recovery (got: $reason)"
fi

# Test 8: PR with wrong head repository should block
echo "Test 8: PR with wrong head repository"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "fork/repo" "false" "null" "[]" 1 1)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"is not 'owner/repo'"* ]]; then
  pass "PR with wrong head repository blocks recovery"
else
  fail "PR with wrong head repository should block recovery (got: $reason)"
fi

# Test 9: PR not closing the issue should block
echo "Test 9: PR not closing the issue"
pr_json='{"number":1,"headRefName":"slice-42-test","baseRefName":"main","headRepository":{"nameWithOwner":"owner/repo"},"isDraft":false,"reviewDecision":null,"latestReviews":[],"closingIssuesReferences":[],"statusCheckRollup":[{"conclusion":"FAILURE"}],"body":"Some PR without closing reference"}'
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"does not close issue"* ]]; then
  pass "PR not closing issue blocks recovery"
else
  fail "PR not closing issue should block recovery (got: $reason)"
fi

# ===========================================================================
# Group 4 — Check validation
# ===========================================================================
echo "=== Group 4: Check validation ==="

# Test 10: PR with no checks should block
echo "Test 10: PR with no checks"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "owner/repo" "false" "null" "[]" 0 0)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"no failing or pending checks"* ]]; then
  pass "PR with no checks blocks recovery"
else
  fail "PR with no checks should block recovery (got: $reason)"
fi

# Test 11: Non-approved PR with all checks passing should block
echo "Test 11: Non-approved PR with all checks passing"
pr_json=$(mock_pr_json 42 "slice-42-test" "main" "owner/repo" "false" "null" "[]" 2 0)
reason=$(pr_ownership_block_reason "$pr_json" "owner/repo" "main" "42" "slice-42-test" "1" || true)
if [[ -n "$reason" && "$reason" == *"checks are already passing"* ]]; then
  pass "Non-approved PR with passing checks blocks recovery"
else
  fail "Non-approved PR with passing checks should block recovery (got: $reason)"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo "================================="
echo "PASS: $pass_count"
echo "FAIL: $fail_count"
[[ $fail_count -eq 0 ]] && exit 0 || exit 1
