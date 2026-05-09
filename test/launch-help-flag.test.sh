#!/usr/bin/env bash
# Integration test for launch.sh --help/-h and unknown flag handling.

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

# --- Test 1: --help exits 0 and prints usage ---
output=$(RALPH_MAIN_REPO="$MAIN_REPO" RALPH_LOOP_REPO="$LOOP_REPO" \
  "$MAIN_REPO/.ralph/launch.sh" --help 2>&1)
status=$?

if [[ "$status" -ne 0 ]]; then
  echo "FAIL: --help should exit 0, got $status"
  echo "$output"
  exit 1
fi
for flag in "--status" "--stop" "--cleanup" "--enqueue" "--enqueue-prd" "--foreground"; do
  if ! grep -qF -- "$flag" <<<"$output"; then
    echo "FAIL: --help output should mention $flag"
    echo "$output"
    exit 1
  fi
done
if [[ -d "$LOOP_REPO" ]]; then
  echo "FAIL: --help should not create a worktree"
  exit 1
fi
echo "PASS: --help exits 0 and prints usage"

# --- Test 2: -h exits 0 and prints usage (short alias) ---
set +e
output=$(RALPH_MAIN_REPO="$MAIN_REPO" RALPH_LOOP_REPO="$LOOP_REPO" \
  "$MAIN_REPO/.ralph/launch.sh" -h 2>&1)
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  echo "FAIL: -h should exit 0, got $status"
  echo "$output"
  exit 1
fi
if ! grep -qF -- "--status" <<<"$output"; then
  echo "FAIL: -h should print usage containing --status"
  echo "$output"
  exit 1
fi
if [[ -d "$LOOP_REPO" ]]; then
  echo "FAIL: -h should not create a worktree"
  exit 1
fi
echo "PASS: -h exits 0 and prints usage"

# --- Test 3: unknown flag exits non-zero and prints error message ---
set +e
output=$(RALPH_MAIN_REPO="$MAIN_REPO" RALPH_LOOP_REPO="$LOOP_REPO" \
  "$MAIN_REPO/.ralph/launch.sh" --bogus 2>&1)
bogus_status=$?
set -e

if [[ "$bogus_status" -eq 0 ]]; then
  echo "FAIL: --bogus should exit non-zero"
  exit 1
fi
if ! grep -qF -- "unknown option: --bogus" <<<"$output"; then
  echo "FAIL: should print 'unknown option: --bogus', got:"
  echo "$output"
  exit 1
fi
if ! grep -qF -- "--status" <<<"$output"; then
  echo "FAIL: unknown flag output should include usage block"
  echo "$output"
  exit 1
fi
if [[ -d "$LOOP_REPO" ]]; then
  echo "FAIL: unknown flag should not create a worktree"
  exit 1
fi
echo "PASS: unknown flag exits non-zero with error + usage"

# --- Test 4: bare invocation gets past flag parsing (no "unknown option:" error) ---
set +e
output=$(RALPH_MAIN_REPO="$MAIN_REPO" RALPH_LOOP_REPO="$LOOP_REPO" \
  "$MAIN_REPO/.ralph/launch.sh" 2>&1)
bare_status=$?
set -e

if grep -qF -- "unknown option:" <<<"$output"; then
  echo "FAIL: bare invocation must not trigger unknown option error"
  echo "$output"
  exit 1
fi
# The script will fail for other reasons (no git remote), which is acceptable.
echo "PASS: bare invocation gets past flag parsing (exit=$bare_status)"

echo ""
echo "All launch.sh --help / unknown-flag tests passed!"
