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
echo "Test 2: --cleanup retires an ownership-created run that never registered a worker"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture zero-registration)
printf '{"items":{}}\n' >"$repo/.ralph/runs/$prior_run/status.json"
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
  fail "zero-registration PRD cleanup should succeed after proving abandonment"
}
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "$cleanup_output"
  fail "zero-registration PRD branch should be retired"
fi
jq -e \
  '.retired_at != null
   and .retired_by_run_id == "cleanup"
   and .retirement_reason
     == "abandoned before worker registration (zero-item guarded recovery)"' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "zero-registration retirement should record its distinct reason"
echo "PASS: --cleanup recovers an ownership-created zero-registration crash"

echo ""
echo "Test 2c: --cleanup preserves published PRD ownership without failing"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture published-cleanup)
git -C "$repo" push -q origin "$branch"
cleanup_output=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$repo/.ralph/launch.sh" --cleanup 2>&1
) || {
  echo "$cleanup_output"
  fail "published PRD cleanup should skip preserved ownership successfully"
}
assert_branch_exists "$repo" "$branch" "published cleanup"
[[ "$(git -C "$repo" ls-remote --heads origin "refs/heads/$branch" | awk '{print $1}')" == "$base" ]] \
  || fail "published cleanup should preserve the remote PRD branch"
jq -e '.retired_at == null' "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "published cleanup should preserve active ownership for same-PRD recovery"
grep -Fq "preserving it for same-PRD recovery" <<<"$cleanup_output" \
  || fail "published cleanup should report its non-destructive skip"
echo "PASS: --cleanup treats published PRD ownership as a safe skip"

echo ""
echo "Test 2d: --cleanup waits for the shared launcher setup lock"
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
echo "Test 3: a fresh launch transfers a published branch without deleting delivery history"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture relaunch)
tree=$(git -C "$repo" rev-parse "${base}^{tree}")
delivered_tip=$(
  printf 'delivered PRD work\n' |
    git -C "$repo" commit-tree "$tree" -p "$base"
)
git -C "$repo" push -q origin \
  "$delivered_tip:refs/heads/$branch"
printf '{"items":{"506":{"status":"slice-integrated","pid":null,"integrated_commit":"%s"}}}\n' \
  "$delivered_tip" >"$repo/.ralph/runs/$prior_run/status.json"
echo "advanced main" >>"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm "advance main"
git -C "$repo" push -q origin main
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
test "\$(git -C "\$RALPH_MAIN_REPO" rev-parse "$branch")" = "$delivered_tip"
test "\$(git -C "\$RALPH_MAIN_REPO" ls-remote --heads origin "refs/heads/$branch" | awk '{print \$1}')" = "$delivered_tip"
jq -e --arg run "\$RALPH_RUN_ID" \
  '.run_id == \$run
   and .branch_name == "$branch"
   and .initial_base_sha == "$base"
   and .owned_tip_sha == "$delivered_tip"
   and .resumed_from_run_id == "$prior_run"' \
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
  --arg tip "$delivered_tip" \
  '.retired_by_run_id == $run
   and .retirement_reason == "terminal PRD ownership transferred"
   and .transferred_tip_sha == $tip' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "fresh launch should durably transfer prior ownership"
echo "PASS: fresh launch safely transfers the published PRD integration branch"

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
echo "Test 4b: a later run completes an interrupted ownership transfer without rewriting history"
IFS='|' read -r repo origin bin prior_run branch base < <(create_fixture interrupted-transfer)
tree=$(git -C "$repo" rev-parse "${base}^{tree}")
delivered_tip=$(
  printf 'delivered before interrupted transfer\n' |
    git -C "$repo" commit-tree "$tree" -p "$base"
)
git -C "$repo" push -q origin \
  "$delivered_tip:refs/heads/$branch"
printf '{"items":{"506":{"status":"slice-integrated","pid":null,"integrated_commit":"%s"}}}\n' \
  "$delivered_tip" >"$repo/.ralph/runs/$prior_run/status.json"
