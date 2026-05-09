#!/usr/bin/env bash
# Integration tests for install.sh skill symlinking behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

pass_count=0
fail_count=0

pass() { echo "PASS: $1"; ((pass_count++)) || true; }
fail() { echo "FAIL: $1"; ((fail_count++)) || true; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_fake_home() {
  local h
  h="$(mktemp -d)"
  mkdir -p "$h/.agents/skills"
  echo "$h"
}

make_fake_home_no_skills() {
  local h
  h="$(mktemp -d)"
  # intentionally no ~/.agents/skills/
  echo "$h"
}

skill_link() { echo "$1/.agents/skills/to-ralph"; }

# ---------------------------------------------------------------------------
# Test 1 (tracer bullet): SKILL.md file exists with required frontmatter
# ---------------------------------------------------------------------------
skill_file="$REPO_ROOT/skills/to-ralph/SKILL.md"

if [[ ! -f "$skill_file" ]]; then
  fail "skills/to-ralph/SKILL.md does not exist"
else
  pass "skills/to-ralph/SKILL.md exists"
fi

if grep -q '^name: to-ralph' "$skill_file" 2>/dev/null; then
  pass "SKILL.md has 'name: to-ralph' frontmatter"
else
  fail "SKILL.md missing 'name: to-ralph' frontmatter"
fi

if grep -q '^description:' "$skill_file" 2>/dev/null; then
  pass "SKILL.md has 'description:' frontmatter"
else
  fail "SKILL.md missing 'description:' frontmatter"
fi

# Must describe the 5 steps
for step_keyword in "enqueue" "status" "preflight" "summary|ready|blocker"; do
  if grep -qiE "$step_keyword" "$skill_file" 2>/dev/null; then
    pass "SKILL.md mentions '$step_keyword'"
  else
    fail "SKILL.md missing content for '$step_keyword'"
  fi
done

# Must forbid running launch.sh without --status or --enqueue
if grep -qE "forbid|never|do not|must not|only.*--status|only.*--enqueue" "$skill_file" 2>/dev/null; then
  pass "SKILL.md includes prohibition on unsanctioned launch.sh usage"
else
  fail "SKILL.md must explicitly forbid running launch.sh without --status/--enqueue"
fi

# ---------------------------------------------------------------------------
# Test 2: --skills-only creates symlink in ~/.agents/skills/to-ralph
# ---------------------------------------------------------------------------
TEST_HOME="$(make_fake_home)"
trap 'rm -rf "$TEST_HOME"' EXIT

exit_code=0
output=$(HOME="$TEST_HOME" "$REPO_ROOT/install.sh" --skills-only 2>&1) || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "--skills-only exits 0"
else
  fail "--skills-only should exit 0, got $exit_code. Output: $output"
fi

link="$(skill_link "$TEST_HOME")"
if [[ -L "$link" ]]; then
  pass "--skills-only creates symlink at ~/.agents/skills/to-ralph"
else
  fail "--skills-only should create a symlink at $link"
fi

# Symlink must point to the correct source
expected_target="$REPO_ROOT/skills/to-ralph"
actual_target="$(readlink "$link")"
if [[ "$actual_target" == "$expected_target" ]]; then
  pass "symlink points to correct source: $expected_target"
else
  fail "symlink points to '$actual_target', expected '$expected_target'"
fi

# ---------------------------------------------------------------------------
# Test 3: --skills-only is idempotent (re-run doesn't fail)
# ---------------------------------------------------------------------------
exit_code2=0
output2=$(HOME="$TEST_HOME" "$REPO_ROOT/install.sh" --skills-only 2>&1) || exit_code2=$?

if [[ "$exit_code2" -eq 0 ]]; then
  pass "--skills-only is idempotent (second run exits 0)"
else
  fail "--skills-only second run should exit 0, got $exit_code2. Output: $output2"
fi

link_after="$(readlink "$(skill_link "$TEST_HOME")")"
if [[ "$link_after" == "$expected_target" ]]; then
  pass "symlink still points to correct source after re-run"
else
  fail "symlink target changed after re-run: $link_after"
fi

# ---------------------------------------------------------------------------
# Test 4: missing ~/.agents/skills/ prints actionable hint, exits 0
# ---------------------------------------------------------------------------
NO_SKILLS_HOME="$(make_fake_home_no_skills)"
trap 'rm -rf "$NO_SKILLS_HOME"' EXIT

hint_exit=0
hint_output=$(HOME="$NO_SKILLS_HOME" "$REPO_ROOT/install.sh" --skills-only 2>&1) || hint_exit=$?

if [[ "$hint_exit" -eq 0 ]]; then
  pass "--skills-only with missing ~/.agents/skills/ exits 0 (hint mode)"
else
  fail "--skills-only with missing ~/.agents/skills/ should exit 0, got $hint_exit"
fi

if echo "$hint_output" | grep -qi "agents/skills\|skill"; then
  pass "--skills-only prints hint when ~/.agents/skills/ missing"
else
  fail "--skills-only should print actionable hint when ~/.agents/skills/ missing. Output: $hint_output"
fi

if [[ ! -e "$NO_SKILLS_HOME/.agents/skills/to-ralph" ]]; then
  pass "no symlink created when ~/.agents/skills/ missing"
else
  fail "should not create symlink when ~/.agents/skills/ doesn't exist"
fi

# ---------------------------------------------------------------------------
# Test 5: non-symlink at target path is not clobbered
# ---------------------------------------------------------------------------
SAFE_HOME="$(make_fake_home)"
trap 'rm -rf "$SAFE_HOME"' EXIT

# Place a real file at the target location
mkdir -p "$SAFE_HOME/.agents/skills"
echo "custom content" > "$SAFE_HOME/.agents/skills/to-ralph"

clobber_exit=0
clobber_output=$(HOME="$SAFE_HOME" "$REPO_ROOT/install.sh" --skills-only 2>&1) || clobber_exit=$?

if [[ "$clobber_exit" -ne 0 ]]; then
  pass "--skills-only exits non-zero when target is a plain file"
else
  fail "--skills-only should exit non-zero when ~/.agents/skills/to-ralph is a plain file"
fi

if [[ "$(cat "$SAFE_HOME/.agents/skills/to-ralph")" == "custom content" ]]; then
  pass "non-symlink file not clobbered"
else
  fail "non-symlink file was overwritten"
fi

# ---------------------------------------------------------------------------
# Test 6: --both mode installs skills (best-effort, does not fail on missing skills dir)
# ---------------------------------------------------------------------------
BOTH_HOME="$(make_fake_home)"
trap 'rm -rf "$BOTH_HOME"' EXIT
TARGET="$BOTH_HOME/target"

git init -q "$TARGET"
cd "$TARGET"
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"
cd - > /dev/null

both_exit=0
both_output=$(HOME="$BOTH_HOME" "$REPO_ROOT/install.sh" "$TARGET" --both --profile generic 2>&1) || both_exit=$?

if [[ "$both_exit" -eq 0 ]]; then
  pass "--both mode exits 0"
else
  fail "--both mode should exit 0, got $both_exit. Output: $both_output"
fi

both_link="$(skill_link "$BOTH_HOME")"
if [[ -L "$both_link" ]]; then
  pass "--both mode creates skills symlink"
else
  fail "--both mode should create skills symlink at $both_link"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass_count passed, $fail_count failed"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
