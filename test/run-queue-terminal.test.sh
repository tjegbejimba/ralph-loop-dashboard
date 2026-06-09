#!/usr/bin/env bash
# Integration test for run-aware worker exit when queues are empty or terminal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

run_worker() {
  local run_id="$1"
  local output_file="$TEST_ROOT/${run_id}.out"
  (
    cd "$TEST_ROOT/main"
    RALPH_REPO="testowner/testrepo" \
      RALPH_RUN_ID="$run_id" \
      RALPH_POLL_SEC=1 \
    RALPH_GH_BIN="$TEST_ROOT/bin/gh" \
    PATH="$TEST_ROOT/bin:$PATH" \
    .ralph/ralph.sh
  ) >"$output_file" 2>&1 &
  local pid=$!

  for _ in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      cat "$output_file"
      return 0
    fi
    sleep 0.25
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$output_file"
  return 124
}

mkdir -p "$TEST_ROOT/main" "$TEST_ROOT/origin.git"
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "issue view 200")
    printf '{"state":"OPEN","labels":[],"body":""}\n'
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

mkdir -p .ralph/lib .ralph/runs/empty .ralph/runs/all-terminal .ralph/runs/unsafe
cp "$REPO_ROOT/ralph/ralph.sh" .ralph/ralph.sh
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
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

cat > .ralph/runs/empty/queue.json <<'EOF'
[]
EOF
cat > .ralph/runs/empty/status.json <<'EOF'
{"items":{}}
EOF

cat > .ralph/runs/all-terminal/queue.json <<'EOF'
[
  {"number": 100, "title": "Test issue 100"},
  {"number": 101, "title": "Test issue 101"},
  {"number": 102, "title": "Test issue 102"}
]
EOF
cat > .ralph/runs/all-terminal/status.json <<'EOF'
{
  "items": {
    "100": {"status": "merged"},
    "101": {"status": "failed"},
    "102": {"status": "skipped"}
  }
}
EOF
cat > .ralph/runs/unsafe/queue.json <<'EOF'
[
  {"number": 200, "title": "Test issue 200"}
]
EOF
cat > .ralph/runs/unsafe/status.json <<'EOF'
{"items":{}}
EOF

echo "Test 1: empty run queue exits cleanly"
empty_output=$(run_worker empty) || fail "empty queue worker should exit cleanly"
if ! grep -q "queue is empty. Done." <<<"$empty_output"; then
  echo "$empty_output"
  fail "empty queue worker should report queue is empty"
fi
echo "PASS: empty run queue exits cleanly"

echo ""
echo "Test 2: all-terminal run queue exits cleanly"
terminal_output=$(run_worker all-terminal) || fail "all-terminal worker should exit cleanly"
if ! grep -q "queue fully resolved (3/3 terminal). Done." <<<"$terminal_output"; then
  echo "$terminal_output"
  fail "all-terminal worker should report fully resolved queue"
fi
echo "PASS: all-terminal run queue exits cleanly"

echo ""
echo "Test 3: unsafe run queue item is failed instead of claimed"
unsafe_output=$(run_worker unsafe) || fail "unsafe queue worker should exit cleanly after failing unsafe item"
if ! grep -q "missing ready-for-agent; marked as failed" <<<"$unsafe_output"; then
  echo "$unsafe_output"
  fail "unsafe queue worker should report missing ready-for-agent"
fi
unsafe_status=$(jq -r '.items["200"].status' "$TEST_ROOT/main/.ralph/runs/unsafe/status.json")
unsafe_error=$(jq -r '.items["200"].error' "$TEST_ROOT/main/.ralph/runs/unsafe/status.json")
if [[ "$unsafe_status" != "failed" || "$unsafe_error" != "Issue is missing ready-for-agent" ]]; then
  cat "$TEST_ROOT/main/.ralph/runs/unsafe/status.json"
  fail "unsafe issue should be terminal failed with AFK guard error"
fi
echo "PASS: unsafe run queue item is failed instead of claimed"

echo ""
echo "All run queue terminal tests passed!"
