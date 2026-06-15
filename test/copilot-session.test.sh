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
    printf 'main\n'
    ;;
  "issue view")
    count="$(cat "${COPILOT_CALL_COUNT:?}" 2>/dev/null || echo 0)"
    if printf '%s\n' "$*" | grep -q 'closedByPullRequestsReferences'; then
      if [[ "$count" -ge 2 ]]; then
        printf '{"state":"CLOSED","closedByPullRequestsReferences":[{"number":302}]}\n'
      else
        printf '{"state":"OPEN","closedByPullRequestsReferences":[]}\n'
      fi
    else
      printf '{"number":301,"state":"OPEN","title":"Test issue 301","body":"","labels":[{"name":"ralph:ready"},{"name":"work:standalone"}],"assignees":[]}\n'
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
    *)
      shift
      ;;
  esac
done

[[ -n "$session_id" ]] || { echo "missing --session-id" >&2; exit 42; }
[[ -n "$session_name" ]] || { echo "missing --name" >&2; exit 43; }

count="$(cat "${COPILOT_CALL_COUNT:?}" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" > "$COPILOT_CALL_COUNT"
printf '%s\n' "$session_id" >> "${COPILOT_SESSION_IDS_OUT:?}"

session_dir="${RALPH_COPILOT_SESSION_STATE_DIR:?}/$session_id"
mkdir -p "$session_dir"
cat > "$session_dir/workspace.yaml" <<YAML
id: $session_id
cwd: $(pwd -P)
name: "$session_name"
user_named: true
YAML

if [[ "$count" -eq 1 ]]; then
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

echo "PASS: Ralph worker names, records, and archives completed Copilot sessions"
