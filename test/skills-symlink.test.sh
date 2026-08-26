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
# Single cleanup trap — accumulates all temp dirs, cleaned on exit.
# ---------------------------------------------------------------------------
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

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

skill_link() { echo "$1/.agents/skills/${2:-to-ralph}"; }
is_skill_install() {
  [[ -L "$1" || -f "$1/.ralph-skill-source" ]]
}
skill_install_source() {
  if [[ -L "$1" ]]; then
    readlink "$1"
  else
    sed -n 's/^source=//p' "$1/.ralph-skill-source"
  fi
}

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

triage_skill_file="$REPO_ROOT/skills/ralph-issue-triage-agent/SKILL.md"

if [[ ! -f "$triage_skill_file" ]]; then
  fail "skills/ralph-issue-triage-agent/SKILL.md does not exist"
else
  pass "skills/ralph-issue-triage-agent/SKILL.md exists"
fi

if grep -q '^name: ralph-issue-triage-agent' "$triage_skill_file" 2>/dev/null; then
  pass "triage SKILL.md has expected name frontmatter"
else
  fail "triage SKILL.md missing expected name frontmatter"
fi

for triage_keyword in \
  "Recommendation: Pursue / Refine / Needs info / Defer / Close / Uncertain" \
  "Automation safety: safe after prep / needs prep / hitl-required" \
  "zero mutations" \
  "Every factual or evidence claim must cite"; do
  if grep -q "$triage_keyword" "$triage_skill_file" 2>/dev/null; then
    pass "triage SKILL.md mentions '$triage_keyword'"
  else
    fail "triage SKILL.md missing content for '$triage_keyword'"
  fi
done

orchestrator_skill_file="$REPO_ROOT/skills/ralph-orchestrator/SKILL.md"

if [[ ! -f "$orchestrator_skill_file" ]]; then
  fail "skills/ralph-orchestrator/SKILL.md does not exist"
else
  pass "skills/ralph-orchestrator/SKILL.md exists"
fi

if grep -q '^name: ralph-orchestrator' "$orchestrator_skill_file" 2>/dev/null; then
  pass "orchestrator SKILL.md has expected name frontmatter"
else
  fail "orchestrator SKILL.md missing expected name frontmatter"
fi

# Thin control plane: must do mode detection and point at lazy-loaded mode files.
for orchestrator_keyword in "prd-run" "repo-maintain" "allowAgentLaunch" "orchestrateRun"; do
  if grep -q "$orchestrator_keyword" "$orchestrator_skill_file" 2>/dev/null; then
    pass "orchestrator SKILL.md mentions '$orchestrator_keyword'"
  else
    fail "orchestrator SKILL.md missing content for '$orchestrator_keyword'"
  fi
done

# Lazy-loaded mode files and shared references must exist.
for orchestrator_part in \
  "skills/ralph-orchestrator/modes/prd-run.md" \
  "skills/ralph-orchestrator/modes/repo-maintain.md" \
  "skills/ralph-orchestrator/references/policy.md" \
  "skills/ralph-orchestrator/references/triage-contract.md"; do
  if [[ -f "$REPO_ROOT/$orchestrator_part" ]]; then
    pass "orchestrator part exists: $orchestrator_part"
  else
    fail "orchestrator part missing: $orchestrator_part"
  fi
done

# ---------------------------------------------------------------------------
# Test 2: --skills-only creates symlink in ~/.agents/skills/to-ralph
# ---------------------------------------------------------------------------
TEST_HOME="$(make_fake_home)"
CLEANUP_DIRS+=("$TEST_HOME")

exit_code=0
output=$(HOME="$TEST_HOME" "$REPO_ROOT/install.sh" --skills-only 2>&1) || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "--skills-only exits 0"
else
  fail "--skills-only should exit 0, got $exit_code. Output: $output"
fi

link="$(skill_link "$TEST_HOME")"
if is_skill_install "$link"; then
  pass "--skills-only installs ~/.agents/skills/to-ralph"
else
  fail "--skills-only should install a managed skill at $link"
fi

triage_link="$(skill_link "$TEST_HOME" "ralph-issue-triage-agent")"
if is_skill_install "$triage_link"; then
  pass "--skills-only installs ~/.agents/skills/ralph-issue-triage-agent"
else
  fail "--skills-only should install a managed skill at $triage_link"
fi

