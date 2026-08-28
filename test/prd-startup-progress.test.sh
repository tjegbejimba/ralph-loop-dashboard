#!/usr/bin/env bash
# Verifies that normal PRD launch reports progress before remote initialization.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
LAUNCH_PID=""
trap '[[ -n "$LAUNCH_PID" ]] && kill "$LAUNCH_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

repo="$TEST_ROOT/main"
origin="$TEST_ROOT/origin.git"
bin="$TEST_ROOT/bin"
run_id="20260825-prd-startup-progress"
run_dir="$repo/.ralph/runs/$run_id"
marker="$TEST_ROOT/issue-view-started"
launch_log="$TEST_ROOT/launch.out"

mkdir -p "$repo" "$bin"
git init -q --bare "$origin"
git init -q "$repo"
git -C "$repo" checkout -qb main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
printf 'base\n' >"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm "base"
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q -u origin main

mkdir -p "$repo/.ralph/lib" "$run_dir"
cp "$REPO_ROOT/ralph/launch.sh" "$repo/.ralph/launch.sh"
cp "$REPO_ROOT/ralph/lib/state.sh" "$repo/.ralph/lib/state.sh"
cp "$REPO_ROOT/ralph/lib/status.sh" "$repo/.ralph/lib/status.sh"
cp "$REPO_ROOT/ralph/lib/prd-branch.sh" "$repo/.ralph/lib/prd-branch.sh"
chmod +x "$repo/.ralph/launch.sh"
cat >"$repo/.ralph/ralph.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$repo/.ralph/ralph.sh"
cat >"$repo/.ralph/config.json" <<'EOF'
{
  "issue": {"numbers": [506]},
  "prd": {
    "integrationBranchTemplate": "ralph/prd/{feature-slug}-{prd_number}",
    "remote": "origin",
    "deliveryBranch": "main"
  }
}
EOF
printf '<!-- RALPH_PRD_REF: #505 -->\n' >"$repo/.ralph/RALPH.md"
printf '[{"number":506,"title":"Leaf slice"}]\n' >"$run_dir/queue.json"
printf '{"items":{}}\n' >"$run_dir/status.json"

cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue view" && "$3" == "505" ]]; then
  : >"$GH_STARTED_MARKER"
  sleep 2
  printf '{"number":505,"title":"PRD startup progress","state":"OPEN"}\n'
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  printf '[]\n'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$bin/gh"

RALPH_MAIN_REPO="$repo" \
RALPH_LOOP_REPO="$TEST_ROOT/worker" \
RALPH_RUN_ID="$run_id" \
RALPH_RUN_DIR="$run_dir" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
GH_STARTED_MARKER="$marker" \
  "$repo/.ralph/launch.sh" --foreground --once >"$launch_log" 2>&1 &
LAUNCH_PID=$!

for _ in {1..100}; do
  [[ -f "$marker" ]] && break
  kill -0 "$LAUNCH_PID" 2>/dev/null \
    || { cat "$launch_log"; fail "launch exited before PRD initialization blocked"; }
  sleep 0.02
done
[[ -f "$marker" ]] || fail "PRD issue lookup did not start"

jq -e \
  '.phase == "setup-locks-acquired" and (.sequence | type == "number")' \
  "$run_dir/startup.json" >/dev/null \
  || { cat "$launch_log"; fail "setup-lock progress must precede PRD initialization"; }
jq -e '.items | length == 0' "$run_dir/status.json" >/dev/null \
  || fail "startup progress must not count as worker registration"

if ! wait "$LAUNCH_PID"; then
  LAUNCH_PID=""
  cat "$launch_log"
  fail "PRD launch should complete after initialization resumes"
fi
LAUNCH_PID=""

echo "PASS: normal PRD launch reports setup-lock progress before worker registration"

echo ""
echo "Test 2: healthy guarded ownership transfer keeps startup progress active"
slow_repo="$TEST_ROOT/slow-transfer-main"
slow_origin="$TEST_ROOT/slow-transfer-origin.git"
slow_bin="$TEST_ROOT/slow-transfer-bin"
prior_run="20260828-153824-5b0ab07d"
new_run="20260828-222049-4567b999"
branch="ralph/prd/prd-parent-tasks-hierarchy-and-leaf-first-execution-505"
prior_dir="$slow_repo/.ralph/runs/$prior_run"
new_dir="$slow_repo/.ralph/runs/$new_run"
worker_marker="$TEST_ROOT/slow-transfer-worker-started"
slow_log="$TEST_ROOT/slow-transfer-launch.out"
phases_file="$TEST_ROOT/slow-transfer-phases"
sequences_file="$TEST_ROOT/slow-transfer-sequences"

mkdir -p "$slow_repo" "$slow_bin"
git init -q --bare "$slow_origin"
git init -q "$slow_repo"
git -C "$slow_repo" checkout -qb main
git -C "$slow_repo" config user.email "test@example.com"
git -C "$slow_repo" config user.name "Test"
printf 'base\n' >"$slow_repo/README.md"
git -C "$slow_repo" add README.md
git -C "$slow_repo" commit -qm "base"
git -C "$slow_repo" remote add origin "$slow_origin"
git -C "$slow_repo" push -q -u origin main
base=$(git -C "$slow_repo" rev-parse HEAD)
git -C "$slow_repo" branch "$branch" "$base"
git -C "$slow_repo" push -q origin "$branch"

