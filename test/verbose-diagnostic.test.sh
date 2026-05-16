#!/usr/bin/env bash
# Integration tests for the per-candidate verbose diagnostic and the
# idle-line behaviour added in issue #65. These tests drive the legacy
# (search-based) candidate loop of ralph.sh with a stubbed `gh` so we can
# assert on the actual log output a worker would emit when it rejects a
# candidate.
#
# Covers:
#   - "↳ skipping #N: blocker #M not satisfied (state=… reason=… prs=…)"
#     emits exactly once per rejected candidate when RALPH_VERBOSE=1
#   - The verbose diagnostic stays silent when RALPH_VERBOSE is unset
#   - The idle line reports `claimed=0` (not `claimed=1`) when state.json
#     has no claims (the off-by-one fix)
#   - The one-time `Set RALPH_VERBOSE=1` hint prints on first idle and
#     does NOT repeat on subsequent idle polls

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# Build a `gh` stub that returns canned JSON for the calls ralph.sh's
# legacy candidate loop makes. The stub writes every invocation to
# $TEST_ROOT/gh.log so we can introspect call patterns. The stub answers:
#   gh issue list ...                 → one open candidate (#101) whose body
#                                       lists #100 in its "## Blocked by"
#                                       section
#   gh issue view 100 --json state,stateReason,closedByPullRequestsReferences
#                                     → state=OPEN, no PR refs (blocker
#                                       still open, candidate must be
#                                       rejected)
#   gh issue view 101 ...             → state=OPEN (the candidate itself,
#                                       in case anything else asks)
#   anything else                     → empty JSON / null
make_gh_stub() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'GH'
#!/usr/bin/env bash
# Stub gh — used by verbose-diagnostic.test.sh
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[{"number":101,"title":"Slice 2: do thing","body":"## Blocked by\n- #100\n\n## Description\nfoo"}]
JSON
    ;;
  "issue view")
    case "$3" in
      100)
        printf '{"state":"OPEN","stateReason":"","closedByPullRequestsReferences":[]}\n'
        ;;
      *)
        printf '{"state":"OPEN","stateReason":"","closedByPullRequestsReferences":[]}\n'
        ;;
    esac
    ;;
  *)
    printf '{}\n'
    ;;
esac
GH
  chmod +x "$bindir/gh"
}

setup_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  cd "$dir"
  git checkout -qb main
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "test" > README.md
  git add README.md
  git commit -qm "initial"

  local bare="$dir.origin.git"
  git init -q --bare "$bare"
  git remote add origin "$bare"
  git push -q -u origin main
  printf '.ralph\n' >> .git/info/exclude

  mkdir -p .ralph/lib .ralph/logs .ralph/lock
  cp "$REPO_ROOT/ralph/ralph.sh"        .ralph/ralph.sh
  cp "$REPO_ROOT/ralph/launch.sh"       .ralph/launch.sh
  cp "$REPO_ROOT/ralph/lib/state.sh"    .ralph/lib/state.sh
  cp "$REPO_ROOT/ralph/lib/status.sh"   .ralph/lib/status.sh
  cp "$REPO_ROOT/ralph/lib/pr-merge.sh" .ralph/lib/pr-merge.sh
  cp "$REPO_ROOT/ralph/lib/resume.sh" .ralph/lib/resume.sh
  chmod +x .ralph/ralph.sh .ralph/launch.sh

  cat > .ralph/RALPH.md <<'EOF'
Test prompt.
EOF
  cat > .ralph/config.json <<'EOF'
{
  "issue": {
    "titleRegex": "^Slice [0-9]+:",
    "titleNumRegex": "^Slice (?<x>[0-9]+):"
  }
}
EOF
  echo '{"claims":{}}' > .ralph/state.json
  cd "$SCRIPT_DIR/.."
}

