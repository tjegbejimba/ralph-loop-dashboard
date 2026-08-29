#!/usr/bin/env bash
# Integration test for Ralph-owned Copilot session naming and cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

MAIN_REPO="$TEST_ROOT/main"
ORIGIN="$TEST_ROOT/origin.git"
BIN_DIR="$TEST_ROOT/bin"
SESSION_STATE_DIR="$TEST_ROOT/session-state"
SESSION_ARCHIVE_DIR="$TEST_ROOT/session-archive"
RUN_ID="run-success"
ISSUE=300

mkdir -p "$BIN_DIR" "$SESSION_STATE_DIR"

cat > "$BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_CALL_LOG:?}"

case "$1 $2" in
  "repo view")
    printf 'main\n'
    ;;
  "issue view")
    if printf '%s\n' "$*" | grep -q 'closedByPullRequestsReferences'; then
      printf '{"state":"CLOSED","closedByPullRequestsReferences":[{"number":301}]}\n'
    else
      printf '{"number":300,"state":"OPEN","title":"Test issue 300","body":"","labels":[{"name":"ralph:ready"},{"name":"work:standalone"}],"assignees":[]}\n'
    fi
    ;;
  "pr view")
    if printf '%s\n' "$*" | grep -q -- '-q'; then
      printf '2026-01-01T00:00:00Z\n'
    else
      printf '{"mergedAt":"2026-01-01T00:00:00Z"}\n'
    fi
    ;;
  "pr list")
    ;;
  "issue edit")
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
chmod +x "$BIN_DIR/gh"

cat > "$BIN_DIR/copilot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
session_id=""
session_name=""
model=""
has_no_remote=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)
      session_id="${2:-}"
      shift 2
      ;;
    --name)
      session_name="${2:-}"
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --no-remote)
      has_no_remote=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$session_id" ]] || { echo "missing --session-id" >&2; exit 42; }
[[ -n "$session_name" ]] || { echo "missing --name" >&2; exit 43; }
[[ "$has_no_remote" -eq 1 ]] || { echo "missing --no-remote" >&2; exit 44; }
[[ "$model" == "gpt-5.6-sol" ]] || { echo "unexpected --model '$model'" >&2; exit 45; }

printf '%s\n' "$session_id" > "${COPILOT_SESSION_ID_OUT:?}"
printf '%s\n' "$session_name" > "${COPILOT_SESSION_NAME_OUT:?}"
session_dir="${RALPH_COPILOT_SESSION_STATE_DIR:?}/$session_id"
mkdir -p "$session_dir"
cat > "$session_dir/workspace.yaml" <<YAML
id: $session_id
cwd: $(pwd -P)
name: "$session_name"
user_named: true
YAML
printf 'mock copilot ok\n'
EOF
chmod +x "$BIN_DIR/copilot"

git init -q --bare "$ORIGIN"
git init -q "$MAIN_REPO"
cd "$MAIN_REPO"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
git remote add origin "$ORIGIN"
git push -q -u origin main
printf '%s\n' ".ralph" >> .git/info/exclude

mkdir -p ".ralph/lib" ".ralph/logs" ".ralph/lock" ".ralph/runs/$RUN_ID"
cp "$REPO_ROOT/ralph/ralph.sh" .ralph/ralph.sh
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
cp "$REPO_ROOT/ralph/lib/recovery-ledger.sh" .ralph/lib/recovery-ledger.sh
cp "$REPO_ROOT/ralph/lib/copilot-session.sh" .ralph/lib/copilot-session.sh
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
cat > ".ralph/runs/$RUN_ID/queue.json" <<EOF
[{"number":$ISSUE,"title":"Test issue $ISSUE"}]
EOF
printf '{"items":{}}\n' > ".ralph/runs/$RUN_ID/status.json"

output_file="$TEST_ROOT/worker.out"
GH_CALL_LOG="$TEST_ROOT/gh-calls.log" \
COPILOT_SESSION_ID_OUT="$TEST_ROOT/copilot-session-id.txt" \
COPILOT_SESSION_NAME_OUT="$TEST_ROOT/copilot-session-name.txt" \
RALPH_REPO="testowner/testrepo" \
RALPH_RUN_ID="$RUN_ID" \
RALPH_WORKER_ID=1 \
RALPH_GH_BIN="$BIN_DIR/gh" \
RALPH_COPILOT_BIN="$BIN_DIR/copilot" \
RALPH_COPILOT_SESSION_STATE_DIR="$SESSION_STATE_DIR" \
RALPH_COPILOT_SESSION_ARCHIVE_DIR="$SESSION_ARCHIVE_DIR" \
RALPH_DISABLE_LABEL_TRANSITIONS=1 \
RALPH_TIMEOUT_SEC=30 \
PATH="$BIN_DIR:$PATH" \
  .ralph/ralph.sh --once >"$output_file" 2>&1 || {
    cat "$output_file"
    fail "worker should complete successfully"
  }

