#!/usr/bin/env bash
# Tests for --enqueue and --enqueue-prd in launch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_exit_zero() {
  local rc="$1" label="$2"
  [[ "$rc" -eq 0 ]] && pass "$label" || fail "$label (expected exit 0, got $rc)"
}

assert_exit_nonzero() {
  local rc="$1" label="$2"
  [[ "$rc" -ne 0 ]] && pass "$label" || fail "$label (expected non-zero, got 0)"
}

assert_contains() {
  local text="$1" needle="$2" label="$3"
  echo "$text" | grep -qF -- "$needle" && pass "$label" || fail "$label (expected to contain '$needle')"
}

assert_json() {
  local file="$1" path="$2" expected="$3" label="$4"
  local actual
  actual=$(jq -r "$path" "$file" 2>/dev/null)
  [[ "$actual" == "$expected" ]] && pass "$label" || fail "$label (expected '$expected', got '$actual')"
}

# Create a fresh minimal test repo with .ralph structure
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
  cp "$REPO_ROOT/ralph/launch.sh" .ralph/launch.sh
  cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
  echo "$dir"
}

# Create a mock gh binary in $1 that dispatches on $GH_MOCK_DISPATCH
# GH_MOCK_DISPATCH: comma-separated "subcommand:subsubcommand=response" pairs
# For enqueue-prd tests we use a script file approach
write_mock_gh() {
  local bin_dir="$1"
  local script_body="$2"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\n%s\n' "$script_body" > "$bin_dir/gh"
  chmod +x "$bin_dir/gh"
}

# ─── --enqueue tests ─────────────────────────────────────────────────────────

# Test 1: --enqueue happy path
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [5, 6], "order": "asc"}, "profile": "default"}
EOF
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 8 9 10 2>&1) || rc=$?
  assert_exit_zero "$rc" "--enqueue happy path exits 0"
  assert_contains "$out" "Enqueued 3 issues" "--enqueue happy path output"
  assert_contains "$out" "#8 #9 #10" "--enqueue lists issue numbers"
  assert_json "$repo/.ralph/config.json" '.issue.numbers | join(",")' "8,9,10" "--enqueue updates numbers"
  assert_json "$repo/.ralph/config.json" '.issue.order' "asc" "--enqueue preserves issue.order"
  assert_json "$repo/.ralph/config.json" '.profile' "default" "--enqueue preserves profile"
}

# Test 2: --enqueue missing config.json
{
  repo=$(new_repo)
  # No config.json
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 8 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue missing config exits non-zero"
  assert_contains "$out" "config.json" "--enqueue missing config error mentions config.json"
}

# Test 3: --enqueue invalid argument
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 8 abc 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue invalid arg exits non-zero"
}

# Test 4: --enqueue zero arguments
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue no args exits non-zero"
}

# Test 4b: --enqueue duplicate issue number
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 8 9 8 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue duplicate exits non-zero"
  assert_contains "$out" "Duplicate" "--enqueue duplicate reports error"
}

# Test 5: --enqueue idempotency
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": [8, 9]}}
EOF
  before=$(cat "$repo/.ralph/config.json")
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 8 9 2>&1) || rc=$?
  assert_exit_zero "$rc" "--enqueue idempotency exits 0"
  assert_contains "$out" "unchanged" "--enqueue idempotency output says unchanged"
  after=$(cat "$repo/.ralph/config.json")
  [[ "$before" == "$after" ]] && pass "--enqueue idempotency config unchanged" \
    || fail "--enqueue idempotency config changed unexpectedly"
}

# Test 6: --enqueue preserves all top-level config keys
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{
  "issue": {"numbers": [1], "order": "desc", "titleRegex": "^Slice"},
  "validation": "strict",
  "stages": ["build", "test"],
  "profile": "bun"
}
EOF
  rc=0
  RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 5 >/dev/null 2>&1 || rc=$?
  assert_json "$repo/.ralph/config.json" '.validation' "strict" "--enqueue preserves validation"
  assert_json "$repo/.ralph/config.json" '.stages[0]' "build" "--enqueue preserves stages"
  assert_json "$repo/.ralph/config.json" '.issue.titleRegex' "^Slice" "--enqueue preserves issue.titleRegex"
  assert_json "$repo/.ralph/config.json" '.issue.order' "desc" "--enqueue preserves issue.order"
}

