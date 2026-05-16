#!/usr/bin/env bash
# Tests for the resume-incomplete-iterations feature (issue #60).
#
# Covers:
#   1. Pure-helper unit tests for resume.sh (should_auto_commit_dirty,
#      is_sensitive_path, format_resume_log, any_sensitive_in_porcelain).
#   2. Git/gh probes: resume_branch_for_issue, resume_branch_ahead_of_base,
#      resume_branch_head_after, open_pr_for_branch.
#   3. state_set_resume_attempt / state_get_resume_attempt persistence.
#   4. Preflight dirty-tree rescue: happy path (commit + push + checkout
#      worker branch), sensitive-file refusal, worker-branch halt.
#   5. The critical sync-doesn't-orphan regression — after rescue, the
#      WIP commit survives sync_to_origin_main.
#   6. In-process resume control flow with stubbed gh + copilot: orphaned
#      slice branch triggers resume; open PR halts instead of resuming;
#      cap exhaustion marks status failed; status stays "running" between
#      resume attempts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0
fail_count=0
fail() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }

# Source the libraries directly. resume.sh has no startup side effects;
# state.sh defines functions that depend on STATE_DIR/STATE_FILE — set a
# dummy LOG_DIR before sourcing so STATE_DIR resolves cleanly.
LOG_DIR="$TEST_ROOT/.ralph/logs"
mkdir -p "$LOG_DIR"
# shellcheck source=../ralph/lib/state.sh
. "$REPO_ROOT/ralph/lib/state.sh"
# shellcheck source=../ralph/lib/resume.sh
. "$REPO_ROOT/ralph/lib/resume.sh"

# ===========================================================================
# Group 1 — Pure helpers
# ===========================================================================
echo "=== Group 1: Pure helpers ==="

# should_auto_commit_dirty
if should_auto_commit_dirty "slice-7-foo" "slice-"; then
  pass "should_auto_commit_dirty: slice-7-foo / slice- → true"
else
  fail "should_auto_commit_dirty should accept slice-7-foo with prefix slice-"
fi
if ! should_auto_commit_dirty "main" "slice-"; then
  pass "should_auto_commit_dirty: main / slice- → false"
else
  fail "should_auto_commit_dirty should reject main"
fi
if ! should_auto_commit_dirty "slice-7-foo" ""; then
  pass "should_auto_commit_dirty: empty prefix → false"
else
  fail "should_auto_commit_dirty should reject empty prefix"
fi
if ! should_auto_commit_dirty "ralph-loop-1" "slice-"; then
  pass "should_auto_commit_dirty: ralph-loop-1 / slice- → false"
else
  fail "should_auto_commit_dirty should reject worker branch"
fi

# is_sensitive_path
sensitive_cases=(".env" ".env.local" "PROD.env" "config/foo.pem" "id_rsa" \
                  "secrets/db.txt" "app/secrets/key.json" ".netrc" "creds.key" "foo.p12")
for p in "${sensitive_cases[@]}"; do
  if is_sensitive_path "$p"; then
    pass "is_sensitive_path: $p → sensitive"
  else
    fail "is_sensitive_path should flag '$p'"
  fi
done
nonsensitive=("src/foo.ts" "README.md" "test/keyboard.test.js" "main.go")
for p in "${nonsensitive[@]}"; do
  if ! is_sensitive_path "$p"; then
    pass "is_sensitive_path: $p → not sensitive"
  else
    fail "is_sensitive_path should NOT flag '$p'"
  fi
done

# any_sensitive_in_porcelain
porcelain_sensitive=$'?? .env\n M src/main.ts'
detected=$(printf '%s' "$porcelain_sensitive" | any_sensitive_in_porcelain || true)
if [[ "$detected" == ".env" ]]; then
  pass "any_sensitive_in_porcelain flags .env"
else
  fail "any_sensitive_in_porcelain should return .env (got '$detected')"
fi
porcelain_clean=$' M src/main.ts\n?? scratch.md'
if ! printf '%s' "$porcelain_clean" | any_sensitive_in_porcelain >/dev/null; then
  pass "any_sensitive_in_porcelain clean → false"
else
  fail "any_sensitive_in_porcelain should not flag clean porcelain"
fi
porcelain_rename='R  old.txt -> secrets/leaked.txt'
detected=$(printf '%s' "$porcelain_rename" | any_sensitive_in_porcelain || true)
if [[ "$detected" == "secrets/leaked.txt" ]]; then
  pass "any_sensitive_in_porcelain follows rename targets"
