#!/usr/bin/env bash
# Tests for PRD integration branch ownership and lifecycle (Slice #201 / Issue #201).
#
# Covers:
#   1. Default branch name resolution: ralph/prd/{feature-slug}-{prd_number}
#   2. Branch name frozen at run creation (PRD title changes don't rename)
#   3. Branch created from latest remote delivery branch
#   4. Atomic recording of run identity, PRD identity, branch ownership, remote, delivery branch, initial base SHA
#   5. Matching owned branch can be resumed safely
#   6. Conflicting/unprovable ownership causes safe refusal without reset/overwrite/deletion/adoption
#   7. One-active-PRD-per-repository guard remains enforced
#   8. Run-scoped ownership records support future concurrency
#   9. Stale local main detection
#   10. Atomic setup failure handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0
fail_count=0
fail() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }

# Source the library under test
LOG_DIR="$TEST_ROOT/.ralph/logs"
mkdir -p "$LOG_DIR"
# shellcheck source=../ralph/lib/state.sh
. "$REPO_ROOT/ralph/lib/state.sh"
# shellcheck source=../ralph/lib/prd-branch.sh
. "$REPO_ROOT/ralph/lib/prd-branch.sh"

# ===========================================================================
# Group 1 — Branch name resolution
# ===========================================================================
echo "=== Group 1: Branch name resolution ==="

# Test 1: Default branch name template
result=$(resolve_prd_branch_name "200" "Owned PRD integration branches" "")
expected="ralph/prd/owned-prd-integration-branches-200"
if [[ "$result" == "$expected" ]]; then
  pass "Default branch name: $result"
else
  fail "Expected '$expected', got '$result'"
fi

# Test 2: Custom template
result=$(resolve_prd_branch_name "200" "Test Feature" "feature/{feature-slug}")
expected="feature/test-feature"
if [[ "$result" == "$expected" ]]; then
  pass "Custom template: $result"
else
  fail "Expected '$expected', got '$result'"
fi

# Test 3: Template with PRD number
result=$(resolve_prd_branch_name "200" "My Feature" "prd-{prd_number}/{feature-slug}")
expected="prd-200/my-feature"
if [[ "$result" == "$expected" ]]; then
  pass "Template with PRD number: $result"
else
  fail "Expected '$expected', got '$result'"
fi

# ===========================================================================
# Group 2 — Ownership record creation and verification
# ===========================================================================
echo "=== Group 2: Ownership record creation and verification ==="

# Set up a temporary git repository for integration tests
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

# Test 4: Create ownership record
run_id="run-$(date +%s)"
prd_number="200"
branch_name="ralph/prd/test-feature-200"
remote="origin"
delivery_branch="main"
base_sha=$(git rev-parse HEAD)

if create_prd_ownership_record "$run_id" "$prd_number" "$branch_name" "$remote" "$delivery_branch" "$base_sha"; then
  # Verify the record was created
  if [[ -f ".ralph/runs/$run_id/ownership.json" ]]; then
    stored_branch=$(jq -r '.branch_name' ".ralph/runs/$run_id/ownership.json")
    stored_prd=$(jq -r '.prd_number' ".ralph/runs/$run_id/ownership.json")
    stored_remote=$(jq -r '.remote' ".ralph/runs/$run_id/ownership.json")
    stored_delivery=$(jq -r '.delivery_branch' ".ralph/runs/$run_id/ownership.json")
    stored_base=$(jq -r '.initial_base_sha' ".ralph/runs/$run_id/ownership.json")
    
    if [[ "$stored_branch" == "$branch_name" && "$stored_prd" == "$prd_number" && \
          "$stored_remote" == "$remote" && "$stored_delivery" == "$delivery_branch" && \
          "$stored_base" == "$base_sha" ]]; then
      pass "Ownership record created with correct fields"
    else
      fail "Ownership record has incorrect fields"
    fi
  else
    fail "Ownership record file not created"
  fi
else
  fail "create_prd_ownership_record failed"
fi

# Test 5: Verify ownership for matching run
if verify_prd_ownership "$run_id" "$branch_name"; then
  pass "Ownership verified for matching run"
else
  fail "Ownership verification failed for matching run"
fi

# Test 6: Reject ownership for different branch
if ! verify_prd_ownership "$run_id" "ralph/prd/different-branch-200"; then
  pass "Ownership rejected for non-matching branch"
else
  fail "Ownership should be rejected for different branch"
fi

# Test 7: Reject ownership for non-existent run
if ! verify_prd_ownership "run-nonexistent" "$branch_name"; then
  pass "Ownership rejected for non-existent run"
else
  fail "Ownership should be rejected for non-existent run"
fi

# Test 7b: Ownership records remain valid JSON for configuration values
escaped_run_id="run-escaped"
if create_prd_ownership_record \
  "$escaped_run_id" "204" "ralph/prd/escaped-204" 'origin"quoted' "main" "$base_sha" \
  && jq -e '.remote == "origin\"quoted"' ".ralph/runs/$escaped_run_id/ownership.json" >/dev/null; then
  pass "Ownership record safely encodes configuration values"
else
  fail "Ownership record should remain valid JSON for quoted values"
fi

# ===========================================================================
# Group 3 — Branch creation from remote
# ===========================================================================
echo "=== Group 3: Branch creation from remote ==="

# Set up a bare "remote" repository
REMOTE_REPO="$TEST_ROOT/remote.git"
git init -q --bare "$REMOTE_REPO"
cd "$TEMP_REPO"
git remote add origin "$REMOTE_REPO"
git push -qu origin main

