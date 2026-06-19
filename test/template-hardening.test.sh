#!/usr/bin/env bash
# Tests for Ralph template hardening (issue #112)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_no_match() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    fail "$label (pattern '$pattern' should not exist in $file)"
  else
    pass "$label"
  fi
}

assert_match() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (pattern '$pattern' not found in $file)"
  fi
}

assert_syntax_valid() {
  local file="$1" label="$2"
  if bash -n "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (syntax error in $file)"
  fi
}

# ─── Issue 1: Worktree-unsafe git checkout main ──────────────────────────────

# Test: RALPH.md.template should not contain "git checkout main"
{
  template="$REPO_ROOT/ralph/RALPH.md.template"
  assert_no_match "$template" "git checkout main" \
    "RALPH.md.template does not contain 'git checkout main'"
}

# Test: RALPH.md.template should use worktree-safe commands
{
  template="$REPO_ROOT/ralph/RALPH.md.template"
  # Should mention git fetch + git switch or similar worktree-safe pattern
  assert_match "$template" "git fetch origin" \
    "RALPH.md.template contains 'git fetch origin' (worktree-safe)"
}

# ─── Issue 2: Invalid gh field closedByPullRequests ──────────────────────────

# Test: RALPH.md.template should not use invalid field closedByPullRequests
{
  template="$REPO_ROOT/ralph/RALPH.md.template"
  assert_no_match "$template" "closedByPullRequests[^R]" \
    "RALPH.md.template does not use invalid 'closedByPullRequests' field"
}

# Test: RALPH.md.template should use correct field closedByPullRequestsReferences
{
  template="$REPO_ROOT/ralph/RALPH.md.template"
  # Should have at least 2 references (lines 72 and 113 from issue description)
  if count=$(grep -c "closedByPullRequestsReferences" "$template" 2>/dev/null); then
    if [[ "$count" -ge 2 ]]; then
      pass "RALPH.md.template uses 'closedByPullRequestsReferences' (found $count occurrences)"
    else
      fail "RALPH.md.template should use 'closedByPullRequestsReferences' at least 2 times (found $count)"
    fi
  else
    fail "RALPH.md.template should use 'closedByPullRequestsReferences' at least 2 times (found 0)"
  fi
}

# ─── Issue 3: Hardcoded PRD #1 ────────────────────────────────────────────────

# Test: RALPH.md.template should not hardcode "issue view 1"
{
  template="$REPO_ROOT/ralph/RALPH.md.template"
  assert_no_match "$template" "issue view 1 --repo" \
    "RALPH.md.template does not hardcode 'issue view 1'"
}

# Test: RALPH.md.template should use templated PRD reference
{
  template="$REPO_ROOT/ralph/RALPH.md.template"
  # Should reference {{PRD_REFERENCE}} or similar template variable
  assert_match "$template" "{{PRD_REFERENCE}}" \
    "RALPH.md.template uses templated {{PRD_REFERENCE}}"
}

# ─── Issue 4: macOS timeout alarm handler ─────────────────────────────────────

# Test: ralph.sh should document gtimeout preference for macOS
{
  script="$REPO_ROOT/ralph/ralph.sh"
  # Should have a comment about gtimeout or macOS timeout caveats
  if grep -q "gtimeout" "$script" && grep -q "macOS\|darwin\|perl.*timeout" "$script"; then
    pass "ralph.sh documents gtimeout/macOS timeout behavior"
  else
    fail "ralph.sh should document gtimeout preference or macOS timeout caveats"
  fi
}

# ─── Issue 5: Enqueue mutates tracked files ───────────────────────────────────

# Test: launch.sh help should document config mutation
{
  script="$REPO_ROOT/ralph/launch.sh"
  # Help text should mention that --enqueue writes to config.json
  if grep -A 10 "enqueue" "$script" | grep -q "config.json\|tracked\|mutate"; then
    pass "launch.sh documents that --enqueue writes to config.json"
  else
    fail "launch.sh should document config.json mutation in help text"
  fi
}

# ─── Shell syntax validation ───────────────────────────────────────────────────

# Test: ralph.sh is syntactically valid
{
  assert_syntax_valid "$REPO_ROOT/ralph/ralph.sh" \
    "ralph/ralph.sh is syntactically valid"
}

# Test: launch.sh is syntactically valid
{
  assert_syntax_valid "$REPO_ROOT/ralph/launch.sh" \
    "ralph/launch.sh is syntactically valid"
}

# ─── Summary ───────────────────────────────────────────────────────────────────

echo
echo "===================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "===================="

[[ "$FAIL" -eq 0 ]]
