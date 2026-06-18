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
  cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
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

# ─── Tracer bullet: --enqueue surfaces non-runnable canonical states ──────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [], "issueSearch": "is:open no:assignee label:ralph:ready -label:ralph:failed (label:work:slice OR label:work:standalone)"}, "profile": "default"}
EOF

  bin_dir="$TEST_ROOT/bin-tracer"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"

  blob=$(printf '%s\n%s\n' \
    "$(issue_json 5 OPEN 'ralph:needs-triage,priority:P2,work:standalone' 'A child slice.')" \
    "$(issue_json 6 OPEN 'ralph:needs-triage,priority:P2,work:standalone' 'Another slice.')"
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
  assert_contains "$out" "not_runnable_state(ralph:needs-triage)" \
    "--enqueue preflight surfaces non-runnable state"
  # Final verdict line for blocker case.
  assert_contains "$out" "blockers" \
    "--enqueue preflight prints a blockers verdict"
}

# ─── Ready path: queued issue is canonical runnable work, no blockers ─────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [], "issueSearch": "is:open no:assignee label:ralph:ready -label:ralph:failed (label:work:slice OR label:work:standalone)"}, "profile": "default"}
EOF
  # RALPH.md with a concrete PRD reference (no placeholder).
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
# Ralph TDD Loop
You are working through ONE slice of #4 in test-owner/test-repo.
EOF

  bin_dir="$TEST_ROOT/bin-ready"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"

  blob=$(issue_json 7 OPEN 'ralph:ready,priority:P2,work:standalone' 'A ready standalone issue with no blockers.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 7 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "ready: --enqueue exits 0" \
    || fail "ready: --enqueue exits 0 (got $rc)"
  assert_contains     "$out" "Ready to launch"      "ready: verdict is ✅ Ready to launch"
  assert_contains     "$out" "ref #4"                "ready: surfaces concrete PRD ref"
  assert_contains     "$out" "Repo: clean"           "ready: surfaces clean repo state"
  assert_not_contains "$out" "not_runnable_state"    "ready: no non-runnable state warning"
  assert_not_contains "$out" "missing_work_type"     "ready: work type present"
  assert_not_contains "$out" "preflight blockers"    "ready: no blocker verdict"
}

# ─── Queued path: already-enqueued issues remain claimable ────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [17], "issueSearch": "is:open no:assignee label:ralph:ready -label:ralph:failed (label:work:slice OR label:work:standalone)"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  bin_dir="$TEST_ROOT/bin-queued"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"
  blob=$(issue_json 17 OPEN 'ralph:queued,priority:P2,work:standalone' 'Queued by --enqueue.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --status 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "queued: --status exits 0" \
    || fail "queued: --status exits 0 (got $rc)"
  assert_contains     "$out" "Ready to launch"           "queued: verdict is ✅ Ready to launch"
  assert_not_contains "$out" "not_runnable_state(ralph:queued)" "queued: not rejected as non-runnable"
}

# ─── ralph:hitl state is surfaced ─────────────────────────────────────────────
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
  blob=$(issue_json 8 OPEN "ralph:hitl,priority:P2,work:standalone" 'A human-required issue.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 8 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "hitl: --enqueue exits 0" \
    || fail "hitl: --enqueue exits 0 (got $rc)"
  assert_contains "$out" "not_runnable_state(ralph:hitl)" "hitl: warning surfaced"
  assert_contains "$out" "preflight blockers" "hitl: verdict is blockers"
}

# ─── closed issue → queue drained (informational, not a blocker) ─────────────
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
  blob=$(issue_json 9 CLOSED 'ralph:done,priority:P2,work:standalone' 'Already merged slice.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 9 2>&1) || rc=$?

  assert_contains     "$out" "CLOSED"          "closed: state surfaced"
  assert_not_contains "$out" "#9 CLOSED closed" \
    "closed: redundant 'closed' warning tag dropped (state already says CLOSED)"
  assert_contains     "$out" "Queue drained"   "closed: verdict is queue drained"
  assert_not_contains "$out" "preflight blockers" \
    "closed-only queue is informational, not a blocker"
  [[ "$rc" -eq 0 ]] && pass "closed: exits 0 (queue drained is not a blocker)" \
    || fail "closed: exits 0 (got $rc)"
}

