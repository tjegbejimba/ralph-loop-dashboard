#!/usr/bin/env bash
# Integration test for run-aware queue consumption

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Setup mock repo
cd "$TEST_ROOT"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
git remote add origin https://github.com/testowner/testrepo

# Setup .ralph structure
mkdir -p .ralph/runs/test-run-001/logs
mkdir -p .ralph/logs
mkdir -p .ralph/lock
mkdir -p .ralph/lib
cp "$SCRIPT_DIR/../ralph/lib/state.sh" .ralph/lib/state.sh
cp "$SCRIPT_DIR/../ralph/lib/status.sh" .ralph/lib/status.sh

# Create test queue
cat > .ralph/runs/test-run-001/queue.json <<'EOF'
[
  {"number": 100, "title": "Test issue 100"},
  {"number": 101, "title": "Test issue 101"}
]
EOF

# Create initial empty status
cat > .ralph/runs/test-run-001/status.json <<'EOF'
{"items":{}}
EOF

# Create minimal RALPH.md
cat > .ralph/RALPH.md <<'EOF'
You are a test agent. Exit immediately with success.
EOF

# Create config.json
cat > .ralph/config.json <<'EOF'
{
  "issue": {
    "titleRegex": "^Test issue",
    "titleNumRegex": "^Test issue (?<x>[0-9]+)"
  }
}
EOF

# Mock copilot that just exits success
cat > .ralph/mock-copilot.sh <<'EOF'
#!/usr/bin/env bash
echo "Mock copilot running on: $@"
echo "Pretending to work..."
sleep 1
exit 0
EOF
chmod +x .ralph/mock-copilot.sh

# Create test ralph.sh that sources our worker logic but stops before copilot
# This tests queue selection without actually running copilot
cat > .ralph/test-worker.sh <<'WORKER_EOF'
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"

# Parse --run-id flag
RUN_ID=""
if [[ "${1:-}" == "--run-id" && -n "${2:-}" ]]; then
  RUN_ID="$2"
  export RUN_ID
fi

LOG_DIR="$SCRIPT_DIR/logs"
export LOG_DIR

. "$SCRIPT_DIR/lib/state.sh"
. "$SCRIPT_DIR/lib/status.sh"

state_init
status_init

REPO="testowner/testrepo"
WORKER_ID="${RALPH_WORKER_ID:-1}"
LOCK_DIR="$SCRIPT_DIR/lock/worker-${WORKER_ID}"

if ! acquire_lockdir "$LOCK_DIR"; then
  echo "⚠️  Worker $WORKER_ID already running"
  exit 1
fi
trap 'release_lockdir "$LOCK_DIR"' EXIT

# Run-aware mode: load queue
if [[ -n "$RUN_ID" ]]; then
  queue_file="$SCRIPT_DIR/runs/$RUN_ID/queue.json"
  if [[ ! -f "$queue_file" ]]; then
    echo "❌ Queue file not found: $queue_file"
    exit 1
  fi
  
  # Find next unclaimed issue
  state_lock
  status_reap_stale
  
  queue_json=$(cat "$queue_file")
  num=""
  title=""
  
  for row in $(echo "$queue_json" | jq -r '.[] | @base64'); do
    decoded=$(echo "$row" | base64 --decode)
    cand_num=$(echo "$decoded" | jq -r .number)
    cand_title=$(echo "$decoded" | jq -r .title)
    
    # Skip if already claimed in state.json
    if state_claimed_issues | grep -qx "$cand_num"; then
      continue
    fi
    
    # Skip if in terminal state in status.json
    if status_is_terminal "$cand_num"; then
      continue
    fi
    
    # Skip if already CLOSED on GitHub (would need gh mock - skip for now)
    
    num="$cand_num"
    title="$cand_title"
    break
  done
  
  if [[ -z "$num" ]]; then
    state_unlock
    echo "✅ Worker $WORKER_ID: no unclaimed issues in queue"
    exit 0
  fi
  
  # Claim it
  log_file="logs/test-w${WORKER_ID}-issue-${num}.log"
  state_claim "$num" "$WORKER_ID" "$$" "$(basename "$log_file")"
  status_update_item "$num" "claimed" "$WORKER_ID" "$$" "$log_file" "$(date -u +%FT%TZ)"
  state_unlock
  
  echo "✅ Worker $WORKER_ID claimed issue #$num: $title"
  echo "STATUS_FILE_CHECK:$(cat "$SCRIPT_DIR/runs/$RUN_ID/status.json" | jq -c .)"
  exit 0
else
  echo "❌ Legacy mode not implemented in test worker"
  exit 1
fi
WORKER_EOF
chmod +x .ralph/test-worker.sh

# Test 1: Worker with --run-id claims first issue
echo "Test 1: Worker claims first unclaimed issue from queue"
RALPH_WORKER_ID=1 .ralph/test-worker.sh --run-id test-run-001
if [[ $? -ne 0 ]]; then
  echo "FAIL: Worker should claim first issue"
  exit 1
fi

status=$(cat .ralph/runs/test-run-001/status.json | jq -r '.items["100"].status')
if [[ "$status" != "claimed" ]]; then
  echo "FAIL: Issue 100 should be claimed, got: $status"
  exit 1
fi
echo "PASS: Worker claims first issue"

# Test 2: Second worker claims second issue (no conflict)
echo ""
echo "Test 2: Second worker claims next unclaimed issue"
RALPH_WORKER_ID=2 .ralph/test-worker.sh --run-id test-run-001
if [[ $? -ne 0 ]]; then
  echo "FAIL: Second worker should claim second issue"
  exit 1
fi

status100=$(cat .ralph/runs/test-run-001/status.json | jq -r '.items["100"].status')
status101=$(cat .ralph/runs/test-run-001/status.json | jq -r '.items["101"].status')
if [[ "$status100" != "claimed" || "$status101" != "claimed" ]]; then
  echo "FAIL: Both issues should be claimed, got: 100=$status100 101=$status101"
  exit 1
fi

worker100=$(cat .ralph/runs/test-run-001/status.json | jq -r '.items["100"].workerId')
worker101=$(cat .ralph/runs/test-run-001/status.json | jq -r '.items["101"].workerId')
if [[ "$worker100" == "$worker101" ]]; then
  echo "FAIL: Different workers should claim different issues"
  exit 1
fi
echo "PASS: Second worker claims different issue"

# Test 3: Third worker finds no work
echo ""
echo "Test 3: Third worker exits cleanly when queue exhausted"
output=$(RALPH_WORKER_ID=3 .ralph/test-worker.sh --run-id test-run-001 2>&1)
if [[ $? -ne 0 ]]; then
  echo "FAIL: Worker should exit cleanly when no work remains"
  exit 1
fi
if ! echo "$output" | grep -q "no unclaimed issues"; then
  echo "FAIL: Worker should report no unclaimed issues"
  exit 1
fi
echo "PASS: Worker exits when queue exhausted"

echo ""
echo "All queue consumption tests passed!"