session_id="$(cat "$TEST_ROOT/copilot-session-id.txt" 2>/dev/null || true)"
session_name="$(cat "$TEST_ROOT/copilot-session-name.txt" 2>/dev/null || true)"

if ! [[ "$session_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  cat "$output_file"
  [[ -f "$TEST_ROOT/gh-calls.log" ]] && cat "$TEST_ROOT/gh-calls.log"
  fail "worker should pass a generated UUID --session-id, got '$session_id'"
fi
[[ "$session_name" == "Ralph #$ISSUE w1 $RUN_ID" ]] || fail "worker should pass deterministic --name, got '$session_name'"

ledger=".ralph/runs/$RUN_ID/copilot-sessions.jsonl"
[[ -f "$ledger" ]] || fail "worker should write Copilot session ledger"
if ! jq -e --arg id "$session_id" 'select(.event == "terminal" and .sessionId == $id and .terminalStatus == "merged")' "$ledger" >/dev/null; then
  cat "$ledger"
  fail "worker should record terminal merged session"
fi

[[ ! -d "$SESSION_STATE_DIR/$session_id" ]] || fail "merged Ralph session should be archived from active session-state"
[[ -d "$SESSION_ARCHIVE_DIR/$session_id" ]] || fail "merged Ralph session should exist in archive"

RESUME_REPO="$TEST_ROOT/resume-main"
RESUME_ORIGIN="$TEST_ROOT/resume-origin.git"
RESUME_BIN="$TEST_ROOT/resume-bin"
RESUME_STATE_DIR="$TEST_ROOT/resume-session-state"
RESUME_ARCHIVE_DIR="$TEST_ROOT/resume-session-archive"
RESUME_RUN_ID="run-resume"
RESUME_ISSUE=301
RESUME_CALL_COUNT="$TEST_ROOT/resume-copilot-count.txt"

mkdir -p "$RESUME_BIN" "$RESUME_STATE_DIR"
printf '0\n' > "$RESUME_CALL_COUNT"

cat > "$RESUME_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
  "repo view")
    if printf '%s\n' "$*" | grep -q 'nameWithOwner'; then
      printf 'testowner/testrepo\n'
    else
      printf 'main\n'
    fi
    ;;
  "issue view")
    if [[ "${MUTATE_RECOVERY_STATUS:-0}" == "1" ]]; then
      printf '{"items":{"301":{"status":"running","workerId":1}}}\n' > "${RECOVERY_STATUS_PATH:?}"
    fi
    count="$(cat "${COPILOT_CALL_COUNT:?}" 2>/dev/null || echo 0)"
    if printf '%s\n' "$*" | grep -q 'closedByPullRequestsReferences'; then
      if [[ "${EXACT_RECOVERY:-0}" == "1" && "$count" -ge 1 ]] || [[ "$count" -ge 2 ]]; then
        printf '{"state":"CLOSED","closedByPullRequestsReferences":[{"number":302}]}\n'
      else
        printf '{"state":"OPEN","closedByPullRequestsReferences":[]}\n'
      fi
    else
      labels='[{"name":"ralph:ready"},{"name":"work:standalone"}]'
      [[ "${EXACT_RECOVERY:-0}" == "1" ]] && labels='[{"name":"ralph:running"},{"name":"work:slice"}]'
      printf '{"number":301,"state":"OPEN","title":"Test issue 301","body":"","labels":%s,"assignees":[]}\n' "$labels"
    fi
    ;;
  "pr view")
    if printf '%s\n' "$*" | grep -q -- '-q'; then
      printf '2026-01-01T00:00:00Z\n'
    else
      printf '{"mergedAt":"2026-01-01T00:00:00Z"}\n'
    fi
    ;;
  "pr list")
    if [[ "${EXACT_RECOVERY:-0}" == "1" ]]; then
      printf '[]\n'
    fi
    ;;
  "issue edit")
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
chmod +x "$RESUME_BIN/gh"

cat > "$RESUME_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$RESUME_BIN/sleep"

