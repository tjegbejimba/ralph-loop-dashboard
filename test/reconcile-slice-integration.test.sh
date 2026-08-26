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
  local branch="ralph/prd/prd-parent-tasks-hierarchy-and-leaf-first-execution-505"

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
  jq -n '{
    repo: "test/example",
    prd: {remote: "origin", deliveryBranch: "main"},
    issue: {branchPrefix: "slice-"}
  }' >"$repo/.ralph/config.json"
  printf '{"claims":{},"active_prd":"505","active_run_id":"%s"}\n' "$run_id" \
    >"$repo/.ralph/state.json"
  printf '[{"number":507,"title":"Legacy integrated slice"}]\n' \
    >"$repo/.ralph/runs/$run_id/queue.json"
  printf '{"items":{"507":{"status":"merged","pr_number":"533","pid":null,"legacy_marker":"remove-me"}}}\n' \
    >"$repo/.ralph/runs/$run_id/status.json"
  jq -n --arg root "$(cd "$repo" && pwd -P)" \
    '{repoRoot:$root,runMode:"until-empty",createdAt:"2026-08-25T18:46:31Z"}' \
    >"$repo/.ralph/runs/$run_id/metadata.json"
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
    closed) printf '{"number":507,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-08-25T20:05:00Z","closedByPullRequestsReferences":[],"comments":[{"author":{"login":"test-owner"},"authorAssociation":"OWNER","body":"Merged via PR #533 into \`$branch\`.","createdAt":"2026-08-25T20:01:00Z"}],"url":"https://github.com/test/example/issues/507"}\n' ;;
    closed-by-pr) printf '{"number":507,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-08-25T20:05:00Z","closedByPullRequestsReferences":[{"number":533}],"comments":[],"url":"https://github.com/test/example/issues/507"}\n' ;;
    no-closure) printf '{"number":507,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-08-25T20:05:00Z","closedByPullRequestsReferences":[],"comments":[],"url":"https://github.com/test/example/issues/507"}\n' ;;
    untrusted-closure) printf '{"number":507,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-08-25T20:05:00Z","closedByPullRequestsReferences":[],"comments":[{"author":{"login":"outside-user"},"authorAssociation":"CONTRIBUTOR","body":"Merged via PR #533 into \`$branch\`.","createdAt":"2026-08-25T20:01:00Z"}],"url":"https://github.com/test/example/issues/507"}\n' ;;
    stale-closure) printf '{"number":507,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-08-25T20:05:00Z","closedByPullRequestsReferences":[],"comments":[{"author":{"login":"test-owner"},"authorAssociation":"OWNER","body":"Merged via PR #533 into \`$branch\`.","createdAt":"2026-08-25T19:59:00Z"}],"url":"https://github.com/test/example/issues/507"}\n' ;;
    open) printf '{"number":507,"state":"OPEN","stateReason":null,"closedAt":null,"closedByPullRequestsReferences":[],"comments":[],"url":"https://github.com/test/example/issues/507"}\n' ;;
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
    merged) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507-safe-canonical-parent-hierarchy","headRepository":{"nameWithOwner":"test/example"},"mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Implements the slice. Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    closing-ref) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507-safe-canonical-parent-hierarchy","headRepository":{"nameWithOwner":"test/example"},"mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507}],"body":"","url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-base) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"main","headRefName":"slice-507-safe-canonical-parent-hierarchy","headRepository":{"nameWithOwner":"test/example"},"mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-link) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507-safe-canonical-parent-hierarchy","headRepository":{"nameWithOwner":"test/example"},"mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":999}],"body":"Closes #999","url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-head) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"feature-unrelated","headRepository":{"nameWithOwner":"test/example"},"mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-head-repo) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507-safe-canonical-parent-hierarchy","headRepository":{"nameWithOwner":"attacker/fork"},"mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
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
if [[ "\$1 \$2" == "api --paginate" ]]; then
  case "\${GH_OPEN_PRS_MODE:-empty}" in
    empty) printf '[[]]\n' ;;
    body-conflict) printf '[[{"number":534,"state":"open","base":{"ref":"main"},"head":{"ref":"other","repo":{"full_name":"test/example"}},"body":"Fixes #507"}]]\n' ;;
    head-conflict) printf '[[{"number":534,"state":"open","base":{"ref":"main"},"head":{"ref":"slice-507-competing","repo":{"full_name":"test/example"}},"body":""}]]\n' ;;
    branch-pr) printf '[[{"number":534,"state":"open","base":{"ref":"main"},"head":{"ref":"$branch","repo":{"full_name":"test/example"}},"body":""}]]\n' ;;
    page-two-conflict) printf '[[{"number":534,"state":"open","base":{"ref":"main"},"head":{"ref":"unrelated","repo":{"full_name":"test/example"}},"body":""}],[{"number":535,"state":"open","base":{"ref":"main"},"head":{"ref":"slice-507-page-two","repo":{"full_name":"test/example"}},"body":""}]]\n' ;;
    malformed) printf '{not-json\n' ;;
    malformed-page) printf '[{"number":534}]\n' ;;
    fail) echo "simulated open PR API failure" >&2; exit 1 ;;
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
  and .issue.closed_at == "2026-08-25T23:05:34Z"
  and .issue.closure_comment.author_association == "OWNER"
  and .issue.ralph_status == "merged"
  and .issue.integrated_commit == null
  and .pull_request.number == 533
  and .pull_request.state == "MERGED"
  and .pull_request.merged_at == "2026-08-25T23:04:39Z"
  and .pull_request.base
    == "ralph/prd/prd-parent-tasks-hierarchy-and-leaf-first-execution-505"
  and .pull_request.head == "slice-507-safe-canonical-parent-hierarchy"
  and .pull_request.head_repository == "tjegbejimba/Glasswork"
  and .pull_request.body_link == "Closes #507"
  and .pull_request.closing_issue_references == []
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
    and .issue.closed_at == "2026-08-25T20:05:00Z"
    and .issue.closure.kind == "trusted-explicit-comment"
    and .issue.closure.author == "test-owner"
    and .issue.closure.author_association == "OWNER"
    and .issue.closure.created_at == "2026-08-25T20:01:00Z"
    and .pull_request.number == 533
    and .pull_request.state == "MERGED"
    and .pull_request.base == $branch
    and .pull_request.head == "slice-507-safe-canonical-parent-hierarchy"
    and .pull_request.head_repository == "test/example"
    and .pull_request.issue_link == "closing-keyword"
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
    and .items["507"].legacy_marker == null
    and ((.items["507"] | keys | sort) == [
      "error",
      "integrated_at",
      "integrated_commit",
      "logFile",
      "pid",
      "pr_number",
      "reconciliation",
      "startedAt",
      "status",
      "workerId"
    ])
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
assert_dry_run_rejected "$repo" "$bin" "$run_id" "does not use canonical issue head" \
  GH_PR_MODE=wrong-head