# Installation must record the correct source.
expected_target="$REPO_ROOT/skills/to-ralph"
actual_target="$(skill_install_source "$link")"
if [[ "$actual_target" == "$expected_target" ]]; then
  pass "installation points to correct source: $expected_target"
else
  fail "installation points to '$actual_target', expected '$expected_target'"
fi

expected_triage_target="$REPO_ROOT/skills/ralph-issue-triage-agent"
actual_triage_target="$(skill_install_source "$triage_link")"
if [[ "$actual_triage_target" == "$expected_triage_target" ]]; then
  pass "triage installation points to correct source: $expected_triage_target"
else
  fail "triage installation points to '$actual_triage_target', expected '$expected_triage_target'"
fi

orchestrator_link="$(skill_link "$TEST_HOME" "ralph-orchestrator")"
if is_skill_install "$orchestrator_link"; then
  pass "--skills-only installs ~/.agents/skills/ralph-orchestrator"
else
  fail "--skills-only should install a managed skill at $orchestrator_link"
fi

expected_orchestrator_target="$REPO_ROOT/skills/ralph-orchestrator"
actual_orchestrator_target="$(skill_install_source "$orchestrator_link")"
if [[ "$actual_orchestrator_target" == "$expected_orchestrator_target" ]]; then
  pass "orchestrator installation points to correct source: $expected_orchestrator_target"
else
  fail "orchestrator installation points to '$actual_orchestrator_target', expected '$expected_orchestrator_target'"
fi

for planning_skill in to-spec to-tickets; do
  planning_link="$(skill_link "$TEST_HOME" "$planning_skill")"
  expected_planning_target="$REPO_ROOT/skills/$planning_skill"
  if is_skill_install "$planning_link"; then
    pass "--skills-only installs ~/.agents/skills/$planning_skill"
  else
    fail "--skills-only should install a managed skill at $planning_link"
    continue
  fi
  actual_planning_target="$(skill_install_source "$planning_link")"
  if [[ "$actual_planning_target" == "$expected_planning_target" ]]; then
    pass "$planning_skill installation points to correct source"
  else
    fail "$planning_skill installation points to '$actual_planning_target', expected '$expected_planning_target'"
  fi
done

# ---------------------------------------------------------------------------
# Test 3: --skills-only is idempotent (re-run doesn't fail)
# ---------------------------------------------------------------------------
managed_copy_refreshed=0
managed_copy_path="$(skill_link "$TEST_HOME" "to-spec")"
if [[ -f "$managed_copy_path/.ralph-skill-source" ]]; then
  printf 'stale managed copy\n' > "$managed_copy_path/SKILL.md"
  managed_copy_refreshed=1
fi

exit_code2=0
output2=$(HOME="$TEST_HOME" "$REPO_ROOT/install.sh" --skills-only 2>&1) || exit_code2=$?

if [[ "$exit_code2" -eq 0 ]]; then
  pass "--skills-only is idempotent (second run exits 0)"
else
  fail "--skills-only second run should exit 0, got $exit_code2. Output: $output2"
fi

if [[ "$managed_copy_refreshed" -eq 1 ]]; then
  if cmp -s "$REPO_ROOT/skills/to-spec/SKILL.md" "$managed_copy_path/SKILL.md"; then
    pass "--skills-only refreshes a stale Windows managed copy"
  else
    fail "--skills-only should refresh a stale Windows managed copy"
  fi
fi

link_after="$(skill_install_source "$(skill_link "$TEST_HOME")")"
if [[ "$link_after" == "$expected_target" ]]; then
  pass "installation still points to correct source after re-run"
else
  fail "installation source changed after re-run: $link_after"
fi

triage_link_after="$(skill_install_source "$(skill_link "$TEST_HOME" "ralph-issue-triage-agent")")"
if [[ "$triage_link_after" == "$expected_triage_target" ]]; then
  pass "triage installation still points to correct source after re-run"
else
  fail "triage installation source changed after re-run: $triage_link_after"
fi

orchestrator_link_after="$(skill_install_source "$(skill_link "$TEST_HOME" "ralph-orchestrator")")"
if [[ "$orchestrator_link_after" == "$expected_orchestrator_target" ]]; then
  pass "orchestrator installation still points to correct source after re-run"
else
  fail "orchestrator installation source changed after re-run: $orchestrator_link_after"
fi