cat > "$RESUME_BIN/copilot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
session_id=""
session_name=""
resume_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume=*)
      resume_id="${1#--resume=}"
      shift
      ;;
    --session-id)
      session_id="${2:-}"
      shift 2
      ;;
    --name)
      session_name="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "${EXACT_RECOVERY:-0}" == "1" ]]; then
  [[ "$resume_id" == "${EXPECTED_RECOVERY_SESSION:?}" ]] || { echo "wrong --resume" >&2; exit 46; }
  [[ -z "$session_id$session_name" ]] || { echo "recovery created a new session" >&2; exit 47; }
  session_id="$resume_id"
else
  [[ -n "$session_id" ]] || { echo "missing --session-id" >&2; exit 42; }
  [[ -n "$session_name" ]] || { echo "missing --name" >&2; exit 43; }
fi

count="$(cat "${COPILOT_CALL_COUNT:?}" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" > "$COPILOT_CALL_COUNT"
printf '%s\n' "$session_id" >> "${COPILOT_SESSION_IDS_OUT:?}"

[[ "${FAIL_EXACT_RECOVERY:-0}" != "1" ]] || exit 48

session_dir="${RALPH_COPILOT_SESSION_STATE_DIR:?}/$session_id"
mkdir -p "$session_dir"
cat > "$session_dir/workspace.yaml" <<YAML
id: $session_id
cwd: $(pwd -P)
name: "$session_name"
user_named: true
YAML

if [[ "${EXACT_RECOVERY:-0}" == "1" ]]; then
  git add recovery-dirty.txt
  git commit -qm "finish exact recovery"
elif [[ "$count" -eq 1 ]]; then
  git checkout -qb slice-301-resume
  printf 'resume work\n' > resume-work.txt
  git add resume-work.txt
  git commit -qm "resume work"
  git push -q -u origin slice-301-resume
fi

printf 'mock copilot call %s ok\n' "$count"
EOF
chmod +x "$RESUME_BIN/copilot"

git init -q --bare "$RESUME_ORIGIN"
git init -q "$RESUME_REPO"
cd "$RESUME_REPO"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit -qm "initial"
git remote add origin "$RESUME_ORIGIN"
git push -q -u origin main
printf '%s\n' ".ralph" >> .git/info/exclude

mkdir -p ".ralph/lib" ".ralph/logs" ".ralph/lock" ".ralph/runs/$RESUME_RUN_ID"
cp "$REPO_ROOT/ralph/ralph.sh" .ralph/ralph.sh
cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
cp "$REPO_ROOT/ralph/lib/recovery-ledger.sh" .ralph/lib/recovery-ledger.sh
cp "$REPO_ROOT/ralph/lib/copilot-session.sh" .ralph/lib/copilot-session.sh
chmod +x .ralph/ralph.sh

cat > .ralph/RALPH.md <<'EOF'
Test prompt.
EOF
cat > .ralph/config.json <<'EOF'
{
  "issue": {
    "titleRegex": "^Test issue",
    "titleNumRegex": "^Test issue (?<x>[0-9]+)",
    "branchPrefix": "slice-"
  }
}
EOF
cat > ".ralph/runs/$RESUME_RUN_ID/queue.json" <<EOF
[{"number":$RESUME_ISSUE,"title":"Test issue $RESUME_ISSUE"}]
EOF
printf '{"items":{}}\n' > ".ralph/runs/$RESUME_RUN_ID/status.json"

resume_output_file="$TEST_ROOT/resume-worker.out"
COPILOT_CALL_COUNT="$RESUME_CALL_COUNT" \
COPILOT_SESSION_IDS_OUT="$TEST_ROOT/resume-session-ids.txt" \
RALPH_REPO="testowner/testrepo" \
RALPH_RUN_ID="$RESUME_RUN_ID" \
RALPH_WORKER_ID=1 \
RALPH_GH_BIN="$RESUME_BIN/gh" \
RALPH_COPILOT_BIN="$RESUME_BIN/copilot" \
RALPH_COPILOT_SESSION_STATE_DIR="$RESUME_STATE_DIR" \
RALPH_COPILOT_SESSION_ARCHIVE_DIR="$RESUME_ARCHIVE_DIR" \
RALPH_DISABLE_LABEL_TRANSITIONS=1 \
RALPH_TIMEOUT_SEC=30 \
PATH="$RESUME_BIN:$PATH" \
  .ralph/ralph.sh --once >"$resume_output_file" 2>&1 || {
    cat "$resume_output_file"
    fail "resume worker should complete successfully"
  }

