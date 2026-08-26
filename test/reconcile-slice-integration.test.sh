#!/usr/bin/env bash
# Integration coverage for guarded legacy slice-integration reconciliation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INCIDENT_FIXTURE="$SCRIPT_DIR/fixtures/reconcile-slice-507-legacy.json"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_dry_run_rejected() {
  local repo="$1" bin="$2" run_id="$3" expected="$4"
  shift 4
  local output
  if output=$(
    env "$@" \
      RALPH_MAIN_REPO="$repo" \
      RALPH_REPO="test/example" \
      RALPH_GH_BIN="$bin/gh" \
      "$REPO_ROOT/ralph/reconcile-slice.sh" \
        --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run 2>&1
  ); then
    fail "$expected should be rejected"
  fi
  grep -Fqi "$expected" <<<"$output" \
    || fail "rejection should explain '$expected' (got: $output)"
}

create_fixture() {
  local name="$1"
  local root="$TEST_ROOT/$name"
  local repo="$root/main"
  local origin="$root/origin.git"
  local bin="$root/bin"
  local run_id="20260825-184631-43b25623"
  local branch="ralph/prd/glasswork-505"

  mkdir -p "$repo" "$bin"
  git init -q --bare "$origin"
  git init -q "$repo"
  git -C "$repo" checkout -qb main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  printf 'base\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "base"
  git -C "$repo" remote add origin "https://github.com/test/example.git"
  git -C "$repo" config "url.$origin.insteadOf" \
    "https://github.com/test/example.git"
  git -C "$repo" push -q -u origin main

  local base merge_commit
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb slice-507
  printf 'integrated\n' >>"$repo/README.md"
  git -C "$repo" commit -qam "slice 507"
  git -C "$repo" checkout -q main
  git -C "$repo" branch "$branch" "$base"
  git -C "$repo" checkout -q "$branch"
  git -C "$repo" merge -q --no-ff slice-507 -m "Merge PR 533"
  merge_commit=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin "$branch"
  git -C "$repo" checkout -q main

  mkdir -p "$repo/.ralph/logs" "$repo/.ralph/runs/$run_id"
  printf '{"claims":{},"active_prd":"505","active_run_id":"%s"}\n' "$run_id" \
    >"$repo/.ralph/state.json"
  printf '[{"number":507,"title":"Legacy integrated slice"}]\n' \
    >"$repo/.ralph/runs/$run_id/queue.json"
  printf '{"items":{"507":{"status":"merged","pr_number":"533","pid":null}}}\n' \
    >"$repo/.ralph/runs/$run_id/status.json"
  jq -n \
    --arg run "$run_id" \
    --arg branch "$branch" \
    --arg base "$base" \
    '{
      run_id: $run,
      prd_number: "505",
      branch_name: $branch,
      remote: "origin",
      delivery_branch: "main",
      initial_base_sha: $base,
      owned_tip_sha: $base,
      created_at: "2026-08-25T18:46:31Z"
    }' >"$repo/.ralph/runs/$run_id/ownership.json"

  cat >"$bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1 \$2 \$3" == "issue view 507" ]]; then
  case "\${GH_ISSUE_MODE:-closed}" in
    closed) printf '{"number":507,"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/test/example/issues/507"}\n' ;;
    open) printf '{"number":507,"state":"OPEN","stateReason":null,"url":"https://github.com/test/example/issues/507"}\n' ;;
    malformed) printf '{not-json\n' ;;
    fail) echo "simulated issue API failure" >&2; exit 1 ;;
  esac
  exit 0
fi
if [[ "\$1 \$2 \$3" == "issue view 508" ]]; then
  printf '{"number":508,"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/test/example/issues/508"}\n'
  exit 0
fi
if [[ "\$1 \$2 \$3" == "pr view 533" ]]; then
  case "\${GH_PR_MODE:-merged}" in
    merged) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507}],"url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-base) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"main","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507}],"url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-link) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":999}],"url":"https://github.com/test/example/pull/533"}\n' ;;
    open) printf '{"number":533,"state":"OPEN","mergedAt":null,"baseRefName":"$branch","headRefName":"slice-507","mergeCommit":null,"url":"https://github.com/test/example/pull/533"}\n' ;;
    malformed) printf '{not-json\n' ;;
    fail) echo "simulated PR API failure" >&2; exit 1 ;;
  esac
  exit 0
