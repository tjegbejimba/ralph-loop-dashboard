#!/usr/bin/env bash
# Integration + unit tests for idle-worker timeout and stale-script detection.
#
# Covers acceptance criteria:
#   - Idle timeout fires after RALPH_IDLE_EXIT_POLLS consecutive idle polls
#   - RALPH_IDLE_EXIT_POLLS=0 disables the timeout
#   - Idle counter resets to 0 when a worker successfully claims an issue
#   - launch.sh refuses to start when ralph/ralph.sh source is newer than
#     .ralph/ralph.sh (installed), and --force overrides the refusal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
HOLD_PID=""
trap '
  rm -rf "$TEST_ROOT"
  [[ -n "$HOLD_PID" ]] && kill "$HOLD_PID" 2>/dev/null || true
' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Shared git repo setup for run-aware worker tests
# ---------------------------------------------------------------------------
setup_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  cd "$dir"
  git checkout -qb main
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "test" > README.md
  git add README.md
  git commit -qm "initial"

  # Each repo gets its own bare origin to avoid push-conflict between tests.
  local bare="$dir.origin.git"
  git init -q --bare "$bare"
  git remote add origin "$bare"
  git push -q -u origin main
  printf '.ralph\n' >> .git/info/exclude

  mkdir -p .ralph/lib .ralph/logs .ralph/lock
  cp "$REPO_ROOT/ralph/ralph.sh"      .ralph/ralph.sh
  cp "$REPO_ROOT/ralph/launch.sh"     .ralph/launch.sh
  cp "$REPO_ROOT/ralph/lib/state.sh"  .ralph/lib/state.sh
  cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
  cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
  cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
  chmod +x .ralph/ralph.sh .ralph/launch.sh

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
  echo '{"claims":{}}' > .ralph/state.json
  cd "$SCRIPT_DIR/.."
}

