#!/usr/bin/env bash
# Regression test for issue #131: stale-script guard should use content, not mtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

make_repo() {
  local name="$1"
  local main_repo="$TEST_ROOT/$name-main"
  local origin="$TEST_ROOT/$name-origin.git"
  git init -q --bare "$origin"
  git init -q "$main_repo"
  cd "$main_repo"
  git checkout -qb main
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "initial" > README.md
  git add README.md
  git commit -qm "initial"
  git remote add origin "$origin"
  git push -q -u origin main

  # Create minimal Ralph structure
  mkdir -p ralph .ralph/lib .ralph/logs .ralph/lock
  
  # Copy launch.sh and dependencies
  cp "$REPO_ROOT/ralph/launch.sh" .ralph/launch.sh
  cp "$REPO_ROOT/ralph/lib/state.sh" .ralph/lib/state.sh
  cp "$REPO_ROOT/ralph/lib/labels.sh" .ralph/lib/labels.sh
  chmod +x .ralph/launch.sh

  # Create a minimal stub ralph.sh that exits cleanly
  cat > .ralph/ralph.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x .ralph/ralph.sh

  # Create minimal config and state
  cat > .ralph/config.json <<'EOF'
{"parallelism":1}
EOF
  cat > .ralph/state.json <<'EOF'
{"currentRun":null}
EOF

  echo "$main_repo"
}

# Test 1: Identical content with newer source mtime should NOT trip guard
echo "Test 1: identical content, newer source mtime → guard passes"
repo1=$(make_repo stale1)
cd "$repo1"

# Create source ralph.sh with known content
cat > ralph/ralph.sh <<'EOF'
#!/usr/bin/env bash
echo "version 1.0.0"
exit 0
EOF

# Copy to installed location (identical content)
cp ralph/ralph.sh .ralph/ralph.sh

# Artificially advance source mtime (simulate git checkout/merge)
sleep 1
touch ralph/ralph.sh

# Verify source is newer by mtime
if [[ "$(uname)" == "Darwin" ]]; then
  src_mtime=$(stat -f %m ralph/ralph.sh 2>/dev/null)
  ins_mtime=$(stat -f %m .ralph/ralph.sh 2>/dev/null)
else
  src_mtime=$(stat -c %Y ralph/ralph.sh 2>/dev/null)
  ins_mtime=$(stat -c %Y .ralph/ralph.sh 2>/dev/null)
fi
if [[ "$src_mtime" -le "$ins_mtime" ]]; then
  echo "❌ Test setup failed: source mtime not newer" >&2
  exit 1
fi

# Launch (actual launch, not --help) should succeed with identical content despite newer source mtime
# Use --once for minimal overhead
if RALPH_MAIN_REPO="$repo1" RALPH_LOOP_REPO="$repo1-loop" .ralph/launch.sh --once >/dev/null 2>&1; then
  echo "✅ Test 1 passed: identical content bypasses guard"
else
  exit_code=$?
  echo "❌ Test 1 failed: guard blocked on identical content (exit $exit_code)" >&2
  exit 1
fi

# Test 2: Different content should trip guard
echo "Test 2: different content → guard blocks"
repo2=$(make_repo stale2)
cd "$repo2"

# Install old version first
cat > .ralph/ralph.sh <<'EOF'
#!/usr/bin/env bash
echo "version 1.0.0"
exit 0
EOF
chmod +x .ralph/ralph.sh

# Wait, then create newer source with different content
sleep 1
cat > ralph/ralph.sh <<'EOF'
#!/usr/bin/env bash
echo "version 2.0.0"
exit 0
EOF

# Verify content differs
if cmp -s ralph/ralph.sh .ralph/ralph.sh; then
  echo "❌ Test setup failed: content should differ" >&2
  exit 1
fi

# Verify source is newer by mtime
if [[ "$(uname)" == "Darwin" ]]; then
  src_mtime=$(stat -f %m ralph/ralph.sh 2>/dev/null)
  ins_mtime=$(stat -f %m .ralph/ralph.sh 2>/dev/null)
else
  src_mtime=$(stat -c %Y ralph/ralph.sh 2>/dev/null)
  ins_mtime=$(stat -c %Y .ralph/ralph.sh 2>/dev/null)
fi
if [[ "$src_mtime" -le "$ins_mtime" ]]; then
  echo "❌ Test setup failed: source mtime not newer" >&2
  exit 1
fi

# Launch should fail due to content divergence
if RALPH_MAIN_REPO="$repo2" RALPH_LOOP_REPO="$repo2-loop" .ralph/launch.sh --once >/dev/null 2>&1; then
  echo "❌ Test 2 failed: guard did not block on different content" >&2
  exit 1
else
  echo "✅ Test 2 passed: different content triggers guard"
fi

# Test 3: Force flag should bypass guard even with different content
echo "Test 3: --force bypasses guard on different content"
cd "$repo2"  # Reuse repo2 which has different content

if RALPH_MAIN_REPO="$repo2" RALPH_LOOP_REPO="$repo2-loop" .ralph/launch.sh --force --once >/dev/null 2>&1; then
  echo "✅ Test 3 passed: --force bypasses guard"
else
  echo "❌ Test 3 failed: --force did not bypass guard" >&2
  exit 1
fi

echo "All tests passed!"
