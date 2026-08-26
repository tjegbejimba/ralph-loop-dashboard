#!/usr/bin/env bash
# Integration coverage for guarded recovery of missing PRD slice evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
LIVE_PID=""
trap '[[ -n "$LIVE_PID" ]] && kill "$LIVE_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

RUN_ID="20260825-184631-43b25623"
ISSUE="507"
PR="533"
PRD="505"
BRANCH="ralph/prd/prd-parent-tasks-hierarchy-and-leaf-first-execution-505"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

create_fixture() {
  local name="$1"
  local root="$TEST_ROOT/$name"
  local repo="$root/repo"
  local origin="$root/origin.git"
  local bin="$root/bin"

  mkdir -p "$bin"
  git init -q --bare "$origin"
  git init -q "$repo"
  git -C "$repo" checkout -qb main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "base" >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "base"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  git -C "$repo" checkout -qb "$BRANCH"
  echo "slice" >>"$repo/README.md"
  git -C "$repo" commit -qam "integrate slice"
  git -C "$repo" push -q -u origin "$BRANCH"
  git -C "$repo" checkout -q main

  local base merge_sha
  base=$(git -C "$repo" rev-parse main)
  merge_sha=$(git -C "$repo" rev-parse "$BRANCH")

  mkdir -p "$repo/.ralph/lib" "$repo/.ralph/logs" "$repo/.ralph/runs/$RUN_ID"
  cp "$REPO_ROOT/ralph/launch.sh" "$repo/.ralph/launch.sh"
  cp "$REPO_ROOT/ralph/lib/state.sh" "$repo/.ralph/lib/state.sh"
  cp "$REPO_ROOT/ralph/lib/status.sh" "$repo/.ralph/lib/status.sh"
  cp "$REPO_ROOT/ralph/lib/prd-branch.sh" "$repo/.ralph/lib/prd-branch.sh"
  cp "$REPO_ROOT/ralph/lib/slice-integration.sh" "$repo/.ralph/lib/slice-integration.sh"
  chmod +x "$repo/.ralph/launch.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/.ralph/ralph.sh"
  chmod +x "$repo/.ralph/ralph.sh"

  jq -n --arg repo "octo/widget" \
    '{repo:$repo,prd:{remote:"origin",deliveryBranch:"main"}}' \
    >"$repo/.ralph/config.json"
  jq -n --arg run "$RUN_ID" --arg prd "$PRD" \
    '{claims:{},active_run_id:$run,active_prd:$prd}' >"$repo/.ralph/state.json"
  jq -n --argjson issue "$ISSUE" '[{number:$issue,title:"Leaf slice"}]' \
    >"$repo/.ralph/runs/$RUN_ID/queue.json"
  jq -n --arg root "$(cd "$repo" && pwd -P)" \
    '{repoRoot:$root,runMode:"until-empty",model:"test",parallelism:1,createdAt:"2026-08-25T18:46:31Z"}' \
    >"$repo/.ralph/runs/$RUN_ID/metadata.json"
  jq -n --arg issue "$ISSUE" \
    '{items:{($issue):{status:"merged",workerId:null,pid:null,logFile:null,startedAt:null,error:null}}}' \
    >"$repo/.ralph/runs/$RUN_ID/status.json"
  jq -n \
    --arg run "$RUN_ID" \
    --arg prd "$PRD" \
    --arg branch "$BRANCH" \
    --arg base "$base" \
    '{
      run_id:$run,
      prd_number:$prd,
      branch_name:$branch,
      remote:"origin",
      delivery_branch:"main",
      initial_base_sha:$base,
      owned_tip_sha:$base,
      created_at:"2026-08-25T18:46:31Z"
    }' >"$repo/.ralph/runs/$RUN_ID/ownership.json"

  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "issue view" ]]; then
  jq -n \
    --argjson issue "$3" \
    --arg state "$TEST_ISSUE_STATE" \
    --arg closed_at "$TEST_ISSUE_CLOSED_AT" \
    --argjson comments "$TEST_ISSUE_COMMENTS_JSON" \
    '{
      number:$issue,
      state:$state,
      closedAt:(if $closed_at == "" then null else $closed_at end),
      closedByPullRequestsReferences:[],
      comments:$comments
    }'
