#!/usr/bin/env bash
# Integration test for install.sh self-hosting symlink behavior.
# Per ADR 0004 decision 2, when TARGET is the Ralph source repo itself,
# installed scripts should be symlinks to the tracked sources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Test 1: Self-hosting checkout gets symlinks for executables
echo "Test 1: Self-hosting checkout creates symlinks..."
SELF_TARGET="$TEST_ROOT/ralph-source"
cp -R "$REPO_ROOT" "$SELF_TARGET"
cd "$SELF_TARGET"

# Clean any existing .ralph/ to start fresh
rm -rf .ralph

"$SELF_TARGET/install.sh" "$SELF_TARGET" --scripts-only --profile generic >/dev/null

# Verify executable surface is symlinked
if [[ ! -L ".ralph/ralph.sh" ]]; then
  echo "FAIL: .ralph/ralph.sh should be a symlink in self-hosting checkout"
  exit 1
fi

if [[ ! -L ".ralph/launch.sh" ]]; then
  echo "FAIL: .ralph/launch.sh should be a symlink in self-hosting checkout"
  exit 1
fi

if [[ ! -L ".ralph/lib" ]]; then
  echo "FAIL: .ralph/lib should be a symlink in self-hosting checkout"
  exit 1
fi

if [[ ! -L ".ralph/profiles" ]]; then
  echo "FAIL: .ralph/profiles should be a symlink in self-hosting checkout"
  exit 1
fi

# Verify symlinks resolve to tracked sources
if [[ "$(readlink .ralph/ralph.sh)" != "../ralph/ralph.sh" ]]; then
  echo "FAIL: .ralph/ralph.sh should link to ../ralph/ralph.sh, got $(readlink .ralph/ralph.sh)"
  exit 1
fi

if [[ "$(readlink .ralph/launch.sh)" != "../ralph/launch.sh" ]]; then
  echo "FAIL: .ralph/launch.sh should link to ../ralph/launch.sh, got $(readlink .ralph/launch.sh)"
  exit 1
fi

if [[ "$(readlink .ralph/lib)" != "../ralph/lib" ]]; then
  echo "FAIL: .ralph/lib should link to ../ralph/lib, got $(readlink .ralph/lib)"
  exit 1
fi

if [[ "$(readlink .ralph/profiles)" != "../ralph/profiles" ]]; then
  echo "FAIL: .ralph/profiles should link to ../ralph/profiles, got $(readlink .ralph/profiles)"
  exit 1
fi

# Test 2: config.json and RALPH.md remain regular files
echo "Test 2: Customization files remain regular files..."
if [[ -L ".ralph/config.json" ]]; then
  echo "FAIL: .ralph/config.json should be a regular file, not a symlink"
  exit 1
fi

if [[ ! -f ".ralph/config.json" ]]; then
  echo "FAIL: .ralph/config.json should exist as a regular file"
  exit 1
fi

if [[ -L ".ralph/RALPH.md" ]]; then
  echo "FAIL: .ralph/RALPH.md should be a regular file, not a symlink"
  exit 1
fi

if [[ ! -f ".ralph/RALPH.md" ]]; then
  echo "FAIL: .ralph/RALPH.md should exist as a regular file"
  exit 1
fi

# Test 3: Foreign target repo gets regular file copies
echo "Test 3: Foreign target gets copied files..."
FOREIGN_TARGET="$TEST_ROOT/foreign"
git init -q "$FOREIGN_TARGET"
cd "$FOREIGN_TARGET"
git checkout -qb main
git config user.email "test@example.com"
git config user.name "Test"
echo "foreign" > README.md
git add README.md
git commit -qm "initial"

"$SELF_TARGET/install.sh" "$FOREIGN_TARGET" --scripts-only --profile generic >/dev/null

# Verify executables are regular files, not symlinks
if [[ -L ".ralph/ralph.sh" ]]; then
  echo "FAIL: .ralph/ralph.sh should be a regular file in foreign target, not a symlink"
  exit 1
fi

if [[ ! -f ".ralph/ralph.sh" ]]; then
  echo "FAIL: .ralph/ralph.sh should exist as a regular file in foreign target"
  exit 1
fi

if [[ -L ".ralph/launch.sh" ]]; then
  echo "FAIL: .ralph/launch.sh should be a regular file in foreign target, not a symlink"
  exit 1
fi

if [[ -L ".ralph/lib" ]]; then
  echo "FAIL: .ralph/lib should be a directory in foreign target, not a symlink"
  exit 1
fi

if [[ ! -d ".ralph/lib" ]]; then
  echo "FAIL: .ralph/lib should exist as a directory in foreign target"
  exit 1
fi

if [[ -L ".ralph/profiles" ]]; then
  echo "FAIL: .ralph/profiles should be a directory in foreign target, not a symlink"
  exit 1
fi

# Verify content is byte-identical (cp worked correctly)
if ! cmp -s "$SELF_TARGET/ralph/ralph.sh" ".ralph/ralph.sh"; then
  echo "FAIL: .ralph/ralph.sh content should match source in foreign target"
  exit 1
fi

# Test 4: Idempotent re-install preserves symlinks
echo "Test 4: Re-install preserves symlinks in self-hosting checkout..."
cd "$SELF_TARGET"

# Modify config.json to ensure it's preserved
custom_config='{"profile":"custom","keep":true}'
printf '%s\n' "$custom_config" > .ralph/config.json

# Re-run install
"$SELF_TARGET/install.sh" "$SELF_TARGET" --scripts-only --profile generic >/dev/null

# Symlinks should still be symlinks
if [[ ! -L ".ralph/ralph.sh" ]]; then
  echo "FAIL: .ralph/ralph.sh should remain a symlink after re-install"
  exit 1
fi

if [[ ! -L ".ralph/lib" ]]; then
  echo "FAIL: .ralph/lib should remain a symlink after re-install"
  exit 1
fi

# config.json should be preserved and still a regular file
if [[ -L ".ralph/config.json" ]]; then
  echo "FAIL: .ralph/config.json should remain a regular file after re-install"
  exit 1
fi

if [[ "$(cat .ralph/config.json)" != "$custom_config" ]]; then
  echo "FAIL: .ralph/config.json content should be preserved after re-install"
  exit 1
fi

echo "PASS: install.sh creates symlinks in self-hosting checkout, copies in foreign targets"