staged_run="20260825-staged-transfer"
successor_run="20260825-successor-transfer"
for run_id in "$staged_run" "$successor_run"; do
  mkdir -p "$repo/.ralph/runs/$run_id"
  printf '[{"number":506,"title":"Leaf slice"}]\n' \
    >"$repo/.ralph/runs/$run_id/queue.json"
  printf '{"items":{}}\n' >"$repo/.ralph/runs/$run_id/status.json"
done
printf '{"claims":{},"active_prd":"505","active_run_id":"%s"}\n' "$prior_run" \
  >"$repo/.ralph/state.json"
mkdir -p "$repo/.ralph/launch.lock" "$repo/.git/ralph-launch.lock"
printf '%s\n' "$$" >"$repo/.ralph/launch.lock/owner"
printf '%s\n' "$$" >"$repo/.git/ralph-launch.lock/owner"
LOG_DIR="$repo/.ralph/logs"
REPO="test/example"
GH="$bin/gh"
cd "$repo"
. "$repo/.ralph/lib/state.sh"
. "$repo/.ralph/lib/status.sh"
. "$repo/.ralph/lib/prd-branch.sh"
scoped_ralph_processes() {
  return 0
}

set +e
interrupted_transfer_output=$(
  state_mktemp() {
    return 1
  }
  recover_stale_prd_branch \
    "$staged_run" "505" "$branch" "origin" "main" 2>&1
)
interrupted_transfer_status=$?
set -e
[[ "$interrupted_transfer_status" -ne 0 ]] \
  || fail "injected activation-state failure should interrupt ownership transfer"
jq -e \
  --arg run "$staged_run" \
  '.retired_at == null and .transfer_pending.new_run_id == $run' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "interrupted transfer should preserve staged prior ownership"
jq -e \
  --arg run "$staged_run" \
  --arg prior "$prior_run" \
  '.run_id == $run and .resumed_from_run_id == $prior and .retired_at == null' \
  "$repo/.ralph/runs/$staged_run/ownership.json" >/dev/null \
  || fail "interrupted transfer should preserve staged new ownership"

recover_stale_prd_branch \
  "$successor_run" "505" "$branch" "origin" "main" >/dev/null \
  || fail "a later run should complete and succeed the interrupted transfer"
jq -e \
  --arg run "$staged_run" \
  '.retired_by_run_id == $run
   and .retirement_reason == "terminal PRD ownership transferred"' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "later recovery should finalize the originally staged handoff"
jq -e \
  --arg run "$successor_run" \
  '.retired_by_run_id == $run
   and .retirement_reason == "zero-registration PRD ownership transferred"' \
  "$repo/.ralph/runs/$staged_run/ownership.json" >/dev/null \
  || fail "later recovery should preserve the audit chain through the staged run"
jq -e \
  --arg run "$successor_run" \
  --arg prior "$staged_run" \
  --arg tip "$delivered_tip" \
  '.run_id == $run
   and .resumed_from_run_id == $prior
   and .owned_tip_sha == $tip
   and .retired_at == null' \
  "$repo/.ralph/runs/$successor_run/ownership.json" >/dev/null \
  || fail "later recovery should leave one successor ownership record"
[[ "$(git -C "$repo" ls-remote --heads origin "refs/heads/$branch" | awk '{print $1}')" == "$delivered_tip" ]] \
  || fail "interrupted transfer recovery must preserve the published branch"
[[ "$(git -C "$repo" rev-parse "refs/heads/$branch")" == "$base" ]] \
  || fail "ownership recovery must not rewrite a lagging local ref before branch setup"
echo "PASS: interrupted transfer is completed through a guarded ownership chain"

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

# Direct seam tests model launch.sh after it has successfully inspected the
# process table. Integration tests above exercise the real implementation.
scoped_ralph_processes() {
  return 0
}

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  current_winpid=$(ps -p "$$" -l | awk '
    NR > 1 && $1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $4; exit }
  ')
  prd_launcher_pid_is_current "$current_winpid" \
    || fail "native Windows launcher PID should map to the current Bash process"