# ─── mixed open+closed queue → open issues drive verdict ──────────────────────
# Regression for the "Loop is mid-run with some issues already merged" case.
# The closed entries should not flag as blockers because the loop will just
# skip them; the open ones are ready, so the overall verdict is Ready.
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  bin_dir="$TEST_ROOT/bin-mixed"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"
  blob=$(printf '%s\n%s\n' \
    "$(issue_json 30 CLOSED 'ralph:done,priority:P2,work:standalone' 'Done.')" \
    "$(issue_json 31 OPEN  'ralph:ready,priority:P2,work:standalone' 'Pending.')"
  )

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue 30 31 2>&1) || rc=$?

  assert_contains     "$out" "Ready to launch"  "mixed: verdict is Ready (open issues remain)"
  assert_not_contains "$out" "preflight blockers" \
    "mixed: closed entries alongside open ones do not block"
  [[ "$rc" -eq 0 ]] && pass "mixed: exits 0" || fail "mixed: exits 0 (got $rc)"
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
  blob=$(issue_json 10 OPEN 'ralph:ready,priority:P2,work:standalone' 'A slice.')

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
  blob=$(issue_json 11 OPEN 'ralph:ready,priority:P2,work:standalone' 'A slice.')

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
  blob=$(issue_json 12 OPEN 'ralph:ready,priority:P2,work:standalone' "$body")

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
  # Two layers: --enqueue-prd uses `gh issue list ...` to find canonical
  # runnable slices, then preflight uses per-issue canonical metadata.
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    num="$3"
    if [[ "$num" == "20" ]]; then
      echo "{\"number\":20,\"state\":\"OPEN\",\"labels\":[{\"name\":\"ralph:evaluated\"},{\"name\":\"priority:P2\"},{\"name\":\"work:prd\"}],\"body\":\"PRD\"}"
      exit 0
    fi
    # Preflight per-issue lookup.
    echo "{\"number\":$num,\"state\":\"OPEN\",\"labels\":[{\"name\":\"ralph:ready\"},{\"name\":\"priority:P2\"},{\"name\":\"work:slice\"}],\"body\":\"Parent #20\"}"
    exit 0
    ;;
  "issue list")
    if echo "$@" | grep -qF "label:work:slice"; then
      echo "[{\"number\":21,\"state\":\"OPEN\",\"title\":\"Slice 1: A\",\"body\":\"Parent #20\",\"labels\":[{\"name\":\"ralph:ready\"},{\"name\":\"priority:P2\"},{\"name\":\"work:slice\"}],\"assignees\":[]},{\"number\":22,\"state\":\"OPEN\",\"title\":\"Slice 2: B\",\"body\":\"Parent #20\",\"labels\":[{\"name\":\"ralph:ready\"},{\"name\":\"priority:P2\"},{\"name\":\"work:slice\"}],\"assignees\":[]}]"
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
    "$(issue_json 5 OPEN 'ralph:needs-triage,priority:P2,work:standalone' 'Triage me.')" \
    "$(issue_json 6 OPEN 'ralph:ready,priority:P2,work:standalone' 'OK.')"
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
  assert_contains "$out" "not_runnable_state(ralph:needs-triage)" "status: surfaces non-runnable state for #5"
  assert_contains "$out" "{{PRD_REFERENCE}}"   "status: surfaces placeholder RALPH.md ref"
  # Existing --status fields still present.
  assert_contains "$out" "Parallelism"         "status: still prints Parallelism"
  assert_contains "$out" "Workers"             "status: still prints Workers"
}