fi
if [[ "\$1 \$2 \$3" == "pr view 534" && -n "\${GH_DESCENDANT_COMMIT:-}" ]]; then
  printf '{"number":534,"state":"MERGED","mergedAt":"2026-08-25T21:00:00Z","baseRefName":"$branch","headRefName":"slice-508","mergeCommit":{"oid":"%s"},"closingIssuesReferences":[{"number":508}],"url":"https://github.com/test/example/pull/534"}\n' "\$GH_DESCENDANT_COMMIT"
  exit 0
fi
if [[ "\$1 \$2" == "pr list" ]]; then
  case "\${GH_LIST_MODE:-exact}" in
    exact)
      if [[ -n "\${GH_DESCENDANT_COMMIT:-}" ]]; then
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507}]},{"number":534,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"%s"},"closingIssuesReferences":[{"number":508}]}]\n' "\$GH_DESCENDANT_COMMIT"
      else
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507}]}]\n'
      fi
      ;;
    conflict) printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507}]},{"number":534,"state":"OPEN","baseRefName":"$branch","mergeCommit":null,"closingIssuesReferences":[{"number":507}]}]\n' ;;
    empty) printf '[]\n' ;;
    malformed) printf '{not-json\n' ;;
    fail) echo "simulated PR list API failure" >&2; exit 1 ;;
  esac
  exit 0
fi
if [[ "\$1 \$2" == "api user" ]]; then
  case "\${GH_ACTOR_MODE:-ok}" in
    ok) printf 'test-operator\n' ;;
    malformed) printf '\n' ;;
    fail) echo "simulated actor API failure" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unhandled gh invocation: \$*" >&2
exit 1
EOF
  chmod +x "$bin/gh"

  printf '%s\n' "$repo|$bin|$run_id|$branch|$base|$merge_commit"
}

echo "Test 0: fixture preserves the exact Glasswork #507 incident evidence"
jq -e '
  .repository == "tjegbejimba/Glasswork"
  and .run_id == "20260825-184631-43b25623"
  and .prd_number == 505
  and .issue.number == 507
  and .issue.state == "CLOSED"
  and .issue.ralph_status == "merged"
  and .issue.integrated_commit == null
  and .pull_request.number == 533
  and .pull_request.state == "MERGED"
  and .pull_request.merge_commit
    == "f1d5213c3e07148afa508b044ea630406ad98422"
  and .remote_integration_tip == .pull_request.merge_commit
' "$INCIDENT_FIXTURE" >/dev/null \
  || fail "exact incident fixture is incomplete"
echo "PASS: exact Glasswork #507 incident evidence is frozen"

echo ""
echo "Test 1: dry-run proves the exact legacy #507 integration without mutation"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture exact-legacy)
before=$(jq -cS . "$repo/.ralph/runs/$run_id/status.json")
proof=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run
) || fail "exact legacy dry-run should succeed"
printf '%s\n' "$proof" | jq -e \
  --arg run "$run_id" \
  --arg branch "$branch" \
  --arg commit "$merge_commit" '
    .schema_version == 1
    and .action == "reconcile-slice-integrated"
    and .mode == "dry-run"
    and .repository == "test/example"
    and .run_id == $run
    and .prd_number == "505"
    and .issue.number == 507
    and .issue.state == "CLOSED"
    and .pull_request.number == 533
    and .pull_request.state == "MERGED"
    and .pull_request.base == $branch
    and .pull_request.merge_commit == $commit
    and .remote.tip == $commit
    and .remote.policy == "exact-tip"
    and .operator.login == "test-operator"
    and .prior_evidence.status == "merged"
    and .prior_evidence.pr_number == "533"
    and .proof_generated_at != null
  ' >/dev/null || fail "dry-run should emit the complete canonical proof"
