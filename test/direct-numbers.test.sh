#!/usr/bin/env bash
# Tests for ralph.sh direct-numbers queue mode (issue #64 follow-up #2).
# Verifies that when .issue.numbers is populated and RALPH_RUN_ID is unset,
# workers actually consume that list instead of silently falling back to
# legacy issueSearch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local text="$1" needle="$2" label="$3"
  if echo "$text" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label (expected to contain '$needle')"
    echo "--- output ---" >&2
    echo "$text" >&2
    echo "--------------" >&2
  fi
}

# Create a repo with origin pointing to itself (bare-equivalent) so
# `git fetch origin main` succeeds offline.
new_repo() {
  local dir
  dir=$(mktemp -d "$TEST_ROOT/repo-XXXX")
  (
    cd "$dir"
    git init -q
    git checkout -qb main
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "initial" > README.md
    git add README.md
    git commit -qm "initial"

    # Bare clone serves as "origin" so git fetch works without network.
    local bare="$dir/../$(basename "$dir").git"
    git clone --quiet --bare "$dir" "$bare" >/dev/null 2>&1
    git remote add origin "$bare"
    git fetch -q origin
    git branch --quiet --set-upstream-to=origin/main main >/dev/null 2>&1 || true

    mkdir -p .ralph/lib .ralph/logs .ralph/lock
    # Hide .ralph from git porcelain so ralph.sh's "clean tree" preflight
    # passes when the worktree is the test repo itself (real launcher path
    # adds this to .git/info/exclude during setup).
    mkdir -p .git/info
    echo ".ralph" >> .git/info/exclude
    cp "$REPO_ROOT/ralph/ralph.sh" .ralph/ralph.sh
    cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
    cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
    cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
    cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
    cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
cp "$REPO_ROOT/ralph/lib/recovery-ledger.sh" .ralph/lib/recovery-ledger.sh
  ) >&2
  echo "$dir"
}

# Install a mock gh in a bin directory. The body is a bash dispatch.
write_mock_gh() {
  local bin_dir="$1" body="$2"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$bin_dir/gh"
  chmod +x "$bin_dir/gh"
}

# Build a JSON record for `gh issue view ... --json number,state,title,labels,body`.
issue_json() {
  local n="$1" state="$2" labels_csv="$3" title="$4" body="$5"
  local labels_json
  labels_json=$(printf '%s' "$labels_csv" | jq -R 'split(",") | map(select(length>0)) | map({name: .})')
  jq -nc \
    --argjson n "$n" \
    --arg state "$state" \
    --argjson labels "$labels_json" \
    --arg title "$title" \
    --arg body "$body" \
    '{number: $n, state: $state, title: $title, labels: $labels, body: $body}'
}

# ─── Negative: numbers configured, none ready → idle exit, blocker reasons ────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [5, 6], "titleRegex": "^Slice", "titleNumRegex": "^Slice (?<x>[0-9]+):", "issueSearch": "label:ralph:ready label:work:standalone"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
Test prompt.
EOF

  bin_dir="$TEST_ROOT/bin-neg"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    n="$3"
    case "$n" in
      5) echo "{\"number\":5,\"state\":\"OPEN\",\"title\":\"#5\",\"labels\":[{\"name\":\"ralph:needs-triage\"},{\"name\":\"priority:P2\"},{\"name\":\"work:standalone\"}],\"body\":\"slice\",\"assignees\":[]}" ;;
      6) echo "{\"number\":6,\"state\":\"OPEN\",\"title\":\"#6\",\"labels\":[{\"name\":\"ralph:needs-triage\"},{\"name\":\"priority:P2\"},{\"name\":\"work:standalone\"}],\"body\":\"slice\",\"assignees\":[]}" ;;
      *) echo "issue not found" >&2; exit 1 ;;
    esac
    exit 0
    ;;
esac
echo "mock gh: unhandled: $*" >&2
exit 2
'

  rc=0
  out=$(cd "$repo" && \
        RALPH_REPO="test-owner/test-repo" \
        RALPH_GH_BIN="$bin_dir/gh" \
        RALPH_POLL_SEC=0.05 \
        RALPH_IDLE_EXIT_POLLS=1 \
        PATH="$bin_dir:$PATH" \
        "$repo/.ralph/ralph.sh" 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "negative: exits 0 via idle path" \
    || fail "negative: exits 0 via idle path (got $rc)"
  assert_contains "$out" "direct-numbers queue"      "negative: announces direct-numbers mode"
  assert_contains "$out" "#5: not canonical Ralph-runnable (not_runnable_state(ralph:needs-triage))" "negative: reports #5 reason"
  assert_contains "$out" "#6: not canonical Ralph-runnable (not_runnable_state(ralph:needs-triage))" "negative: reports #6 reason"
  assert_contains "$out" "idle for"                  "negative: idle-exit log present"
}

# ─── ralph:hitl issue is skipped ──────────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [7], "issueSearch": "label:ralph:ready label:work:standalone"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
Test prompt.
EOF

  bin_dir="$TEST_ROOT/bin-hitl"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    echo "{\"number\":7,\"state\":\"OPEN\",\"title\":\"#7\",\"labels\":[{\"name\":\"ralph:hitl\"},{\"name\":\"priority:P2\"},{\"name\":\"work:standalone\"}],\"body\":\"\",\"assignees\":[]}"
    exit 0
    ;;