assert_dry_run_rejected "$repo" "$bin" "$run_id" "head repository does not match" \
  GH_PR_MODE=wrong-head-repo
echo "PASS: wrong PR base, linkage, head, and head repository are rejected"

echo ""
echo "Test 6: exact-tip policy rejects even fully accounted descendants"
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
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "does not equal current remote integration tip"
echo "PASS: accounted descendants cannot weaken exact-tip recovery"

echo ""
echo "Test 7: dry-run rejects open issues and open pull requests"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture open-state)
assert_dry_run_rejected "$repo" "$bin" "$run_id" "not closed" \
  GH_ISSUE_MODE=open
assert_dry_run_rejected "$repo" "$bin" "$run_id" "not merged" \
  GH_PR_MODE=open
echo "PASS: open issue and PR evidence are rejected"

echo ""
echo "Test 7a: issue closure provenance is mandatory and independently trusted"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture closure-provenance)
assert_dry_run_rejected "$repo" "$bin" "$run_id" "lacks canonical closure provenance" \
  GH_ISSUE_MODE=no-closure
assert_dry_run_rejected "$repo" "$bin" "$run_id" "lacks canonical closure provenance" \
  GH_ISSUE_MODE=untrusted-closure
assert_dry_run_rejected "$repo" "$bin" "$run_id" "lacks canonical closure provenance" \
  GH_ISSUE_MODE=stale-closure
