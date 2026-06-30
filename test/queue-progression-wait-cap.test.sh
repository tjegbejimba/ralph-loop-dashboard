#!/usr/bin/env bash
# Integration test for 30-minute wait cap on recoverable items.
# Slice 4: When a queue has only recoverable items with future leases,
# the worker should exit after a bounded wait period (simulated with IDLE_EXIT_POLLS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

# Setup test repo
mkdir -p "$TEST_ROOT/main" "$TEST_ROOT/origin.git" "$TEST_ROOT/bin"

# Mock gh that returns a recoverable issue
cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "issue view 200")
    printf '{"number":200,"state":"OPEN","title":"Test issue 200","labels":[{"name":"ralph:ready"},{"name":"work:standalone"}],"body":"","assignees":[]}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/gh"

git init -q --bare "$TEST_ROOT/origin.git"
git init -q "$TEST_ROOT/main"
cd "$TEST_ROOT/main"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
git remote add origin "$TEST_ROOT/origin.git"
git push -q -u origin main
printf '%s\n' ".ralph" >> .git/info/exclude

# Install Ralph
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
{
  "issue": {
    "titleRegex": "^Test issue",
    "titleNumRegex": "^Test issue (?<x>[0-9]+)"
  }
}
EOF

# Create run with only recoverable item
mkdir -p .ralph/runs/wait-cap-test
cat > .ralph/runs/wait-cap-test/queue.json <<'EOF'
[
  {"number": 200, "title": "Test issue 200"}
]
EOF
cat > .ralph/runs/wait-cap-test/status.json <<'EOF'
{"items":{}}
EOF

# Park issue 200 as recoverable with future lease (5 minutes from now)
next_retry=$(date -u -v+5M +%FT%TZ 2>/dev/null || date -u -d '+5 minutes' +%FT%TZ)
LOG_DIR="$TEST_ROOT/main/.ralph/logs" \
  RUN_ID="wait-cap-test" \
  bash -c ". .ralph/lib/state.sh && . .ralph/lib/recovery-ledger.sh && ledger_record_recoverable '200' '999' 'slice-200-test' '1' '$next_retry' 'worker exit'"

echo "Test: Queue with only recoverable (not due) exits after idle poll cap"

# Run worker with short IDLE_EXIT_POLLS to simulate 30-minute wait cap
(
  cd "$TEST_ROOT/main"
  export PATH="$TEST_ROOT/bin:$PATH"
  export RALPH_REPO="testowner/testrepo"
  export RALPH_RUN_ID="wait-cap-test"
  export RALPH_POLL_SEC=1
  export RALPH_IDLE_EXIT_POLLS=3
  export RALPH_GH_BIN="$TEST_ROOT/bin/gh"
  
  .ralph/ralph.sh 2>&1 &
  worker_pid=$!
  sleep 15
  kill -0 "$worker_pid" 2>/dev/null && kill "$worker_pid" 2>/dev/null
  wait "$worker_pid" 2>/dev/null || true
) > /tmp/wait-cap-output.log 2>&1

output=$(cat /tmp/wait-cap-output.log)

# Worker should report waiting for recoverable leased items
if ! echo "$output" | grep -q "recoverable_leased=1"; then
  echo "$output"
  fail "Worker should report recoverable_leased count"
fi

# Worker should exit after idle poll limit
if ! echo "$output" | grep -q "idle for.*polls, exiting"; then
  echo "$output"
  fail "Worker should exit after reaching idle poll limit"
fi

# Status should still show recoverable as not terminal
status_200=$(jq -r '.items["200"].status // "missing"' .ralph/runs/wait-cap-test/status.json)
if [[ "$status_200" != "missing" ]]; then
  # If status was set, it should not be terminal
  if [[ "$status_200" == "merged" || "$status_200" == "failed" || "$status_200" == "skipped" || "$status_200" == "rejected" ]]; then
    fail "Recoverable issue should not be in terminal state, got: $status_200"
  fi
fi

echo "PASS: Worker exits after wait cap with recoverable items"
echo ""
echo "========================================="
echo "All queue progression wait cap tests passed!"
echo "========================================="