# ─── --status with no queue uses issueSearch mode ─────────────────────────────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [], "issueSearch": "is:open no:assignee label:ralph:ready -label:ralph:failed (label:work:slice OR label:work:standalone)"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  rc=0
  out=$(RALPH_MAIN_REPO="$repo" \
    "$repo/.ralph/launch.sh" --status 2>&1) || rc=$?

  assert_contains "$out" "Queue mode: issueSearch" \
    "status (search): surfaces issueSearch queue mode"
  assert_contains "$out" "label:ralph:ready" \
    "status (search): echoes the configured search query"
}

# ─── Regression: config.json with CRLF line endings ───────────────────────────
# On Windows, `jq -r '.[]'` emits CRLF line endings, which leaked through
# preflight's numbers iterator and produced calls like
# `gh issue view 187$'\r' ...` that real gh rejects with "lookup_failed".
# The actual worker path in ralph.sh already stripped CR (`| tr -d '\r'`);
# preflight was missing it. This test uses a stricter mock gh that rejects
# any non-numeric issue number — the shared mock parses with jq --argjson,
# which silently tolerates trailing whitespace like \r, so it cannot
# reproduce the user-visible failure.
{
  repo=$(new_repo)
  # Write a config with explicit CRLF endings to reproduce the on-Windows
  # state of config.json after `gh`/`jq`-mediated writes on git-bash.
  printf '{\r\n  "issue": {\r\n    "numbers": [11, 12]\r\n  },\r\n  "profile": "default"\r\n}\r\n' \
    > "$repo/.ralph/config.json"
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF

  bin_dir="$TEST_ROOT/bin-crlf"
  # Strict mock: refuse to look up any issue whose number isn't purely digits.
  # Matches real gh's behavior — it URL-encodes the path and the server 404s.
  write_mock_gh "$bin_dir" '
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  num="$3"
  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    echo "gh: not a valid issue number: $num" >&2
    exit 1
  fi
  match=$(printf "%s\n" "$ISSUE_BLOB" | jq -c --argjson n "$num" "select(.number == \$n)")
  [[ -z "$match" ]] && { echo "issue not found" >&2; exit 1; }
  echo "$match"
  exit 0
fi
[[ "$1" == "auth" && "$2" == "status" ]] && exit 0
echo "mock gh: unhandled: $*" >&2
exit 2
'

  blob=$(printf '%s\n%s\n' \
    "$(issue_json 11 OPEN 'ralph:ready,priority:P2,work:standalone' 'CRLF-config slice.')" \
    "$(issue_json 12 OPEN 'ralph:ready,priority:P2,work:standalone' 'Another CRLF-config slice.')"
  )

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --status 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "crlf: --status exits 0" \
    || fail "crlf: --status exits 0 (got $rc)"
  assert_contains     "$out" "#11"           "crlf: lists issue #11"
  assert_contains     "$out" "#12"           "crlf: lists issue #12"
  assert_not_contains "$out" "lookup_failed" "crlf: no lookup_failed warning"
}

# ─── --status: empty state.json claims renders "(none)", not a blank section ──
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [], "issueSearch": "is:open no:assignee label:ralph:ready -label:ralph:failed (label:work:slice OR label:work:standalone)"}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF
  # state.json exists but claims map is empty (loop ran and released claims).
  echo '{"claims": {}}' > "$repo/.ralph/state.json"

  rc=0
  out=$(RALPH_MAIN_REPO="$repo" \
    "$repo/.ralph/launch.sh" --status 2>&1) || rc=$?

  # Find the "Claims (from state.json):" header and the line that follows it.
  claims_section=$(echo "$out" | awk '/^Claims \(from state\.json\):/{flag=1; next} flag && /^[[:space:]]*$/{exit} flag{print}')
  if echo "$claims_section" | grep -qE '^\s*\(none\)'; then
    pass "empty claims: renders (none) instead of a blank section"
  else
    fail "empty claims: expected '(none)' under Claims header, got: $claims_section"
    echo "--- output ---" >&2
    echo "$out" >&2
    echo "--------------" >&2
  fi
}