elif [[ "$1 $2" == "pr view" ]]; then
  jq -n \
    --argjson pr "$3" \
    --arg issue "$TEST_ISSUE" \
    --arg branch "$TEST_PR_BASE" \
    --arg sha "$TEST_MERGE_SHA" \
    --arg head_ref "$TEST_PR_HEAD_REF" \
    --arg head_oid "$TEST_PR_HEAD_OID" \
    --arg head_repo "$TEST_PR_HEAD_REPO" \
    --arg state "$TEST_PR_STATE" \
    --arg merged_at "$TEST_PR_MERGED_AT" \
    --arg body "$TEST_PR_BODY" \
    --argjson closing_refs "$TEST_PR_CLOSING_REFS_JSON" \
    '{
      number:$pr,
      state:$state,
      mergedAt:(if $merged_at == "" then null else $merged_at end),
      baseRefName:$branch,
      headRefName:$head_ref,
      headRefOid:$head_oid,
      headRepository:{nameWithOwner:$head_repo},
      mergeCommit:{oid:$sha},
      closingIssuesReferences:$closing_refs,
      body:$body
    }'
elif [[ "$1 $2" == "pr list" ]]; then
  if [[ " $* " == *" --head "* ]]; then
    if [[ "$TEST_BRANCH_PR_ONLY_IN_ALL" == "1" && " $* " != *" --state all "* ]]; then
      printf '[]\n'
    else
      printf '%s\n' "$TEST_BRANCH_PRS_JSON"
    fi
  elif [[ "$TEST_OPEN_PR_ONLY_IN_API" == "1" ]]; then
    printf '[]\n'
  else
    printf '%s\n' "$TEST_OPEN_PRS_JSON"
  fi
elif [[ "$1" == "api" && " $* " == *" --paginate "* ]]; then
  printf '[%s]\n' "$TEST_OPEN_PRS_JSON"
else
  echo "unhandled gh invocation: $*" >&2
  exit 1
fi
EOF
  chmod +x "$bin/gh"

  printf '%s|%s|%s\n' "$repo" "$bin" "$merge_sha"
}

run_reconcile() {
  local repo="$1" bin="$2" merge_sha="$3"
  local issue_comments
  issue_comments=$(jq -cn \
    --arg body "Integrated via PR #533 into PRD integration branch. (Ralph explicit closure for non-default-base PR.)" \
    '[{
      body:$body,
      authorAssociation:"OWNER",
      createdAt:"2026-08-25T18:58:00Z"
    }]')
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="octo/widget" \
  RALPH_GH_BIN="$bin/gh" \
  TEST_ISSUE="$ISSUE" \
  TEST_BRANCH="$BRANCH" \
  TEST_MERGE_SHA="$merge_sha" \
  TEST_ISSUE_STATE="${TEST_ISSUE_STATE:-CLOSED}" \
  TEST_ISSUE_CLOSED_AT="${TEST_ISSUE_CLOSED_AT:-2026-08-25T18:58:00Z}" \
  TEST_ISSUE_COMMENTS_JSON="${TEST_ISSUE_COMMENTS_JSON:-$issue_comments}" \
  TEST_PR_STATE="${TEST_PR_STATE:-MERGED}" \
  TEST_PR_MERGED_AT="${TEST_PR_MERGED_AT:-2026-08-25T18:57:00Z}" \
  TEST_PR_BASE="${TEST_PR_BASE:-$BRANCH}" \
  TEST_PR_HEAD_REF="${TEST_PR_HEAD_REF:-slice-507-test}" \
  TEST_PR_HEAD_OID="${TEST_PR_HEAD_OID:-$merge_sha}" \
  TEST_PR_HEAD_REPO="${TEST_PR_HEAD_REPO:-octo/widget}" \
  TEST_PR_BODY="${TEST_PR_BODY:-Closes #507}" \
  TEST_PR_CLOSING_REFS_JSON="${TEST_PR_CLOSING_REFS_JSON:-[]}" \
  TEST_BRANCH_PRS_JSON="${TEST_BRANCH_PRS_JSON:-[]}" \
  TEST_BRANCH_PR_ONLY_IN_ALL="${TEST_BRANCH_PR_ONLY_IN_ALL:-0}" \
  TEST_OPEN_PRS_JSON="${TEST_OPEN_PRS_JSON:-[]}" \
  TEST_OPEN_PR_ONLY_IN_API="${TEST_OPEN_PR_ONLY_IN_API:-0}" \
    "$repo/.ralph/launch.sh" \
      --reconcile-slice-integration \
      --run-id "$RUN_ID" \
      --issue "$ISSUE" \
      --pr "$PR" \
      --prd "$PRD" \
      --branch "$BRANCH"
}

