#!/usr/bin/env bash
# Integration test for install.sh script refresh behavior.

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
if [[ ! -f "$instructions_file" ]]; then
  echo "FAIL: installer should create repo-level Copilot instructions"
  exit 1
fi
if ! grep -q "ralph-loop" "$instructions_file"; then
  echo "FAIL: Copilot instructions should point agents to the ralph-loop skill"
  exit 1
fi

custom_prompt="# Custom Ralph prompt"
custom_config='{"profile":"custom","keep":true}'
printf '%s\n' "$custom_prompt" > "$TARGET/.ralph/RALPH.md"
printf '%s\n' "$custom_config" > "$TARGET/.ralph/config.json"
printf '%s\n' "# stale launch" > "$TARGET/.ralph/launch.sh"
printf '%s\n' "# stale status" > "$TARGET/.ralph/lib/status.sh"
printf '%s\n' "# Local agent note" >> "$instructions_file"

"$REPO_ROOT/install.sh" "$TARGET" --scripts-only --profile generic >/dev/null

if [[ "$(cat "$TARGET/.ralph/RALPH.md")" != "$custom_prompt" ]]; then
  echo "FAIL: installer should not overwrite an existing RALPH.md"
  exit 1
fi

if [[ "$(cat "$TARGET/.ralph/config.json")" != "$custom_config" ]]; then
  echo "FAIL: installer should not overwrite an existing config.json"
  exit 1
fi

if ! cmp -s "$REPO_ROOT/ralph/launch.sh" "$TARGET/.ralph/launch.sh"; then
  echo "FAIL: installer should refresh launch.sh"
  exit 1
fi

if ! cmp -s "$REPO_ROOT/ralph/lib/status.sh" "$TARGET/.ralph/lib/status.sh"; then
  echo "FAIL: installer should refresh lib/status.sh"
  exit 1
fi

if [[ ! -x "$TARGET/.ralph/launch.sh" || ! -x "$TARGET/.ralph/ralph.sh" ]]; then
  echo "FAIL: installer should keep shell entrypoints executable"
  exit 1
fi

marker_count=$(grep -c "<!-- ralph-loop-instructions -->" "$instructions_file")
if [[ "$marker_count" != "1" ]]; then
  echo "FAIL: installer should not duplicate Ralph Copilot instructions, got marker count $marker_count"
  exit 1
fi

if ! grep -q "# Local agent note" "$instructions_file"; then
  echo "FAIL: installer should preserve existing Copilot instruction content"
  exit 1
fi

# Verify the installer also installs preflight.sh — needed for launch.sh's
# preflight feature (issue #64). Refreshing should keep it in sync.
if ! cmp -s "$REPO_ROOT/ralph/lib/preflight.sh" "$TARGET/.ralph/lib/preflight.sh"; then
  echo "FAIL: installer should install/refresh lib/preflight.sh"
  exit 1
fi

# Verify the installer surfaces a dirty-tree warning + copy-pasteable commit
# hint when the freshly installed files would otherwise leave the working
# tree dirty (issue #64 follow-up #1).
fresh_target="$TEST_ROOT/target-dirty"
git init -q "$fresh_target"
( cd "$fresh_target" \
  && git checkout -qb main \
  && git config user.email "test@example.com" \
  && git config user.name "Test" \
  && echo seed > README.md \
  && git add README.md \
  && git commit -qm seed )

install_out=$("$REPO_ROOT/install.sh" "$fresh_target" --scripts-only --profile generic 2>&1)
if ! echo "$install_out" | grep -qF "Target repo is dirty after install"; then
  echo "FAIL: installer should warn when post-install tree is dirty"
  echo "--- install output ---"
  echo "$install_out"
  echo "----------------------"
  exit 1
fi
if ! echo "$install_out" | grep -qF "git -C \"$fresh_target\" commit -m 'Install Ralph loop scripts'"; then
  echo "FAIL: installer should print a copy-pasteable commit one-liner"
  exit 1
fi

# Verify the installer adds `.ralph` to `.git/info/exclude` so subsequent
# --enqueue mutations to config.json don't dirty the working tree (issue #64
# follow-up #1 — the real cause of the dirty-tree footgun).
if ! grep -qxF ".ralph" "$fresh_target/.git/info/exclude"; then
  echo "FAIL: installer should add .ralph to .git/info/exclude"
  exit 1
fi

echo "PASS: install.sh refreshes scripts without clobbering prompt/config"
