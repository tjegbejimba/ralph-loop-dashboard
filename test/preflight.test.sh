#!/usr/bin/env bash
# Tests for launch.sh preflight: surfaces queue + repo readiness signals
# whenever the operator enqueues or asks for status. Covers issue #64.

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

assert_not_contains() {
  local text="$1" needle="$2" label="$3"
  if echo "$text" | grep -qF -- "$needle"; then
    fail "$label (did not expect to contain '$needle')"
    echo "--- output ---" >&2
    echo "$text" >&2
    echo "--------------" >&2
  else
    pass "$label"
  fi
}

# Minimal repo with the launch.sh under test installed at .ralph/launch.sh.
new_repo() {
  local dir
  dir=$(mktemp -d "$TEST_ROOT/repo-XXXX")
  git init -q "$dir"
  cd "$dir"
  git checkout -qb main
  git config user.email "test@example.com"
  git config user.name "Test"
  git remote add origin "https://github.com/test-owner/test-repo"
  echo "initial" > README.md
  git add README.md
  git commit -qm "initial"
  mkdir -p .ralph/lib .ralph/logs .ralph/lock
  # Mirror what install.sh does in the real launcher path: hide .ralph from
  # git porcelain so config.json updates don't fail the dirty-tree preflight.
  mkdir -p .git/info
  echo ".ralph" >> .git/info/exclude
  cp "$REPO_ROOT/ralph/launch.sh" .ralph/launch.sh
  cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
  cp "$REPO_ROOT/ralph/lib/status.sh" .ralph/lib/status.sh
  cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
  cp "$REPO_ROOT/ralph/lib/preflight.sh" .ralph/lib/preflight.sh
  echo "$dir"
}

write_mock_gh() {
  local bin_dir="$1"
  local script_body="$2"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\n%s\n' "$script_body" > "$bin_dir/gh"
  chmod +x "$bin_dir/gh"
}

# Build a JSON object representing an issue for the mock gh.
# Args: number state labels-csv body
issue_json() {
  local n="$1" state="$2" labels_csv="$3" body="$4"
  local labels_json
  labels_json=$(
    if [[ -z "$labels_csv" ]]; then
      echo "[]"
    else
      printf '%s' "$labels_csv" | jq -R 'split(",") | map({name: .})'
    fi
  )
  jq -nc \
    --argjson n "$n" \
    --arg state "$state" \
    --argjson labels "$labels_json" \
    --arg body "$body" \
    '{number: $n, state: $state, labels: $labels, body: $body}'
}

# Mock gh script that responds to `gh issue view <N> --json number,state,labels,body`
# based on a $ISSUE_BLOB env-var of newline-separated JSON objects.
GH_MOCK_PREFLIGHT='
# Mock gh: only handles `issue view <N> --json ...`. Reads issues from $ISSUE_BLOB.
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  num="$3"
  match=$(printf "%s\n" "$ISSUE_BLOB" | jq -c --argjson n "$num" "select(.number == \$n)")
  if [[ -z "$match" ]]; then
    echo "issue not found" >&2
    exit 1
  fi
  # Honor --json by returning the full record; we ignore the field list and
  # let jq downstream pick what it needs.
  echo "$match"
  exit 0
fi
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  exit 0
fi
echo "mock gh: unhandled: $*" >&2
exit 2
'

# ─── Tracer bullet: --enqueue surfaces needs-triage on each queued issue ──────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [], "issueSearch": "label:ready-for-agent -label:hitl"}, "profile": "default"}
EOF

  bin_dir="$TEST_ROOT/bin-tracer"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"

  blob=$(printf '%s\n%s\n' \
    "$(issue_json 5 OPEN needs-triage 'A child slice.')" \
    "$(issue_json 6 OPEN needs-triage 'Another slice.')"
  )

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 5 6 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "--enqueue + preflight exits 0" \
    || fail "--enqueue + preflight exits 0 (got $rc)"

  assert_contains "$out" "Preflight" "--enqueue prints a Preflight section"
  assert_contains "$out" "#5"        "--enqueue preflight lists issue #5"
  assert_contains "$out" "#6"        "--enqueue preflight lists issue #6"
  assert_contains "$out" "needs_triage" \
    "--enqueue preflight surfaces needs_triage warning"
  assert_contains "$out" "not_ready_for_agent" \
    "--enqueue preflight surfaces not_ready_for_agent warning"
  # Final verdict line for blocker case.
  assert_contains "$out" "blockers" \
    "--enqueue preflight prints a blockers verdict"
}