else
  prd_launcher_pid_is_current "$$" \
    || fail "POSIX launcher PID should match the current Bash process"
fi

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
git -C "$repo" push -q origin "$branch"
export GH_PR_MODE=exists
set +e
transfer_pr_output=$(
  recover_stale_prd_branch \
    "replacement-run" "505" "$branch" "origin" "main" 2>&1
)
transfer_pr_status=$?
set -e
[[ "$transfer_pr_status" -ne 0 ]] \
  || fail "published ownership with PR evidence must not transfer"
grep -Fq "still has a pull request" <<<"$transfer_pr_output" \
  || fail "transfer refusal should diagnose conflicting PR evidence"
assert_branch_exists "$repo" "$branch" "published PR evidence"

reset_guard_fixture
tree=$(git -C "$repo" rev-parse "${base}^{tree}")
rewritten_remote_tip=$(
  printf 'rewritten remote\n' | git -C "$repo" commit-tree "$tree"
)
git -C "$repo" push -q --force origin \
  "$rewritten_remote_tip:refs/heads/$branch"
set +e
transfer_rewrite_output=$(
  recover_stale_prd_branch \
    "replacement-run" "505" "$branch" "origin" "main" 2>&1
)
transfer_rewrite_status=$?
set -e
[[ "$transfer_rewrite_status" -ne 0 ]] \
  || fail "non-descendant remote movement must not transfer ownership"
grep -Eq "does not descend|differs from remote" <<<"$transfer_rewrite_output" \
  || fail "remote movement refusal should be diagnosed"
assert_branch_exists "$repo" "$branch" "rewritten remote history"

reset_guard_fixture
tree=$(git -C "$repo" rev-parse "${base}^{tree}")
delivery_commit=$(printf 'unmerged delivery\n' | git -C "$repo" commit-tree "$tree" -p "$base")
git -C "$repo" update-ref "refs/heads/$branch" "$delivery_commit"
expect_guard "contains delivery beyond frozen base"

reset_zero_registration_fixture() {
  local worker_worktree="$TEST_ROOT/guards/worker-worktree"
  if [[ -d "$worker_worktree" ]]; then
    git -C "$repo" worktree remove -f "$worker_worktree" >/dev/null 2>&1 || true
  fi
  git -C "$repo" branch -D ralph-loop-fixture >/dev/null 2>&1 || true
  reset_guard_fixture
  rm -rf "$repo/.ralph/launch.lock" "$repo/.git/ralph-launch.lock"
  rm -f \
    "$repo/.ralph/launcher.pid" \
    "$repo/.ralph/runs/$prior_run/copilot-sessions.jsonl"
  printf '{"items":{}}\n' >"$repo/.ralph/runs/$prior_run/status.json"
  mkdir -p "$repo/.ralph/launch.lock" "$repo/.git/ralph-launch.lock"
  printf '%s\n' "$$" >"$repo/.ralph/launch.lock/owner"
  printf '%s\n' "$$" >"$repo/.git/ralph-launch.lock/owner"
}

reset_zero_registration_fixture
printf '{"items":{"506":{"status":"running","workerId":1,"pid":999999}}}\n' \
  >"$repo/.ralph/runs/$prior_run/status.json"
expect_guard "worker registration evidence"

reset_zero_registration_fixture
printf '{"claims":{"506":{"workerId":1,"pid":999999}}}\n' \
  >"$repo/.ralph/state.json"
expect_guard "explicit empty claim evidence"

reset_zero_registration_fixture
printf '{"event":"start","sessionId":"fixture"}\n' \
  >"$repo/.ralph/runs/$prior_run/copilot-sessions.jsonl"
expect_guard "Copilot session registration evidence"

reset_zero_registration_fixture
scoped_ralph_processes() {
  printf '123 fixture-ralph-process\n'
}
expect_guard "still has a live Ralph process"

reset_zero_registration_fixture
scoped_ralph_processes() {
  return 1
}
expect_guard "could not inspect Ralph process evidence"
scoped_ralph_processes() {
  return 0
}

