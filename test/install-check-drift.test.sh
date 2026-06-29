#!/usr/bin/env bash
# Test install.sh --check drift detection (content-based).
#
# Regression test for issue #139 — verifies that install.sh --check:
#   - Exits 0 when installed .ralph/* scripts match ralph/* source content
#   - Exits non-zero and reports diverged files when content differs
#   - Is read-only (no mutations)

set -euo pipefail

# --- RED: Test 1 - exits 0 when content matches ---
test_check_passes_when_content_matches() {
  local tmp_repo
  tmp_repo=$(mktemp -d)
  trap "rm -rf '$tmp_repo'" EXIT

  # Minimal repo structure
  git init "$tmp_repo" >/dev/null 2>&1
  cd "$tmp_repo"
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "# test" > README.md
  git add README.md
  git commit -m "init" >/dev/null 2>&1

  # Install scripts
  "$INSTALL_SH" "$tmp_repo" --scripts-only >/dev/null 2>&1

  # Run check — should pass
  if "$INSTALL_SH" "$tmp_repo" --check >/dev/null 2>&1; then
    echo "✓ Test 1: --check exits 0 when content matches"
  else
    echo "✗ Test 1 FAILED: --check exited non-zero when content matched"
    exit 1
  fi
}

# --- RED: Test 2 - exits non-zero and reports file when content diverges ---
test_check_fails_when_content_diverges() {
  local tmp_repo
  tmp_repo=$(mktemp -d)
  trap "rm -rf '$tmp_repo'" EXIT

  # Minimal repo structure
  git init "$tmp_repo" >/dev/null 2>&1
  cd "$tmp_repo"
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "# test" > README.md
  git add README.md
  git commit -m "init" >/dev/null 2>&1

  # Install scripts
  "$INSTALL_SH" "$tmp_repo" --scripts-only >/dev/null 2>&1

  # Tamper with installed script
  echo "# drift" >> "$tmp_repo/.ralph/ralph.sh"

  # Run check — should fail and report the file
  local output
  set +e
  output=$("$INSTALL_SH" "$tmp_repo" --check 2>&1)
  local exit_code=$?
  set -e

  if [[ $exit_code -ne 0 ]]; then
    if echo "$output" | grep -q "ralph.sh"; then
      echo "✓ Test 2: --check exits non-zero and reports diverged file"
    else
      echo "✗ Test 2 FAILED: --check exited non-zero but did not report file name"
      echo "   Output: $output"
      exit 1
    fi
  else
    echo "✗ Test 2 FAILED: --check exited 0 when content diverged"
    exit 1
  fi
}

# --- RED: Test 3 - check is read-only (no mutations) ---
test_check_is_read_only() {
  local tmp_repo
  tmp_repo=$(mktemp -d)
  trap "rm -rf '$tmp_repo'" EXIT

  # Minimal repo structure
  git init "$tmp_repo" >/dev/null 2>&1
  cd "$tmp_repo"
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "# test" > README.md
  git add README.md
  git commit -m "init" >/dev/null 2>&1

  # Install scripts
  "$INSTALL_SH" "$tmp_repo" --scripts-only >/dev/null 2>&1

  # Tamper with installed script
  echo "# drift" >> "$tmp_repo/.ralph/ralph.sh"

  # Capture mtime before check
  local mtime_before
  mtime_before=$(stat -f "%m" "$tmp_repo/.ralph/ralph.sh" 2>/dev/null || stat -c "%Y" "$tmp_repo/.ralph/ralph.sh" 2>/dev/null)

  # Run check
  "$INSTALL_SH" "$tmp_repo" --check >/dev/null 2>&1 || true

  # Capture mtime after check
  local mtime_after
  mtime_after=$(stat -f "%m" "$tmp_repo/.ralph/ralph.sh" 2>/dev/null || stat -c "%Y" "$tmp_repo/.ralph/ralph.sh" 2>/dev/null)

  # Verify content not restored
  if grep -q "# drift" "$tmp_repo/.ralph/ralph.sh"; then
    echo "✓ Test 3: --check is read-only (no mutations)"
  else
    echo "✗ Test 3 FAILED: --check modified the file"
    exit 1
  fi
}

# Main
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

if [[ ! -x "$INSTALL_SH" ]]; then
  echo "✗ install.sh not found or not executable: $INSTALL_SH"
  exit 1
fi

test_check_passes_when_content_matches
test_check_fails_when_content_diverges
test_check_is_read_only

echo "All install --check drift tests passed"