# ─── --enqueue-prd tests ─────────────────────────────────────────────────────

# Test 7: --enqueue-prd happy path
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}, "profile": "default"}
EOF
  # RALPH.md with marker
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: {{PRD_REFERENCE}} -->
# Ralph TDD Loop

You are working through ONE slice of {{PRD_REFERENCE}} in test-owner/test-repo.
Read parent {{PRD_REFERENCE}} for vocabulary.
EOF
  bin_dir="$TEST_ROOT/bin-t7"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view")
    echo "{\"number\": 7}"
    exit 0
    ;;
  "issue list")
    if echo "$@" | grep -qF "label:ready-for-agent"; then
      echo "[{\"number\": 8, \"labels\": []}, {\"number\": 9, \"labels\": []}]"
    else
      echo "[{\"number\": 10}]"
    fi
    exit 0
    ;;
esac
echo "mock gh: unhandled: $*" >&2
exit 1
'
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 7 2>&1) || rc=$?
  assert_exit_zero "$rc" "--enqueue-prd happy path exits 0"
  assert_contains "$out" "Enqueued PRD #7" "--enqueue-prd happy path output"
  assert_contains "$out" "2 AFK slices" "--enqueue-prd AFK count"
  assert_contains "$out" "1 HITL skipped" "--enqueue-prd HITL count"
  assert_contains "$out" "#8 #9" "--enqueue-prd lists slice numbers"
  assert_json "$repo/.ralph/config.json" '.issue.numbers | join(",")' "8,9" "--enqueue-prd updates config"
  # RALPH.md updated
  ralph_content=$(cat "$repo/.ralph/RALPH.md")
  echo "$ralph_content" | grep -qF "#7" \
    && pass "--enqueue-prd updates RALPH.md" \
    || fail "--enqueue-prd updates RALPH.md (no #7 found)"
  echo "$ralph_content" | grep -qF "{{PRD_REFERENCE}}" \
    && fail "--enqueue-prd leaves {{PRD_REFERENCE}} placeholder in RALPH.md" \
    || pass "--enqueue-prd removes {{PRD_REFERENCE}} from RALPH.md"
}

# Test 8: --enqueue-prd no children found
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  bin_dir="$TEST_ROOT/bin-t8"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view") echo "{\"number\": 7}"; exit 0 ;;
  "issue list") echo "[]"; exit 0 ;;
esac
exit 1
'
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 7 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue-prd no children exits non-zero"
  assert_contains "$out" "No AFK" "--enqueue-prd no children error message"
}

# Test 9: --enqueue-prd HITL-only PRD
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  bin_dir="$TEST_ROOT/bin-t9"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view") echo "{\"number\": 7}"; exit 0 ;;
  "issue list")
    if echo "$@" | grep -qF "label:ready-for-agent"; then
      echo "[]"
    else
      echo "[{\"number\": 15}]"
    fi
    exit 0
    ;;
esac
exit 1
'
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 7 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue-prd HITL-only exits non-zero"
}

# Test 10: --enqueue-prd missing PRD
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  bin_dir="$TEST_ROOT/bin-t10"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view") echo "issue not found" >&2; exit 1 ;;
esac
exit 1
'
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 999 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue-prd missing PRD exits non-zero"
  assert_contains "$out" "#999" "--enqueue-prd missing PRD error mentions issue number"
}

# Test 11: --enqueue-prd RALPH.md without marker — warns and continues
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  # RALPH.md without marker
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
# Custom prompt without PRD marker
This is a custom prompt that has no RALPH_PRD_REF marker.
EOF
  bin_dir="$TEST_ROOT/bin-t11"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view") echo "{\"number\": 7}"; exit 0 ;;
  "issue list")
    if echo "$@" | grep -qF "label:ready-for-agent"; then
      echo "[{\"number\": 8}]"
    else
      echo "[]"
    fi
    exit 0
    ;;
