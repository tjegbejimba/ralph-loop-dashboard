#!/usr/bin/env bash
# Integration coverage for fail-closed stale PRD integration-branch recovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
LIVE_PID=""
CLEANUP_PID=""
trap '[[ -n "$LIVE_PID" ]] && kill "$LIVE_PID" 2>/dev/null || true; [[ -n "$CLEANUP_PID" ]] && kill "$CLEANUP_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

create_fixture() {
  local name="$1"
  local repo="$TEST_ROOT/$name/main"
  local origin="$TEST_ROOT/$name/origin.git"
  local bin="$TEST_ROOT/$name/bin"
  local prior_run="20260824-224754-5295ed25"
  local branch="ralph/prd/prd-parent-tasks-hierarchy-and-leaf-first-execution-505"

  mkdir -p "$TEST_ROOT/$name" "$bin"
  git init -q --bare "$origin"
  git init -q "$repo"
  git -C "$repo" checkout -qb main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "frozen base" >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "frozen base"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main

  local base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" branch "$branch" "$base"

  mkdir -p \
    "$repo/.ralph/lib" \
    "$repo/.ralph/logs" \
    "$repo/.ralph/lock" \
    "$repo/.ralph/runs/$prior_run"
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
  printf '{"claims":{}}\n' >"$repo/.ralph/state.json"
  printf '[{"number":506,"title":"Leaf slice"}]\n' \
    >"$repo/.ralph/runs/$prior_run/queue.json"
  printf '{"items":{"506":{"status":"failed","pid":null}}}\n' \
    >"$repo/.ralph/runs/$prior_run/status.json"
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
      created_at: "2026-08-24T22:47:54Z"
    }' >"$repo/.ralph/runs/$prior_run/ownership.json"

  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  case "${GH_PR_MODE:-empty}" in
    empty) printf '[]\n' ;;
    exists) printf '[{"number":520}]\n' ;;
    fail) echo "simulated GitHub failure" >&2; exit 1 ;;
  esac
  exit 0
fi
if [[ "$1 $2" == "issue view" && "$3" == "505" ]]; then
  printf '{"number":505,"title":"PRD parent tasks hierarchy and leaf-first execution","state":"OPEN"}\n'
  exit 0
fi
echo "unhandled gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$bin/gh"

  printf '%s\n' "$repo|$origin|$bin|$prior_run|$branch|$base"
}

assert_branch_exists() {
  local repo="$1" branch="$2" context="$3"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "$context should preserve the PRD branch"
}

echo "Test 1: --cleanup retires an eligible stale PRD integration branch"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture cleanup)
mkdir -p "$repo/.ralph/launch.lock" "$repo/.git/ralph-launch.lock"
printf '999999\n' >"$repo/.ralph/launch.lock/owner"
printf '999999\n' >"$repo/.git/ralph-launch.lock/owner"
cleanup_output=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$repo/.ralph/launch.sh" --cleanup 2>&1
) || {
  echo "$cleanup_output"
  fail "eligible stale PRD cleanup should succeed"
}
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "$cleanup_output"
  fail "eligible stale PRD branch should be retired"
fi
[[ ! -d "$repo/.ralph/launch.lock" && ! -d "$repo/.git/ralph-launch.lock" ]] \
  || fail "cleanup should hold and release both launcher setup locks"
jq -e \
  '.retired_at != null
   and .retired_by_run_id == "cleanup"
   and .retirement_reason == "terminal stale PRD integration branch"' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "cleanup should durably retire prior ownership"
echo "PASS: --cleanup retires an eligible stale PRD integration branch"

echo ""
echo "Test 2: --cleanup waits for the shared launcher setup lock"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture serialized)
mkdir -p "$repo/.git/ralph-launch.lock"
printf '%s\n' "$$" >"$repo/.git/ralph-launch.lock/owner"
cleanup_log="$TEST_ROOT/serialized/cleanup.out"
RALPH_MAIN_REPO="$repo" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
  "$repo/.ralph/launch.sh" --cleanup >"$cleanup_log" 2>&1 &