after=$(jq -cS . "$repo/.ralph/runs/$run_id/status.json")
[[ "$after" == "$before" ]] || fail "dry-run must not mutate status evidence"
echo "PASS: exact legacy integration is proven without mutation"

echo ""
echo "Test 2: apply consumes the reviewed proof and records canonical evidence atomically"
proof_file="$TEST_ROOT/exact-legacy/proof.json"
printf '%s\n' "$proof" >"$proof_file"
apply_result=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 \
      --apply --proof "$proof_file"
) || fail "exact legacy apply should succeed"
printf '%s\n' "$apply_result" | jq -e '
  .mode == "apply"
  and .result == "recorded"
  and .status == "slice-integrated"
' >/dev/null || fail "apply should report the canonical recorded result"
jq -e \
  --arg commit "$merge_commit" '
    .items["507"].status == "slice-integrated"
    and .items["507"].pr_number == "533"
    and .items["507"].integrated_commit == $commit
    and (.items["507"].integrated_at | type == "string" and length > 0)
    and .items["507"].workerId == null
    and .items["507"].pid == null
    and .items["507"].reconciliation.schema_version == 1
    and .items["507"].reconciliation.source
      == "operator-guarded-reconciliation"
    and .items["507"].reconciliation.previous_status == "merged"
    and .items["507"].reconciliation.proof_generated_at != null
    and .items["507"].reconciliation.applied_at != null
  ' "$repo/.ralph/runs/$run_id/status.json" >/dev/null \
  || fail "apply should persist canonical evidence and reconciliation provenance"
echo "PASS: reviewed proof is applied atomically with provenance"

echo ""
echo "Test 3: rerunning apply with the same proof is idempotent"
recorded=$(jq -cS . "$repo/.ralph/runs/$run_id/status.json")
rerun_result=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 \
      --apply --proof "$proof_file"
) || fail "idempotent apply rerun should succeed"
printf '%s\n' "$rerun_result" | jq -e '
  .mode == "apply" and .result == "unchanged"
' >/dev/null || fail "idempotent rerun should report unchanged"
rerun_recorded=$(jq -cS . "$repo/.ralph/runs/$run_id/status.json")
[[ "$rerun_recorded" == "$recorded" ]] \
  || fail "idempotent rerun must not rewrite canonical evidence"
echo "PASS: repeated apply leaves identical canonical evidence"

echo ""
echo "Test 4: a fresh proof also reapplies idempotently"
fresh_proof="$TEST_ROOT/exact-legacy/fresh-proof.json"
RALPH_MAIN_REPO="$repo" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
  "$REPO_ROOT/ralph/reconcile-slice.sh" \
    --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run >"$fresh_proof"
fresh_result=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 \
      --apply --proof "$fresh_proof"
) || fail "fresh proof over prior reconciliation should be idempotent"
printf '%s\n' "$fresh_result" | jq -e '.result == "unchanged"' >/dev/null \
  || fail "fresh idempotent proof should report unchanged"
echo "PASS: fresh proof preserves prior canonical evidence"

echo ""
echo "Test 5: dry-run rejects a merged PR with the wrong base or issue link"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture wrong-base)
assert_dry_run_rejected "$repo" "$bin" "$run_id" "not merged into owned branch" \
  GH_PR_MODE=wrong-base
assert_dry_run_rejected "$repo" "$bin" "$run_id" "not linked to issue" \
  GH_PR_MODE=wrong-link
echo "PASS: wrong PR base and issue link are rejected"

echo ""
echo "Test 6: dry-run accepts only fully accounted descendants of the target merge"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture accounted-descendant)
git -C "$repo" checkout -qb slice-508 "$branch"
printf 'second integrated slice\n' >>"$repo/README.md"
git -C "$repo" commit -qam "slice 508"
git -C "$repo" checkout -q "$branch"
git -C "$repo" merge -q --no-ff slice-508 -m "Merge PR 534"
descendant_tip=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q origin "$branch"
git -C "$repo" checkout -q main
jq --arg tip "$descendant_tip" '
  .items["508"] = {
    status: "slice-integrated",
    pr_number: "534",
    integrated_commit: $tip,
    integrated_at: "2026-08-25T21:00:00Z",
    pid: null
  }