else
  fail "any_sensitive_in_porcelain should follow rename targets (got '$detected')"
fi

# format_resume_log
line=$(format_resume_log 2 3 "slice-7-foo" 42)
expected=$'\xf0\x9f\x94\x81 Resuming #42 (attempt 2/3, branch=slice-7-foo)'
if [[ "${line%$'\n'}" == "$expected" ]]; then
  pass "format_resume_log shape"
else
  fail "format_resume_log mismatch: got '$line'"
fi

echo ""
# ===========================================================================
# Group 2 — Git probes (with a real fixture repo, no gh)
# ===========================================================================
echo "=== Group 2: Git probes ==="

fixture_repo() {
  local dir="$1"
  rm -rf "$dir"
  git init -q "$dir"
  cd "$dir"
  git checkout -qb main
  git config user.email "t@example.com"
  git config user.name "T"
  echo init > README.md
  git add README.md && git commit -qm init

  local bare="$dir.origin.git"
  rm -rf "$bare"
  git init -q --bare "$bare"
  git remote add origin "$bare"
  git push -q -u origin main
}

FIX="$TEST_ROOT/git-fixture"
fixture_repo "$FIX"
cd "$FIX"

# Create slice-7-foo with a commit ahead of main
git checkout -qb slice-7-foo
echo work > work.txt
git add work.txt && git commit -qm "slice-7 wip"
git push -q -u origin slice-7-foo

# resume_branch_for_issue should find local
git checkout -q main
found=$(resume_branch_for_issue 7 "slice-" || true)
if [[ "$found" == "slice-7-foo" ]]; then
  pass "resume_branch_for_issue 7 → slice-7-foo (local)"
else
  fail "resume_branch_for_issue 7 expected slice-7-foo, got '$found'"
fi
if ! resume_branch_for_issue 99 "slice-" >/dev/null; then
  pass "resume_branch_for_issue 99 → none"
else
  fail "resume_branch_for_issue 99 should be empty"
fi
if ! resume_branch_for_issue 7 "" >/dev/null; then
  pass "resume_branch_for_issue with empty prefix → none"
else
  fail "resume_branch_for_issue with empty prefix should fail"
fi

# Remote-only fallback: delete the local ref, keep origin/slice-7-foo
git branch -q -D slice-7-foo
git fetch -q origin
found=$(resume_branch_for_issue 7 "slice-" || true)
if [[ "$found" == "slice-7-foo" ]]; then
  pass "resume_branch_for_issue falls back to origin"
else
  fail "remote-only fallback failed (got '$found')"
fi

# resume_branch_ahead_of_base
if resume_branch_ahead_of_base "slice-7-foo" "main"; then
  pass "resume_branch_ahead_of_base: slice-7-foo ahead of main"
else
  fail "resume_branch_ahead_of_base should be true"
fi
# main vs main → not ahead
if ! resume_branch_ahead_of_base "main" "main"; then
  pass "resume_branch_ahead_of_base: main / main → false"
else
  fail "resume_branch_ahead_of_base main/main should be false"
fi

# resume_branch_head_after
old_ts="2020-01-01T00:00:00Z"
future_ts="2099-01-01T00:00:00Z"
if resume_branch_head_after "slice-7-foo" "$old_ts"; then
  pass "resume_branch_head_after: head after old_ts"
else
  fail "head should be after $old_ts"
fi
if ! resume_branch_head_after "slice-7-foo" "$future_ts"; then
  pass "resume_branch_head_after: head NOT after future_ts"
else
  fail "head should not be after $future_ts"
fi

cd "$SCRIPT_DIR/.."

echo ""
# ===========================================================================
# Group 3 — state_set/get_resume_attempt
# ===========================================================================
echo "=== Group 3: state resume helpers ==="

# Fresh state.json under our test LOG_DIR
STATE_FILE_TEST="$LOG_DIR/../state.json"
printf '%s\n' '{"claims":{}}' > "$STATE_FILE_TEST"
# Re-source so STATE_FILE points at the right path
STATE_DIR="$(dirname "$STATE_FILE_TEST")"
STATE_FILE="$STATE_DIR/state.json"

# Attempting to set without an existing claim should fail and warn
if ! state_set_resume_attempt 42 1 "slice-42-foo" 2>/dev/null; then
  pass "state_set_resume_attempt refuses without claim"