echo "Test 1: command records canonical slice-integration evidence"
IFS='|' read -r repo bin merge_sha < <(create_fixture happy)
output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1) || {
  echo "$output"
  fail "guarded reconciliation should succeed"
}
jq -e \
  --arg issue "$ISSUE" \
  --arg pr "$PR" \
  --arg commit "$merge_sha" \
  '.items[$issue] == {
    status:"slice-integrated",
    pr_number:$pr,
    integrated_commit:$commit,
    integrated_at:.items[$issue].integrated_at,
    workerId:null,
    pid:null,
    logFile:null,
    startedAt:null,
    error:null
  }
  and (.items[$issue].integrated_at
    | type == "string" and test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}T"))' \
  "$repo/.ralph/runs/$RUN_ID/status.json" >/dev/null \
  || fail "status should contain only canonical slice-integrated provenance"
grep -Fq "Reconciled issue #$ISSUE" <<<"$output" \
  || fail "command should report the reconciled issue"
echo "PASS: command records canonical slice-integration evidence"

echo "Test 2: command rejects a PR SHA that is not the remote integration tip"
IFS='|' read -r repo bin merge_sha < <(create_fixture sha-mismatch)
wrong_sha=$(git -C "$repo" rev-parse main)
if output=$(run_reconcile "$repo" "$bin" "$wrong_sha" 2>&1); then
  echo "$output"
  fail "mismatched merge SHA should fail"
fi
grep -Fq "does not equal remote tip" <<<"$output" \
  || fail "mismatched SHA should identify the remote-tip proof"
jq -e --arg issue "$ISSUE" '.items[$issue].status == "merged"' \
  "$repo/.ralph/runs/$RUN_ID/status.json" >/dev/null \
  || fail "mismatched SHA must not mutate terminal evidence"
echo "PASS: command rejects a mismatched PR SHA"