# ─── Ready path: queued issue is ready-for-agent, no warnings ─────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [], "issueSearch": "label:ready-for-agent -label:hitl"}, "profile": "default"}
EOF
  # RALPH.md with a concrete PRD reference (no placeholder).
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
# Ralph TDD Loop
You are working through ONE slice of #4 in test-owner/test-repo.
EOF

  bin_dir="$TEST_ROOT/bin-ready"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"

  blob=$(issue_json 7 OPEN ready-for-agent 'A ready slice with no blockers.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 7 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "ready: --enqueue exits 0" \
    || fail "ready: --enqueue exits 0 (got $rc)"
  assert_contains     "$out" "Ready to launch"      "ready: verdict is ✅ Ready to launch"
  assert_contains     "$out" "ref #4"                "ready: surfaces concrete PRD ref"
  assert_contains     "$out" "Repo: clean"           "ready: surfaces clean repo state"
  assert_not_contains "$out" "needs_triage"          "ready: no needs_triage warning"
  assert_not_contains "$out" "not_ready_for_agent"   "ready: no not_ready_for_agent warning"
  assert_not_contains "$out" "preflight blockers"    "ready: no blocker verdict"
}

# ─── hitl label is surfaced ───────────────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  bin_dir="$TEST_ROOT/bin-hitl"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"
  blob=$(issue_json 8 OPEN "ready-for-agent,hitl" 'A human-required slice.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 8 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "hitl: --enqueue exits 0" \
    || fail "hitl: --enqueue exits 0 (got $rc)"
  assert_contains "$out" "hitl"             "hitl: warning surfaced"
  assert_contains "$out" "preflight blockers" "hitl: verdict is blockers"
}

# ─── closed issue is surfaced ─────────────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  bin_dir="$TEST_ROOT/bin-closed"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"
  blob=$(issue_json 9 CLOSED ready-for-agent 'Already merged slice.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 9 2>&1) || rc=$?

  assert_contains "$out" "CLOSED"           "closed: state surfaced"
  assert_contains "$out" "closed"           "closed: warning surfaced"
  assert_contains "$out" "preflight blockers" "closed: verdict is blockers"
}

# ─── placeholder PRD reference in RALPH.md is surfaced ────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  # Marker still carries the install-time placeholder.
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: {{PRD_REFERENCE}} -->
# Ralph TDD Loop
You are working through ONE slice of {{PRD_REFERENCE}} in test-owner/test-repo.
EOF

  bin_dir="$TEST_ROOT/bin-placeholder"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"
  blob=$(issue_json 10 OPEN ready-for-agent 'A slice.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 10 2>&1) || rc=$?

  assert_contains "$out" "{{PRD_REFERENCE}}"  "placeholder: warning surfaced"
  assert_contains "$out" "preflight blockers" "placeholder: verdict is blockers"
}

# ─── dirty target repo is surfaced ────────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF
  # Add an uncommitted change to a tracked file.
  echo "uncommitted change" >> "$repo/README.md"

  bin_dir="$TEST_ROOT/bin-dirty"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"
  blob=$(issue_json 11 OPEN ready-for-agent 'A slice.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 11 2>&1) || rc=$?

  assert_contains "$out" "Repo: dirty"        "dirty: state surfaced"
  assert_contains "$out" "preflight blockers" "dirty: verdict is blockers"
}

# ─── unresolved blocker in issue body is surfaced ─────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  bin_dir="$TEST_ROOT/bin-blocker"
  # Mock gh: also handle `gh issue view <N> --json state,closedByPullRequestsReferences`
  # for is_issue_satisfied calls. #99 is OPEN so it is unresolved.
  write_mock_gh "$bin_dir" '
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  num="$3"
  # Default record from $ISSUE_BLOB.
  match=$(printf "%s\n" "$ISSUE_BLOB" | jq -c --argjson n "$num" "select(.number == \$n)")
  if [[ -z "$match" ]]; then
    # Synthesize an OPEN record so is_issue_satisfied sees state=OPEN
    # (which counts as unsatisfied).
    echo "{\"number\":$num,\"state\":\"OPEN\",\"closedByPullRequestsReferences\":[]}"
    exit 0
  fi
  echo "$match"
  exit 0