CLEANUP_PID=$!
sleep 1
kill -0 "$CLEANUP_PID" 2>/dev/null \
  || fail "cleanup should wait while another launcher owns the common-gitdir lock"
assert_branch_exists "$repo" "$branch" "serialized cleanup"
rm -f "$repo/.git/ralph-launch.lock/owner"
rmdir "$repo/.git/ralph-launch.lock"
if ! wait "$CLEANUP_PID"; then
  cat "$cleanup_log"
  fail "cleanup should continue after the shared launcher lock is released"
fi
CLEANUP_PID=""
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  cat "$cleanup_log"
  fail "serialized cleanup should retire the stale branch after lock release"
fi
echo "PASS: --cleanup serializes branch retirement with fresh launch setup"

echo ""
echo "Test 3: a fresh launch retires stale ownership and reinitializes from current main"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture relaunch)
echo "advanced main" >>"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm "advance main"
git -C "$repo" push -q origin main
current_base=$(git -C "$repo" rev-parse HEAD)
new_run="20260825-014856-6852b6b1"
new_run_dir="$repo/.ralph/runs/$new_run"
mkdir -p "$new_run_dir"
printf '[{"number":506,"title":"Leaf slice"}]\n' >"$new_run_dir/queue.json"
printf '{"items":{}}\n' >"$new_run_dir/status.json"
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
cat >"$repo/.ralph/ralph.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
test "\$(git -C "\$RALPH_MAIN_REPO" rev-parse "$branch")" = "$current_base"
jq -e --arg run "\$RALPH_RUN_ID" \
  '.run_id == \$run and .branch_name == "$branch" and .initial_base_sha == "$current_base"' \
  "\$RALPH_MAIN_REPO/.ralph/runs/\$RALPH_RUN_ID/ownership.json" >/dev/null
printf 'worker-started\n' >"\$RALPH_MAIN_REPO/.ralph/worker-started"
EOF
chmod +x "$repo/.ralph/ralph.sh"
launch_output=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_LOOP_REPO="$TEST_ROOT/relaunch/loop" \
  RALPH_RUN_ID="$new_run" \
  RALPH_RUN_DIR="$new_run_dir" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$repo/.ralph/launch.sh" --foreground --once 2>&1
) || {
  echo "$launch_output"
  fail "fresh PRD launch should recover an eligible stale integration branch"
}
[[ -f "$repo/.ralph/worker-started" ]] \
  || fail "fresh launch should reach the worker after recovery"
jq -e --arg run "$new_run" \
  '.retired_by_run_id == $run' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "fresh launch should attribute retirement to the new run"
echo "PASS: fresh launch safely reinitializes the stale PRD integration branch"

echo ""
echo "Test 4: a branchless stale ownership record cannot be bypassed"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture branchless)
git -C "$repo" update-ref -d "refs/heads/$branch" "$base"
new_run="20260825-branchless-recovery"
mkdir -p "$repo/.ralph/runs/$new_run"
(
  cd "$repo"
  LOG_DIR="$repo/.ralph/logs"
  REPO="test/example"
  GH="$bin/gh"
  . "$repo/.ralph/lib/state.sh"
  . "$repo/.ralph/lib/status.sh"
  . "$repo/.ralph/lib/prd-branch.sh"
  recover_stale_prd_branch "$new_run" "505" "$branch" "origin" "main"
  create_prd_branch \
    "$new_run" \
    "505" \
    "PRD parent tasks hierarchy and leaf-first execution" \
    "origin" \
    "main" \
    "ralph/prd/{feature-slug}-{prd_number}"
)
jq -e --arg run "$new_run" '.retired_by_run_id == $run' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "branchless stale ownership should be retired before reinitialization"
git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
  || fail "branchless recovery should create the newly-owned branch"
jq -e --arg run "$new_run" '.run_id == $run and .retired_at == null' \
  "$repo/.ralph/runs/$new_run/ownership.json" >/dev/null \
  || fail "branchless recovery should create one active ownership record"
echo "PASS: branchless stale ownership is proven terminal before reinitialization"

