#!/usr/bin/env bash
# Integration test for launch.sh --cleanup worktree handling.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MAIN_REPO="$TEST_ROOT/main"
LOOP_REPO="$TEST_ROOT/main-ralph"

git init -q "$MAIN_REPO"
cd "$MAIN_REPO"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"

mkdir -p .ralph/lib .ralph/logs .ralph/lock
cp "$REPO_ROOT/ralph/launch.sh" .ralph/launch.sh
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cat > .ralph/ralph.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x .ralph/launch.sh .ralph/ralph.sh

git worktree add -q -B ralph-loop-1 "$LOOP_REPO-1" main
git worktree add -q -B ralph-loop-2 "$LOOP_REPO-2" main
mkdir -p .ralph/lock/worker-1 .ralph/lock/worker-2
echo "999999" > .ralph/lock/worker-1/owner
echo "999999" > .ralph/lock/worker-2/owner
echo "local edit" >> "$LOOP_REPO-2/README.md"

set +e
output=$(
  RALPH_MAIN_REPO="$MAIN_REPO" \
    RALPH_LOOP_REPO="$LOOP_REPO" \
    RALPH_PARALLELISM=2 \
    "$MAIN_REPO/.ralph/launch.sh" --cleanup 2>&1
)
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "FAIL: cleanup should exit non-zero when a dirty worktree is skipped"
  echo "$output"
  exit 1
fi

if [[ -d "$LOOP_REPO-1" ]]; then
  echo "FAIL: cleanup should remove clean worker worktree"
  echo "$output"
  exit 1
fi

if [[ ! -d "$LOOP_REPO-2" ]]; then
  echo "FAIL: cleanup should preserve dirty worker worktree"
  echo "$output"
  exit 1
fi

if [[ -d "$MAIN_REPO/.ralph/lock/worker-1" ]]; then
  echo "FAIL: cleanup should remove the lock for a removed worker"
  echo "$output"
  exit 1
fi

if [[ ! -d "$MAIN_REPO/.ralph/lock/worker-2" ]]; then
  echo "FAIL: cleanup should preserve the lock for a skipped worker"
  echo "$output"
  exit 1
fi

if ! grep -q "removed=1 skipped=1" <<<"$output"; then
  echo "FAIL: cleanup should report removed=1 skipped=1"
  echo "$output"
  exit 1
fi

echo "PASS: launch.sh --cleanup removes clean worktrees and preserves dirty ones"