# run_worker_legacy REPO MAX_WAIT_SEC EXTRA_ENV…
# Run ralph.sh in legacy mode (no RALPH_RUN_ID) against the stubbed gh.
# Echoes combined stdout+stderr; exits 0 on clean worker exit, 124 on
# timeout (in which case the worker is killed).
run_worker_legacy() {
  local repo="$1" max_wait="$2"
  shift 2
  local extra_env=("$@")
  local stub_bin="$TEST_ROOT/bin"
  local out="$TEST_ROOT/$(basename "$repo").out"
  make_gh_stub "$stub_bin"

  env RALPH_REPO="testowner/testrepo" \
      RALPH_WORKER_ID=1 \
      PATH="$stub_bin:$PATH" \
      GH_LOG="$TEST_ROOT/gh.log" \
      "${extra_env[@]}" \
      bash -c "cd '$repo' && .ralph/ralph.sh" >"$out" 2>&1 &
  local pid=$!

  local waited=0
  while [[ $waited -lt $((max_wait * 10)) ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      cat "$out"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$out"
  return 124
}

# ===========================================================================
# Test 1: RALPH_VERBOSE=1 emits the structured skip diagnostic on rejection
# ===========================================================================
echo "Test 1: RALPH_VERBOSE=1 emits structured skip diagnostic"

REPO1="$TEST_ROOT/verbose-on"
setup_repo "$REPO1"

output1=$(run_worker_legacy "$REPO1" 5 \
  RALPH_POLL_SEC=0.1 \
  RALPH_IDLE_EXIT_POLLS=2 \
  RALPH_VERBOSE=1) || true

# Expect at least one skip line naming both the candidate and the blocker
# with the structured state/reason/prs detail.
if ! echo "$output1" | grep -qE "skipping #101: blocker #100 not satisfied \(state=OPEN reason= prs=\)"; then
  echo "$output1"
  fail "verbose mode should emit '↳ skipping #101: blocker #100 not satisfied (state=OPEN reason= prs=)'"
fi
echo "PASS: RALPH_VERBOSE=1 emits structured skip diagnostic"
echo ""

# ===========================================================================
# Test 2: Without RALPH_VERBOSE, the per-candidate skip line is suppressed
# ===========================================================================
echo "Test 2: verbose-off suppresses per-candidate skip lines"

REPO2="$TEST_ROOT/verbose-off"
setup_repo "$REPO2"

output2=$(run_worker_legacy "$REPO2" 5 \
  RALPH_POLL_SEC=0.1 \
  RALPH_IDLE_EXIT_POLLS=2) || true

if echo "$output2" | grep -qE "skipping #[0-9]+:"; then
  echo "$output2"
  fail "non-verbose mode should NOT emit per-candidate skip lines"
fi
echo "PASS: verbose-off suppresses per-candidate skip lines"
echo ""

# ===========================================================================
# Test 3: Idle line reports `claimed=0` when state.json is empty
# ===========================================================================
echo "Test 3: empty state.json reports claimed=0 (off-by-one fix)"

# Reuse output2 — same scenario, no claims in state.json.
if echo "$output2" | grep -qE "claimed=[2-9]|claimed=1[0-9]"; then
  echo "$output2"
  fail "idle line should not report a wildly inflated claimed count"
fi
if ! echo "$output2" | grep -qE "no eligible issue \(remaining=1, claimed=0\)"; then
  echo "$output2"
  fail "idle line should report 'claimed=0' when state.json has no claims"
fi
echo "PASS: empty state.json reports claimed=0"
echo ""

# ===========================================================================
# Test 4: One-time RALPH_VERBOSE hint prints exactly once per worker
# ===========================================================================
echo "Test 4: RALPH_VERBOSE hint prints exactly once per worker"

# Reuse output2 — verbose was off, so the hint should appear. The worker
# idles twice (RALPH_IDLE_EXIT_POLLS=2) before exiting, so a non-one-shot
# implementation would emit the hint twice.
hint_count=$(echo "$output2" | grep -c "Set RALPH_VERBOSE=1" || true)
if [[ "$hint_count" -ne 1 ]]; then
  echo "$output2"
  fail "one-time RALPH_VERBOSE hint should print exactly once per worker (got $hint_count)"
fi
echo "PASS: RALPH_VERBOSE hint prints exactly once per worker"
echo ""

# ===========================================================================
# Test 5: With RALPH_VERBOSE=1, the one-time hint is suppressed entirely
# ===========================================================================
echo "Test 5: hint suppressed when RALPH_VERBOSE=1"

if echo "$output1" | grep -q "Set RALPH_VERBOSE=1"; then
  echo "$output1"
  fail "verbose-on output should not include the 'Set RALPH_VERBOSE=1' hint"
fi
echo "PASS: hint suppressed when RALPH_VERBOSE=1"
echo ""

echo "All verbose-diagnostic tests passed!"
