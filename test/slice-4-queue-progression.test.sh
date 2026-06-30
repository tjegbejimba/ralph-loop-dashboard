#!/usr/bin/env bash
# Comprehensive integration test for Slice 4: Queue progression with recoverables.
#
# Test scenarios based on acceptance criteria:
# 1. Mixed queue (recoverable + ready) → processes ready first, skips recoverable
# 2. Queue with only terminal items → exits cleanly
# 3. Status distinctions → recoverable is not terminal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

pass() {
  echo "PASS: $*"
}

echo "==============================================="
echo "Slice 4: Queue Progression with Recoverables"
echo "==============================================="
echo ""

#
# Test 1: Recoverable is not terminal
#
echo "Test 1: Recoverable status is not terminal"
mkdir -p "$TEST_ROOT/test1"
cd "$TEST_ROOT/test1"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
mkdir -p .ralph/lib .ralph/runs/r1
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
cat > .ralph/runs/r1/status.json <<'EOF'
{"items": {"100": {"status": "recoverable", "error": "open PR exists"}}}
EOF

LOG_DIR="$TEST_ROOT/test1/.ralph/logs"
RUN_ID="r1"
export LOG_DIR RUN_ID
mkdir -p "$LOG_DIR"

. .ralph/lib/state.sh
. .ralph/lib/status.sh

if status_is_terminal "100"; then
  fail "Recoverable status should not be terminal"
fi
pass "Recoverable status is not terminal"

# Verify other statuses ARE terminal
cat > .ralph/runs/r1/status.json <<'EOF'
{"items": {
  "100": {"status": "merged"},
  "101": {"status": "failed"},
  "102": {"status": "skipped"},
  "103": {"status": "rejected"}
}}
EOF

for num in 100 101 102 103; do
  if ! status_is_terminal "$num"; then
    fail "Issue $num should be terminal"
  fi
done
pass "Terminal statuses (merged/failed/skipped/rejected) are terminal"

#
# Test 2: Queue progression - mixed queue processes ready items
#
echo ""
echo "Test 2: Mixed queue (recoverable + ready) progresses correctly"

# This test verifies that when a queue has both recoverable (not due) and ready items,
# the worker skips the recoverable and processes the ready item.
# We'll check this by verifying the worker's selection logic via status.json.

mkdir -p "$TEST_ROOT/test2/main" "$TEST_ROOT/test2/origin.git" "$TEST_ROOT/test2/bin"

# Mock gh
cat > "$TEST_ROOT/test2/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "issue view 100")
    printf '{"number":100,"state":"OPEN","title":"Ready issue 100","labels":[{"name":"ralph:ready"},{"name":"work:standalone"}],"body":"","assignees":[]}\n'
    ;;
  "issue view 200")
    printf '{"number":200,"state":"OPEN","title":"Recoverable issue 200","labels":[{"name":"ralph:ready"},{"name":"work:standalone"}],"body":"","assignees":[]}\n'
    ;;
  "pr list "*" 100")
    echo ""  # No PR for #100
    ;;
  "pr list "*" 200")
    echo ""  # No PR for #200 (parked)
    ;;
  *)
    printf '{}\n'
    ;;
esac
GH_EOF
chmod +x "$TEST_ROOT/test2/bin/gh"

# Mock copilot that exits quickly
cat > "$TEST_ROOT/test2/bin/copilot" <<'COPILOT_EOF'
#!/usr/bin/env bash
# Mock copilot - simulate work without actually doing anything
echo "Mock copilot run"
sleep 0.5
exit 1  # Exit with failure so worker doesn't try to verify PR
COPILOT_EOF
chmod +x "$TEST_ROOT/test2/bin/copilot"

git init -q --bare "$TEST_ROOT/test2/origin.git"
git init -q "$TEST_ROOT/test2/main"
cd "$TEST_ROOT/test2/main"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
git remote add origin "$TEST_ROOT/test2/origin.git"
git push -q -u origin main
printf '%s\n' ".ralph" >> .git/info/exclude

mkdir -p .ralph/lib
cp "$REPO_ROOT/ralph/ralph.sh" .ralph/ralph.sh
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
cp "$REPO_ROOT/ralph/lib/recovery-ledger.sh" .ralph/lib/recovery-ledger.sh
chmod +x .ralph/ralph.sh

cat > .ralph/RALPH.md <<'EOF'
Test prompt.
EOF

cat > .ralph/config.json <<'EOF'
{"issue": {"titleRegex": "^", "titleNumRegex": "^.*(?<x>[0-9]+)"}}
EOF

mkdir -p .ralph/runs/mixed
cat > .ralph/runs/mixed/queue.json <<'EOF'
[
  {"number": 200, "title": "Recoverable issue 200"},
  {"number": 100, "title": "Ready issue 100"}
]
EOF
cat > .ralph/runs/mixed/status.json <<'EOF'
{"items":{}}
EOF

# Park issue 200 as recoverable (not due for 5 minutes)
next_retry=$(date -u -v+5M +%FT%TZ 2>/dev/null || date -u -d '+5 minutes' +%FT%TZ)
LOG_DIR="$TEST_ROOT/test2/main/.ralph/logs" \
  RUN_ID="mixed" \
  bash -c ". .ralph/lib/state.sh && . .ralph/lib/recovery-ledger.sh && ledger_record_recoverable '200' '999' 'slice-200' '1' '$next_retry' 'exit before merge'"

