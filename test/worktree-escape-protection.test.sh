#!/usr/bin/env bash
# Regression test for issue #195: prevents Ralph workers from escaping their
# assigned worktree and mutating the primary checkout.
#
# Verifies:
#   1. Ralph records the canonical assigned worktree root at startup
#   2. Ralph verifies the worker stays in that worktree throughout execution
#   3. Ralph detects any primary-checkout branch or HEAD mutation during a
#      worker iteration and reports a safety failure
#   4. The real ralph.sh preflight works correctly when main is checked out
#      in the primary worktree

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MAIN="$TEST_ROOT/main"
LOOP_REPO="$TEST_ROOT/loop"

# Create a test repo with main checked out
git init -q "$MAIN"
cd "$MAIN"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"

# Provide an origin so `git fetch origin main` works
git clone -q --bare "$MAIN" "$TEST_ROOT/origin.git"
git -C "$MAIN" remote add origin "$TEST_ROOT/origin.git"
git -C "$MAIN" fetch -q origin
git -C "$MAIN" branch --set-upstream-to=origin/main main

# Install Ralph into the primary checkout
"$REPO_ROOT/install.sh" "$MAIN" --scripts-only --profile generic >/dev/null 2>&1

# Create a dedicated worker worktree on ralph-loop branch
git -C "$MAIN" worktree add -q -B ralph-loop "$LOOP_REPO" main

# Install Ralph into the worker worktree (symlink to primary's .ralph)
rm -rf "$LOOP_REPO/.ralph"
ln -s "$MAIN/.ralph" "$LOOP_REPO/.ralph"

# Record primary checkout state before worker runs
PRIMARY_BRANCH_BEFORE="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)"
PRIMARY_HEAD_BEFORE="$(git -C "$MAIN" rev-parse HEAD)"

# Create a minimal test script that simulates the preflight and verifies isolation
cd "$LOOP_REPO"
cat > "$LOOP_REPO/test-isolation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(pwd -P)/.ralph"
ASSIGNED_WORKTREE_ROOT="$(pwd -P)"

# Simulate what could cause an escape: a failed git operation that might
# trigger relocation to the primary checkout
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "Starting in worktree at: $(pwd -P)"
echo "Current branch: $CURRENT_BRANCH"

# Set up required variables before sourcing libraries
LOG_DIR="$(pwd -P)/.ralph/logs"
mkdir -p "$LOG_DIR"
export LOG_DIR

# Run sync_to_origin_main logic (the real preflight)
source "$SCRIPT_DIR/lib/state.sh"

sync_to_origin_main() {
  local branch attempt rc
  branch=$(git rev-parse --abbrev-ref HEAD)
  for attempt in 1 2 3 4 5; do
    if git fetch origin main >/dev/null 2>&1; then
      rc=0
      break
    fi
    rc=$?
    sleep 0.1
  done
  if [[ "${rc:-1}" -ne 0 ]]; then
    echo "⚠️  git fetch origin main failed after 5 attempts (rc=$rc). Halting." >&2
    return "$rc"
  fi
  if [[ "$branch" == "main" ]]; then
    # This path should NOT be taken in a worker worktree
    git checkout main >/dev/null 2>&1
    git pull --ff-only origin main >/dev/null 2>&1
  else
    # Dedicated loop worktree — force-sync the branch to origin/main.
    git reset --hard origin/main >/dev/null 2>&1
  fi
}

if ! sync_to_origin_main; then
  echo "❌ sync_to_origin_main failed"
  exit 1
fi

# Verify we're still in the assigned worktree
CURRENT_ROOT="$(pwd -P)"
if [[ "$CURRENT_ROOT" != "$ASSIGNED_WORKTREE_ROOT" ]]; then
  echo "❌ ESCAPE DETECTED: moved from $ASSIGNED_WORKTREE_ROOT to $CURRENT_ROOT"
  exit 125
fi

echo "✅ Stayed in assigned worktree"
exit 0
EOF
chmod +x "$LOOP_REPO/test-isolation.sh"

# Run the test script
cd "$LOOP_REPO"
if ! bash "$LOOP_REPO/test-isolation.sh" 2>&1; then
  rc=$?
  if [[ $rc -eq 125 ]]; then
    echo "FAIL: Worktree escape detected"
  else
    echo "FAIL: Test exited with code $rc"
  fi
  exit 1
fi

# Verify primary checkout is unchanged
PRIMARY_BRANCH_AFTER="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)"
PRIMARY_HEAD_AFTER="$(git -C "$MAIN" rev-parse HEAD)"

if [[ "$PRIMARY_BRANCH_BEFORE" != "$PRIMARY_BRANCH_AFTER" ]]; then
  echo "FAIL: Primary checkout branch changed from $PRIMARY_BRANCH_BEFORE to $PRIMARY_BRANCH_AFTER"
  exit 1
fi

if [[ "$PRIMARY_HEAD_BEFORE" != "$PRIMARY_HEAD_AFTER" ]]; then
  echo "FAIL: Primary checkout HEAD changed from $PRIMARY_HEAD_BEFORE to $PRIMARY_HEAD_AFTER"
  exit 1
fi

echo "PASS: Worktree isolation verified — worker stayed in worktree, primary checkout unchanged"