mapfile -t resume_session_ids < "$TEST_ROOT/resume-session-ids.txt"
[[ "${#resume_session_ids[@]}" -eq 2 ]] || {
  cat "$resume_output_file"
  fail "resume scenario should invoke copilot twice"
}
resumed_session_id="${resume_session_ids[0]}"
merged_session_id="${resume_session_ids[1]}"
resume_ledger=".ralph/runs/$RESUME_RUN_ID/copilot-sessions.jsonl"

if ! jq -e --arg id "$resumed_session_id" 'select(.event == "terminal" and .sessionId == $id and .terminalStatus == "resumed")' "$resume_ledger" >/dev/null; then
  cat "$resume_ledger"
  fail "resumable iteration should record terminal resumed session"
fi
if ! jq -e --arg id "$merged_session_id" 'select(.event == "terminal" and .sessionId == $id and .terminalStatus == "merged")' "$resume_ledger" >/dev/null; then
  cat "$resume_ledger"
  fail "final resume attempt should record terminal merged session"
fi

[[ ! -d "$RESUME_STATE_DIR/$resumed_session_id" ]] || fail "resumed Ralph session should be archived from active session-state"
[[ -d "$RESUME_ARCHIVE_DIR/$resumed_session_id" ]] || fail "resumed Ralph session should exist in archive"
[[ ! -d "$RESUME_STATE_DIR/$merged_session_id" ]] || fail "merged resume session should be archived from active session-state"
[[ -d "$RESUME_ARCHIVE_DIR/$merged_session_id" ]] || fail "merged resume session should exist in archive"

EXACT_SESSION="595b45ce-c350-40b1-8844-a16e4bd5baa9"
EXACT_BASE="$(git rev-parse main)"
printf 'dirty recovery work\n' > recovery-dirty.txt
: > "$resume_ledger"; printf '0\n' > "$RESUME_CALL_COUNT"
printf '{"items":{"301":{"status":"failed","workerId":1,"error":"Worker process died"}}}\n' > ".ralph/runs/$RESUME_RUN_ID/status.json"
printf '{"claims":{},"active_prd":"505","active_run_id":"%s"}\n' "$RESUME_RUN_ID" > .ralph/state.json
printf '{"run_id":"%s","prd_number":"505","initial_base_sha":"%s"}\n' "$RESUME_RUN_ID" "$EXACT_BASE" > ".ralph/runs/$RESUME_RUN_ID/ownership.json"
mkdir -p "$RESUME_STATE_DIR/$EXACT_SESSION"
cat > "$RESUME_STATE_DIR/$EXACT_SESSION/workspace.yaml" <<EOF
id: $EXACT_SESSION
cwd: $(pwd -P)
name: "Ralph #301 w1 $RESUME_RUN_ID"
EOF
cat >> "$resume_ledger" <<EOF
{"event":"start","sessionId":"$EXACT_SESSION","issue":301,"workerId":1,"cwd":"$(pwd -P)","runId":"$RESUME_RUN_ID"}
EOF

run_exact_worker() {
  local output_file="$1"
  EXACT_RECOVERY=1 EXPECTED_RECOVERY_SESSION="$EXACT_SESSION" \
COPILOT_CALL_COUNT="$RESUME_CALL_COUNT" COPILOT_SESSION_IDS_OUT="$TEST_ROOT/exact-session-ids.txt" \
RALPH_REPO="testowner/testrepo" RALPH_RUN_ID="$RESUME_RUN_ID" RALPH_WORKER_ID=1 \
RALPH_GH_BIN="$RESUME_BIN/gh" RALPH_COPILOT_BIN="$RESUME_BIN/copilot" \
RALPH_COPILOT_SESSION_STATE_DIR="$RESUME_STATE_DIR" RALPH_COPILOT_SESSION_ARCHIVE_DIR="$RESUME_ARCHIVE_DIR" \
RALPH_DISABLE_LABEL_TRANSITIONS=1 RALPH_TIMEOUT_SEC=30 PATH="$RESUME_BIN:$PATH" \
RALPH_RECOVERY_RUN_ID="$RESUME_RUN_ID" RALPH_RECOVERY_ISSUE_NUMBER=301 RALPH_RECOVERY_WORKER_ID=1 \
RALPH_RECOVERY_SESSION_ID="$EXACT_SESSION" RALPH_RECOVERY_WORKTREE_PATH="$(pwd -P)" \
RALPH_RECOVERY_BRANCH="slice-301-resume" RALPH_RECOVERY_PRD_NUMBER=505 RALPH_RECOVERY_BASE_COMMIT="$EXACT_BASE" \
RALPH_BASE_COMMIT="$EXACT_BASE" \
    .ralph/ralph.sh --once >"$output_file" 2>&1
}
if MUTATE_RECOVERY_STATUS=1 RECOVERY_STATUS_PATH="$(pwd -P)/.ralph/runs/$RESUME_RUN_ID/status.json" \
  run_exact_worker "$TEST_ROOT/drifted-worker.out"; then
  fail "worker should reject recovery evidence changed after controller spawn"