echo "Test 3: command rejects an open issue"
IFS='|' read -r repo bin merge_sha < <(create_fixture open-issue)
if output=$(TEST_ISSUE_STATE=OPEN run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "open issue should fail"
fi
grep -Fq "Issue #$ISSUE is not CLOSED" <<<"$output" \
  || fail "open issue should identify the closure proof"
jq -e --arg issue "$ISSUE" '.items[$issue].status == "merged"' \
  "$repo/.ralph/runs/$RUN_ID/status.json" >/dev/null \
  || fail "open issue must not mutate terminal evidence"
echo "PASS: command rejects an open issue"

echo "Test 4: command rejects an unmerged or wrong-base PR"
IFS='|' read -r repo bin merge_sha < <(create_fixture unmerged-pr)
if output=$(TEST_PR_STATE=OPEN TEST_PR_MERGED_AT="" \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "unmerged PR should fail"
fi
grep -Fq "not a merged, issue-linked delivery" <<<"$output" \
  || fail "unmerged PR should identify the delivery proof"

IFS='|' read -r repo bin merge_sha < <(create_fixture wrong-base-pr)
if output=$(TEST_PR_BASE=main run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "wrong-base PR should fail"
fi
grep -Fq "not a merged, issue-linked delivery" <<<"$output" \
  || fail "wrong-base PR should identify the delivery proof"
echo "PASS: command rejects unmerged and wrong-base PRs"

echo "Test 5: command rejects live workers, claims, and conflicting ownership"
IFS='|' read -r repo bin merge_sha < <(create_fixture live-worker)
cat >"$TEST_ROOT/live-worker.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$TEST_ROOT/live-worker.sh"
"$TEST_ROOT/live-worker.sh" &
LIVE_PID=$!
jq --arg issue "$ISSUE" --argjson pid "$LIVE_PID" \
  '.items[$issue].pid = $pid' \
  "$repo/.ralph/runs/$RUN_ID/status.json" >"$repo/.ralph/runs/$RUN_ID/status.tmp"
mv "$repo/.ralph/runs/$RUN_ID/status.tmp" "$repo/.ralph/runs/$RUN_ID/status.json"
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "live worker should fail"
fi
grep -Fq "still has a live worker" <<<"$output" \
  || fail "live worker should identify the occupancy proof"
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
LIVE_PID=""

IFS='|' read -r repo bin merge_sha < <(create_fixture live-claim)
jq --arg issue "$ISSUE" \
  '.claims[$issue] = {workerId:1,pid:999999,startedAt:"2026-08-25T18:46:31Z"}' \
  "$repo/.ralph/state.json" >"$repo/.ralph/state.tmp"
mv "$repo/.ralph/state.tmp" "$repo/.ralph/state.json"
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "recorded claim should fail closed"
fi
grep -Fq "claim or conflicting active-run ownership" <<<"$output" \
  || fail "claim should identify the ownership proof"

IFS='|' read -r repo bin merge_sha < <(create_fixture conflicting-ownership)
other_run="$RUN_ID-other"
mkdir -p "$repo/.ralph/runs/$other_run"
jq \
  --arg run "$other_run" \
  --arg branch "$BRANCH-other" \
  '.run_id = $run | .branch_name = $branch' \
  "$repo/.ralph/runs/$RUN_ID/ownership.json" \
  >"$repo/.ralph/runs/$other_run/ownership.json"
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "conflicting active ownership should fail"
fi
grep -Fq "Conflicting active PRD ownership" <<<"$output" \
  || fail "conflicting ownership should identify its evidence"
echo "PASS: command rejects live and conflicting local ownership"

echo "Test 6: command rejects pending ownership transfer and live PR conflicts"
IFS='|' read -r repo bin merge_sha < <(create_fixture pending-transfer)
jq \
  --arg run "successor-run" \
  --arg tip "$merge_sha" \
  '.transfer_pending = {
    new_run_id:$run,
    expected_remote_tip:$tip,
    reason:"terminal PRD ownership transferred",
    recorded_at:"2026-08-25T19:00:00Z"
  }' \
  "$repo/.ralph/runs/$RUN_ID/ownership.json" \
  >"$repo/.ralph/runs/$RUN_ID/ownership.tmp"
mv "$repo/.ralph/runs/$RUN_ID/ownership.tmp" \
  "$repo/.ralph/runs/$RUN_ID/ownership.json"
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "pending ownership transfer should fail"
fi
grep -Fq "does not own PRD" <<<"$output" \
  || fail "pending transfer should invalidate ownership proof"

IFS='|' read -r repo bin merge_sha < <(create_fixture branch-pr)
if output=$(TEST_BRANCH_PRS_JSON='[{"number":600}]' TEST_BRANCH_PR_ONLY_IN_ALL=1 \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "open integration-branch PR should fail"
fi
grep -Fq "has a branch PR" <<<"$output" \
  || fail "branch PR should identify its conflict"

IFS='|' read -r repo bin merge_sha < <(create_fixture issue-pr)
conflicting_pr='[{"number":601,"base":{"ref":"main"},"head":{"ref":"slice-507-other"},"body":"Closes #507"}]'
if output=$(TEST_OPEN_PRS_JSON="$conflicting_pr" \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "other live issue PR should fail"
fi
grep -Fq "another open delivery PR" <<<"$output" \
  || fail "other live PR should identify its conflict"
echo "PASS: command rejects transfers and live PR conflicts"

echo "Test 7: replay is idempotent and preserves original provenance timestamp"
IFS='|' read -r repo bin merge_sha < <(create_fixture replay)
run_reconcile "$repo" "$bin" "$merge_sha" >/dev/null \
  || fail "first reconciliation should succeed"
before=$(jq -cS . "$repo/.ralph/runs/$RUN_ID/status.json")
sleep 1
output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1) || {
  echo "$output"
  fail "idempotent replay should succeed"
}
after=$(jq -cS . "$repo/.ralph/runs/$RUN_ID/status.json")
[[ "$after" == "$before" ]] \
  || fail "idempotent replay must preserve the original evidence byte-for-byte"
grep -Fq "already has canonical slice-integrated evidence" <<<"$output" \
  || fail "idempotent replay should report a no-op"
echo "PASS: replay is idempotent"

echo "Test 8: replay rejects non-canonical existing evidence instead of normalizing it"
IFS='|' read -r repo bin merge_sha < <(create_fixture conflicting-replay)
run_reconcile "$repo" "$bin" "$merge_sha" >/dev/null \
  || fail "first reconciliation should succeed"
jq --arg issue "$ISSUE" '.items[$issue].workerId = 7' \
  "$repo/.ralph/runs/$RUN_ID/status.json" >"$repo/.ralph/runs/$RUN_ID/status.tmp"
mv "$repo/.ralph/runs/$RUN_ID/status.tmp" "$repo/.ralph/runs/$RUN_ID/status.json"
before=$(jq -cS . "$repo/.ralph/runs/$RUN_ID/status.json")
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "non-canonical existing evidence should fail closed"
fi
after=$(jq -cS . "$repo/.ralph/runs/$RUN_ID/status.json")
[[ "$after" == "$before" ]] \
  || fail "conflicting replay must not normalize or replace evidence"
grep -Fq "Existing slice-integrated evidence conflicts" <<<"$output" \
  || fail "conflicting replay should identify provenance conflict"
echo "PASS: replay rejects non-canonical existing evidence"

echo "Test 9: ownership remote must match the configured PRD remote"
IFS='|' read -r repo bin merge_sha < <(create_fixture wrong-remote)
origin_url=$(git -C "$repo" remote get-url origin)
git -C "$repo" remote add mirror "$origin_url"
jq '.remote = "mirror"' \
  "$repo/.ralph/runs/$RUN_ID/ownership.json" >"$repo/.ralph/runs/$RUN_ID/ownership.tmp"
mv "$repo/.ralph/runs/$RUN_ID/ownership.tmp" \
  "$repo/.ralph/runs/$RUN_ID/ownership.json"
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "ownership on a different remote should fail"
fi
grep -Fq "does not match configured PRD remote" <<<"$output" \
  || fail "remote mismatch should identify its ownership proof"
jq -e --arg issue "$ISSUE" '.items[$issue].status == "merged"' \
  "$repo/.ralph/runs/$RUN_ID/status.json" >/dev/null \
  || fail "remote mismatch must not mutate terminal evidence"
echo "PASS: ownership remote must match Ralph configuration"

echo "Test 10: native Windows run metadata resolves to the same repository"
if command -v cygpath >/dev/null 2>&1; then
  IFS='|' read -r repo bin merge_sha < <(create_fixture windows-metadata)
  native_root=$(cygpath -w "$repo")
  jq --arg root "$native_root" '.repoRoot = $root' \
    "$repo/.ralph/runs/$RUN_ID/metadata.json" >"$repo/.ralph/runs/$RUN_ID/metadata.tmp"
  mv "$repo/.ralph/runs/$RUN_ID/metadata.tmp" \
    "$repo/.ralph/runs/$RUN_ID/metadata.json"
  output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1) || {
    echo "$output"
    fail "native Windows metadata path should normalize to the active repo"
  }
  grep -Fq "Reconciled issue #$ISSUE" <<<"$output" \
    || fail "Windows metadata reconciliation should report success"
  echo "PASS: native Windows metadata path is canonicalized"
else
  echo "SKIP: native Windows metadata path requires cygpath"
fi

echo "Test 11: unsafe configured remote names are rejected before git invocation"
IFS='|' read -r repo bin merge_sha < <(create_fixture unsafe-remote)
jq '.prd.remote = "--upload-pack=false"' \
  "$repo/.ralph/config.json" >"$repo/.ralph/config.tmp"
mv "$repo/.ralph/config.tmp" "$repo/.ralph/config.json"
jq '.remote = "--upload-pack=false"' \
  "$repo/.ralph/runs/$RUN_ID/ownership.json" >"$repo/.ralph/runs/$RUN_ID/ownership.tmp"
mv "$repo/.ralph/runs/$RUN_ID/ownership.tmp" \
  "$repo/.ralph/runs/$RUN_ID/ownership.json"
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "option-like configured remote should fail"
fi
grep -Fq "Invalid configured PRD remote" <<<"$output" \
  || fail "unsafe remote should be rejected as an identifier"
echo "PASS: unsafe configured remote is rejected"

echo "Test 12: remote tip must descend from the run's owned history"
IFS='|' read -r repo bin merge_sha < <(create_fixture unrelated-history)
unrelated=$(printf 'unrelated ownership\n' | \
  git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'main^{tree}')")
jq --arg unrelated "$unrelated" \
  '.initial_base_sha = $unrelated | .owned_tip_sha = $unrelated' \
  "$repo/.ralph/runs/$RUN_ID/ownership.json" >"$repo/.ralph/runs/$RUN_ID/ownership.tmp"
mv "$repo/.ralph/runs/$RUN_ID/ownership.tmp" \
  "$repo/.ralph/runs/$RUN_ID/ownership.json"
if output=$(run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "unrelated owned history should fail"
fi
grep -Fq "does not descend from run-owned history" <<<"$output" \
  || fail "unrelated ownership should identify the ancestry proof"
echo "PASS: unrelated owned history is rejected"

echo "Test 13: body-only linking requires the canonical issue closure comment"
IFS='|' read -r repo bin merge_sha < <(create_fixture missing-closure-comment)
if output=$(TEST_ISSUE_COMMENTS_JSON='[]' \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "mutable PR body alone should not prove delivery"
fi
grep -Fq "lacks canonical closure provenance" <<<"$output" \
  || fail "missing closure comment should identify the provenance gap"

IFS='|' read -r repo bin merge_sha < <(create_fixture closing-ref-without-closure)
if output=$(TEST_PR_CLOSING_REFS_JSON='[{"number":507}]' \
  TEST_ISSUE_COMMENTS_JSON='[]' \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "PR closing refs without issue closure provenance should fail"
fi
grep -Fq "lacks canonical closure provenance" <<<"$output" \
  || fail "closing refs should not bypass issue closure provenance"
echo "PASS: body-only linking requires closure provenance"

echo "Test 14: body-only closure provenance requires a trusted author"
IFS='|' read -r repo bin merge_sha < <(create_fixture untrusted-closure-comment)
untrusted_comments=$(jq -cn \
  --arg body "Integrated via PR #533 into PRD integration branch. (Ralph explicit closure for non-default-base PR.)" \
  '[{
    body:$body,
    authorAssociation:"CONTRIBUTOR",
    createdAt:"2026-08-25T18:58:00Z"
  }]')
if output=$(TEST_ISSUE_COMMENTS_JSON="$untrusted_comments" \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "an untrusted canonical-looking comment should fail"
fi
grep -Fq "lacks canonical closure provenance" <<<"$output" \
  || fail "untrusted closure comment should not establish provenance"
echo "PASS: body-only closure provenance requires a trusted author"

echo "Test 15: body-only closure provenance must follow the merged PR"
IFS='|' read -r repo bin merge_sha < <(create_fixture stale-closure-comment)
stale_comments=$(jq -cn \
  --arg body "Integrated via PR #533 into PRD integration branch. (Ralph explicit closure for non-default-base PR.)" \
  '[{
    body:$body,
    authorAssociation:"OWNER",
    createdAt:"2026-08-25T18:00:00Z"
  }]')
if output=$(TEST_ISSUE_COMMENTS_JSON="$stale_comments" \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "a pre-merge canonical-looking comment should fail"
fi
grep -Fq "lacks canonical closure provenance" <<<"$output" \
  || fail "stale closure comment should not establish provenance"
echo "PASS: body-only closure provenance follows the merged PR"

echo "Test 16: PR head provenance must belong to this repo and issue"
IFS='|' read -r repo bin merge_sha < <(create_fixture wrong-head-repo)
if output=$(TEST_PR_HEAD_REPO=attacker/widget \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "fork head should fail"
fi
grep -Fq "not a merged, issue-linked delivery" <<<"$output" \
  || fail "wrong head repo should invalidate PR provenance"

IFS='|' read -r repo bin merge_sha < <(create_fixture wrong-head-issue)
if output=$(TEST_PR_HEAD_REF=slice-999-test \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "head ref for a different issue should fail"
fi
grep -Fq "not a merged, issue-linked delivery" <<<"$output" \
  || fail "wrong head issue should invalidate PR provenance"

IFS='|' read -r repo bin merge_sha < <(create_fixture ambiguous-head-issue)
if output=$(TEST_PR_HEAD_REF=slice-999-507-test \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "head ref merely containing the issue number should fail"
fi
grep -Fq "not a merged, issue-linked delivery" <<<"$output" \
  || fail "head ref should start with the canonical issue prefix"

IFS='|' read -r repo bin merge_sha < <(create_fixture canonical-repo-case)
if ! output=$(TEST_PR_HEAD_REPO=OCTO/Widget \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "canonical GitHub repository casing should be accepted"
fi

IFS='|' read -r repo bin merge_sha < <(create_fixture configured-head-prefix)
if ! output=$(RALPH_BRANCH_PREFIX=mu- TEST_PR_HEAD_REF=mu-507-test \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "RALPH_BRANCH_PREFIX should define canonical head provenance"
fi
echo "PASS: PR head provenance is bound to repo and issue"

echo "Test 17: conflicting open PR proof uses exhaustive pagination"
IFS='|' read -r repo bin merge_sha < <(create_fixture paginated-conflict)
conflicting_pr='[{"number":602,"base":{"ref":"main"},"head":{"ref":"slice-507-late"},"body":"Closes #507"}]'
if output=$(TEST_OPEN_PRS_JSON="$conflicting_pr" TEST_OPEN_PR_ONLY_IN_API=1 \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "paginated conflicting PR should fail"
fi
grep -Fq "another open delivery PR" <<<"$output" \
  || fail "paginated conflict should be detected"
echo "PASS: open PR conflict proof is exhaustive"

echo "Test 18: malformed paginated PR evidence fails closed"
IFS='|' read -r repo bin merge_sha < <(create_fixture malformed-open-pr)
if output=$(TEST_OPEN_PRS_JSON='[{}]' \
  run_reconcile "$repo" "$bin" "$merge_sha" 2>&1); then
  echo "$output"
  fail "malformed open PR evidence should fail"
fi
grep -Fq "Could not validate conflicting open pull requests" <<<"$output" \
  || fail "malformed open PR evidence should identify validation failure"
echo "PASS: malformed open PR evidence fails closed"
