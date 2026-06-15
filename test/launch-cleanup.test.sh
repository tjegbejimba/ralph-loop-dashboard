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
cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
if [[ -f "$REPO_ROOT/ralph/lib/copilot-session.sh" ]]; then
  cp "$REPO_ROOT/ralph/lib/copilot-session.sh" .ralph/lib/copilot-session.sh
fi
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

SESSION_STATE_DIR="$TEST_ROOT/session-state"
SESSION_ARCHIVE_DIR="$TEST_ROOT/session-archive"
RECORDED_SESSION_ID="11111111-1111-4111-8111-111111111111"
UNRECORDED_SESSION_ID="22222222-2222-4222-8222-222222222222"
FAILED_SESSION_ID="33333333-3333-4333-8333-333333333333"
LIVE_SESSION_ID="44444444-4444-4444-8444-444444444444"
mkdir -p \
  "$SESSION_STATE_DIR/$RECORDED_SESSION_ID" \
  "$SESSION_STATE_DIR/$UNRECORDED_SESSION_ID" \
  "$SESSION_STATE_DIR/$FAILED_SESSION_ID" \
  "$SESSION_STATE_DIR/$LIVE_SESSION_ID"
cat > "$SESSION_STATE_DIR/$RECORDED_SESSION_ID/workspace.yaml" <<EOF
id: $RECORDED_SESSION_ID
cwd: $LOOP_REPO-1
name: "Ralph #100 w1"
user_named: true
EOF
cat > "$SESSION_STATE_DIR/$UNRECORDED_SESSION_ID/workspace.yaml" <<EOF
id: $UNRECORDED_SESSION_ID
cwd: $LOOP_REPO-1
name: "Ralph #999 w1"
user_named: true
EOF
cat > "$SESSION_STATE_DIR/$FAILED_SESSION_ID/workspace.yaml" <<EOF
id: $FAILED_SESSION_ID
cwd: $LOOP_REPO-1
name: "Ralph #101 w1"
user_named: true
EOF
cat > "$SESSION_STATE_DIR/$LIVE_SESSION_ID/workspace.yaml" <<EOF
id: $LIVE_SESSION_ID
cwd: $LOOP_REPO-1
name: "Ralph #102 w1"
user_named: true
EOF
(sleep 60) &
LIVE_LOCK_PID=$!
trap 'kill "$LIVE_LOCK_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
touch "$SESSION_STATE_DIR/$LIVE_SESSION_ID/inuse.$LIVE_LOCK_PID.lock"
cat > .ralph/copilot-sessions.jsonl <<EOF
{"event":"terminal","sessionId":"$RECORDED_SESSION_ID","issue":100,"workerId":1,"terminalStatus":"merged","cwd":"$LOOP_REPO-1","name":"Ralph #100 w1"}
{"event":"terminal","sessionId":"$FAILED_SESSION_ID","issue":101,"workerId":1,"terminalStatus":"failed","cwd":"$LOOP_REPO-1","name":"Ralph #101 w1"}
{"event":"terminal","sessionId":"$LIVE_SESSION_ID","issue":102,"workerId":1,"terminalStatus":"merged","cwd":"$LOOP_REPO-1","name":"Ralph #102 w1"}
EOF

set +e
output=$(
  RALPH_MAIN_REPO="$MAIN_REPO" \
    RALPH_LOOP_REPO="$LOOP_REPO" \
    RALPH_COPILOT_SESSION_STATE_DIR="$SESSION_STATE_DIR" \
    RALPH_COPILOT_SESSION_ARCHIVE_DIR="$SESSION_ARCHIVE_DIR" \
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

if [[ -d "$SESSION_STATE_DIR/$RECORDED_SESSION_ID" ]]; then
  echo "FAIL: cleanup should archive recorded completed Ralph Copilot session"
  echo "$output"
  exit 1
fi

if [[ ! -d "$SESSION_ARCHIVE_DIR/$RECORDED_SESSION_ID" ]]; then
  echo "FAIL: archived Ralph Copilot session should be moved to archive dir"
  echo "$output"
  exit 1
fi

if [[ ! -d "$SESSION_STATE_DIR/$UNRECORDED_SESSION_ID" ]]; then
  echo "FAIL: cleanup must not archive Ralph-named sessions that are not recorded in Ralph ledger"
  echo "$output"
  exit 1
fi

if [[ ! -d "$SESSION_STATE_DIR/$FAILED_SESSION_ID" ]]; then
  echo "FAIL: cleanup should preserve failed Ralph Copilot sessions for debugging"
  echo "$output"
  exit 1
fi

if [[ ! -d "$SESSION_STATE_DIR/$LIVE_SESSION_ID" ]]; then
  echo "FAIL: cleanup should preserve live in-use Ralph Copilot sessions"
  echo "$output"
  exit 1
fi

echo "PASS: launch.sh --cleanup removes clean worktrees and preserves dirty ones"
