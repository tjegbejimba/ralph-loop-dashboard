#!/usr/bin/env bash
# Integration test for install.sh portable instructions (issue #63).
# Verifies that .github/copilot-instructions.md contains no host-absolute
# paths and that .ralph/local.md contains the machine-specific context.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

TARGET="$TEST_ROOT/target"

git init -q "$TARGET"
cd "$TARGET"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"

"$REPO_ROOT/install.sh" "$TARGET" --scripts-only --profile generic >/dev/null

instructions_file="$TARGET/.github/copilot-instructions.md"
local_file="$TARGET/.ralph/local.md"

# AC1: .github/copilot-instructions.md must not contain absolute host paths
if [[ ! -f "$instructions_file" ]]; then
  echo "FAIL: .github/copilot-instructions.md should exist"
  exit 1
fi

if grep -qE '(/Users/|/home/|C:\\Users\\)' "$instructions_file"; then
  echo "FAIL: .github/copilot-instructions.md contains absolute host paths"
  echo "--- content ---"
  cat "$instructions_file"
  echo "---------------"
  exit 1
fi

# Verify the committed file still has useful repo-relative info
if ! grep -q "\.ralph/RALPH\.md" "$instructions_file"; then
  echo "FAIL: .github/copilot-instructions.md should mention .ralph/RALPH.md"
  exit 1
fi

if ! grep -q "\.ralph/config\.json" "$instructions_file"; then
  echo "FAIL: .github/copilot-instructions.md should mention .ralph/config.json"
  exit 1
fi

if ! grep -q "\.ralph/launch\.sh" "$instructions_file"; then
  echo "FAIL: .github/copilot-instructions.md should mention .ralph/launch.sh"
  exit 1
fi

# AC2: .ralph/local.md must exist and contain host-absolute paths
if [[ ! -f "$local_file" ]]; then
  echo "FAIL: .ralph/local.md should exist"
  exit 1
fi

if ! grep -qF "Ralph source checkout" "$local_file"; then
  echo "FAIL: .ralph/local.md should mention Ralph source checkout"
  exit 1
fi

if ! grep -qF "$REPO_ROOT" "$local_file"; then
  echo "FAIL: .ralph/local.md should contain the actual Ralph source path ($REPO_ROOT)"
  echo "--- content ---"
  cat "$local_file"
  echo "---------------"
  exit 1
fi

if ! grep -qF "$TARGET" "$local_file"; then
  echo "FAIL: .ralph/local.md should contain the target repo path ($TARGET)"
  echo "--- content ---"
  cat "$local_file"
  echo "---------------"
  exit 1
fi

# AC3: .ralph/local.md must be gitignored
ralph_gitignore="$TARGET/.ralph/.gitignore"
if [[ ! -f "$ralph_gitignore" ]]; then
  echo "FAIL: .ralph/.gitignore should exist"
  exit 1
fi

if ! grep -qxF "local.md" "$ralph_gitignore"; then
  echo "FAIL: .ralph/.gitignore should contain local.md"
  echo "--- content ---"
  cat "$ralph_gitignore"
  echo "---------------"
  exit 1
fi

# Verify local.md is actually ignored by git
cd "$TARGET"
if git status --porcelain | grep -qF ".ralph/local.md"; then
  echo "FAIL: .ralph/local.md should be ignored by git"
  echo "--- git status ---"
  git status --porcelain
  echo "------------------"
  exit 1
fi

# AC4: Refresh behavior — subsequent installs should update local.md
echo "# Old local context" > "$local_file"
"$REPO_ROOT/install.sh" "$TARGET" --scripts-only --profile generic >/dev/null

if grep -qF "Old local context" "$local_file"; then
  echo "FAIL: install.sh should overwrite .ralph/local.md on refresh"
  exit 1
fi

if ! grep -qF "$REPO_ROOT" "$local_file"; then
  echo "FAIL: refreshed .ralph/local.md should still contain Ralph source path"
  exit 1
fi

# AC5: Upgrade path — installer should replace old marker-based blocks with new portable content
UPGRADE_TARGET="$TEST_ROOT/upgrade-target"
git init -q "$UPGRADE_TARGET"
cd "$UPGRADE_TARGET"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > README.md
git add README.md
git commit -qm "initial"

# Simulate old install with absolute paths
upgrade_instructions="$UPGRADE_TARGET/.github/copilot-instructions.md"
mkdir -p "$UPGRADE_TARGET/.github"
cat > "$upgrade_instructions" <<EOF
<!-- ralph-loop-instructions -->
# Copilot instructions

## Ralph Loop

This repo may use Ralph Loop. If an agent needs to understand, install, refresh, operate, or troubleshoot Ralph here, load the \`ralph-loop\` skill.

- Ralph source checkout on this machine: \`/Users/old/Code/ralph-loop-dashboard\`
- Repo worker prompt: \`.ralph/RALPH.md\`
- Repo config: \`.ralph/config.json\`
- Refresh scripts: \`/Users/old/Code/ralph-loop-dashboard/install.sh "$UPGRADE_TARGET" --scripts-only\`
- Check/stop/cleanup workers: \`.ralph/launch.sh --status\`, \`--stop\`, or \`--cleanup\`

Do not overwrite \`.ralph/RALPH.md\` or \`.ralph/config.json\` unless explicitly asked.
EOF

# Run new installer — should replace the old block
"$REPO_ROOT/install.sh" "$UPGRADE_TARGET" --scripts-only --profile generic >/dev/null

if grep -qE '(/Users/|/home/|C:\\Users\\)' "$upgrade_instructions"; then
  echo "FAIL: installer should replace old block with portable content on upgrade"
  echo "--- content ---"
  cat "$upgrade_instructions"
  echo "---------------"
  exit 1
fi

if ! grep -q "\.ralph/RALPH\.md" "$upgrade_instructions"; then
  echo "FAIL: upgraded instructions should still mention .ralph/RALPH.md"
  exit 1
fi

if ! grep -q "ralph-loop" "$upgrade_instructions"; then
  echo "FAIL: upgraded instructions should still reference ralph-loop skill"
  exit 1
fi

echo "PASS: install.sh writes portable instructions and local context separately"
