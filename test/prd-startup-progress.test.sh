#!/usr/bin/env bash
# Verifies that normal PRD launch reports progress before remote initialization.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
LAUNCH_PID=""
trap '[[ -n "$LAUNCH_PID" ]] && kill "$LAUNCH_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

repo="$TEST_ROOT/main"
origin="$TEST_ROOT/origin.git"
bin="$TEST_ROOT/bin"
run_id="20260825-prd-startup-progress"
run_dir="$repo/.ralph/runs/$run_id"
marker="$TEST_ROOT/issue-view-started"
launch_log="$TEST_ROOT/launch.out"

mkdir -p "$repo" "$bin"
git init -q --bare "$origin"
git init -q "$repo"
git -C "$repo" checkout -qb main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
printf 'base\n' >"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm "base"
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q -u origin main

mkdir -p "$repo/.ralph/lib" "$run_dir"
cp "$REPO_ROOT/ralph/launch.sh" "$repo/.ralph/launch.sh"
cp "$REPO_ROOT/ralph/lib/state.sh" "$repo/.ralph/lib/state.sh"
cp "$REPO_ROOT/ralph/lib/status.sh" "$repo/.ralph/lib/status.sh"
cp "$REPO_ROOT/ralph/lib/prd-branch.sh" "$repo/.ralph/lib/prd-branch.sh"
chmod +x "$repo/.ralph/launch.sh"
cat >"$repo/.ralph/ralph.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$repo/.ralph/ralph.sh"
cat >"$repo/.ralph/config.json" <<'EOF'
{
  "issue": {"numbers": [506]},
  "prd": {
    "integrationBranchTemplate": "ralph/prd/{feature-slug}-{prd_number}",
    "remote": "origin",
    "deliveryBranch": "main"
  }
}
EOF
printf '<!-- RALPH_PRD_REF: #505 -->\n' >"$repo/.ralph/RALPH.md"
printf '[{"number":506,"title":"Leaf slice"}]\n' >"$run_dir/queue.json"
printf '{"items":{}}\n' >"$run_dir/status.json"

cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue view" && "$3" == "505" ]]; then
  : >"$GH_STARTED_MARKER"
  sleep 2
  printf '{"number":505,"title":"PRD startup progress","state":"OPEN"}\n'
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  printf '[]\n'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$bin/gh"

RALPH_MAIN_REPO="$repo" \
RALPH_LOOP_REPO="$TEST_ROOT/worker" \
RALPH_RUN_ID="$run_id" \
RALPH_RUN_DIR="$run_dir" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
GH_STARTED_MARKER="$marker" \
  "$repo/.ralph/launch.sh" --foreground --once >"$launch_log" 2>&1 &
LAUNCH_PID=$!

for _ in {1..100}; do
  [[ -f "$marker" ]] && break
  kill -0 "$LAUNCH_PID" 2>/dev/null \
    || { cat "$launch_log"; fail "launch exited before PRD initialization blocked"; }
  sleep 0.02
done
[[ -f "$marker" ]] || fail "PRD issue lookup did not start"

jq -e \
  '.phase == "setup-locks-acquired" and (.sequence | type == "number")' \
  "$run_dir/startup.json" >/dev/null \
  || { cat "$launch_log"; fail "setup-lock progress must precede PRD initialization"; }
jq -e '.items | length == 0' "$run_dir/status.json" >/dev/null \
  || fail "startup progress must not count as worker registration"

if ! wait "$LAUNCH_PID"; then
  LAUNCH_PID=""
  cat "$launch_log"
  fail "PRD launch should complete after initialization resumes"
fi
LAUNCH_PID=""

echo "PASS: normal PRD launch reports setup-lock progress before worker registration"