# Run worker for one iteration (--once)
output_file="$TEST_ROOT/test2-output.log"
(
  cd "$TEST_ROOT/test2/main"
  export PATH="$TEST_ROOT/test2/bin:$PATH"
  export RALPH_REPO="testowner/testrepo"
  export RALPH_RUN_ID="mixed"
  export RALPH_POLL_SEC=1
  export RALPH_IDLE_EXIT_POLLS=1
  export RALPH_GH_BIN="$TEST_ROOT/test2/bin/gh"
  export RALPH_COPILOT_BIN="$TEST_ROOT/test2/bin/copilot"
  export RALPH_TIMEOUT_SEC=10
  
  .ralph/ralph.sh --once 2>&1 &
  worker_pid=$!
  sleep 12
  kill -0 "$worker_pid" 2>/dev/null && kill "$worker_pid" 2>/dev/null
  wait "$worker_pid" 2>/dev/null || true
) > "$output_file" 2>&1

output=$(cat "$output_file")

# Worker should have attempted to claim issue #100 (the ready one), not #200 (recoverable)
if echo "$output" | grep -q "#100"; then
  pass "Worker selected ready issue #100"
else
  echo "$output" | head -50
  # Not a hard failure - the queue selection logic may vary
  echo "Note: Worker output doesn't show #100 explicitly"
fi

# Check status: #100 should have been attempted (claimed/running/failed), #200 untouched
status_100=$(jq -r '.items["100"].status // "missing"' .ralph/runs/mixed/status.json 2>/dev/null || echo "missing")
status_200=$(jq -r '.items["200"].status // "missing"' .ralph/runs/mixed/status.json 2>/dev/null || echo "missing")

if [[ "$status_100" == "missing" ]]; then
  echo "$output" | head -50
  fail "Issue #100 (ready) must be processed; got status: missing"
fi
pass "Issue #100 (ready) was processed (status: $status_100)"

if [[ "$status_200" == "missing" || "$status_200" == "recoverable" ]]; then
  pass "Issue #200 (recoverable, not due) was skipped"
else
  echo "$output" | head -50
  fail "Issue #200 should remain unprocessed or recoverable, got: $status_200"
fi

#
# Test 3: All-terminal queue exits cleanly (existing behavior preserved)
#
echo ""
echo "Test 3: All-terminal queue exits cleanly"

mkdir -p "$TEST_ROOT/test3/main" "$TEST_ROOT/test3/origin.git" "$TEST_ROOT/test3/bin"
cat > "$TEST_ROOT/test3/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '{}\n'
EOF
chmod +x "$TEST_ROOT/test3/bin/gh"

git init -q --bare "$TEST_ROOT/test3/origin.git"
git init -q "$TEST_ROOT/test3/main"
cd "$TEST_ROOT/test3/main"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
git remote add origin "$TEST_ROOT/test3/origin.git"
git push -q -u origin main
printf '%s\n' ".ralph" >> .git/info/exclude

mkdir -p .ralph/lib
cp "$REPO_ROOT/ralph/ralph.sh" .ralph/ralph.sh
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
cp "$REPO_ROOT/ralph/lib/recovery-ledger.sh" .ralph/lib/recovery-ledger.sh
chmod +x .ralph/ralph.sh

cat > .ralph/RALPH.md <<'EOF'
Test prompt.
EOF
cat > .ralph/config.json <<'EOF'
{"issue": {"titleRegex": "^", "titleNumRegex": "^.*(?<x>[0-9]+)"}}
EOF

mkdir -p .ralph/runs/terminal
cat > .ralph/runs/terminal/queue.json <<'EOF'
[
  {"number": 10, "title": "Merged"},
  {"number": 11, "title": "Failed"},
  {"number": 12, "title": "Skipped"}
]
EOF
cat > .ralph/runs/terminal/status.json <<'EOF'
{
  "items": {
    "10": {"status": "merged"},
    "11": {"status": "failed"},
    "12": {"status": "skipped"}
  }
}
EOF

output=$(
  cd "$TEST_ROOT/test3/main"
  export PATH="$TEST_ROOT/test3/bin:$PATH"
  export RALPH_REPO="testowner/testrepo"
  export RALPH_RUN_ID="terminal"
  export RALPH_GH_BIN="$TEST_ROOT/test3/bin/gh"
  
  .ralph/ralph.sh 2>&1 &
  worker_pid=$!
  sleep 3
  kill -0 "$worker_pid" 2>/dev/null && kill "$worker_pid" 2>/dev/null
  wait "$worker_pid" 2>/dev/null || true
)

if echo "$output" | grep -q "queue fully resolved.*3/3 terminal"; then
  pass "All-terminal queue exits cleanly with correct message"
else
  echo "$output" | head -20
  fail "All-terminal queue should exit with 'fully resolved' message"
fi

echo ""
echo "========================================="
echo "All Slice 4 tests passed!"
echo "========================================="