reset_zero_registration_fixture
git -C "$repo" worktree add -q -b ralph-loop-fixture \
  "$TEST_ROOT/guards/worker-worktree" "$base"
expect_guard "Ralph worker worktree"

reset_zero_registration_fixture
"$TEST_ROOT/guards/live-ralph.sh" &
LIVE_PID=$!
printf '%s\n' "$LIVE_PID" >"$repo/.ralph/launcher.pid"
expect_guard "exclusive launcher shutdown evidence"
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
LIVE_PID=""

reset_zero_registration_fixture
rm -f "$repo/.ralph/launch.lock/owner"
expect_guard "exclusive launcher shutdown evidence"

reset_zero_registration_fixture
rm -f "$repo/.ralph/runs/$prior_run/status.json"
expect_guard "invalid status evidence"

reset_zero_registration_fixture
printf '{not-json\n' >"$repo/.ralph/state.json"
expect_guard "explicit empty claim evidence"

reset_zero_registration_fixture
git -C "$repo" update-ref -d "refs/heads/$branch" "$base"
set +e
branchless_zero_output=$(
  retire_owned_prd_branch "$prior_run" "replacement-run" 2>&1
)
branchless_zero_status=$?
set -e
[[ "$branchless_zero_status" -ne 0 ]] \
  || fail "unproven branchless zero-registration ownership must not retire"
grep -Fq "requires local branch" <<<"$branchless_zero_output" \
  || fail "branchless zero-registration refusal should be diagnosed"
jq -e '.retired_at == null and .retirement_pending == null' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "branchless refusal must preserve active ownership without staging retirement"

reset_zero_registration_fixture
printf '{"claims":{},"active_prd":"505","active_run_id":"%s"}\n' "$prior_run" \
  >"$repo/.ralph/state.json"
set +e
pending_retry_output=$(
  state_mktemp() { return 1; }
  retire_owned_prd_branch "$prior_run" "replacement-run" 2>&1
)
pending_retry_status=$?
set -e
[[ "$pending_retry_status" -ne 0 ]] \
  || fail "state failure should interrupt zero-registration retirement"
grep -Fq "pending ownership remains recoverable" <<<"$pending_retry_output" \
  || fail "partial zero-registration retirement should report durable recovery"
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  fail "partial zero-registration retirement should have CAS-deleted the branch"
fi
jq -e \
  --arg base "$base" \
  '.retired_at == null
   and .retirement_pending.reason
     == "abandoned before worker registration (zero-item guarded recovery)"
   and .retirement_pending.expected_branch_tip == $base' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "partial zero-registration retirement should durably record CAS evidence"
retire_owned_prd_branch "$prior_run" "replacement-run" >/dev/null \
  || fail "pending zero-registration retirement should retry without manual repair"
jq -e \
  '.retired_at != null
   and .retirement_pending == null
   and .retirement_reason
     == "abandoned before worker registration (zero-item guarded recovery)"' \
  "$repo/.ralph/runs/$prior_run/ownership.json" >/dev/null \
  || fail "pending zero-registration retirement should finalize durable ownership"

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
set +e
ownership_cas_output=$(
  state_lock() {
    jq '.created_at = "changed-during-retirement"' \
      "$repo/.ralph/runs/$prior_run/ownership.json" \
      >"$repo/.ralph/runs/$prior_run/ownership.tmp"
    mv "$repo/.ralph/runs/$prior_run/ownership.tmp" \
      "$repo/.ralph/runs/$prior_run/ownership.json"
  }
  retire_owned_prd_branch "$prior_run" "replacement-run" 2>&1
)
ownership_cas_status=$?
set -e
[[ "$ownership_cas_status" -ne 0 ]] \
  || fail "ownership evidence changes must fail branch retirement"
grep -Fq "changed during retirement" <<<"$ownership_cas_output" \
  || fail "ownership CAS failure should be diagnosed"
assert_branch_exists "$repo" "$branch" "ownership CAS"

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

echo "PASS: terminal, registration, launcher, claim, session, worktree, PR, remote, delivery, and evidence guards fail closed"
echo ""
echo "All stale PRD branch recovery tests passed!"