' "$repo/.ralph/runs/$run_id/status.json" \
  >"$repo/.ralph/runs/$run_id/status.tmp"
mv "$repo/.ralph/runs/$run_id/status.tmp" \
  "$repo/.ralph/runs/$run_id/status.json"
jq '. + [{"number":508,"title":"Later integrated slice"}]' \
  "$repo/.ralph/runs/$run_id/queue.json" \
  >"$repo/.ralph/runs/$run_id/queue.tmp"
mv "$repo/.ralph/runs/$run_id/queue.tmp" \
  "$repo/.ralph/runs/$run_id/queue.json"
descendant_proof=$(
  GH_DESCENDANT_COMMIT="$descendant_tip" \
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run
) || fail "fully accounted descendant history should be accepted"
printf '%s\n' "$descendant_proof" | jq -e \
  --arg tip "$descendant_tip" '
    .remote.tip == $tip
    and .remote.policy == "accounted-first-parent-descendant"
    and .remote.accounted_commits == [$tip]
  ' >/dev/null || fail "descendant proof should identify the exact accounted commits"
echo "PASS: fully accounted first-parent descendant history is proven"

echo ""
echo "Test 7: dry-run rejects open issues and open pull requests"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture open-state)
assert_dry_run_rejected "$repo" "$bin" "$run_id" "not closed" \
  GH_ISSUE_MODE=open
assert_dry_run_rejected "$repo" "$bin" "$run_id" "not merged into owned branch" \
  GH_PR_MODE=open
echo "PASS: open issue and PR evidence are rejected"

echo ""
echo "Test 8: unaccounted remote descendants fail closed"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture descendant-ambiguity)
git -C "$repo" checkout -q "$branch"
printf 'unaccounted branch movement\n' >>"$repo/README.md"
git -C "$repo" commit -qam "unaccounted branch movement"
git -C "$repo" push -q origin "$branch"
git -C "$repo" checkout -q main
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "lacks unique canonical slice evidence"
echo "PASS: descendant branch ambiguity is rejected"

echo ""
echo "Test 9: unrelated remote branch movement fails closed"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture remote-divergence)
tree=$(git -C "$repo" rev-parse "${base}^{tree}")
diverged_tip=$(printf 'diverged\n' | git -C "$repo" commit-tree "$tree")
git -C "$repo" push -q --force origin \
  "$diverged_tip:refs/heads/$branch"
git -C "$repo" update-ref "refs/heads/$branch" "$diverged_tip"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "does not descend from owned history"
echo "PASS: unrelated remote branch movement is rejected"

echo ""
echo "Test 10: conflicting existing integration evidence fails closed"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture conflicting-evidence)
jq --arg conflict "$base" '
  .items["507"].status = "slice-integrated"
  | .items["507"].integrated_commit = $conflict
  | .items["507"].integrated_at = "2026-08-25T19:00:00Z"
' "$repo/.ralph/runs/$run_id/status.json" \
  >"$repo/.ralph/runs/$run_id/status.tmp"
mv "$repo/.ralph/runs/$run_id/status.tmp" \
  "$repo/.ralph/runs/$run_id/status.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "existing integrated commit conflicts"
echo "PASS: conflicting canonical evidence is rejected"

echo ""
echo "Test 11: claims and linked worktrees block reconciliation"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture live-claim)
printf '{"claims":{"507":{"workerId":1,"pid":999999}},"active_prd":"505","active_run_id":"%s"}\n' \
  "$run_id" >"$repo/.ralph/state.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" "claimed"

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture live-worktree)
git -C "$repo" branch worker-fixture main
git -C "$repo" worktree add -q "$TEST_ROOT/live-worktree/worker" worker-fixture
assert_dry_run_rejected "$repo" "$bin" "$run_id" "linked worktree"
echo "PASS: claim and worktree activity are rejected"

echo ""
echo "Test 12: live Ralph worker and launcher processes block reconciliation"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture live-process)
cat >"$repo/.ralph/ralph.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$repo/.ralph/ralph.sh"
"$repo/.ralph/ralph.sh" &
live_pid=$!
sleep 0.2
assert_dry_run_rejected "$repo" "$bin" "$run_id" "launcher or worker is still active"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