mkdir -p "$slow_repo/.ralph/lib" "$prior_dir" "$new_dir"
cp "$REPO_ROOT/ralph/launch.sh" "$slow_repo/.ralph/launch.sh"
cp "$REPO_ROOT/ralph/lib/state.sh" "$slow_repo/.ralph/lib/state.sh"
cp "$REPO_ROOT/ralph/lib/status.sh" "$slow_repo/.ralph/lib/status.sh"
cp "$REPO_ROOT/ralph/lib/prd-branch.sh" "$slow_repo/.ralph/lib/prd-branch.sh"
chmod +x "$slow_repo/.ralph/launch.sh"
cat >"$slow_repo/.ralph/ralph.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'worker-started\n' >"$SLOW_WORKER_MARKER"
EOF
chmod +x "$slow_repo/.ralph/ralph.sh"
cat >"$slow_repo/.ralph/config.json" <<'EOF'
{
  "issue": {"numbers": [509]},
  "prd": {
    "integrationBranchTemplate": "ralph/prd/{feature-slug}-{prd_number}",
    "remote": "origin",
    "deliveryBranch": "main"
  }
}
EOF
printf '<!-- RALPH_PRD_REF: #505 -->\n' >"$slow_repo/.ralph/RALPH.md"
printf '[{"number":508,"title":"Prior slice"}]\n' >"$prior_dir/queue.json"
printf '{"items":{"508":{"status":"slice-integrated","pid":null,"integrated_commit":"%s"}}}\n' \
  "$base" >"$prior_dir/status.json"
printf '[{"number":509,"title":"New slice"}]\n' >"$new_dir/queue.json"
printf '{"items":{}}\n' >"$new_dir/status.json"
jq -n \
  --arg run "$prior_run" \
  --arg branch "$branch" \
  --arg base "$base" \
  '{
    run_id: $run,
    prd_number: "505",
    branch_name: $branch,
    remote: "origin",
    delivery_branch: "main",
    initial_base_sha: $base,
    owned_tip_sha: $base,
    created_at: "2026-08-28T15:38:24Z"
  }' >"$prior_dir/ownership.json"
jq -n \
  --arg run "$prior_run" \
  '{claims:{},active_prd:"505",active_run_id:$run}' \
  >"$slow_repo/.ralph/state.json"

cat >"$slow_bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue view" && "$3" == "505" ]]; then
  printf '{"number":505,"title":"PRD parent tasks hierarchy and leaf-first execution","state":"OPEN"}\n'
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  sleep 0.35
  printf '[]\n'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$slow_bin/gh"
real_git=$(command -v git)
cat >"$slow_bin/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "ls-remote" || "$arg" == "fetch" ]]; then
    sleep 0.35
    break
  fi
done
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$slow_bin/git"

PATH="$slow_bin:$PATH" \
REAL_GIT_BIN="$real_git" \
RALPH_MAIN_REPO="$slow_repo" \
RALPH_LOOP_REPO="$TEST_ROOT/slow-transfer-worker" \
RALPH_RUN_ID="$new_run" \
RALPH_RUN_DIR="$new_dir" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$slow_bin/gh" \
SLOW_WORKER_MARKER="$worker_marker" \
  "$slow_repo/.ralph/launch.sh" --foreground --once >"$slow_log" 2>&1 &
LAUNCH_PID=$!

last_startup=""
idle_ticks=0
completed=0
: >"$phases_file"
: >"$sequences_file"
for _ in {1..400}; do
  if [[ -f "$new_dir/startup.json" ]]; then
    startup=$(cat "$new_dir/startup.json")
    if [[ "$startup" != "$last_startup" ]]; then
      last_startup="$startup"
      idle_ticks=0
      printf '%s\n' "$(printf '%s\n' "$startup" | jq -r '.phase')" >>"$phases_file"
      printf '%s\n' "$(printf '%s\n' "$startup" | jq -r '.sequence')" >>"$sequences_file"
    else
      idle_ticks=$((idle_ticks + 1))
    fi
  fi
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    completed=1
    break
  fi
  if [[ "$idle_ticks" -ge 50 ]]; then
    kill "$LAUNCH_PID" 2>/dev/null || true
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""
    cat "$slow_log"
    fail "healthy ownership transfer exceeded the startup inactivity deadline after phases: $(paste -sd, "$phases_file")"
  fi
  sleep 0.02
done
[[ "$completed" -eq 1 ]] || {
  kill "$LAUNCH_PID" 2>/dev/null || true
  wait "$LAUNCH_PID" 2>/dev/null || true
  LAUNCH_PID=""
  fail "healthy ownership transfer exceeded the startup hard cap"
}
if ! wait "$LAUNCH_PID"; then
  LAUNCH_PID=""
  cat "$slow_log"
  fail "healthy ownership transfer should complete"
fi
LAUNCH_PID=""
[[ -f "$worker_marker" ]] || fail "healthy ownership transfer should reach the worker"
jq -e \
  --arg run "$new_run" \
  '.retired_by_run_id == $run
   and .retirement_reason == "terminal PRD ownership transferred"' \
  "$prior_dir/ownership.json" >/dev/null \
  || fail "healthy ownership transfer should retire prior ownership durably"
awk 'NR > 1 && $1 <= previous { exit 1 } { previous = $1 }' "$sequences_file" \
  || fail "startup progress sequence must increase monotonically across ownership recovery"

echo "PASS: healthy guarded ownership transfer keeps startup progress active"
