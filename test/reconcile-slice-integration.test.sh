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
    merged) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/507"}],"url":"https://github.com/test/example/pull/533"}\n' ;;
    nondefault-body) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    nondefault-large-body)
      padding=\$(printf '%20000s' '')
      padding=\${padding// /a}
      printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Intro %s\\\\n\\\\nCloses #507","url":"https://github.com/test/example/pull/533"}\n' "\$padding"
      ;;
    nondefault-body-modified) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Intro\\\\n\\\\nCloses #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    nondefault-trailing-body) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507\\\\n\\\\n","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-example) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Example: Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-quote) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"> Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-code) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"    Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-list) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"- Example:\\\\n  Closes #507","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-long-fence) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"\`\`\`\`text\\\\n\`\`\`\\\\nCloses #507\\\\n\`\`\`\`","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-fence-info) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"\`\`\`text\\\\n\`\`\`not-a-close\\\\nCloses #507\\\\n\`\`\`","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-html) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"<pre>\\\\nCloses #507\\\\n</pre>","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-html-blank) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"<pre>\\\\n\\\\nCloses #507\\\\n\\\\n</pre>","url":"https://github.com/test/example/pull/533"}\n' ;;
    spoof-html-comment-adjacent) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"<!--x--><pre>\\\\n\\\\nCloses #507\\\\n\\\\n</pre><!--y-->","url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-body-issue) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #508","url":"https://github.com/test/example/pull/533"}\n' ;;
    ambiguous-body) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507\\\\nCloses #508","url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-base) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"main","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/507"}],"url":"https://github.com/test/example/pull/533"}\n' ;;
    wrong-link) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":999,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/999"}],"url":"https://github.com/test/example/pull/533"}\n' ;;
    cross-repo-link) printf '{"number":533,"state":"MERGED","mergedAt":"2026-08-25T20:00:00Z","baseRefName":"$branch","headRefName":"slice-507","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507,"repository":{"name":"mirror","owner":{"login":"attacker"}},"url":"https://github.com/attacker/mirror/issues/507"}],"url":"https://github.com/test/example/pull/533"}\n' ;;
    open) printf '{"number":533,"state":"OPEN","mergedAt":null,"baseRefName":"$branch","headRefName":"slice-507","mergeCommit":null,"url":"https://github.com/test/example/pull/533"}\n' ;;
    malformed) printf '{not-json\n' ;;
    fail) echo "simulated PR API failure" >&2; exit 1 ;;
  esac
  exit 0
fi
if [[ "\$1 \$2 \$3" == "pr view 534" && -n "\${GH_DESCENDANT_COMMIT:-}" ]]; then
  printf '{"number":534,"state":"MERGED","mergedAt":"2026-08-25T21:00:00Z","baseRefName":"$branch","headRefName":"slice-508","mergeCommit":{"oid":"%s"},"closingIssuesReferences":[{"number":508,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/508"}],"url":"https://github.com/test/example/pull/534"}\n' "\$GH_DESCENDANT_COMMIT"
  exit 0
fi
if [[ "\$1 \$2" == "pr list" ]]; then
  case "\${GH_LIST_MODE:-exact}" in
    exact)
      if [[ "\${GH_PR_MODE:-merged}" == "nondefault-body" ]]; then
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507"}]\n'
      elif [[ "\${GH_PR_MODE:-merged}" == "nondefault-large-body" ]]; then
        padding=\$(printf '%20000s' '')
        padding=\${padding// /a}
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Intro %s\\\\n\\\\nCloses #507"}]\n' "\$padding"
      elif [[ "\${GH_PR_MODE:-merged}" == "nondefault-body-modified" ]]; then
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Intro\\\\n\\\\nCloses #507"}]\n'
      elif [[ "\${GH_PR_MODE:-merged}" == "nondefault-trailing-body" ]]; then
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507\\\\n\\\\n"}]\n'
      elif [[ -n "\${GH_DESCENDANT_COMMIT:-}" ]]; then
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/507"}]},{"number":534,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"%s"},"closingIssuesReferences":[{"number":508,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/508"}]}]\n' "\$GH_DESCENDANT_COMMIT"
      else
        printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/507"}]}]\n'
      fi
      ;;
    conflict) printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[{"number":507,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/507"}]},{"number":534,"state":"OPEN","baseRefName":"$branch","mergeCommit":null,"closingIssuesReferences":[{"number":507,"repository":{"name":"example","owner":{"login":"test"}},"url":"https://github.com/test/example/issues/507"}]}]\n' ;;
    fallback-conflict) printf '[{"number":533,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507"},{"number":534,"state":"MERGED","baseRefName":"$branch","mergeCommit":{"oid":"$merge_commit"},"closingIssuesReferences":[],"body":"Closes #507"}]\n' ;;
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
if [[ "\$1" == "api" && "\$2" == "repos/test/example/issues/507" ]]; then
  case "\${GH_ISSUE_MODE:-closed}" in
    closed) printf '{"number":507,"state":"closed","state_reason":"completed","closed_at":"2026-08-25T20:00:00Z","closed_by":{"login":"ralph-owner"},"html_url":"https://github.com/test/example/issues/507","repository_url":"https://api.github.com/repos/test/example"}\n' ;;
    open) printf '{"number":507,"state":"open","state_reason":null,"closed_at":null,"closed_by":null,"html_url":"https://github.com/test/example/issues/507","repository_url":"https://api.github.com/repos/test/example"}\n' ;;
    malformed) printf '{not-json\n' ;;
    fail) echo "simulated issue API failure" >&2; exit 1 ;;
  esac
  exit 0