fi
echo "mock gh: unhandled: $*" >&2
exit 2
'
  body=$'Description.\n\n## Blocked by\n- #99\n- #100\n\n## Acceptance Criteria\n- thing'
  blob=$(issue_json 12 OPEN ready-for-agent "$body")

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 12 2>&1) || rc=$?

  assert_contains "$out" "unresolved_blocker" "blocker: warning surfaced"
  assert_contains "$out" "#99"                "blocker: #99 listed"
  assert_contains "$out" "preflight blockers" "blocker: verdict is blockers"
}

# ─── --enqueue-prd also runs preflight ────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: {{PRD_REFERENCE}} -->
EOF

  bin_dir="$TEST_ROOT/bin-enqueue-prd"
  # Two layers: --enqueue-prd uses `gh issue list ... --json number,labels`
  # to find AFK slices, then preflight uses `gh issue view ... --json state,labels,body`.
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    num="$3"
    if [[ "$num" == "20" ]]; then
      echo "{\"number\":20}"
      exit 0
    fi
    # Preflight per-issue lookup.
    echo "{\"number\":$num,\"state\":\"OPEN\",\"labels\":[{\"name\":\"ready-for-agent\"}],\"body\":\"slice\"}"
    exit 0
    ;;
  "issue list")
    if echo "$@" | grep -qF "label:ready-for-agent"; then
      echo "[{\"number\":21,\"labels\":[{\"name\":\"ready-for-agent\"}]},{\"number\":22,\"labels\":[{\"name\":\"ready-for-agent\"}]}]"
    else
      echo "[]"
    fi
    exit 0
    ;;
esac
echo "mock gh: unhandled: $*" >&2
exit 2
'
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 20 2>&1) || rc=$?

  assert_contains "$out" "Enqueued PRD #20"   "enqueue-prd: enqueue message surfaced"
  assert_contains "$out" "Preflight"          "enqueue-prd: runs preflight"
  assert_contains "$out" "#21"                "enqueue-prd: preflight lists #21"
  assert_contains "$out" "#22"                "enqueue-prd: preflight lists #22"
  assert_contains "$out" "ref #20"            "enqueue-prd: RALPH.md updated, preflight shows ref #20"
}

# ─── --status also runs preflight ────────────────────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [5, 6]}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: {{PRD_REFERENCE}} -->
EOF

  bin_dir="$TEST_ROOT/bin-status"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"

  blob=$(printf '%s\n%s\n' \
    "$(issue_json 5 OPEN needs-triage 'Triage me.')" \
    "$(issue_json 6 OPEN ready-for-agent 'OK.')"
  )

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --status 2>&1) || rc=$?

  # --status always exits 0 even when preflight surfaces blockers — operators
  # use --status to inspect, not gate.
  [[ "$rc" -eq 0 ]] && pass "status: exits 0 even with blockers" \
    || fail "status: exits 0 even with blockers (got $rc)"
  assert_contains "$out" "Preflight"           "status: prints Preflight section"
  assert_contains "$out" "Queue mode: direct-numbers" \
    "status: surfaces queue mode"
  assert_contains "$out" "#5"                  "status: lists queued #5"
  assert_contains "$out" "#6"                  "status: lists queued #6"
  assert_contains "$out" "needs_triage"        "status: surfaces needs_triage for #5"
  assert_contains "$out" "{{PRD_REFERENCE}}"   "status: surfaces placeholder RALPH.md ref"
  # Existing --status fields still present.
  assert_contains "$out" "Parallelism"         "status: still prints Parallelism"
  assert_contains "$out" "Workers"             "status: still prints Workers"
}

# ─── --status with no queue uses issueSearch mode ─────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [], "issueSearch": "label:ready-for-agent -label:hitl"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  rc=0
  out=$(RALPH_MAIN_REPO="$repo" \
    "$repo/.ralph/launch.sh" --status 2>&1) || rc=$?

  assert_contains "$out" "Queue mode: issueSearch" \
    "status (search): surfaces issueSearch queue mode"
  assert_contains "$out" "label:ready-for-agent -label:hitl" \
    "status (search): echoes the configured search query"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