fi
[[ "$(cat "$RESUME_CALL_COUNT")" == "0" ]] || fail "drifted recovery must not invoke Copilot"
printf '{"items":{"301":{"status":"failed","workerId":1,"error":"Worker process died"}}}\n' > ".ralph/runs/$RESUME_RUN_ID/status.json"
run_exact_worker "$TEST_ROOT/exact-worker.out" || {
    cat "$TEST_ROOT/exact-worker.out"
    fail "exact registered session recovery should complete"
  }

[[ "$(cat "$TEST_ROOT/exact-session-ids.txt")" == "$EXACT_SESSION" ]] || fail "recovery should invoke only the registered session"
[[ "$(jq -sr --arg id "$EXACT_SESSION" '[.[] | select(.sessionId == $id) | .event] | join(",")' "$resume_ledger")" == "start,terminal" ]] ||
  fail "recovery should retain one start and append normal terminal evidence"

FAILED_SESSION="695b45ce-c350-40b1-8844-a16e4bd5baa9"
printf 'failed recovery work\n' > recovery-failure.txt
printf '{"items":{"301":{"status":"failed","workerId":1,"error":"Worker process died"}}}\n' > ".ralph/runs/$RESUME_RUN_ID/status.json"
mkdir -p "$RESUME_STATE_DIR/$FAILED_SESSION"
cat > "$RESUME_STATE_DIR/$FAILED_SESSION/workspace.yaml" <<EOF
id: $FAILED_SESSION
cwd: $(pwd -P)
name: "Ralph #301 w1 $RESUME_RUN_ID"
EOF
printf '{"event":"start","sessionId":"%s","issue":301,"workerId":1,"worktree":"%s","runId":"%s"}\n' \
  "$FAILED_SESSION" "$(pwd -P)" "$RESUME_RUN_ID" >> "$resume_ledger"

if EXACT_RECOVERY=1 FAIL_EXACT_RECOVERY=1 EXPECTED_RECOVERY_SESSION="$FAILED_SESSION" \
  COPILOT_CALL_COUNT="$RESUME_CALL_COUNT" COPILOT_SESSION_IDS_OUT="$TEST_ROOT/failed-session-ids.txt" \
  RALPH_REPO="testowner/testrepo" RALPH_RUN_ID="$RESUME_RUN_ID" RALPH_WORKER_ID=1 \
  RALPH_GH_BIN="$RESUME_BIN/gh" RALPH_COPILOT_BIN="$RESUME_BIN/copilot" \
  RALPH_COPILOT_SESSION_STATE_DIR="$RESUME_STATE_DIR" RALPH_COPILOT_SESSION_ARCHIVE_DIR="$RESUME_ARCHIVE_DIR" \
  RALPH_DISABLE_LABEL_TRANSITIONS=1 RALPH_TIMEOUT_SEC=30 PATH="$RESUME_BIN:$PATH" \
  RALPH_RECOVERY_RUN_ID="$RESUME_RUN_ID" RALPH_RECOVERY_ISSUE_NUMBER=301 RALPH_RECOVERY_WORKER_ID=1 \
  RALPH_RECOVERY_SESSION_ID="$FAILED_SESSION" RALPH_RECOVERY_WORKTREE_PATH="$(pwd -P)" \
  RALPH_RECOVERY_BRANCH="slice-301-resume" RALPH_RECOVERY_PRD_NUMBER=505 RALPH_RECOVERY_BASE_COMMIT="$EXACT_BASE" \
  RALPH_BASE_COMMIT="$EXACT_BASE" .ralph/ralph.sh --once >"$TEST_ROOT/failed-worker.out" 2>&1; then
  fail "failed exact recovery should halt"
fi
[[ "$(jq -sr --arg id "$FAILED_SESSION" '[.[] | select(.sessionId == $id) | .event] | join(",")' "$resume_ledger")" == "start,terminal" ]] ||
  fail "failed recovery should retain one start and append failed terminal evidence"
[[ "$(jq -sr --arg id "$FAILED_SESSION" '[.[] | select(.sessionId == $id and .event == "terminal") | .terminalStatus] | join(",")' "$resume_ledger")" == "failed" ]] ||
  fail "failed recovery should preserve failed terminal status"

echo "PASS: Ralph worker names, records, and archives completed Copilot sessions"