fi
if [[ "\$1" == "api" && "\$2" == "repos/test/example/issues/507/comments?per_page=100" ]]; then
  case "\${GH_COMMENT_MODE:-valid}" in
    valid) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"OWNER"}]]\n' "$branch" ;;
    missing) printf '[[]]\n' ;;
    edited) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:01:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"OWNER"}]]\n' "$branch" ;;
    valid-plus-edited) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"OWNER"},{"id":7002,"html_url":"https://github.com/test/example/issues/507#issuecomment-7002","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:01:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"OWNER"}]]\n' "$branch" "$branch" ;;
    valid-plus-conflict) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"OWNER"},{"id":7002,"html_url":"https://github.com/test/example/issues/507#issuecomment-7002","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #999 into \`ralph/prd/other\`.","author_association":"OWNER"}]]\n' "$branch" ;;
    ambiguous) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"OWNER"},{"id":7002,"html_url":"https://github.com/test/example/issues/507#issuecomment-7002","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"OWNER"}]]\n' "$branch" "$branch" ;;
    wrong-pr) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #999 into \`%s\`.","author_association":"OWNER"}]]\n' "$branch" ;;
    wrong-branch) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"ralph-owner"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #533 into \`ralph/prd/other\`.","author_association":"OWNER"}]]\n' ;;
    actor-mismatch) printf '[[{"id":7001,"html_url":"https://github.com/test/example/issues/507#issuecomment-7001","user":{"login":"intruder"},"created_at":"2026-08-25T20:00:00Z","updated_at":"2026-08-25T20:00:00Z","body":"Merged via PR #533 into \`%s\`.","author_association":"NONE"}]]\n' "$branch" ;;
    malformed) printf '{"not":"pages"}\n' ;;
    fail) echo "simulated comment API failure" >&2; exit 1 ;;
  esac
  exit 0
fi
if [[ "\$1" == "api" && "\$2" == "repos/test/example/collaborators/ralph-owner/permission" ]]; then
  case "\${GH_PERMISSION_MODE:-allowed}" in
    allowed) printf '{"permission":"admin","role_name":"admin","user":{"login":"ralph-owner"}}\n' ;;
    denied) printf '{"permission":"read","role_name":"read","user":{"login":"ralph-owner"}}\n' ;;
    mismatch) printf '{"permission":"admin","role_name":"admin","user":{"login":"different-user"}}\n' ;;
    malformed) printf '{not-json\n' ;;
    fail) echo "simulated permission API failure" >&2; exit 1 ;;
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
  and .issue.closed_by == "tjegbejimba"
  and .issue.ralph_status == "merged"
  and .issue.integrated_commit == null
  and .pull_request.number == 533
  and .pull_request.state == "MERGED"
  and .pull_request.base
    == "ralph/prd/prd-parent-tasks-hierarchy-and-leaf-first-execution-505"
  and .pull_request.body_closing_directive == "Closes #507"
  and .pull_request.closing_issues_references == []
  and .pull_request.merge_commit
    == "f1d5213c3e07148afa508b044ea630406ad98422"
  and .remote_integration_tip == .pull_request.merge_commit
  and .integration_comment.id == 5418101322
  and .integration_comment.author == "tjegbejimba"
  and .integration_comment.author_association == "OWNER"
  and .integration_comment.created_at == .issue.closed_at
  and .integration_comment.updated_at == .integration_comment.created_at
  and .integration_comment.author_permission == "admin"
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
assert_dry_run_rejected "$repo" "$bin" "$run_id" "conflicting GitHub closing-reference" \
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