closing_ref_proof=$(
  GH_ISSUE_MODE=closed-by-pr \
  GH_PR_MODE=closing-ref \
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run
) || fail "GitHub closing-reference provenance should be accepted"
printf '%s\n' "$closing_ref_proof" \
  | jq -e '
      .issue.closure.kind == "github-closing-reference"
      and .pull_request.issue_link == "github-closing-reference"
    ' >/dev/null \
  || fail "closing-reference proof should preserve exact provenance"
echo "PASS: missing, untrusted, and stale closure evidence fail closed"

echo ""
echo "Test 8: unaccounted remote descendants fail closed"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture descendant-ambiguity)
git -C "$repo" checkout -q "$branch"
printf 'unaccounted branch movement\n' >>"$repo/README.md"
git -C "$repo" commit -qam "unaccounted branch movement"
git -C "$repo" push -q origin "$branch"
git -C "$repo" checkout -q main
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "does not equal current remote integration tip"
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
  "another open delivery PR" GH_OPEN_PRS_MODE=body-conflict
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "another open delivery PR" GH_OPEN_PRS_MODE=head-conflict
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "another open delivery PR" GH_OPEN_PRS_MODE=page-two-conflict
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "integration branch has a live pull request" GH_OPEN_PRS_MODE=branch-pr
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
jq '.prd.remote = "evil"' "$repo/.ralph/config.json" \
  >"$repo/.ralph/config.tmp"
mv "$repo/.ralph/config.tmp" "$repo/.ralph/config.json"
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
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "conflicting open pull request lookup failed" GH_OPEN_PRS_MODE=fail
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "returned malformed evidence" GH_OPEN_PRS_MODE=malformed
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "returned malformed evidence" GH_OPEN_PRS_MODE=malformed-page
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

echo ""
echo "Test 22: config and run metadata must bind to this repository and ownership"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture config-repo)
jq '.repo = "attacker/mirror"' "$repo/.ralph/config.json" \
  >"$repo/.ralph/config.tmp"
mv "$repo/.ralph/config.tmp" "$repo/.ralph/config.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "does not match canonical Ralph config"

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture config-remote)
jq '.prd.remote = "upstream"' "$repo/.ralph/config.json" \
  >"$repo/.ralph/config.tmp"
mv "$repo/.ralph/config.tmp" "$repo/.ralph/config.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "does not match configured PRD remote"

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture metadata-root)
mkdir -p "$TEST_ROOT/metadata-root/other"
jq --arg root "$TEST_ROOT/metadata-root/other" '.repoRoot = $root' \
  "$repo/.ralph/runs/$run_id/metadata.json" \
  >"$repo/.ralph/runs/$run_id/metadata.tmp"
mv "$repo/.ralph/runs/$run_id/metadata.tmp" \
  "$repo/.ralph/runs/$run_id/metadata.json"
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "does not belong to this repository"
echo "PASS: configuration and run metadata are canonical ownership evidence"

echo ""
echo "Test 23: native Windows metadata resolves to the same repository"
if command -v cygpath >/dev/null 2>&1; then
  IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture windows-metadata)
  native_root=$(cygpath -w "$repo")
  jq --arg root "$native_root" '.repoRoot = $root' \
    "$repo/.ralph/runs/$run_id/metadata.json" \
    >"$repo/.ralph/runs/$run_id/metadata.tmp"
  mv "$repo/.ralph/runs/$run_id/metadata.tmp" \
    "$repo/.ralph/runs/$run_id/metadata.json"
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run >/dev/null \
    || fail "native Windows metadata path should normalize to the active repository"
  echo "PASS: native Windows metadata path is canonicalized"
else
  echo "SKIP: native Windows metadata path requires cygpath"
fi