esac
exit 1
'
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 7 2>&1) || rc=$?
  assert_exit_zero "$rc" "--enqueue-prd without RALPH.md marker exits 0"
  assert_contains "$out" "Warning" "--enqueue-prd without marker prints warning"
  # Config should still be updated
  assert_json "$repo/.ralph/config.json" '.issue.numbers[0]' "8" "--enqueue-prd without marker still updates config"
}

# Test 12: --enqueue-prd RALPH.md does not exist
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  # No RALPH.md
  bin_dir="$TEST_ROOT/bin-t12"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view") echo "{\"number\": 7}"; exit 0 ;;
  "issue list")
    if echo "$@" | grep -qF "label:ready-for-agent"; then
      echo "[{\"number\": 8}]"
    else
      echo "[]"
    fi
    exit 0
    ;;
esac
exit 1
'
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 7 2>&1) || rc=$?
  assert_exit_zero "$rc" "--enqueue-prd no RALPH.md exits 0 with warning"
  assert_contains "$out" "Warning" "--enqueue-prd no RALPH.md prints warning"
}

# Test 13: --enqueue-prd idempotent RALPH.md update
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  # Already-installed RALPH.md with prior PRD ref #5
  cat > "$repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #5 -->
# Ralph TDD Loop

You are working through ONE slice of #5 in test-owner/test-repo.
Read parent #5 for vocabulary.
EOF
  bin_dir="$TEST_ROOT/bin-t13"
  write_mock_gh "$bin_dir" '
case "$1 $2" in
  "issue view") echo "{\"number\": 7}"; exit 0 ;;
  "issue list")
    if echo "$@" | grep -qF "label:ready-for-agent"; then
      echo "[{\"number\": 8}]"
    else
      echo "[]"
    fi
    exit 0
    ;;
esac
exit 1
'
  rc=0
  RALPH_MAIN_REPO="$repo" RALPH_GH_BIN="$bin_dir/gh" \
    "$repo/.ralph/launch.sh" --enqueue-prd 7 >/dev/null 2>&1 || rc=$?
  ralph_content=$(cat "$repo/.ralph/RALPH.md")
  echo "$ralph_content" | grep -qF "#7" \
    && pass "--enqueue-prd updates prior PRD ref in RALPH.md" \
    || fail "--enqueue-prd updates prior PRD ref in RALPH.md"
  echo "$ralph_content" | grep -qF "#5" \
    && fail "--enqueue-prd leaves stale #5 in RALPH.md" \
    || pass "--enqueue-prd removes stale #5 from RALPH.md"
}

# Test 14: --enqueue and --enqueue-prd are mutually exclusive
{
  repo=$(new_repo)
  cat > "$repo/.ralph/config.json" <<'EOF'
{"issue": {"numbers": []}}
EOF
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --enqueue 8 --enqueue-prd 7 2>&1) || rc=$?
  assert_exit_nonzero "$rc" "--enqueue + --enqueue-prd mutual exclusivity exits non-zero"
  assert_contains "$out" "mutually exclusive" "--enqueue + --enqueue-prd error message"
}

# Test 15: --help documents --enqueue and --enqueue-prd
{
  repo=$(new_repo)
  # Create a minimal ralph.sh so the script doesn't fail before --help
  touch "$repo/.ralph/ralph.sh"
  chmod +x "$repo/.ralph/ralph.sh"
  rc=0
  out=$(RALPH_MAIN_REPO="$repo" "$repo/.ralph/launch.sh" --help 2>&1) || rc=$?
  assert_exit_zero "$rc" "--help exits 0"
  assert_contains "$out" "--enqueue" "--help documents --enqueue"
  assert_contains "$out" "--enqueue-prd" "--help documents --enqueue-prd"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