# ─── --status: workers line truncates the giant copilot -p prompt ─────────────
# Exercises the truncation logic on a synthetic ps-style worker line. The
# regression we care about: a `--flag` example embedded inside the prompt body
# (e.g. `gh pr list --repo …`) must NOT become the cut point for trailing
# CLI flags. The cut MUST be at the last ` --` in the line.
{
  synthetic='99999 copilot -p # Ralph Loop\n\nbody with embedded gh pr list --repo example --json state and more text --allow-all --model claude-sonnet-4.5'
  truncated=$(printf '%s\n' "$synthetic" | awk '
    {
      pid=$1
      cmd=""
      for (i=2; i<=NF; i++) cmd = cmd (i==2 ? "" : " ") $i
      marker = "copilot -p "
      idx = index(cmd, marker)
      if (idx > 0) {
        prefix = substr(cmd, 1, idx + length(marker) - 1)
        rest   = substr(cmd, idx + length(marker))
        n_tok = split(rest, toks, /[ \t]+/)
        cut = n_tok + 1
        i = n_tok
        while (i >= 1) {
          if (toks[i] ~ /^--[a-zA-Z]/) {
            cut = i; i--
          } else if (i > 1 && toks[i-1] ~ /^--[a-zA-Z]/) {
            cut = i - 1; i -= 2
          } else { break }
        }
        if (cut <= n_tok) {
          prompt_part = ""
          for (j = 1; j < cut; j++) prompt_part = prompt_part (j == 1 ? "" : " ") toks[j]
          trailing = ""
          for (j = cut; j <= n_tok; j++) trailing = trailing " " toks[j]
        } else {
          prompt_part = rest; trailing = ""
        }
        printf "  %s %s<prompt %d chars>%s\n", pid, prefix, length(prompt_part), trailing
      } else {
        printf "  %s %s\n", pid, cmd
      }
    }
  ')
  assert_contains     "$truncated" "<prompt "          "workers truncate: prompt replaced with placeholder"
  assert_contains     "$truncated" "--allow-all"       "workers truncate: trailing flag preserved"
  assert_contains     "$truncated" "--model"           "workers truncate: --model preserved"
  assert_not_contains "$truncated" "embedded gh pr list" "workers truncate: prompt body removed"
  # The first " --" in the prompt body (` --repo`) must NOT have been used as
  # the cut point — regression for the first-`--` heuristic bug.
  assert_not_contains "$truncated" "--repo example" \
    "workers truncate: did not cut at first ' --' inside prompt body"
}

# ─── --status with active loop → "Loop in progress" verdict, dirty tree OK ────
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [50]}, "profile": "default"}
EOF
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #4 -->
EOF
  # Mimic an in-flight loop: claim in state.json + dirty tree.
  echo '{"claims": {"50": {"workerId": 1, "pid": 1, "logFile": "x.log"}}}' \
    > "$repo/.ralph/state.json"
  echo "in-progress edit" >> "$repo/README.md"

  bin_dir="$TEST_ROOT/bin-loop-active"
  write_mock_gh "$bin_dir" "$GH_MOCK_PREFLIGHT"
  blob=$(issue_json 50 OPEN 'ralph:running,priority:P2,work:standalone' 'Slice in flight.')

  rc=0
  out=$(ISSUE_BLOB="$blob" \
    RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --status 2>&1) || rc=$?

  [[ "$rc" -eq 0 ]] && pass "loop-active: --status exits 0" \
    || fail "loop-active: --status exits 0 (got $rc)"
  assert_contains     "$out" "Loop in progress"   "loop-active: verdict is Loop in progress"
  assert_not_contains "$out" "preflight blockers" "loop-active: dirty tree is not flagged as blocker"
  assert_contains     "$out" "Repo: dirty"        "loop-active: still surfaces the dirty repo state"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