# Add a commit to remote main
echo "Remote change" >> README.md
git add README.md
git commit -qm "Remote commit"
git push -q origin main

# Reset local main to previous commit (simulate stale local)
git reset --hard HEAD~1 >/dev/null

# Test 8: Create PRD branch from latest remote main
new_run_id="run-$(date +%s)-2"
new_branch="ralph/prd/another-feature-201"

remote_sha=$(git ls-remote origin main | awk '{print $1}')
if create_prd_branch "$new_run_id" "201" "Another Feature" "origin" "main" ""; then
  # Verify branch was created
  if git rev-parse --verify "$new_branch" >/dev/null 2>&1; then
    branch_sha=$(git rev-parse "$new_branch")
    if [[ "$branch_sha" == "$remote_sha" ]]; then
      pass "PRD branch created from latest remote main"
    else
      fail "PRD branch not at remote main SHA (expected $remote_sha, got $branch_sha)"
    fi
  else
    fail "PRD branch not created"
  fi
else
  fail "create_prd_branch failed"
fi

# Test 8b: Resume an owned remote branch at its existing head, not newer main
git push -q origin "$new_branch"
owned_remote_sha=$(git rev-parse "$new_branch")
recorded_base_sha=$(jq -r '.initial_base_sha' ".ralph/runs/$new_run_id/ownership.json")
git branch -D "$new_branch" >/dev/null
git checkout -q main
git reset --hard origin/main >/dev/null
echo "Newer delivery change" >> README.md
git add README.md
git commit -qm "Advance delivery branch"
git push -q origin main

if create_prd_branch "$new_run_id" "201" "Renamed Feature" "origin" "main" ""; then
  resumed_sha=$(git rev-parse "$new_branch")
  resumed_base_sha=$(jq -r '.initial_base_sha' ".ralph/runs/$new_run_id/ownership.json")
  if [[ "$resumed_sha" == "$owned_remote_sha" && "$resumed_base_sha" == "$recorded_base_sha" ]]; then
    pass "Owned remote branch resumes at its frozen head and base"
  else
    fail "Owned remote resume changed branch head or initial base"
  fi
else
  fail "Owned remote branch should resume safely"
fi

# Test 9: Refuse to create branch that already exists without ownership
git checkout -qb "ralph/prd/conflicting-202"
git checkout -q main

conflict_run_id="run-$(date +%s)-3"
if ! create_prd_branch "$conflict_run_id" "202" "Conflicting" "origin" "main" "" 2>/dev/null; then
  pass "Refused to adopt existing branch without ownership"
else
  fail "Should refuse to adopt existing branch"
fi

# Test 9b: Branch name is frozen after first creation
frozen_run_id="run-$(date +%s)-4"
frozen_branch="ralph/prd/frozen-title-203"
if create_prd_branch "$frozen_run_id" "203" "Frozen Title" "origin" "main" ""; then
  # Call again with different title but same run ID
  if create_prd_branch "$frozen_run_id" "203" "Changed Title After Creation" "origin" "main" ""; then
    # Verify the branch name did not change
    stored_branch=$(jq -r '.branch_name' ".ralph/runs/$frozen_run_id/ownership.json")
    if [[ "$stored_branch" == "$frozen_branch" ]]; then
      pass "Branch name frozen at run creation (title changes ignored)"
    else
      fail "Branch name changed from '$frozen_branch' to '$stored_branch' on resumption"
    fi
  else
    fail "Resumption with changed title should succeed with frozen name"
  fi
else
  fail "Initial PRD branch creation failed"
fi

# Test 9c: Invalid resolved names fail without leaving ownership evidence
invalid_run_id="run-invalid-branch"
if ! create_prd_branch \
  "$invalid_run_id" "205" "Invalid Branch" "origin" "main" "bad..{prd_number}" 2>/dev/null \
  && [[ ! -e ".ralph/runs/$invalid_run_id/ownership.json" ]]; then
  pass "Invalid branch setup fails without partial ownership evidence"
else
  fail "Invalid branch setup should not leave ownership evidence"
fi

# ===========================================================================
# Group 4 — Resumption safety
# ===========================================================================
echo "=== Group 4: Resumption safety ==="

# Test 10: Resume with matching ownership succeeds
if can_resume_prd_branch "$new_run_id" "$new_branch"; then
  pass "Can resume owned branch"
else
  fail "Should allow resuming owned branch"
fi

# Test 11: Resume with different ownership fails
different_run_id="run-different"
if ! can_resume_prd_branch "$different_run_id" "$new_branch"; then
  pass "Cannot resume branch owned by different run"
else
  fail "Should not allow resuming branch owned by different run"
fi

# ===========================================================================
# Group 5 — One-active-PRD guard
# ===========================================================================
echo "=== Group 5: One-active-PRD guard ==="

# Test 12: Cannot start second PRD when one is active
echo '{"active_prd": "200", "active_run_id": "run-existing"}' > "$STATE_FILE"

if ! can_start_prd "201"; then
  pass "Blocked starting PRD when another is active"
else
  fail "Should block starting PRD when another is active"
fi

# Test 13: Can start PRD when none is active
echo '{}' > "$STATE_FILE"

if can_start_prd "201"; then
  pass "Allowed starting PRD when none is active"
else
  fail "Should allow starting PRD when none is active"
fi

# Test 14: The same durable run can resume its active PRD
echo '{"active_prd": "201", "active_run_id": "run-resume"}' > "$STATE_FILE"
if can_start_prd "201" "run-resume"; then
  pass "Allowed resuming the same active PRD run"
else
  fail "Should allow resuming the same active PRD run"
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
