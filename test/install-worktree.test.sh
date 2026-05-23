#!/usr/bin/env bash
# Integration test: install.sh accepts a git worktree as a target.
#
# Worktrees have a `.git` *file* (gitlink) instead of a directory. The
# installer used to reject these outright at the `[[ -d $TARGET/.git ]]`
# check. This test verifies:
#   1. install.sh --scripts-only succeeds against a linked worktree.
#   2. `.ralph/` is installed inside the worktree.
#   3. The `.ralph` entry is appended to the *common* gitdir's
#      info/exclude (resolved via `git rev-parse --git-path info/exclude`),
#      not a non-existent `<worktree>/.git/info/exclude` path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MAIN="$TEST_ROOT/main"
WT="$TEST_ROOT/wt-feature"

git init -q "$MAIN"
cd "$MAIN"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"

git -C "$MAIN" worktree add -q -b feature "$WT" main

if [[ -d "$WT/.git" ]]; then
  echo "FAIL: precondition — worktree's .git should be a file (gitlink), got directory"
  exit 1
fi

"$REPO_ROOT/install.sh" "$WT" --scripts-only --profile generic >/dev/null

if [[ ! -d "$WT/.ralph" ]]; then
  echo "FAIL: install.sh should create .ralph/ inside the worktree"
  exit 1
fi

if [[ ! -x "$WT/.ralph/launch.sh" || ! -x "$WT/.ralph/ralph.sh" ]]; then
  echo "FAIL: install.sh should install executable launch.sh and ralph.sh into the worktree"
  exit 1
fi

EXCLUDE_FILE="$(git -C "$WT" rev-parse --git-path info/exclude)"
if [[ ! -f "$EXCLUDE_FILE" ]]; then
  echo "FAIL: expected info/exclude to exist at $EXCLUDE_FILE"
  exit 1
fi

if ! grep -qxF ".ralph" "$EXCLUDE_FILE"; then
  echo "FAIL: install.sh should add .ralph to the common gitdir info/exclude ($EXCLUDE_FILE)"
  cat "$EXCLUDE_FILE"
  exit 1
fi

echo "PASS: install.sh accepts a worktree target and writes exclude via git rev-parse"