for planning_skill in to-spec to-tickets; do
  planning_link_after="$(skill_install_source "$(skill_link "$TEST_HOME" "$planning_skill")")"
  expected_planning_target="$REPO_ROOT/skills/$planning_skill"
  if [[ "$planning_link_after" == "$expected_planning_target" ]]; then
    pass "$planning_skill installation still points to correct source after re-run"
  else
    fail "$planning_skill installation source changed after re-run: $planning_link_after"
  fi
done

# A managed install belongs to Ralph, not to one checkout path. Reinstalling
# from a replacement clone/worktree must refresh it to the new source.
ALT_SOURCE="$(mktemp -d)"
CLEANUP_DIRS+=("$ALT_SOURCE")
mkdir -p "$ALT_SOURCE/skills"
cp "$REPO_ROOT/install.sh" "$ALT_SOURCE/install.sh"
chmod +x "$ALT_SOURCE/install.sh"
cp -R "$REPO_ROOT/skills/." "$ALT_SOURCE/skills/"

alternate_exit=0
alternate_output=$(HOME="$TEST_HOME" "$ALT_SOURCE/install.sh" --skills-only 2>&1) || alternate_exit=$?
if [[ "$alternate_exit" -eq 0 ]]; then
  pass "--skills-only refreshes installs from a replacement checkout"
else
  fail "--skills-only replacement-checkout refresh failed: $alternate_output"
fi

alternate_spec_source="$(skill_install_source "$(skill_link "$TEST_HOME" "to-spec")")"
if [[ "$alternate_spec_source" == "$ALT_SOURCE/skills/to-spec" ]]; then
  pass "replacement-checkout refresh records the new source"
else
  fail "replacement-checkout source is '$alternate_spec_source', expected '$ALT_SOURCE/skills/to-spec'"
fi

# ---------------------------------------------------------------------------
# Test 4: missing ~/.agents/skills/ prints actionable hint, exits 0
# ---------------------------------------------------------------------------
NO_SKILLS_HOME="$(make_fake_home_no_skills)"
CLEANUP_DIRS+=("$NO_SKILLS_HOME")

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

if [[ ! -e "$NO_SKILLS_HOME/.agents/skills/ralph-issue-triage-agent" ]]; then
  pass "no triage symlink created when ~/.agents/skills/ missing"
else
  fail "should not create triage symlink when ~/.agents/skills/ doesn't exist"
fi

if [[ ! -e "$NO_SKILLS_HOME/.agents/skills/ralph-orchestrator" ]]; then
  pass "no orchestrator symlink created when ~/.agents/skills/ missing"
else
  fail "should not create orchestrator symlink when ~/.agents/skills/ doesn't exist"
fi

for planning_skill in to-spec to-tickets; do
  if [[ ! -e "$NO_SKILLS_HOME/.agents/skills/$planning_skill" ]]; then
    pass "no $planning_skill symlink created when ~/.agents/skills/ missing"
  else
    fail "should not create $planning_skill symlink when ~/.agents/skills/ doesn't exist"
  fi
done

# ---------------------------------------------------------------------------
# Test 5: non-symlink at target path is not clobbered
# ---------------------------------------------------------------------------
SAFE_HOME="$(make_fake_home)"
CLEANUP_DIRS+=("$SAFE_HOME")

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
CLEANUP_DIRS+=("$BOTH_HOME")
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
if is_skill_install "$both_link"; then
  pass "--both mode installs to-ralph skill"
else
  fail "--both mode should install to-ralph at $both_link"
fi

both_triage_link="$(skill_link "$BOTH_HOME" "ralph-issue-triage-agent")"
if is_skill_install "$both_triage_link"; then
  pass "--both mode installs triage skill"
else
  fail "--both mode should install triage skill at $both_triage_link"
fi

both_orchestrator_link="$(skill_link "$BOTH_HOME" "ralph-orchestrator")"
if is_skill_install "$both_orchestrator_link"; then
  pass "--both mode installs orchestrator skill"
else
  fail "--both mode should install orchestrator skill at $both_orchestrator_link"
fi

for planning_skill in to-spec to-tickets; do
  both_planning_link="$(skill_link "$BOTH_HOME" "$planning_skill")"
  if is_skill_install "$both_planning_link"; then
    pass "--both mode installs $planning_skill skill"
  else
    fail "--both mode should install $planning_skill skill at $both_planning_link"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass_count passed, $fail_count failed"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
