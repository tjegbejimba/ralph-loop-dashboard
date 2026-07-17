#!/usr/bin/env bash
# High-level PRD launch coverage: ownership must exist before a worker starts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

main_repo="$TEST_ROOT/main"
origin="$TEST_ROOT/origin.git"
loop_repo="$TEST_ROOT/loop"
run_id="run-prd-200"
run_dir="$main_repo/.ralph/runs/$run_id"

git init -q --bare "$origin"
git init -q "$main_repo"
git -C "$main_repo" checkout -qb main
git -C "$main_repo" config user.email "test@example.com"
git -C "$main_repo" config user.name "Test"
echo "initial" > "$main_repo/README.md"
git -C "$main_repo" add README.md
git -C "$main_repo" commit -qm "initial"
git -C "$main_repo" remote add origin "$origin"
git -C "$main_repo" push -q -u origin main

mkdir -p "$main_repo/.ralph/lib" "$main_repo/.ralph/logs" "$main_repo/.ralph/lock" "$run_dir"
cp "$REPO_ROOT/ralph/launch.sh" "$main_repo/.ralph/launch.sh"
cp "$REPO_ROOT/ralph/lib/state.sh" "$main_repo/.ralph/lib/state.sh"
cp "$REPO_ROOT/ralph/lib/labels.sh" "$main_repo/.ralph/lib/labels.sh"
cp "$REPO_ROOT/ralph/lib/prd-branch.sh" "$main_repo/.ralph/lib/prd-branch.sh"
chmod +x "$main_repo/.ralph/launch.sh"

cat > "$main_repo/.ralph/config.json" <<'EOF'
{
  "issue": { "numbers": [201] },
  "prd": {
    "integrationBranchTemplate": "integration/{feature-slug}-{prd_number}",
    "remote": "origin",
    "deliveryBranch": "main"
  }
}
EOF
cat > "$main_repo/.ralph/RALPH.md" <<'EOF'
<!-- RALPH_PRD_REF: #200 -->
EOF
printf '{"items":{}}\n' > "$run_dir/status.json"

bin_dir="$TEST_ROOT/bin"
mkdir -p "$bin_dir"
cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue view" && "$3" == "200" ]]; then
  printf '%s\n' '{"number":200,"title":"Owned PRD integration branches","state":"OPEN"}'
  exit 0
fi
printf 'mock gh: unhandled: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$bin_dir/gh"

cat > "$main_repo/.ralph/ralph.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ownership="$RALPH_MAIN_REPO/.ralph/runs/$RALPH_RUN_ID/ownership.json"
test -f "$ownership"
test "$(jq -r '.branch_name' "$ownership")" = "integration/owned-prd-integration-branches-200"
git -C "$RALPH_MAIN_REPO" show-ref --verify --quiet \
  refs/heads/integration/owned-prd-integration-branches-200
printf 'worker-started\n' > "$RALPH_MAIN_REPO/.ralph/worker-started"
EOF
chmod +x "$main_repo/.ralph/ralph.sh"

RALPH_MAIN_REPO="$main_repo" \
RALPH_LOOP_REPO="$loop_repo" \
RALPH_RUN_ID="$run_id" \
RALPH_RUN_DIR="$run_dir" \
RALPH_GH_BIN="$bin_dir/gh" \
  "$main_repo/.ralph/launch.sh" --foreground --once >/dev/null

test -f "$main_repo/.ralph/worker-started"
jq -e \
  --arg run "$run_id" \
  '.run_id == $run
   and .prd_number == "200"
   and .branch_name == "integration/owned-prd-integration-branches-200"
   and .remote == "origin"
   and .delivery_branch == "main"
   and (.initial_base_sha | length == 40)' \
  "$run_dir/ownership.json" >/dev/null
test "$(jq -r '.active_prd' "$main_repo/.ralph/state.json")" = "200"
test "$(jq -r '.active_run_id' "$main_repo/.ralph/state.json")" = "$run_id"
test "$(jq -r '.claims | type' "$main_repo/.ralph/state.json")" = "object"

echo "PASS: PRD ownership and branch are initialized before workers launch"
