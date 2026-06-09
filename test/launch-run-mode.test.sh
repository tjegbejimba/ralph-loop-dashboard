#!/usr/bin/env bash
# Integration test for launch.sh forwarding one-pass mode to workers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

make_repo() {
  local name="$1"
  local main_repo="$TEST_ROOT/$name-main"
  local origin="$TEST_ROOT/$name-origin.git"
  git init -q --bare "$origin"
  git init -q "$main_repo"
  cd "$main_repo"
  git checkout -qb main
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "initial" > README.md
  git add README.md
  git commit -qm "initial"
  git remote add origin "$origin"
  git push -q -u origin main

  mkdir -p .ralph/lib .ralph/logs .ralph/lock
  cp "$REPO_ROOT/ralph/launch.sh" .ralph/launch.sh
  cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
  cat > .ralph/ralph.sh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$(cd "$(dirname "$0")" && pwd -P)/args.txt"
exit 0
EOF
  chmod +x .ralph/launch.sh .ralph/ralph.sh
  echo "$main_repo"
}

wait_for_args() {
  local args_file="$1"
  for _ in {1..40}; do
    [[ -f "$args_file" ]] && return 0
    sleep 0.1
  done
  return 1
}

foreground_repo=$(make_repo foreground)
foreground_loop="$TEST_ROOT/foreground-loop"
RALPH_MAIN_REPO="$foreground_repo" \
  RALPH_LOOP_REPO="$foreground_loop" \
  "$foreground_repo/.ralph/launch.sh" --foreground --once >/dev/null 2>&1

if [[ "$(cat "$foreground_repo/.ralph/args.txt")" != "--once" ]]; then
  echo "FAIL: --foreground --once should pass --once to ralph.sh"
  exit 1
fi
echo "PASS: --foreground --once forwards --once"

background_repo=$(make_repo background)
background_loop="$TEST_ROOT/background-loop"
RALPH_MAIN_REPO="$background_repo" \
  RALPH_LOOP_REPO="$background_loop" \
  "$background_repo/.ralph/launch.sh" --once >/dev/null 2>&1

if ! wait_for_args "$background_repo/.ralph/args.txt"; then
  echo "FAIL: --once background launch did not run worker"
  exit 1
fi
if [[ "$(cat "$background_repo/.ralph/args.txt")" != "--once" ]]; then
  echo "FAIL: --once should pass --once to background ralph.sh"
  exit 1
fi
echo "PASS: --once forwards --once to background worker"