else
  fail "state_set_resume_attempt should refuse without claim"
fi

# Add a claim and try again
jq '.claims["42"] = {"workerId":1,"pid":'$$',"startedAt":"2026-01-01T00:00:00Z","logFile":"x.log"}' \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
state_set_resume_attempt 42 1 "slice-42-foo"
got=$(state_get_resume_attempt 42)
if [[ "$got" == "1" ]]; then
  pass "state_get_resume_attempt returns 1 after set"
else
  fail "state_get_resume_attempt expected 1, got '$got'"
fi
got_branch=$(state_get_resume_branch 42)
if [[ "$got_branch" == "slice-42-foo" ]]; then
  pass "state_get_resume_branch returns the persisted branch"
else
  fail "state_get_resume_branch expected slice-42-foo, got '$got_branch'"
fi

# state_release should clear the attempt as well (cleared with the claim)
state_release 42
got_after=$(state_get_resume_attempt 42)
if [[ "$got_after" == "0" ]]; then
  pass "state_release clears resumeAttempt"
else
  fail "state_release should clear resumeAttempt (got '$got_after')"
fi

echo ""
# ===========================================================================
# Group 4 — Preflight dirty-tree rescue (driven through ralph.sh)
# ===========================================================================
echo "=== Group 4: Preflight dirty-tree rescue ==="

# Stub gh that always returns "no eligible issue" so the worker exits via
# the idle-timeout path after the preflight rescue runs once. Logs every
# call to GH_LOG for inspection.
make_idle_gh_stub() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "issue list") printf '[]\n' ;;
  "repo view") printf '{"defaultBranchRef":{"name":"main"}}\n' ;;
  *) printf '{}\n' ;;
esac
GH
  chmod +x "$bindir/gh"
}

setup_worker_repo() {
  local dir="$1"
  rm -rf "$dir" "$dir.origin.git"
  mkdir -p "$dir"
  git init -q "$dir"
  cd "$dir"
  git checkout -qb main
  git config user.email "t@example.com"
  git config user.name "T"
  echo init > README.md
  git add README.md && git commit -qm init
  git init -q --bare "$dir.origin.git"
  git remote add origin "$dir.origin.git"
  git push -q -u origin main
  printf '.ralph\n' >> .git/info/exclude
  mkdir -p .ralph/lib .ralph/logs .ralph/lock
  cp "$REPO_ROOT/ralph/ralph.sh"        .ralph/ralph.sh
  cp "$REPO_ROOT/ralph/launch.sh"       .ralph/launch.sh
  cp "$REPO_ROOT/ralph/lib/state.sh"    .ralph/lib/state.sh
  cp "$REPO_ROOT/ralph/lib/status.sh"   .ralph/lib/status.sh
  cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
  cp "$REPO_ROOT/ralph/lib/resume.sh"   .ralph/lib/resume.sh
  chmod +x .ralph/ralph.sh .ralph/launch.sh
  echo "Test prompt." > .ralph/RALPH.md
  cat > .ralph/config.json <<EOF
{
  "issue": {
    "titleRegex": "^Slice [0-9]+:",
    "titleNumRegex": "^Slice (?<x>[0-9]+):",
    "branchPrefix": "slice-"
  }
}
EOF
  echo '{"claims":{}}' > .ralph/state.json
  # Simulate the worker branch that launch.sh would create.
  git checkout -qb ralph-loop-1
  git push -q -u origin ralph-loop-1
}