echo ""
echo "Test 5: every unsafe condition hard-stops retirement"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture guards)
LOG_DIR="$repo/.ralph/logs"
REPO="test/example"
GH="$bin/gh"
cd "$repo"
. "$repo/.ralph/lib/state.sh"
. "$repo/.ralph/lib/status.sh"
. "$repo/.ralph/lib/prd-branch.sh"

reset_guard_fixture() {
  local extra_worktree="$TEST_ROOT/guards/branch-worktree"
  if [[ -d "$extra_worktree" ]]; then
    git -C "$repo" worktree remove "$extra_worktree" >/dev/null 2>&1 || true
  fi
  git -C "$repo" update-ref "refs/heads/$branch" "$base"
  git -C "$repo" push -q origin --delete "$branch" >/dev/null 2>&1 || true
  printf '{"claims":{}}\n' >"$repo/.ralph/state.json"
  printf '[{"number":506,"title":"Leaf slice"}]\n' \
    >"$repo/.ralph/runs/$prior_run/queue.json"
  printf '{"items":{"506":{"status":"failed","pid":null}}}\n' \
    >"$repo/.ralph/runs/$prior_run/status.json"
  jq 'del(.retired_at, .retired_by_run_id, .retirement_reason)' \
    "$repo/.ralph/runs/$prior_run/ownership.json" \
    >"$repo/.ralph/runs/$prior_run/ownership.tmp"
  mv "$repo/.ralph/runs/$prior_run/ownership.tmp" \
    "$repo/.ralph/runs/$prior_run/ownership.json"
  export GH_PR_MODE=empty
}

expect_guard() {
  local expected="$1"
  local output status
  set +e
  output=$(retire_owned_prd_branch "$prior_run" "replacement-run" 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$expected should block retirement"
  assert_branch_exists "$repo" "$branch" "$expected"
  grep -Fq "$expected" <<<"$output" || {
    echo "$output"
    fail "expected diagnostic containing '$expected'"
  }
}

reset_guard_fixture
printf '{"items":{"506":{"status":"running","pid":999999}}}\n' \
  >"$repo/.ralph/runs/$prior_run/status.json"
expect_guard "is not terminal"

reset_guard_fixture
printf '[{"number":506}]\n[{"number":506}]\n' \
  >"$repo/.ralph/runs/$prior_run/queue.json"
expect_guard "is not terminal"

reset_guard_fixture
printf '{"items":{"506":{"status":"failed","pid":"not-a-pid"}}}\n' \
  >"$repo/.ralph/runs/$prior_run/status.json"
expect_guard "is not terminal"

reset_guard_fixture
printf '{"items":{"506":{"status":"failed","pid":false}}}\n' \
  >"$repo/.ralph/runs/$prior_run/status.json"
expect_guard "is not terminal"

reset_guard_fixture
cat >"$TEST_ROOT/guards/live-ralph.sh" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
chmod +x "$TEST_ROOT/guards/live-ralph.sh"
"$TEST_ROOT/guards/live-ralph.sh" &
LIVE_PID=$!
printf '{"items":{"506":{"status":"failed","pid":%s}}}\n' "$LIVE_PID" \
  >"$repo/.ralph/runs/$prior_run/status.json"
expect_guard "still has a live worker"
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
LIVE_PID=""

reset_guard_fixture
"$TEST_ROOT/guards/live-ralph.sh" &
LIVE_PID=$!
printf '{"claims":{"506":{"workerId":1,"pid":%s}}}\n' "$LIVE_PID" \
  >"$repo/.ralph/state.json"
expect_guard "still has a live claim"
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
LIVE_PID=""

reset_guard_fixture
printf '{"claims":{"506":{"workerId":1,"pid":null}}}\n' \
  >"$repo/.ralph/state.json"
expect_guard "still has a live claim"

reset_guard_fixture
git -C "$repo" worktree add -q "$TEST_ROOT/guards/branch-worktree" "$branch"
expect_guard "is checked out by a worktree"

reset_guard_fixture
export GH_PR_MODE=exists
expect_guard "still has a pull request"

reset_guard_fixture
git -C "$repo" push -q origin "$branch"
expect_guard "still exists on remote"

reset_guard_fixture
tree=$(git -C "$repo" rev-parse "${base}^{tree}")
delivery_commit=$(printf 'unmerged delivery\n' | git -C "$repo" commit-tree "$tree" -p "$base")
git -C "$repo" update-ref "refs/heads/$branch" "$delivery_commit"
expect_guard "contains delivery beyond frozen base"

reset_guard_fixture
export GH_PR_MODE=fail
expect_guard "could not verify pull requests"

reset_guard_fixture
current_run="replacement-run"
mkdir -p "$repo/.ralph/runs/$current_run"
jq --arg run "$current_run" '.run_id = $run' \
  "$repo/.ralph/runs/$prior_run/ownership.json" \
  >"$repo/.ralph/runs/$current_run/ownership.json"
set +e
ambiguous_output=$(
  recover_stale_prd_branch \
    "$current_run" "505" "$branch" "origin" "main" 2>&1
)
ambiguous_status=$?
set -e
[[ "$ambiguous_status" -ne 0 ]] \
  || fail "current-run ownership must not bypass another active owner"
grep -Fq "ambiguous ownership" <<<"$ambiguous_output" \
  || fail "current-run ownership ambiguity should be diagnosed"
assert_branch_exists "$repo" "$branch" "ambiguous current ownership"
rm -rf "$repo/.ralph/runs/$current_run"

reset_guard_fixture
ownership_file="$repo/.ralph/runs/$prior_run/ownership.json"
cp "$ownership_file" "$ownership_file.before-cross-prd"
jq '.prd_number = "999"' "$ownership_file" >"$ownership_file.tmp"
mv "$ownership_file.tmp" "$ownership_file"
set +e
cross_prd_output=$(
  recover_stale_prd_branch \
    "replacement-run" "505" "$branch" "origin" "main" 2>&1
)
cross_prd_status=$?
set -e
[[ "$cross_prd_status" -ne 0 ]] \
  || fail "fresh run must not adopt a branch owned by another PRD"
grep -Fq "different PRD or repository settings" <<<"$cross_prd_output" \
  || fail "cross-PRD ownership refusal should be diagnosed"
assert_branch_exists "$repo" "$branch" "cross-PRD ownership"
mv "$ownership_file.before-cross-prd" "$ownership_file"

reset_guard_fixture
printf '{"claims":{},"active_prd":"505","active_run_id":"%s"}\n' "$prior_run" \
  >"$repo/.ralph/state.json"
set +e
rollback_output=$(
  state_mktemp() { return 1; }
  retire_owned_prd_branch "$prior_run" "replacement-run" 2>&1
)
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]] \
  || fail "state-update failure should fail branch retirement"
