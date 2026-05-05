#!/usr/bin/env bash
# Integration test for lib/status.sh — run queue status coordination

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Setup test repo structure
mkdir -p "$TEST_ROOT/.ralph/runs/test-run-123/logs"
mkdir -p "$TEST_ROOT/.ralph/lock"

# Initialize status.json
cat > "$TEST_ROOT/.ralph/runs/test-run-123/status.json" <<'EOF'
{"items":{}}
EOF

# Source the libraries
LOG_DIR="$TEST_ROOT/.ralph/logs"
RUN_ID="test-run-123"
export LOG_DIR RUN_ID

. "$SCRIPT_DIR/../ralph/lib/state.sh"
. "$SCRIPT_DIR/../ralph/lib/status.sh"

# Test 1: status_init creates status.json if missing
rm -f "$TEST_ROOT/.ralph/runs/test-run-123/status.json"
status_init
if [[ ! -f "$TEST_ROOT/.ralph/runs/test-run-123/status.json" ]]; then
  echo "FAIL: status_init should create status.json"
  exit 1
fi
content=$(cat "$TEST_ROOT/.ralph/runs/test-run-123/status.json")
if [[ "$content" != '{"items":{}}' ]]; then
  echo "FAIL: status_init should create empty items map, got: $content"
  exit 1
fi
echo "PASS: status_init"

# Test 2: status_update_item writes atomically
cat > "$TEST_ROOT/.ralph/runs/test-run-123/status.json" <<'EOF'
{"items":{}}
EOF
status_update_item "15" "claimed" "1" "$$" "iter-test.log" "$(date -u +%FT%TZ)"
content=$(cat "$TEST_ROOT/.ralph/runs/test-run-123/status.json")
if ! echo "$content" | jq -e '.items["15"].status == "claimed"' >/dev/null; then
  echo "FAIL: status_update_item should write claimed state"
  exit 1
fi
if ! echo "$content" | jq -e '.items["15"].workerId == 1' >/dev/null; then
  echo "FAIL: status_update_item should write workerId"
  exit 1
fi
echo "PASS: status_update_item"

# Test 3: status_load_item reads item state
status=$(status_load_item "15" "status")
if [[ "$status" != "claimed" ]]; then
  echo "FAIL: status_load_item should read status, got: $status"
  exit 1
fi
worker=$(status_load_item "15" "workerId")
if [[ "$worker" != "1" ]]; then
  echo "FAIL: status_load_item should read workerId, got: $worker"
  exit 1
fi
echo "PASS: status_load_item"

# Test 4: status_reap_stale marks dead PIDs as failed
# Start a background sleep that looks like ralph for testing
( exec -a "ralph.sh-test" sleep 300 ) &
live_pid=$!
trap 'kill $live_pid 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

cat > "$TEST_ROOT/.ralph/runs/test-run-123/status.json" <<EOF
{"items":{
  "15": {"status": "running", "workerId": 1, "pid": 99999, "logFile": "test.log", "startedAt": "2026-01-01T00:00:00Z", "error": null},
  "16": {"status": "running", "workerId": 2, "pid": $live_pid, "logFile": "test2.log", "startedAt": "2026-01-01T00:00:00Z", "error": null}
}}
EOF
state_init
state_lock
status_reap_stale
state_unlock
content=$(cat "$TEST_ROOT/.ralph/runs/test-run-123/status.json")
if ! echo "$content" | jq -e '.items["15"].status == "failed"' >/dev/null; then
  echo "FAIL: status_reap_stale should mark dead PID as failed, got: $(echo "$content" | jq -r '.items["15"].status')"
  exit 1
fi
if ! echo "$content" | jq -e '.items["16"].status == "running"' >/dev/null; then
  echo "FAIL: status_reap_stale should leave live PID as running, got: $(echo "$content" | jq -r '.items["16"].status')"
  exit 1
fi
kill $live_pid 2>/dev/null || true
echo "PASS: status_reap_stale"

echo ""
echo "All status.sh tests passed!"