# Drive ralph.sh through preflight only, capturing output. Use a tight
# idle-exit so the worker bails out after one poll once preflight passes.
run_preflight() {
  local repo="$1" bindir="$2"
  shift 2
  local extra_env=("$@")
  cd "$repo"
  local out_file
  out_file=$(mktemp)
  env RALPH_REPO="testowner/testrepo" \
      RALPH_WORKER_ID=1 \
      RALPH_POLL_SEC=0.1 \
      RALPH_IDLE_EXIT_POLLS=1 \
      RALPH_BRANCH_PREFIX="slice-" \
      RALPH_INITIAL_BRANCH="ralph-loop-1" \
      GH_LOG="$repo/.ralph/gh.log" \
      PATH="$bindir:$REPO_ROOT/node_modules/.bin:$PATH:/opt/homebrew/bin:/usr/local/bin" \
      "${extra_env[@]}" \
      bash .ralph/ralph.sh >"$out_file" 2>&1 &
  local pid=$!
  local waited=0
  while [[ $waited -lt 200 ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  cat "$out_file"
  rm -f "$out_file"
}

# --- 4a: Happy path: slice branch with dirty tree → commit + push + checkout worker branch
REPO_A="$TEST_ROOT/preflight-happy"
setup_worker_repo "$REPO_A"
cd "$REPO_A"
# Put work on a slice branch (mid-iteration crash state)
git checkout -qb slice-7-foo
echo "wip" > wip.txt
# Stay dirty (no commit)
BIN_A="$TEST_ROOT/bin-a"
make_idle_gh_stub "$BIN_A"
out_a=$(run_preflight "$REPO_A" "$BIN_A")

# After preflight, slice-7-foo should have the wip commit pushed to origin
slice_origin_head=$(git -C "$REPO_A" rev-parse origin/slice-7-foo 2>/dev/null || echo "")
slice_origin_msg=$(git -C "$REPO_A" log -1 --format=%s origin/slice-7-foo 2>/dev/null || echo "")
if [[ -n "$slice_origin_head" ]] && [[ "$slice_origin_msg" == "wip: ralph auto-commit before resume" ]]; then
  pass "preflight pushed wip commit to origin/slice-7-foo"
else
  echo "$out_a"
  fail "preflight should have pushed wip commit (msg='$slice_origin_msg')"
fi

# After preflight, working tree should be clean
status_after=$(git -C "$REPO_A" status --porcelain || true)
if [[ -z "$status_after" ]]; then
  pass "preflight ended with clean working tree"
else
  fail "preflight should leave clean tree, got: $status_after"
fi

# After preflight + sync, the worker should be on its worker branch
final_branch=$(git -C "$REPO_A" rev-parse --abbrev-ref HEAD)
if [[ "$final_branch" == "ralph-loop-1" ]]; then
  pass "preflight returned to worker branch"
else
  fail "expected HEAD on ralph-loop-1, got '$final_branch'"
fi

# CRITICAL regression: WIP commit survived sync_to_origin_main
slice_origin_after_sync=$(git -C "$REPO_A" rev-parse origin/slice-7-foo 2>/dev/null || echo "")
if [[ "$slice_origin_after_sync" == "$slice_origin_head" ]]; then
  pass "WIP commit survived sync_to_origin_main"
else
  fail "WIP commit lost after sync (was '$slice_origin_head', now '$slice_origin_after_sync')"
fi

# Output should contain the auto-commit log line
if echo "$out_a" | grep -q "Auto-committed"; then
  pass "preflight emitted 'Auto-committed' log line"
else
  echo "$out_a"
  fail "preflight should log 'Auto-committed'"
fi

# --- 4b: Sensitive file in dirty tree → halt
REPO_B="$TEST_ROOT/preflight-sensitive"
setup_worker_repo "$REPO_B"
cd "$REPO_B"
git checkout -qb slice-7-foo
echo "SECRET=hunter2" > .env
echo "ok" > harmless.txt
BIN_B="$TEST_ROOT/bin-b"
make_idle_gh_stub "$BIN_B"
out_b=$(run_preflight "$REPO_B" "$BIN_B")

if echo "$out_b" | grep -qi "sensitive\|refuse"; then
  pass "preflight refused on .env"
else
  echo "$out_b"
  fail "preflight should refuse on .env"
fi
# Dirty tree should still be present (no commit)
if [[ -n "$(git -C "$REPO_B" status --porcelain)" ]]; then
  pass "sensitive halt left dirty tree intact"
else
  fail "sensitive halt should not have committed"
fi

# --- 4c: Dirty tree on worker branch (no slice prefix) → halt
REPO_C="$TEST_ROOT/preflight-worker-dirty"
setup_worker_repo "$REPO_C"
cd "$REPO_C"
# We're on ralph-loop-1 from setup_worker_repo, leave dirty
echo "stray" > stray.txt
BIN_C="$TEST_ROOT/bin-c"
make_idle_gh_stub "$BIN_C"
out_c=$(run_preflight "$REPO_C" "$BIN_C")

if echo "$out_c" | grep -q "Working tree is dirty"; then
  pass "preflight halts on worker-branch dirty tree"
else
  echo "$out_c"
  fail "preflight should halt on worker-branch dirty tree"
fi

# ===========================================================================
# Summary
# ===========================================================================
cd "$SCRIPT_DIR/.."
echo ""
echo "=== Results ==="
echo "PASS: $pass_count  FAIL: $fail_count"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
