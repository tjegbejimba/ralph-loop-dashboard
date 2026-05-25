#!/usr/bin/env bash
# Unit tests for parse_blockers in ralph/lib/state.sh.
#
# Regression coverage for issue #73: when "## Blocked by" is the last `##`
# section of an issue body, the old awk-based extractor over-matched trailing
# `#N` refs (e.g. the `Part of #<parent>` footer the `to-issues` skill emits),
# permanently stalling slices whose parent PRD stays OPEN.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# state.sh derives STATE_DIR from $LOG_DIR at source time and references
# $REPO inside is_issue_satisfied. We only exercise parse_blockers, so empty
# defaults are fine — just satisfy `set -u`.
export LOG_DIR="$TEST_ROOT/logs"
export REPO="testowner/testrepo"
mkdir -p "$LOG_DIR"

# shellcheck source=/dev/null
source "$REPO_ROOT/ralph/lib/state.sh"

FAILS=0
PASSES=0

# assert_blockers NAME BODY EXPECTED_SPACE_DELIMITED_NUMBERS
# Compares the sorted, newline-stripped output of parse_blockers to a
# space-delimited expected string. An empty EXPECTED means "no blockers".
assert_blockers() {
  local name="$1" body="$2" expected="$3"
  local actual
  actual=$(parse_blockers "$body" | tr '\n' ' ')
  # Portable trailing-whitespace strip (BSD sed doesn't grok `\+`).
  actual="${actual%"${actual##*[![:space:]]}"}"
  expected="${expected%"${expected##*[![:space:]]}"}"
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok   %s\n' "$name"
    PASSES=$((PASSES + 1))
  else
    printf '  FAIL %s\n        expected: [%s]\n        actual:   [%s]\n' \
      "$name" "$expected" "$actual"
    FAILS=$((FAILS + 1))
  fi
}

# 1. Happy path: another `## ` section follows.
assert_blockers "happy path with trailing section" "$(cat <<'EOF'
## Acceptance criteria
- [ ] Foo

## Blocked by
- #125
- #126

## Notes
Some trailing notes referencing #999.
EOF
)" "125 126"

# 2. Bug repro #1: `## Blocked by` is the last `##` section, followed
#    immediately (no blank line) by a `Part of #<parent>` footer. The
#    parent must NOT be reported as a blocker.
assert_blockers "blocked-by last + Part of footer" "$(cat <<'EOF'
## Blocked by
- #322
Part of #320
EOF
)" "322"

# 3. Bug repro #2: `Closes #N` trailer.
assert_blockers "blocked-by last + Closes footer" "$(cat <<'EOF'
## Blocked by
- #322

Closes #999
EOF
)" "322"

# 4. Bug repro #3 — canonical to-issues shape: blank line separates the
#    bullet list from the `Part of #320` footer.
assert_blockers "blocked-by last + blank + Part of footer (canonical)" "$(cat <<'EOF'
## Acceptance criteria
- [ ] Foo

## Blocked by
- #322

Part of #320
EOF
)" "322"

# 5. None short-circuit.
assert_blockers "None short-circuit" "$(cat <<'EOF'
## Blocked by
None — can start immediately.

Part of #320
EOF
)" ""

# 6. "No blockers" short-circuit (advertised in docs/dependency-aware-run-queues.md).
assert_blockers "No blockers short-circuit" "$(cat <<'EOF'
## Blocked by
No blockers; see #320 for parent context.
EOF
)" ""

# 7. Multiple blockers across a blank line — both extracted.
assert_blockers "multiple blockers across blank line" "$(cat <<'EOF'
## Blocked by
- #125

- #126
EOF
)" "125 126"

# 8. Blocker line with trailing text (slice descriptor) still extracted.
assert_blockers "blocker with trailing parenthetical" "$(cat <<'EOF'
## Blocked by
- #125 (Slice 0)
- #126 (Slice 1)
EOF
)" "125 126"

# 9. `*` and `+` bullet markers accepted.
assert_blockers "asterisk and plus bullets" "$(cat <<'EOF'
## Blocked by
* #200
+ #201
EOF
)" "200 201"

# 10. Regression assertion: contract is intentionally bullet-only. Inline
#     prose `Blocked by #N` inside the section is NOT extracted. (Better to
#     fail-closed and skip a candidate that documents blockers in prose
#     than to over-stall on every PRD-decomposed slice in the queue.)
assert_blockers "inline prose blocker NOT extracted" "$(cat <<'EOF'
## Blocked by
Blocked by #777
EOF
)" ""

# 11. Issue body without any `## Blocked by` section at all.
assert_blockers "no blocked-by section" "$(cat <<'EOF'
## Acceptance criteria
- [ ] Foo

Part of #320
EOF
)" ""

printf '\n%d passed, %d failed\n' "$PASSES" "$FAILS"

if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