cat >"$repo/.ralph/launch.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$repo/.ralph/launch.sh"
"$repo/.ralph/launch.sh" &
live_pid=$!
sleep 0.2
assert_dry_run_rejected "$repo" "$bin" "$run_id" "launcher or worker is still active"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
echo "PASS: live Ralph worker and launcher processes are rejected"

echo ""
echo "Test 13: ownership mismatches, duplicate owners, and conflicting linked PRs fail closed"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture ownership-mismatch)
jq '.prd_number = "999"' "$repo/.ralph/runs/$run_id/ownership.json" \
  >"$repo/.ralph/runs/$run_id/ownership.tmp"
mv "$repo/.ralph/runs/$run_id/ownership.tmp" \
  "$repo/.ralph/runs/$run_id/ownership.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "ownership evidence does not match"

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture duplicate-owner)
duplicate_run="20260825-conflicting-owner"
mkdir -p "$repo/.ralph/runs/$duplicate_run"
jq --arg run "$duplicate_run" '.run_id = $run' \
  "$repo/.ralph/runs/$run_id/ownership.json" \
  >"$repo/.ralph/runs/$duplicate_run/ownership.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "exactly one matching active owner"

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture conflicting-pr)
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "missing or conflicting" GH_LIST_MODE=conflict
echo "PASS: ownership and pull request conflicts are rejected"

echo ""
echo "Test 14: configured remote must match the GitHub API repository"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture remote-binding)
git -C "$repo" remote add evil "https://github.com/attacker/mirror.git"
git -C "$repo" config \
  "url.$TEST_ROOT/remote-binding/origin.git.insteadOf" \
  "https://github.com/attacker/mirror.git"
jq '.remote = "evil"' "$repo/.ralph/runs/$run_id/ownership.json" \
  >"$repo/.ralph/runs/$run_id/ownership.tmp"
mv "$repo/.ralph/runs/$run_id/ownership.tmp" \
  "$repo/.ralph/runs/$run_id/ownership.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "does not match GitHub repository"
echo "PASS: mismatched Git remote is rejected"

echo ""
echo "Test 15: replacement refs are forbidden during ancestry proof"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture replace-ref)
unused_commit=$(printf 'unused\n' | git -C "$repo" commit-tree "${base}^{tree}")
git -C "$repo" replace "$unused_commit" "$base"
assert_dry_run_rejected "$repo" "$bin" "$run_id" "replacement refs"
echo "PASS: replacement-object ancestry is rejected"

echo ""
echo "Test 16: target merge must be newer than the run-owned tip"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture old-merge)
jq --arg commit "$merge_commit" '.owned_tip_sha = $commit' \
  "$repo/.ralph/runs/$run_id/ownership.json" \
  >"$repo/.ralph/runs/$run_id/ownership.tmp"
mv "$repo/.ralph/runs/$run_id/ownership.tmp" \
  "$repo/.ralph/runs/$run_id/ownership.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "not a strict descendant of the owned tip"
echo "PASS: pre-ownership merge attribution is rejected"

echo ""
echo "Test 17: evidence changes between dry-run and apply are rejected"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture evidence-race)
race_proof="$TEST_ROOT/evidence-race/proof.json"
RALPH_MAIN_REPO="$repo" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
  "$REPO_ROOT/ralph/reconcile-slice.sh" \
    --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run >"$race_proof"
jq '.items["507"].pr_number = "999"' \
  "$repo/.ralph/runs/$run_id/status.json" \
  >"$repo/.ralph/runs/$run_id/status.tmp"
mv "$repo/.ralph/runs/$run_id/status.tmp" \
  "$repo/.ralph/runs/$run_id/status.json"
if race_output=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 \
      --apply --proof "$race_proof" 2>&1
); then
  fail "changed evidence should block apply"
fi
grep -Eqi "changed|revalidation failed|conflicts" <<<"$race_output" \
  || fail "race rejection should explain changed evidence (got: $race_output)"