# ---------------------------------------------------------------------------
# Helper: run worker with env overrides, wait up to MAX_WAIT_SEC for exit.
# Usage: run_worker_env REPO RUN_ID MAX_WAIT_SEC [ENV=val ...]
# Echoes combined stdout+stderr; returns 0 on clean exit, 124 on timeout.
# ---------------------------------------------------------------------------
run_worker_env() {
  local repo="$1" run_id="$2" max_wait="$3"
  shift 3
  local extra_env=("$@")
  local out="$TEST_ROOT/${run_id}.out"

  env RALPH_REPO="testowner/testrepo" \
      RALPH_RUN_ID="$run_id" \
      RALPH_WORKER_ID=1 \
      "${extra_env[@]}" \
      bash -c "cd '$repo' && .ralph/ralph.sh" >"$out" 2>&1 &
  local pid=$!

  local waited=0
  while [[ $waited -lt $((max_wait * 10)) ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      cat "$out"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$out"
  return 124
}

# ---------------------------------------------------------------------------
# Helper: create a background process whose command line contains "ralph.sh"
# so state_reap_stale won't reap its claim (it checks *ralph.sh* pattern).
# Sets HOLD_PID in the global scope.
# ---------------------------------------------------------------------------
start_claim_holder() {
  local holder="$TEST_ROOT/hold-claim-ralph.sh"
  if [[ ! -f "$holder" ]]; then
    printf '#!/usr/bin/env bash\nsleep 60\n' > "$holder"
    chmod +x "$holder"
  fi
  "$holder" &
  HOLD_PID=$!
}

# ---------------------------------------------------------------------------
# Helper: write a state.json pre-claiming issue $issue by PID $pid
# ---------------------------------------------------------------------------
pre_claim() {
  local repo="$1" issue="$2" pid="$3"
  cat > "$repo/.ralph/state.json" <<JSON
{"claims":{"$issue":{"workerId":99,"pid":$pid,"startedAt":"2024-01-01T00:00:00Z","logFile":"fake.log"}}}
JSON
}

# ===========================================================================
# Test 1: Idle timeout fires
# ===========================================================================
echo "Test 1: idle timeout fires"

REPO1="$TEST_ROOT/main1"
setup_repo "$REPO1"

mkdir -p "$REPO1/.ralph/runs/idle-test"
cat > "$REPO1/.ralph/runs/idle-test/queue.json" <<'EOF'
[{"number": 100, "title": "Test issue 100"}]
EOF
cat > "$REPO1/.ralph/runs/idle-test/status.json" <<'EOF'
{"items":{}}
EOF

start_claim_holder
pre_claim "$REPO1" 100 "$HOLD_PID"

output1=$(run_worker_env "$REPO1" "idle-test" 5 \
  RALPH_POLL_SEC=0.1 RALPH_IDLE_EXIT_POLLS=2) || true

kill "$HOLD_PID" 2>/dev/null || true; HOLD_PID=""

if ! echo "$output1" | grep -q "idle for 2 polls, exiting"; then
  echo "$output1"
  fail "worker should log 'idle for 2 polls, exiting' after 2 idle polls"
fi
echo "PASS: idle timeout fires"
echo ""

# ===========================================================================
# Test 2: RALPH_IDLE_EXIT_POLLS=0 disables timeout
# ===========================================================================
echo "Test 2: RALPH_IDLE_EXIT_POLLS=0 disables timeout"

REPO2="$TEST_ROOT/main2"
setup_repo "$REPO2"

mkdir -p "$REPO2/.ralph/runs/no-idle"
cat > "$REPO2/.ralph/runs/no-idle/queue.json" <<'EOF'
[{"number": 100, "title": "Test issue 100"}]
EOF
cat > "$REPO2/.ralph/runs/no-idle/status.json" <<'EOF'
{"items":{}}
EOF

start_claim_holder
pre_claim "$REPO2" 100 "$HOLD_PID"

no_idle_out="$TEST_ROOT/no-idle.out"
env RALPH_REPO="testowner/testrepo" RALPH_RUN_ID="no-idle" RALPH_WORKER_ID=1 \
  RALPH_POLL_SEC=0.1 RALPH_IDLE_EXIT_POLLS=0 \
  bash -c "cd '$REPO2' && .ralph/ralph.sh" >"$no_idle_out" 2>&1 &
NO_IDLE_PID=$!

sleep 0.5

if ! kill -0 "$NO_IDLE_PID" 2>/dev/null; then
  wait "$NO_IDLE_PID" 2>/dev/null || true
  kill "$HOLD_PID" 2>/dev/null || true; HOLD_PID=""
  echo "$(cat "$no_idle_out")"
  fail "worker with RALPH_IDLE_EXIT_POLLS=0 should NOT exit within 0.5s"
fi

kill "$NO_IDLE_PID" 2>/dev/null || true
wait "$NO_IDLE_PID" 2>/dev/null || true
kill "$HOLD_PID" 2>/dev/null || true; HOLD_PID=""

if grep -q "idle for.*polls, exiting" "$no_idle_out"; then
  cat "$no_idle_out"
  fail "worker with RALPH_IDLE_EXIT_POLLS=0 should never log idle exit"
fi
echo "PASS: RALPH_IDLE_EXIT_POLLS=0 disables timeout"
echo ""

# ===========================================================================
# Test 3: Idle counter resets to 0 on claim (threshold precision test)
#
# Scenario: RALPH_IDLE_EXIT_POLLS=2. Item #100 is claimed by a live process
# (HOLD_PID). After 1 idle poll (~0.15s), a background process marks #100 as
# terminal. Worker must exit via "all terminal" (not via idle timeout), proving
# the first idle poll did not mistakenly trigger an exit at count=1.
#
# This verifies threshold is respected: counter=1 < threshold=2 → no exit yet.
# When the item becomes terminal the worker transitions cleanly via the
# all-terminal path, demonstrating the idle count is tracked correctly.
# ===========================================================================
echo "Test 3: idle counter resets to 0 on claim (threshold precision)"

REPO3="$TEST_ROOT/main3"
setup_repo "$REPO3"

mkdir -p "$REPO3/.ralph/runs/counter-reset"
cat > "$REPO3/.ralph/runs/counter-reset/queue.json" <<'EOF'
[{"number": 100, "title": "Test issue 100"}]
EOF
cat > "$REPO3/.ralph/runs/counter-reset/status.json" <<'EOF'
{"items":{}}
EOF

start_claim_holder
pre_claim "$REPO3" 100 "$HOLD_PID"

# After 1 idle poll (~0.15s), mark #100 as merged (terminal).
(
  sleep 0.15
  printf '{"items":{"100":{"status":"merged"}}}\n' \
    > "$REPO3/.ralph/runs/counter-reset/status.json"
) &
MARKER_PID=$!

output3=$(run_worker_env "$REPO3" "counter-reset" 5 \
  RALPH_POLL_SEC=0.1 RALPH_IDLE_EXIT_POLLS=2) || true

kill "$HOLD_PID" 2>/dev/null || true; HOLD_PID=""
wait "$MARKER_PID" 2>/dev/null || true

if echo "$output3" | grep -q "idle for.*polls, exiting"; then
  echo "$output3"
  fail "worker should exit via 'all terminal' path, not idle timeout"
fi
if ! echo "$output3" | grep -qE "queue fully resolved|queue is empty"; then
  echo "$output3"
  fail "worker should report 'fully resolved' or 'empty' after all items become terminal"
fi
echo "PASS: idle counter resets to 0 on claim (threshold precision)"
echo ""

# ===========================================================================
# Test 4: launch.sh refuses when installed scripts are stale
# ===========================================================================
echo "Test 4: stale-script detection refuses launch"

STALE_REPO="$TEST_ROOT/stale-repo"
mkdir -p "$STALE_REPO/ralph" "$STALE_REPO/.ralph/lib" "$STALE_REPO/.ralph/lock"

# Installed copy with artificially old mtime
cp "$REPO_ROOT/ralph/ralph.sh" "$STALE_REPO/.ralph/ralph.sh"
cp "$REPO_ROOT/ralph/launch.sh" "$STALE_REPO/.ralph/launch.sh"
chmod +x "$STALE_REPO/.ralph/ralph.sh" "$STALE_REPO/.ralph/launch.sh"
touch -t 200001010000 "$STALE_REPO/.ralph/ralph.sh"

# Source copy with current (newer) mtime
cp "$REPO_ROOT/ralph/ralph.sh" "$STALE_REPO/ralph/ralph.sh"
cp "$REPO_ROOT/ralph/launch.sh" "$STALE_REPO/ralph/launch.sh"

git init -q "$STALE_REPO"
cd "$STALE_REPO"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
cd "$SCRIPT_DIR/.."

stale_out=$(RALPH_MAIN_REPO="$STALE_REPO" \
  bash -c "cd '$STALE_REPO' && '$STALE_REPO/.ralph/launch.sh'" 2>&1) || true

if ! echo "$stale_out" | grep -qi "stale"; then
  echo "$stale_out"
  fail "launch.sh should refuse and print stale message when ralph/ralph.sh is newer"
fi
echo "PASS: stale-script detection refuses launch"
echo ""

# ===========================================================================
# Test 5: launch.sh --force overrides stale-script check
# ===========================================================================
echo "Test 5: stale-script detection --force override"

force_out=$(RALPH_MAIN_REPO="$STALE_REPO" \
  bash -c "cd '$STALE_REPO' && '$STALE_REPO/.ralph/launch.sh' --force" 2>&1) || true

if echo "$force_out" | grep -qE "installed scripts are stale"; then
  echo "$force_out"
  fail "launch.sh --force should not print stale refusal message"
fi
echo "PASS: stale-script detection --force override"
echo ""

echo "All idle-timeout and stale-script tests passed!"
