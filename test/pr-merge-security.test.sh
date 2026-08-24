#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="owner/repo"
EXPECTED_SHA="0123456789abcdef0123456789abcdef01234567"
GH_SCENARIO=""
GH_LOG="$TEST_ROOT/gh.log"

gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  case "$1 $2" in
    "pr checks")
      case "$GH_SCENARIO" in
        no-checks) echo '[]' ;;
        *) echo '[{"bucket":"pass"}]' ;;
      esac
      ;;
    "pr list")
      case "$GH_SCENARIO" in
        wrong-head)
          printf '17\tfalse\tmain\tMERGEABLE\texternal-42\t%s\towner/repo\ttrusted-user\tCloses #42\n' "$EXPECTED_SHA"
          ;;
        wrong-sha)
          printf '17\tfalse\tmain\tMERGEABLE\tslice-42-owned\t1111111111111111111111111111111111111111\towner/repo\ttrusted-user\tCloses #42\n'
          ;;
        wrong-repo)
          printf '17\tfalse\tmain\tMERGEABLE\tslice-42-owned\t%s\texternal/fork\ttrusted-user\tCloses #42\n' "$EXPECTED_SHA"
          ;;
        wrong-author)
          printf '17\tfalse\tmain\tMERGEABLE\tslice-42-owned\t%s\towner/repo\texternal-user\tCloses #42\n' "$EXPECTED_SHA"
          ;;
        *)
          printf '17\tfalse\tmain\tMERGEABLE\tslice-42-owned\t%s\towner/repo\ttrusted-user\tCloses #42\n' "$EXPECTED_SHA"
          ;;
      esac
      ;;
    "pr view")
      echo "42"
      ;;
    "pr merge")
      return 0
      ;;
    "issue close")
      return 0
      ;;
    *)
      echo "unexpected gh call: $*" >&2
      return 2
      ;;
  esac
}

# shellcheck source=../ralph/lib/pr-merge.sh
. "$REPO_ROOT/ralph/lib/pr-merge.sh"

GH_SCENARIO="no-checks"
if ralph_pr_checks_passed 17; then
  echo "FAIL: zero-check PR was treated as green" >&2
  exit 1
fi
echo "PASS: zero-check PR fails closed"

for unsafe_scenario in wrong-head wrong-sha wrong-repo wrong-author; do
  : > "$GH_LOG"
  GH_SCENARIO="$unsafe_scenario"
  if ralph_merge_ready_open_pr_for_issue \
    42 main slice-42-owned "$EXPECTED_SHA" trusted-user; then
    echo "FAIL: $unsafe_scenario PR was merged" >&2
    exit 1
  fi
  if grep -q '^pr merge ' "$GH_LOG"; then
    echo "FAIL: $unsafe_scenario PR reached gh pr merge" >&2
    exit 1
  fi
  echo "PASS: $unsafe_scenario PR is rejected"
done

: > "$GH_LOG"
GH_SCENARIO="owned"
ralph_merge_ready_open_pr_for_issue \
  42 main slice-42-owned "$EXPECTED_SHA" trusted-user
if ! grep -q "pr merge 17 .*--match-head-commit $EXPECTED_SHA" "$GH_LOG"; then
  echo "FAIL: owned PR merge was not bound to the approved head commit" >&2
  cat "$GH_LOG" >&2
  exit 1
fi
echo "PASS: owned PR merge is bound to the approved head commit"

: > "$GH_LOG"
GH_SCENARIO="owned"
ralph_merge_release_branch_pr_for_issue \
  42 main slice-42-owned "$EXPECTED_SHA" trusted-user
if ! grep -q "pr merge 17 .*--match-head-commit $EXPECTED_SHA" "$GH_LOG"; then
  echo "FAIL: release PR merge was not bound to the approved head commit" >&2
  cat "$GH_LOG" >&2
  exit 1
fi
echo "PASS: release PR merge uses the same provenance gate"