jq -e '.items["507"].status == "merged"' \
  "$repo/.ralph/runs/$run_id/status.json" >/dev/null \
  || fail "race rejection must not write canonical evidence"
echo "PASS: changed dry-run evidence cannot be applied"

echo ""
echo "Test 18: API failures and malformed JSON fail closed"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture api-errors)
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "operator identity lookup failed" GH_ACTOR_MODE=fail
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "GitHub issue lookup failed" GH_ISSUE_MODE=fail
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "returned invalid evidence" GH_ISSUE_MODE=malformed
printf '{not-json\n' >"$repo/.ralph/runs/$run_id/status.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "not a valid terminal prior run"
echo "PASS: API and JSON failures are rejected without mutation"

echo ""
echo "Test 19: incomplete canonical evidence is rejected"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture incomplete-canonical)
jq --arg commit "$merge_commit" '
  .items["507"] = {
    status: "slice-integrated",
    integrated_commit: $commit,
    pid: null
  }
' "$repo/.ralph/runs/$run_id/status.json" \
  >"$repo/.ralph/runs/$run_id/status.tmp"
mv "$repo/.ralph/runs/$run_id/status.tmp" \
  "$repo/.ralph/runs/$run_id/status.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "existing status evidence is malformed"
echo "PASS: incomplete canonical evidence cannot report unchanged"

echo ""
echo "Test 20: malformed reconciliation provenance is rejected"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture malformed-provenance)
malformed_proof="$TEST_ROOT/malformed-provenance/proof.json"
RALPH_MAIN_REPO="$repo" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
  "$REPO_ROOT/ralph/reconcile-slice.sh" \
    --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run >"$malformed_proof"
jq --arg commit "$merge_commit" --slurpfile proof "$malformed_proof" '
  .items["507"] = {
    status: "slice-integrated",
    pr_number: "533",
    integrated_commit: $commit,
    integrated_at: "2026-08-25T20:00:00Z",
    reconciliation: {
      source: "operator-guarded-reconciliation",
      proof: $proof[0]
    },
    pid: null
  }
' "$repo/.ralph/runs/$run_id/status.json" \
  >"$repo/.ralph/runs/$run_id/status.tmp"
mv "$repo/.ralph/runs/$run_id/status.tmp" \
  "$repo/.ralph/runs/$run_id/status.json"
if malformed_output=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 \
      --apply --proof "$malformed_proof" 2>&1
); then
  fail "malformed reconciliation provenance should be rejected"
fi
grep -Fqi "provenance" <<<"$malformed_output" \
  || fail "malformed provenance rejection should be explicit (got: $malformed_output)"
echo "PASS: malformed reconciliation provenance cannot be blessed"

echo ""
echo "Test 21: identical pre-existing canonical evidence is idempotent"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture identical-evidence)
jq --arg commit "$merge_commit" '
  .items["507"].status = "slice-integrated"
  | .items["507"].integrated_commit = $commit
  | .items["507"].integrated_at = "2026-08-25T20:00:00Z"
' "$repo/.ralph/runs/$run_id/status.json" \
  >"$repo/.ralph/runs/$run_id/status.tmp"
mv "$repo/.ralph/runs/$run_id/status.tmp" \
  "$repo/.ralph/runs/$run_id/status.json"
identical_before=$(jq -cS . "$repo/.ralph/runs/$run_id/status.json")
identical_proof="$TEST_ROOT/identical-evidence/proof.json"
RALPH_MAIN_REPO="$repo" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
  "$REPO_ROOT/ralph/reconcile-slice.sh" \
    --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run \
    >"$identical_proof"
identical_result=$(
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 \
      --apply --proof "$identical_proof"
) || fail "identical canonical evidence should be accepted idempotently"
printf '%s\n' "$identical_result" \
  | jq -e '.result == "unchanged"' >/dev/null \
  || fail "identical evidence should report unchanged"
identical_after=$(jq -cS . "$repo/.ralph/runs/$run_id/status.json")
[[ "$identical_after" == "$identical_before" ]] \
  || fail "identical canonical evidence must not be rewritten"
echo "PASS: identical canonical evidence remains unchanged"
