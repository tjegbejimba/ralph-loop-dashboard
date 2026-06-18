#!/usr/bin/env bash
# Tests for ralph_apply_label_transition set-semantics.
#
# Regression guard for incident #125 (an issue ended up with BOTH ralph:ready and
# ralph:failed). docs/labels.md requires exactly one ralph: state label at a time.
# Each transition must set exactly one canonical state label and remove ALL other
# canonical state labels, so a skipped step (e.g. enqueue) can never leave a stale
# state label behind.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/ralph/lib/labels.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Canonical state labels — exactly one may be set at a time (docs/labels.md).
CANONICAL_STATES=(
  ralph:needs-triage
  ralph:evaluated
  ralph:ready
  ralph:blocked
  ralph:hitl
  ralph:queued
  ralph:running
  ralph:done
  ralph:failed
)

# Fake gh that records its full argument vector (one token per line) to $GH_RECORD.
export GH_RECORD="$TEST_ROOT/gh-args"
GH="$TEST_ROOT/fake-gh"
cat > "$GH" <<'EOF'
#!/usr/bin/env bash
: > "$GH_RECORD"
for a in "$@"; do printf '%s\n' "$a" >> "$GH_RECORD"; done
exit 0
EOF
chmod +x "$GH"
export GH
export REPO="test-owner/test-repo"

run_transition() {
  : > "$GH_RECORD"
  ralph_apply_label_transition "$1" "$2"
}

added_label() {
  awk '/^--add-label$/{getline; print; exit}' "$GH_RECORD"
}

records_remove() {
  local label="$1" prev=""
  while IFS= read -r line; do
    [[ "$prev" == "--remove-label" && "$line" == "$label" ]] && return 0
    prev="$line"
  done < "$GH_RECORD"
  return 1
}

assert_added() {
  local transition="$1" expected="$2" got
  got="$(added_label)"
  [[ "$got" == "$expected" ]] && pass "$transition adds $expected" \
    || fail "$transition adds $expected (got '$got')"
}

assert_removes_siblings() {
  # Every canonical state label except the added one must be removed, and the
  # added one must never be removed.
  local transition="$1" added="$2" s ok=1
  for s in "${CANONICAL_STATES[@]}"; do
    if [[ "$s" == "$added" ]]; then
      if records_remove "$s"; then ok=0; fail "$transition must NOT remove its own state $s"; fi
    else
      if ! records_remove "$s"; then ok=0; fail "$transition must remove sibling state $s"; fi
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    pass "$transition removes all sibling states except $added"
  fi
}

# enqueue -> ralph:queued
run_transition 42 enqueue
assert_added "enqueue" "ralph:queued"
assert_removes_siblings "enqueue" "ralph:queued"

# claim -> ralph:running  (REGRESSION #125: must clear ralph:ready)
run_transition 42 claim
assert_added "claim" "ralph:running"
records_remove "ralph:ready" && pass "claim removes ralph:ready (regression #125)" \
  || fail "claim removes ralph:ready (regression #125)"
assert_removes_siblings "claim" "ralph:running"

# done -> ralph:done
run_transition 42 done
assert_added "done" "ralph:done"
assert_removes_siblings "done" "ralph:done"

# fail -> ralph:failed  (REGRESSION #125: must clear ralph:ready)
run_transition 42 fail
assert_added "fail" "ralph:failed"
records_remove "ralph:ready" && pass "fail removes ralph:ready (regression #125)" \
  || fail "fail removes ralph:ready (regression #125)"
assert_removes_siblings "fail" "ralph:failed"

# retry -> ralph:queued
run_transition 42 retry
assert_added "retry" "ralph:queued"
assert_removes_siblings "retry" "ralph:queued"

# Guard: RALPH_DISABLE_LABEL_TRANSITIONS short-circuits before any gh call.
: > "$GH_RECORD"
RALPH_DISABLE_LABEL_TRANSITIONS=1 ralph_apply_label_transition 42 claim
[[ ! -s "$GH_RECORD" ]] && pass "RALPH_DISABLE_LABEL_TRANSITIONS skips gh" \
  || fail "RALPH_DISABLE_LABEL_TRANSITIONS skips gh (gh was invoked)"

# Guard: missing REPO short-circuits before any gh call.
: > "$GH_RECORD"
( unset REPO; ralph_apply_label_transition 42 claim )
[[ ! -s "$GH_RECORD" ]] && pass "missing REPO skips gh" \
  || fail "missing REPO skips gh (gh was invoked)"

# Unknown transition returns non-zero.
rc=0
ralph_apply_label_transition 42 bogus >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && pass "unknown transition returns non-zero" \
  || fail "unknown transition returns non-zero (got $rc)"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
