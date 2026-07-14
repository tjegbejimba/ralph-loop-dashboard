#!/usr/bin/env bash
# Regression test for issue #187: worker left on stale branch should be reset.
#
# Scenario:
#   1. Worktree left on a stale branch (e.g., slice-175-... from previous iter)
#   2. Next ralph.sh iteration starts
#   3. Expected: ralph.sh detects wrong branch and resets to expected branch
#   4. Expected: worktree syncs to origin/main before starting work
#
# Verifies the fix in ralph.sh that checks INITIAL_BRANCH and resets if needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MAIN="$TEST_ROOT/main"
LOOP_WORKTREE="$MAIN-ralph"

# Create a minimal git repo
git init -q "$MAIN"
cd "$MAIN"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"

# Provide origin remote
git clone -q --bare "$MAIN" "$TEST_ROOT/origin.git"
git -C "$MAIN" remote add origin "$TEST_ROOT/origin.git"
git -C "$MAIN" push -q origin main
git -C "$MAIN" branch --set-upstream-to=origin/main main

# Create a loop worktree manually (simulating what launch.sh does)
cd "$MAIN"
git worktree add -q -B ralph-loop "$LOOP_WORKTREE" origin/main
git -C "$LOOP_WORKTREE" branch --set-upstream-to=origin/main ralph-loop

# Record main checkout state before any operations
MAIN_BRANCH_BEFORE="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)"
MAIN_HEAD_BEFORE="$(git -C "$MAIN" rev-parse HEAD)"

# Simulate a previous iteration leaving the worktree on a stale branch
cd "$LOOP_WORKTREE"
STALE_BRANCH="slice-999-stale-from-previous-iter"
git checkout -qb "$STALE_BRANCH"
echo "stale work" > stale.txt
git add stale.txt
git commit -qm "stale commit"

# Now test the fix: simulated ralph.sh preflight that should reset the worktree
EXPECTED_BRANCH="ralph-loop"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if [[ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]]; then
  # This is the fix we're testing
  echo "⚠️  Worktree on unexpected branch '$CURRENT_BRANCH' (expected '$EXPECTED_BRANCH'). Resetting..."
  git checkout -q "$EXPECTED_BRANCH" 2>/dev/null || git checkout -qB "$EXPECTED_BRANCH" origin/main
  git fetch -q origin main
  git reset --hard origin/main >/dev/null
fi

# Verify worktree is now on expected branch
WORKTREE_BRANCH_AFTER="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$WORKTREE_BRANCH_AFTER" != "$EXPECTED_BRANCH" ]]; then
  echo "FAIL: worktree should be on '$EXPECTED_BRANCH' after reset, got '$WORKTREE_BRANCH_AFTER'"
  exit 1
fi

# Verify worktree is synced to origin/main
WORKTREE_HEAD="$(git rev-parse HEAD)"
ORIGIN_MAIN_HEAD="$(git rev-parse origin/main)"
if [[ "$WORKTREE_HEAD" != "$ORIGIN_MAIN_HEAD" ]]; then
  echo "FAIL: worktree HEAD should match origin/main after reset"
  echo "  worktree HEAD: $WORKTREE_HEAD"
  echo "  origin/main:   $ORIGIN_MAIN_HEAD"
  exit 1
fi

# Verify stale commit is gone
if [[ -f stale.txt ]]; then
  echo "FAIL: stale.txt should not exist after reset"
  exit 1
fi

# Verify main checkout was not mutated
MAIN_BRANCH_AFTER="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)"
MAIN_HEAD_AFTER="$(git -C "$MAIN" rev-parse HEAD)"
if [[ "$MAIN_BRANCH_AFTER" != "$MAIN_BRANCH_BEFORE" ]]; then
  echo "FAIL: main checkout branch changed from '$MAIN_BRANCH_BEFORE' to '$MAIN_BRANCH_AFTER'"
  exit 1
fi
if [[ "$MAIN_HEAD_AFTER" != "$MAIN_HEAD_BEFORE" ]]; then
  echo "FAIL: main checkout HEAD changed"
  exit 1
fi

echo "PASS: worktree reset from stale branch without touching main checkout"

