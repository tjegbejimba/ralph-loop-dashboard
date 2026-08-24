#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MAIN="$TEST_ROOT/main"
REMOTE="$TEST_ROOT/remote.git"
LOOP="$TEST_ROOT/loop"
MARKER="$TEST_ROOT/worker-head"

git init -q --bare "$REMOTE"
git init -q "$MAIN"
git -C "$MAIN" checkout -qb main
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
echo "main" > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit -qm "main"
git -C "$MAIN" remote add origin "$REMOTE"
git -C "$MAIN" remote add upstream "$REMOTE"
git -C "$MAIN" push -q origin main

git -C "$MAIN" checkout -qb release/v2
echo "approved" > "$MAIN/release.txt"
git -C "$MAIN" add release.txt
git -C "$MAIN" commit -qm "approved release base"
APPROVED_COMMIT="$(git -C "$MAIN" rev-parse HEAD)"
git -C "$MAIN" push -q upstream release/v2

echo "moved" >> "$MAIN/release.txt"
git -C "$MAIN" commit -qam "advance release base after preflight"
MOVED_COMMIT="$(git -C "$MAIN" rev-parse HEAD)"
git -C "$MAIN" push -q upstream release/v2
git -C "$MAIN" checkout -q main

"$REPO_ROOT/install.sh" "$MAIN" --scripts-only --profile generic >/dev/null

cat > "$MAIN/.ralph/ralph.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "${RALPH_BASE_REMOTE:-}" = "upstream"
test "${RALPH_BASE_BRANCH:-}" = "release/v2"
test "${RALPH_BASE_COMMIT:-}" = "${EXPECTED_BASE_COMMIT:?}"
git rev-parse HEAD > "${WORKER_HEAD_MARKER:?}"
EOF
chmod +x "$MAIN/.ralph/ralph.sh"

RALPH_MAIN_REPO="$MAIN" \
RALPH_LOOP_REPO="$LOOP" \
RALPH_REPO="owner/repo" \
RALPH_BASE_REMOTE="upstream" \
RALPH_BASE_BRANCH="release/v2" \
RALPH_BASE_COMMIT="$APPROVED_COMMIT" \
EXPECTED_BASE_COMMIT="$APPROVED_COMMIT" \
WORKER_HEAD_MARKER="$MARKER" \
  "$MAIN/.ralph/launch.sh" --foreground --once >/dev/null

WORKER_COMMIT="$(tr -d '\r\n' < "$MARKER")"
if [[ "$WORKER_COMMIT" != "$APPROVED_COMMIT" ]]; then
  echo "FAIL: worker started at $WORKER_COMMIT, expected approved $APPROVED_COMMIT" >&2
  exit 1
fi
if [[ "$WORKER_COMMIT" == "$MOVED_COMMIT" ]]; then
  echo "FAIL: worker followed the moving release ref instead of the approved commit" >&2
  exit 1
fi

UPSTREAM_REF="$(git -C "$LOOP" rev-parse --abbrev-ref '@{upstream}')"
if [[ "$UPSTREAM_REF" != "upstream/release/v2" ]]; then
  echo "FAIL: worker upstream is $UPSTREAM_REF, expected upstream/release/v2" >&2
  exit 1
fi

echo "PASS: launcher pins workers to the approved configured base commit"

cp "$REPO_ROOT/ralph/ralph.sh" "$MAIN/.ralph/ralph.sh"
chmod +x "$MAIN/.ralph/ralph.sh"
cat > "$MAIN/.ralph/config.json" <<'EOF'
{
  "profile": "generic",
  "repo": "owner/repo",
  "issue": {
    "numbers": [7],
    "issueSearch": "label:ralph:ready",
    "titleRegex": "^Slice [0-9]+:",
    "titleNumRegex": "^Slice (?<x>[0-9]+):"
  }
}
EOF
cat > "$MAIN/.ralph/RALPH.md" <<'EOF'
Test prompt.
EOF

MOCK_GH="$TEST_ROOT/gh"
cat > "$MOCK_GH" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue view" ]]; then
  echo '{"number":7,"state":"OPEN","title":"Held item","body":"","labels":[{"name":"ralph:hitl"},{"name":"priority:P2"},{"name":"work:standalone"}],"assignees":[]}'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 2
EOF
chmod +x "$MOCK_GH"

(
  cd "$LOOP"
  RALPH_REPO="owner/repo" \
  RALPH_GH_BIN="$MOCK_GH" \
  RALPH_BASE_REMOTE="upstream" \
  RALPH_BASE_BRANCH="release/v2" \
  RALPH_BASE_COMMIT="$APPROVED_COMMIT" \
  RALPH_IDLE_EXIT_POLLS=1 \
  RALPH_POLL_SEC=0.01 \
    "$MAIN/.ralph/ralph.sh" >/dev/null
)

RESYNCED_COMMIT="$(git -C "$LOOP" rev-parse HEAD)"
if [[ "$RESYNCED_COMMIT" != "$APPROVED_COMMIT" ]]; then
  echo "FAIL: worker startup sync moved to $RESYNCED_COMMIT, expected approved $APPROVED_COMMIT" >&2
  exit 1
fi

echo "PASS: worker startup sync preserves the approved configured base commit"

assert_launch_fails() {
  local label="$1" expected="$2"
  shift 2
  local output rc=0
  output=$(env \
    RALPH_MAIN_REPO="$MAIN" \
    RALPH_LOOP_REPO="$TEST_ROOT/rejected-loop" \
    RALPH_REPO="owner/repo" \
    "$@" \
    "$MAIN/.ralph/launch.sh" --foreground --once 2>&1) || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  fi
  if ! echo "$output" | grep -qF "$expected"; then
    echo "FAIL: $label did not report '$expected'" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "PASS: $label fails closed"
}

assert_launch_fails \
  "option-like base remote" \
  "RALPH_BASE_REMOTE is not a valid remote name" \
  RALPH_BASE_REMOTE=--upload-pack=payload

assert_launch_fails \
  "option-like base branch" \
  "RALPH_BASE_BRANCH is not a valid branch name" \
  RALPH_BASE_BRANCH=--force

git -C "$MAIN" checkout -q --orphan unrelated
git -C "$MAIN" rm -q -rf .
echo "unrelated" > "$MAIN/unrelated.txt"
git -C "$MAIN" add unrelated.txt
git -C "$MAIN" commit -qm "unrelated local commit"
UNRELATED_COMMIT="$(git -C "$MAIN" rev-parse HEAD)"
git -C "$MAIN" checkout -q main

assert_launch_fails \
  "commit outside configured base history" \
  "does not belong to upstream/release/v2" \
  RALPH_BASE_REMOTE=upstream \
  RALPH_BASE_BRANCH=release/v2 \
  RALPH_BASE_COMMIT="$UNRELATED_COMMIT"