echo ""
echo "Test 22: non-default PRD linkage uses the complete #507 evidence bundle"
IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture nondefault-linkage)
nondefault_proof=$(
  GH_PR_MODE=nondefault-body \
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run
) || fail "complete non-default linkage bundle should succeed"
printf '%s\n' "$nondefault_proof" | jq -e \
  --arg branch "$branch" '
    .linkage.policy == "non-default-owned-branch-bundle"
    and .linkage.closing_directive == "Closes #507"
    and .linkage.closing_issues_references == []
    and .linkage.candidate_prs == [533]
    and (.linkage.candidate_pr_evidence | length) == 1
    and .linkage.candidate_pr_evidence[0].number == 533
    and (.linkage.pull_request_body_oid
      | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
    and .linkage.candidate_pr_evidence[0].body_oid
      == .linkage.pull_request_body_oid
    and .linkage.integration_comment.id == 7001
    and .linkage.integration_comment.author == "ralph-owner"
    and .linkage.integration_comment.author_association == "OWNER"
    and .linkage.integration_comment.created_at == .issue.closed_at
    and .linkage.integration_comment.updated_at
      == .linkage.integration_comment.created_at
    and .linkage.integration_comment.body
      == ("Merged via PR #533 into `" + $branch + "`.")
    and .linkage.actor_authorization.login == "ralph-owner"
    and .linkage.actor_authorization.permission == "admin"
  ' >/dev/null || fail "proof should bind the complete non-default linkage evidence"
echo "PASS: complete non-default linkage bundle proves the exact intended workflow"

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture large-body-linkage)
large_body_proof=$(
  GH_PR_MODE=nondefault-large-body \
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run
) || fail "large valid PR bodies should not exceed Windows command-line limits"
printf '%s\n' "$large_body_proof" | jq -e '
  .linkage.policy == "non-default-owned-branch-bundle"
  and (.linkage.pull_request_body_oid | length) >= 40
' >/dev/null || fail "large PR body should be content-addressed in the proof"
echo "PASS: large PR body evidence is bound without command-line duplication"

echo ""
echo "Test 23: incomplete, spoofed, conflicting, or changed linkage evidence fails closed"
for mode in spoof-example spoof-quote spoof-code spoof-list spoof-long-fence \
  spoof-fence-info spoof-html spoof-html-blank spoof-html-comment-adjacent \
  wrong-body-issue ambiguous-body; do
  IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture "reject-$mode")
  assert_dry_run_rejected "$repo" "$bin" "$run_id" \
    "unambiguous literal closing directive" GH_PR_MODE="$mode"
done

for mode in missing edited valid-plus-edited valid-plus-conflict ambiguous \
  wrong-pr wrong-branch actor-mismatch; do
  IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture "reject-comment-$mode")
  assert_dry_run_rejected "$repo" "$bin" "$run_id" \
    "integration closure comment is missing or ambiguous" \
    GH_PR_MODE=nondefault-body GH_COMMENT_MODE="$mode"
done

for mode in denied mismatch; do
  IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture "reject-permission-$mode")
  assert_dry_run_rejected "$repo" "$bin" "$run_id" \
    "not authorized" GH_PR_MODE=nondefault-body GH_PERMISSION_MODE="$mode"
done

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture reject-comment-api)
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "comment lookup failed" GH_PR_MODE=nondefault-body GH_COMMENT_MODE=fail
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "invalid evidence" GH_PR_MODE=nondefault-body GH_COMMENT_MODE=malformed
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "authorization lookup failed" GH_PR_MODE=nondefault-body GH_PERMISSION_MODE=fail
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "not authorized" GH_PR_MODE=nondefault-body GH_PERMISSION_MODE=malformed

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture reject-candidate-conflict)
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "missing or conflicting" GH_PR_MODE=nondefault-body GH_LIST_MODE=fallback-conflict

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture reject-cross-repo-link)
assert_dry_run_rejected "$repo" "$bin" "$run_id" \
  "conflicting GitHub closing-reference" GH_PR_MODE=cross-repo-link

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture default-linkage)
default_proof=$(
  GH_COMMENT_MODE=fail \
  GH_PERMISSION_MODE=fail \
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run
) || fail "GitHub closing references should remain sufficient when present"
printf '%s\n' "$default_proof" | jq -e '
  .linkage.policy == "github-closing-reference"
  and .linkage.integration_comment == null
  and .linkage.actor_authorization == null
  and (.linkage.candidate_pr_evidence | length) == 1
' >/dev/null || fail "default linkage proof should preserve the GitHub reference policy"

IFS='|' read -r repo bin run_id branch base merge_commit < <(create_fixture external-race)
external_proof="$TEST_ROOT/external-race/proof.json"
GH_PR_MODE=nondefault-body \
RALPH_MAIN_REPO="$repo" \
RALPH_REPO="test/example" \
RALPH_GH_BIN="$bin/gh" \
  "$REPO_ROOT/ralph/reconcile-slice.sh" \
    --run "$run_id" --prd 505 --issue 507 --pr 533 --dry-run >"$external_proof"
if race_output=$(
  GH_PR_MODE=nondefault-trailing-body \
  RALPH_MAIN_REPO="$repo" \
  RALPH_REPO="test/example" \
  RALPH_GH_BIN="$bin/gh" \
    "$REPO_ROOT/ralph/reconcile-slice.sh" \
      --run "$run_id" --prd 505 --issue 507 --pr 533 \
      --apply --proof "$external_proof" 2>&1
); then
  fail "trailing-newline PR body changes should block apply"
fi
grep -Fqi "live evidence changed" <<<"$race_output" \
  || fail "external evidence race should be rejected after lock-time revalidation"
echo "PASS: adversarial linkage evidence and concurrent changes are rejected"