grep -Fq "branchless ownership remains recoverable" <<<"$rollback_output" \
  || fail "state-update failure should report recoverable branchless ownership"
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  fail "state-update failure should leave a branchless active ownership record"
fi
jq -e \
  --arg run "$prior_run" \
  '.run_id == $run and .retired_at == null' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "state-update failure should restore prior ownership"
jq -e \
  --arg run "$prior_run" \
  '.active_prd == "505" and .active_run_id == $run' \
  "$repo/.ralph/state.json" >/dev/null \
  || fail "state-update failure should preserve active PRD metadata"
retire_owned_prd_branch "$prior_run" "replacement-run" >/dev/null \
  || fail "branchless ownership should retry without manual branch deletion"

reset_guard_fixture
mkdir -p "$repo/.ralph/runs/malformed"
printf '{not-json\n' >"$repo/.ralph/runs/malformed/ownership.json"
expect_guard "Could not validate PRD ownership evidence"

rm -rf "$repo/.ralph/runs/malformed"
reset_guard_fixture
ownership_file="$repo/.ralph/runs/$prior_run/ownership.json"
cp "$ownership_file" "$ownership_file.single"
cat "$ownership_file.single" "$ownership_file.single" >"$ownership_file"
expect_guard "Could not validate PRD ownership evidence"
mv "$ownership_file.single" "$ownership_file"

echo "PASS: terminal, live-run, claim, worktree, PR, remote, delivery, and evidence guards fail closed"
echo ""
echo "All stale PRD branch recovery tests passed!"