esac
exit 2
'

  rc=0
  out=$(cd "$repo" && \
        RALPH_REPO="test-owner/test-repo" \
        RALPH_GH_BIN="$bin_dir/gh" \
        RALPH_POLL_SEC=0.05 \
        RALPH_IDLE_EXIT_POLLS=1 \
        PATH="$bin_dir:$PATH" \
        "$repo/.ralph/ralph.sh" 2>&1) || rc=$?

  assert_contains "$out" "#7: not canonical Ralph-runnable (not_runnable_state(ralph:hitl))" "hitl: reports hitl skip reason"
  assert_contains "$out" "idle for"     "hitl: idle-exit log present"
}

# ─── Closed issue is skipped ──────────────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [8], "issueSearch": "label:ralph:ready label:work:standalone"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
Test prompt.
EOF

  bin_dir="$TEST_ROOT/bin-closed"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    echo "{\"number\":8,\"state\":\"CLOSED\",\"title\":\"#8\",\"labels\":[{\"name\":\"ralph:done\"},{\"name\":\"priority:P2\"},{\"name\":\"work:standalone\"}],\"body\":\"\",\"assignees\":[]}"
    exit 0
    ;;
esac
exit 2
'

  rc=0
  out=$(cd "$repo" && \
        RALPH_REPO="test-owner/test-repo" \
        RALPH_GH_BIN="$bin_dir/gh" \
        RALPH_POLL_SEC=0.05 \
        RALPH_IDLE_EXIT_POLLS=1 \
        PATH="$bin_dir:$PATH" \
        "$repo/.ralph/ralph.sh" 2>&1) || rc=$?

  assert_contains "$out" "#8: not open" "closed: reports closed skip reason"
}

# ─── queued issue is claimable but not pre-enqueueable ────────────────────────
{
  # Direct-number and run-aware queues contain issues after --enqueue has moved
  # them to ralph:queued, so worker/preflight validation must be claimable.
  # PRD child selection still uses the stricter enqueueable validator.
  # shellcheck source=/dev/null
  . "$REPO_ROOT/ralph/lib/labels.sh"
  queued_record=$(issue_json 10 OPEN 'ralph:queued,priority:P2,work:standalone' '#10' 'queued')
  claim_blockers=$(ralph_claimable_blocker_tags "$queued_record")
  enqueue_blockers=$(ralph_enqueueable_blocker_tags "$queued_record")

  [[ -z "$claim_blockers" ]] && pass "queued: claimable validator accepts queued issue" \
    || fail "queued: claimable validator unexpectedly blocked: $claim_blockers"
  [[ "$enqueue_blockers" == *"not_runnable_state(ralph:queued)"* ]] \
    && pass "queued: enqueueable validator rejects queued issue" \
    || fail "queued: enqueueable validator should reject queued issue (got: $enqueue_blockers)"
}

# ─── bare legacy hitl still fails closed during migration ─────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [11], "issueSearch": "label:ralph:ready label:work:standalone"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
Test prompt.
EOF

  bin_dir="$TEST_ROOT/bin-legacy-hitl"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    echo "{\"number\":11,\"state\":\"OPEN\",\"title\":\"#11\",\"labels\":[{\"name\":\"ralph:ready\"},{\"name\":\"priority:P2\"},{\"name\":\"work:standalone\"},{\"name\":\"hitl\"}],\"body\":\"\",\"assignees\":[]}"
    exit 0
    ;;
esac
exit 2
'

  rc=0
  out=$(cd "$repo" && \
        RALPH_REPO="test-owner/test-repo" \
        RALPH_GH_BIN="$bin_dir/gh" \
        RALPH_POLL_SEC=0.05 \
        RALPH_IDLE_EXIT_POLLS=1 \
        PATH="$bin_dir:$PATH" \
        "$repo/.ralph/ralph.sh" 2>&1) || rc=$?

  assert_contains "$out" "#11: not canonical Ralph-runnable (legacy_safety_label(hitl))" \
    "legacy hitl: rejected even with canonical ready"
  assert_contains "$out" "idle for" "legacy hitl: idle-exit log present"
}

# ─── conflicting states are rejected ──────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [9], "issueSearch": "label:ralph:ready label:work:standalone"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
Test prompt.
EOF

  bin_dir="$TEST_ROOT/bin-triage"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    echo "{\"number\":9,\"state\":\"OPEN\",\"title\":\"#9\",\"labels\":[{\"name\":\"ralph:ready\"},{\"name\":\"ralph:needs-triage\"},{\"name\":\"priority:P2\"},{\"name\":\"work:standalone\"}],\"body\":\"\",\"assignees\":[]}"
    exit 0
    ;;
esac
exit 2
'

  rc=0
  out=$(cd "$repo" && \
        RALPH_REPO="test-owner/test-repo" \
        RALPH_GH_BIN="$bin_dir/gh" \
        RALPH_POLL_SEC=0.05 \
        RALPH_IDLE_EXIT_POLLS=1 \
        PATH="$bin_dir:$PATH" \
        "$repo/.ralph/ralph.sh" 2>&1) || rc=$?

  assert_contains "$out" "#9: not canonical Ralph-runnable (state_conflict(ralph:needs-triage,ralph:ready))" \
    "conflicting states: rejected because exactly one state is required"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
