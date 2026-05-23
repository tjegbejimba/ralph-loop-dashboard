#!/usr/bin/env bash
# Integration test: two git worktrees of the same repo each run their own
# Ralph loop without colliding on branch names or worktree paths.
#
# Verifies:
#   1. launch.sh resolves the per-loop branch from a stable hash of
#      $MAIN_REPO realpath, so two distinct MAIN_REPO paths produce
#      distinct default branch names.
#   2. Setup phase succeeds in BOTH worktrees: each creates its own
#      sibling loop worktree on its own branch — no `git worktree add`
#      conflict on a shared `ralph-loop` ref.
#   3. .ralph/state.json and .ralph/lock/ stay isolated per worktree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MAIN="$TEST_ROOT/main"
WT_A="$TEST_ROOT/wt-a"
WT_B="$TEST_ROOT/wt-b"

git init -q "$MAIN"
cd "$MAIN"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"
# Provide an origin so `git fetch origin main` works in launch.sh setup.
git clone -q --bare "$MAIN" "$TEST_ROOT/origin.git"
git -C "$MAIN" remote add origin "$TEST_ROOT/origin.git"
git -C "$MAIN" fetch -q origin
git -C "$MAIN" branch --set-upstream-to=origin/main main

git -C "$MAIN" worktree add -q -b feature-a "$WT_A" main
git -C "$MAIN" worktree add -q -b feature-b "$WT_B" main

# Install Ralph into both worktrees (--scripts-only avoids touching the
# global extension/skills during the test).
"$REPO_ROOT/install.sh" "$WT_A" --scripts-only --profile generic >/dev/null
"$REPO_ROOT/install.sh" "$WT_B" --scripts-only --profile generic >/dev/null

# Stub ralph.sh so workers exit immediately rather than launching copilot.
for wt in "$WT_A" "$WT_B"; do
  cat > "$wt/.ralph/ralph.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$wt/.ralph/ralph.sh"
done

# Launch from worktree A.
RALPH_PARALLELISM=1 \
  "$WT_A/.ralph/launch.sh" >/dev/null 2>&1
# Launch from worktree B.
RALPH_PARALLELISM=1 \
  "$WT_B/.ralph/launch.sh" >/dev/null 2>&1

# Each worktree should now have its own loop worktree at <wt>-ralph.
if [[ ! -d "$WT_A-ralph" ]]; then
  echo "FAIL: expected loop worktree at $WT_A-ralph"
  git -C "$MAIN" worktree list
  exit 1
fi
if [[ ! -d "$WT_B-ralph" ]]; then
  echo "FAIL: expected loop worktree at $WT_B-ralph"
  git -C "$MAIN" worktree list
  exit 1
fi

# Branch names should be distinct (hash-derived).
BRANCH_A="$(git -C "$WT_A-ralph" rev-parse --abbrev-ref HEAD)"
BRANCH_B="$(git -C "$WT_B-ralph" rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH_A" == "$BRANCH_B" ]]; then
  echo "FAIL: per-worktree branch names should differ; got '$BRANCH_A' for both"
  exit 1
fi

# Both branches should be valid refs.
for b in "$BRANCH_A" "$BRANCH_B"; do
  if ! git -C "$MAIN" check-ref-format --branch "$b" >/dev/null 2>&1; then
    echo "FAIL: '$b' is not a valid git branch name"
    exit 1
  fi
done

# State + locks must be isolated per .ralph/.
if [[ -e "$WT_A/.ralph/state.json" && -e "$WT_B/.ralph/state.json" ]]; then
  if [[ "$(stat -f %d/%i "$WT_A/.ralph/state.json" 2>/dev/null || stat -c %d/%i "$WT_A/.ralph/state.json")" \
        == "$(stat -f %d/%i "$WT_B/.ralph/state.json" 2>/dev/null || stat -c %d/%i "$WT_B/.ralph/state.json")" ]]; then
    echo "FAIL: state.json should not be shared across worktrees"
    exit 1
  fi
fi

# Symlinks inside each loop worktree must point at the *originating* .ralph,
# not the other worktree's. Resolve both sides — on macOS `pwd -P` returns
# /private/var/... while $TMPDIR uses /var/..., so the raw symlink target
# can differ from the test's $WT_A even when they point at the same inode.
resolve() {
  local p="$1"
  if command -v greadlink >/dev/null 2>&1; then
    greadlink -f "$p"
  elif python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null; then
    :
  else
    (cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
  fi
}
sym_a="$(resolve "$WT_A-ralph/.ralph")"
expect_a="$(resolve "$WT_A/.ralph")"
if [[ "$sym_a" != "$expect_a" ]]; then
  echo "FAIL: $WT_A-ralph/.ralph should resolve to $expect_a, got: $sym_a"
  exit 1
fi
sym_b="$(resolve "$WT_B-ralph/.ralph")"
expect_b="$(resolve "$WT_B/.ralph")"
if [[ "$sym_b" != "$expect_b" ]]; then
  echo "FAIL: $WT_B-ralph/.ralph should resolve to $expect_b, got: $sym_b"
  exit 1
fi

echo "PASS: two worktrees of one repo can each spawn an isolated Ralph loop"
