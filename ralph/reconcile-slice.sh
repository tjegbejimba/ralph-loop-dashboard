#!/usr/bin/env bash
# Guarded operator recovery for legacy slices integrated without canonical evidence.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .ralph/reconcile-slice.sh --run RUN --prd N --issue N --pr N --dry-run
  .ralph/reconcile-slice.sh --run RUN --prd N --issue N --pr N --apply --proof FILE
EOF
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
DEFAULT_MAIN="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MAIN_REPO="${RALPH_MAIN_REPO:-$DEFAULT_MAIN}"
MAIN_REPO="$(cd "$MAIN_REPO" && pwd -P)"
REPO="${RALPH_REPO:-$(git -C "$MAIN_REPO" config --get remote.origin.url 2>/dev/null \
  | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//' || true)}"
GH="${RALPH_GH_BIN:-gh}"
LOG_DIR="$MAIN_REPO/.ralph/logs"
RALPH_SCRIPT="$MAIN_REPO/.ralph/ralph.sh"
RUN_ID=""
PRD_NUMBER=""
ISSUE_NUMBER=""
PR_NUMBER=""
MODE=""
PROOF_FILE=""
RECONCILE_SETUP_LOCK=""
RECONCILE_COMMON_SETUP_LOCK=""
RECONCILE_STATE_LOCKED=0

cd "$MAIN_REPO"

error() {
  echo "ERROR: $*" >&2
  return 1
}

require_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || error "$1 must be a positive integer"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_ID="${2:-}"
      shift 2
      ;;
    --prd)
      PRD_NUMBER="${2:-}"
      shift 2
      ;;
    --issue)
      ISSUE_NUMBER="${2:-}"
      shift 2
      ;;
    --pr)
      PR_NUMBER="${2:-}"
      shift 2
      ;;
    --dry-run)
      [[ -z "$MODE" ]] || { error "choose exactly one of --dry-run or --apply"; exit 1; }
      MODE="dry-run"
      shift
      ;;
    --apply)
      [[ -z "$MODE" ]] || { error "choose exactly one of --dry-run or --apply"; exit 1; }
      MODE="apply"
      shift
      ;;
    --proof)
      PROOF_FILE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      error "unknown argument '$1'"
      usage >&2
      exit 1
      ;;
  esac
done

[[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || { error "--run must be a valid run identifier"; exit 1; }
require_positive_integer "--prd" "$PRD_NUMBER" || exit 1
require_positive_integer "--issue" "$ISSUE_NUMBER" || exit 1
require_positive_integer "--pr" "$PR_NUMBER" || exit 1
[[ -n "$MODE" ]] || { error "choose exactly one of --dry-run or --apply"; exit 1; }
[[ -n "$REPO" && "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || { error "could not resolve a valid GitHub repository"; exit 1; }
if [[ "$MODE" == "dry-run" && -n "$PROOF_FILE" ]]; then
  error "--proof is only valid with --apply"
  exit 1
fi
if [[ "$MODE" == "apply" && -z "$PROOF_FILE" ]]; then
  error "--apply requires a proof file produced by --dry-run"
  exit 1
fi

# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/status.sh
. "$SCRIPT_DIR/lib/status.sh"
# shellcheck source=lib/prd-branch.sh
. "$SCRIPT_DIR/lib/prd-branch.sh"

git_proof() {
  GIT_NO_REPLACE_OBJECTS=1 git -C "$MAIN_REPO" "$@"
}

reconcile_remote_repository() {
  local remote="$1"
  local urls url slug
  urls=$(git -C "$MAIN_REPO" config --get-all "remote.$remote.url") \
    || { error "ownership remote '$remote' is not configured"; return 1; }
  [[ "$(printf '%s\n' "$urls" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ]] \
    || { error "ownership remote '$remote' does not have exactly one URL"; return 1; }
  url=$(printf '%s\n' "$urls" | awk 'NF { print; exit }')
  case "$url" in
    https://github.com/*)
      slug="${url#https://github.com/}"
      ;;
    git@github.com:*)
      slug="${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      slug="${url#ssh://git@github.com/}"
      ;;
    *)
      error "ownership remote '$remote' is not a supported GitHub URL"
      return 1
      ;;
  esac
  slug="${slug%.git}"
  [[ "$slug" == "$REPO" ]] \
    || { error "ownership remote '$remote' does not match GitHub repository '$REPO'"; return 1; }
  printf '%s\n' "$url"
}

reconcile_assert_unmodified_graph() {
  local common_git_dir replacement_ref
  common_git_dir=$(git -C "$MAIN_REPO" rev-parse --git-common-dir 2>/dev/null) \
    || { error "could not resolve the repository common git directory"; return 1; }
  case "$common_git_dir" in
    /*|[A-Za-z]:/*) ;;
    *) common_git_dir="$MAIN_REPO/$common_git_dir" ;;
  esac
  common_git_dir=$(cd "$common_git_dir" 2>/dev/null && pwd -P) \
    || { error "could not canonicalize the repository common git directory"; return 1; }
  replacement_ref=$(git -C "$MAIN_REPO" for-each-ref \
    --format='%(refname)' refs/replace 2>/dev/null) \
    || { error "could not inspect replacement refs"; return 1; }
  [[ -z "$replacement_ref" ]] \
    || { error "replacement refs are not permitted during reconciliation"; return 1; }
  [[ ! -e "$common_git_dir/info/grafts" ]] \
    || { error "legacy grafts are not permitted during reconciliation"; return 1; }
}

reconcile_closing_directives() {
  LC_ALL=C awk '
    function prefix_length(value, character, count) {
      count = 0
      while (substr(value, count + 1, 1) == character) count++
      return count
    }
    function whitespace_only(value) {
      return value ~ /^[[:space:]]*$/
    }
    BEGIN {
      fenced = 0
      fence_character = ""
      fence_length = 0
      html_comment = 0
    }
    {
      sub(/\r$/, "")
      lines[++line_count] = $0
    }
    END {
      for (line_number = 1; line_number <= line_count; line_number++) {
        line = lines[line_number]
        remaining = line
        clean = ""
        saw_comment = 0
        while (1) {
          if (html_comment) {
            comment_end = index(remaining, "-->")
            saw_comment = 1
            if (comment_end == 0) {
              remaining = ""
              break
            }
            remaining = substr(remaining, comment_end + 3)
            html_comment = 0
          } else {
            comment_start = index(remaining, "<!--")
            if (comment_start == 0) {
              clean = clean remaining
              break
            }
            clean = clean substr(remaining, 1, comment_start - 1)
            remaining = substr(remaining, comment_start + 4)
            html_comment = 1
            saw_comment = 1
          }
        }
        if (saw_comment && clean !~ /^[[:space:]]*$/) exit 2
        if (saw_comment) continue
        line = clean
        if (index(line, "<") > 0) exit 2

        indent = 0
        while (indent < 4 && substr(line, indent + 1, 1) == " ") indent++
        content = substr(line, indent + 1)
        first = substr(content, 1, 1)
        run_length = (first == "`" || first == "~") \
          ? prefix_length(content, first) \
          : 0
        if (fenced) {
          if (indent <= 3 && first == fence_character && run_length >= fence_length && whitespace_only(substr(content, run_length + 1))) {
            fenced = 0
            fence_character = ""
            fence_length = 0
          }
          continue
        }
        if (indent <= 3 && (first == "`" || first == "~") && run_length >= 3) {
          fenced = 1
          fence_character = first
          fence_length = run_length
          continue
        }

        if (line ~ /^(\t| )/ || line ~ /^[>|*+-][[:space:]]/) continue

        if (line ~ /^(Close|Closes|Closed|Fix|Fixes|Fixed|Resolve|Resolves|Resolved)[[:space:]]+#[1-9][0-9]*[[:space:]]*$/) {
          previous_is_blank = line_number == 1 \
            || lines[line_number - 1] ~ /^[[:space:]]*$/
          next_is_blank = line_number == line_count \
            || lines[line_number + 1] ~ /^[[:space:]]*$/
          if (previous_is_blank && next_is_blank) {
            sub(/[[:space:]]+$/, "", line)
            print line
          }
        }
      }
    }
  '
}

reconcile_directive_issues_json() {
  sed -E 's/^.*#([1-9][0-9]*)[[:space:]]*$/\1/' \
    | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)'
}

reconcile_scoped_processes() {
  local ps_out pid_col=1 ppid_col=2 command_col=3
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      pid_col=2
      ppid_col=3
      command_col=6
      ps_out=$(ps -ef 2>/dev/null) || return 1
      ;;
    *)
      ps_out=$(ps -axww -o pid=,ppid=,command= 2>/dev/null) || return 1
      ;;
  esac
  printf '%s\n' "$ps_out" | LC_ALL=C awk \
    -v ralph="$MAIN_REPO/.ralph/ralph.sh" \
    -v launch="$MAIN_REPO/.ralph/launch.sh" \
    -v self="$$" \
    -v pid_col="$pid_col" \
    -v ppid_col="$ppid_col" \
    -v command_col="$command_col" '
      {
        pid=$pid_col
        ppid=$ppid_col
        if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/ || pid == self) next
        cmd=""
        for (i=command_col; i<=NF; i++) cmd = cmd (i==command_col ? "" : " ") $i
        if (index(cmd, ralph) > 0 || index(cmd, launch) > 0) print pid " " cmd
      }
    '
}

reconcile_assert_inactive() {
  local state_file="$STATE_FILE"
  [[ -f "$state_file" ]] || { error "missing state.json"; return 1; }
  jq -e \
    --arg run "$RUN_ID" \
    --arg prd "$PRD_NUMBER" '
      type == "object"
      and (.claims | type == "object" and length == 0)
      and ((.active_run_id // $run) == $run)
      and ((.active_prd // $prd) == $prd)
    ' "$state_file" >/dev/null 2>&1 \
    || { error "state.json is malformed, claimed, or owned by a different active run"; return 1; }

  local processes
  processes=$(reconcile_scoped_processes) \
    || { error "could not inspect Ralph launcher and worker processes"; return 1; }
  [[ -z "$processes" ]] \
    || { error "a Ralph launcher or worker is still active"; return 1; }

  [[ ! -e "$STATE_DIR/launcher.pid" ]] \
    || { error "launcher.pid exists; launcher inactivity is ambiguous"; return 1; }
  local lock_path
  for lock_path in "$STATE_DIR/launch.lock" "$STATE_DIR/lock"/worker-*; do
    if [[ -e "$lock_path" ]]; then
      if [[ "$MODE" == "apply" \
        && "$lock_path" == "$RECONCILE_SETUP_LOCK" \
        && -f "$lock_path/owner" \
        && "$(cat "$lock_path/owner" 2>/dev/null)" == "$$" ]]; then
        continue
      fi
      error "launcher or worker lock exists at '$lock_path'"
      return 1
    fi
  done

  local worktree_rc=0
  prd_run_has_worker_worktree || worktree_rc=$?
  [[ "$worktree_rc" -eq 1 ]] \
    || { error "a linked worktree exists or worktree evidence cannot be inspected"; return 1; }
}

reconcile_acquire_setup_locks() {
  RECONCILE_SETUP_LOCK="$STATE_DIR/launch.lock"
  if ! acquire_lockdir "$RECONCILE_SETUP_LOCK"; then
    error "another Ralph launch or recovery operation is in flight"
    return 1
  fi

  local common_git_dir
  common_git_dir=$(git -C "$MAIN_REPO" rev-parse --git-common-dir 2>/dev/null) \
    || {
      release_lockdir "$RECONCILE_SETUP_LOCK"
      RECONCILE_SETUP_LOCK=""
      error "could not resolve the repository common git directory"
      return 1
    }
  case "$common_git_dir" in
    /*|[A-Za-z]:/*) ;;
    *) common_git_dir="$MAIN_REPO/$common_git_dir" ;;
  esac
  common_git_dir=$(cd "$common_git_dir" 2>/dev/null && pwd -P) \
    || {
      release_lockdir "$RECONCILE_SETUP_LOCK"
      RECONCILE_SETUP_LOCK=""
      error "could not canonicalize the repository common git directory"
      return 1
    }
  RECONCILE_COMMON_SETUP_LOCK="$common_git_dir/ralph-launch.lock"
  if ! acquire_lockdir "$RECONCILE_COMMON_SETUP_LOCK"; then
    release_lockdir "$RECONCILE_SETUP_LOCK"
    RECONCILE_SETUP_LOCK=""
    RECONCILE_COMMON_SETUP_LOCK=""
    error "another worktree launch or recovery operation is in flight"
    return 1
  fi
}

reconcile_release_locks() {
  if [[ "$RECONCILE_STATE_LOCKED" -eq 1 ]]; then
    state_unlock
    RECONCILE_STATE_LOCKED=0
  fi
  if [[ -n "$RECONCILE_COMMON_SETUP_LOCK" ]]; then
    release_lockdir "$RECONCILE_COMMON_SETUP_LOCK"
    RECONCILE_COMMON_SETUP_LOCK=""
  fi
  if [[ -n "$RECONCILE_SETUP_LOCK" ]]; then
    release_lockdir "$RECONCILE_SETUP_LOCK"
    RECONCILE_SETUP_LOCK=""
  fi
}

reconcile_validate_local_evidence() {
  local run_dir="$STATE_DIR/runs/$RUN_ID"
  local queue_file="$run_dir/queue.json"
  local status_file="$run_dir/status.json"
  local ownership_file="$run_dir/ownership.json"

  [[ -f "$queue_file" && -f "$status_file" && -f "$ownership_file" ]] \
    || { error "run '$RUN_ID' is missing queue, status, or ownership evidence"; return 1; }
  prd_validate_ownership_records || return 1
  prd_run_is_terminal "$RUN_ID" \
    || { error "run '$RUN_ID' is not a valid terminal prior run"; return 1; }
  jq -e --argjson issue "$ISSUE_NUMBER" '
    type == "array"
    and ([.[] | select(.number == $issue)] | length == 1)
  ' "$queue_file" >/dev/null 2>&1 \
    || { error "issue #$ISSUE_NUMBER is not uniquely owned by run '$RUN_ID'"; return 1; }
  jq -e --arg issue "$ISSUE_NUMBER" --arg pr "$PR_NUMBER" '
    type == "object"
    and (.items | type == "object")
    and (.items[$issue] | type == "object")
    and (
      if .items[$issue].status == "merged" then
        ((.items[$issue].pr_number // $pr | tostring) == $pr)
        and (.items[$issue].integrated_commit // null) == null
        and (.items[$issue].reconciliation // null) == null
      elif .items[$issue].status == "slice-integrated" then
        (.items[$issue].pr_number | tostring) == $pr
        and (.items[$issue].integrated_commit
          | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
        and (.items[$issue].integrated_at
          | type == "string"
            and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      else false
      end
    )
  ' "$status_file" >/dev/null 2>&1 \
    || { error "existing status evidence is malformed or conflicts with PR #$PR_NUMBER"; return 1; }
  if ! jq -e --arg issue "$ISSUE_NUMBER" --arg pr "$PR_NUMBER" '
    (.items[$issue].reconciliation // null) as $reconciliation
    | $reconciliation == null
      or (
        ($reconciliation | type == "object")
        and $reconciliation.schema_version == 1
        and $reconciliation.source == "operator-guarded-reconciliation"
        and ($reconciliation.previous_status == "merged"
          or $reconciliation.previous_status == "slice-integrated")
        and ($reconciliation.proof_generated_at
          | type == "string"
            and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and ($reconciliation.applied_at
          | type == "string"
            and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and ($reconciliation.proof | type == "object")
        and $reconciliation.proof.schema_version == 1
        and $reconciliation.proof.action == "reconcile-slice-integrated"
        and $reconciliation.proof.run_id == $RUN_ID
        and ($reconciliation.proof.issue.number | tostring) == $issue
        and ($reconciliation.proof.pull_request.number | tostring) == $pr
        and ($reconciliation.proof.pull_request.merge_commit
          == .items[$issue].integrated_commit)
      )
  ' --arg RUN_ID "$RUN_ID" "$status_file" >/dev/null 2>&1; then
    error "existing reconciliation provenance is malformed or conflicts with canonical evidence"
    return 1
  fi
  jq -e \
    --arg run "$RUN_ID" \
    --arg prd "$PRD_NUMBER" '
      .run_id == $run
      and .prd_number == $prd
      and (.branch_name | type == "string" and length > 0)
      and (.remote | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]*$"))
      and (.initial_base_sha
        | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
      and (.owned_tip_sha
        | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
      and .transfer_pending == null
      and .retirement_pending == null
      and .retired_at == null
    ' "$ownership_file" >/dev/null 2>&1 \
    || { error "ownership evidence does not match run '$RUN_ID' and PRD #$PRD_NUMBER"; return 1; }

  local branch owner_files=()
  branch=$(jq -r '.branch_name' "$ownership_file")
  git -C "$MAIN_REPO" check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || { error "ownership branch name is invalid"; return 1; }
  while IFS= read -r owner_file; do
    [[ -n "$owner_file" ]] && owner_files+=("$owner_file")
  done < <(prd_active_ownership_files "$branch")
  [[ ${#owner_files[@]} -eq 1 && "${owner_files[0]}" == "$ownership_file" ]] \
    || { error "integration branch does not have exactly one matching active owner"; return 1; }
}

reconcile_build_proof() {
  reconcile_validate_local_evidence || return 1
  reconcile_assert_inactive || return 1

  local run_dir="$STATE_DIR/runs/$RUN_ID"
  local status_file="$run_dir/status.json"
  local ownership_file="$run_dir/ownership.json"
  local branch remote remote_url initial_base owned_tip
  branch=$(jq -r '.branch_name' "$ownership_file")
  remote=$(jq -r '.remote' "$ownership_file")
  initial_base=$(jq -r '.initial_base_sha' "$ownership_file")
  owned_tip=$(jq -r '.owned_tip_sha' "$ownership_file")
  remote_url=$(reconcile_remote_repository "$remote") || return 1
  reconcile_assert_unmodified_graph || return 1

  local issue_json pr_json related_prs operator_login
  operator_login=$("$GH" api user --jq .login) \
    || { error "GitHub operator identity lookup failed"; return 1; }
  [[ "$operator_login" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] \
    || { error "GitHub operator identity lookup returned invalid evidence"; return 1; }
  issue_json=$("$GH" api "repos/$REPO/issues/$ISSUE_NUMBER" --jq .) \
    || { error "GitHub issue lookup failed"; return 1; }
  printf '%s\n' "$issue_json" | jq -e \
    --argjson issue "$ISSUE_NUMBER" \
    --arg repo "$REPO" '
      type == "object"
      and .number == $issue
      and .state == "closed"
      and .html_url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
      and .repository_url == ("https://api.github.com/repos/" + $repo)
    ' >/dev/null 2>&1 \
    || { error "issue #$ISSUE_NUMBER is not closed or returned invalid evidence"; return 1; }

  pr_json=$("$GH" pr view "$PR_NUMBER" --repo "$REPO" \
    --json number,state,mergedAt,baseRefName,headRefName,mergeCommit,closingIssuesReferences,url,body) \
    || { error "GitHub pull request lookup failed"; return 1; }
  printf '%s\n' "$pr_json" | jq -e \
    --argjson pr "$PR_NUMBER" \
    --argjson issue "$ISSUE_NUMBER" \
    --arg branch "$branch" \
    --arg repo "$REPO" '
      type == "object"
      and .number == $pr
      and .state == "MERGED"
      and (.mergedAt | type == "string" and length > 0)
      and .baseRefName == $branch
      and (.mergeCommit.oid
        | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
      and (.closingIssuesReferences | type == "array")
      and .url == ("https://github.com/" + $repo + "/pull/" + ($pr | tostring))
    ' >/dev/null 2>&1 \
    || { error "PR #$PR_NUMBER is not merged into owned branch '$branch' or not linked to issue #$ISSUE_NUMBER"; return 1; }

  local linkage_policy="github-closing-reference"
  local closing_directive=""
  local closing_refs_json pr_body pr_body_oid directive_lines directive_issues_json
  local integration_comment_json='null'
  local actor_authorization_json='null'
  closing_refs_json=$(printf '%s\n' "$pr_json" | jq -c '.closingIssuesReferences')
  pr_body=$(printf '%s\n' "$pr_json" | jq -r '.body // ""')
  pr_body_oid=$(printf '%s\n' "$pr_json" \
    | jq -j '.body // ""' \
    | git_proof hash-object --stdin) \
    || { error "could not content-address PR body evidence"; return 1; }
  if ! printf '%s\n' "$closing_refs_json" | jq -e \
    --argjson issue "$ISSUE_NUMBER" \
    --arg repo "$REPO" '
      any(.[];
        .number == $issue
        and .url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
        and ((.repository.owner.login + "/" + .repository.name) == $repo)
      )
      and all(.[];
        if .number == $issue
        then
          .url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
          and ((.repository.owner.login + "/" + .repository.name) == $repo)
        else true
        end
      )
    ' >/dev/null 2>&1; then
    [[ "$(printf '%s\n' "$closing_refs_json" | jq 'length')" -eq 0 ]] \
      || { error "PR #$PR_NUMBER has conflicting GitHub closing-reference evidence"; return 1; }

    if ! directive_lines=$(printf '%s' "$pr_body" \
      | reconcile_closing_directives); then
      error "PR #$PR_NUMBER lacks one unambiguous literal closing directive for issue #$ISSUE_NUMBER"
      return 1
    fi
    directive_issues_json=$(printf '%s\n' "$directive_lines" \
      | reconcile_directive_issues_json) \
      || { error "could not parse PR closing directives"; return 1; }
    printf '%s\n' "$directive_issues_json" | jq -e \
      --argjson issue "$ISSUE_NUMBER" \
      'length == 1 and .[0] == $issue' >/dev/null 2>&1 \
      || { error "PR #$PR_NUMBER lacks one unambiguous literal closing directive for issue #$ISSUE_NUMBER"; return 1; }
    closing_directive="$directive_lines"

    local issue_closed_at issue_closed_by expected_comment comment_pages comments_json
    local comment_author comment_permission_json
    issue_closed_at=$(printf '%s\n' "$issue_json" | jq -r '.closed_at // ""')
    issue_closed_by=$(printf '%s\n' "$issue_json" | jq -r '.closed_by.login // ""')
    [[ "$issue_closed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
      && "$issue_closed_by" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] \
      || { error "issue closure actor or timestamp evidence is missing"; return 1; }
    expected_comment="Merged via PR #$PR_NUMBER into \`$branch\`."
    comment_pages=$("$GH" api \
      "repos/$REPO/issues/$ISSUE_NUMBER/comments?per_page=100" \
      --paginate --slurp) \
      || { error "GitHub issue comment lookup failed"; return 1; }
    comments_json=$(printf '%s\n' "$comment_pages" | jq -c '
      if type == "array" and all(.[]; type == "array")
      then flatten
      else error("invalid comment pages")
      end
    ') || { error "GitHub issue comment lookup returned invalid evidence"; return 1; }
    printf '%s\n' "$comments_json" | jq -e '
      type == "array"
      and all(.[];
        type == "object"
        and (.id | type == "number")
        and (.html_url | type == "string")
        and (.body | type == "string")
        and (.user.login | type == "string")
        and (.author_association | type == "string")
        and (.created_at | type == "string")
        and (.updated_at | type == "string")
      )
    ' >/dev/null 2>&1 \
      || { error "GitHub issue comments contain malformed evidence"; return 1; }
    integration_comment_json=$(printf '%s\n' "$comments_json" | jq -c \
      --arg body "$expected_comment" \
      --arg closed_at "$issue_closed_at" \
      --arg closed_by "$issue_closed_by" '
        [
          .[]
          | select(
              .body
              | test("^Merged via PR #[1-9][0-9]* into `[^`\\r\\n]+`\\.$")
            )
        ]
        | if length == 1
            and .[0].body == $body
            and .[0].created_at == $closed_at
            and .[0].updated_at == .[0].created_at
            and .[0].user.login == $closed_by
            and (.[0].author_association
              | IN("OWNER", "MEMBER", "COLLABORATOR"))
          then .[0]
          else empty
          end
      ') || { error "could not inspect Ralph integration closure comments"; return 1; }
    [[ -n "$integration_comment_json" ]] \
      || { error "exact unedited Ralph integration closure comment is missing or ambiguous"; return 1; }
    comment_author=$(printf '%s\n' "$integration_comment_json" | jq -r '.user.login')
    comment_permission_json=$("$GH" api \
      "repos/$REPO/collaborators/$comment_author/permission" --jq .) \
      || { error "integration comment actor authorization lookup failed"; return 1; }
    printf '%s\n' "$comment_permission_json" | jq -e \
      --arg login "$comment_author" '
        type == "object"
        and .user.login == $login
        and (.permission | IN("admin", "maintain", "write"))
      ' >/dev/null 2>&1 \
      || { error "integration comment actor is not authorized by repository policy"; return 1; }
    actor_authorization_json=$(printf '%s\n' "$comment_permission_json" | jq -c '{
      login: .user.login,
      permission: .permission,
      role_name: (.role_name // null)
    }')
    integration_comment_json=$(printf '%s\n' "$integration_comment_json" | jq -c '{
      id,
      url: .html_url,
      body,
      author: .user.login,
      author_association,
      created_at,
      updated_at
    }')
    linkage_policy="non-default-owned-branch-bundle"
  fi

  related_prs=$("$GH" pr list --repo "$REPO" --state all \
    --base "$branch" --limit 1000 \
    --json number,state,baseRefName,mergeCommit,closingIssuesReferences,body) \
    || { error "GitHub related pull request lookup failed"; return 1; }
  printf '%s\n' "$related_prs" | jq -e '
    type == "array"
    and length < 1000
    and all(.[];
      type == "object"
      and (.number | type == "number")
      and (.closingIssuesReferences | type == "array")
    )
  ' >/dev/null 2>&1 \
    || { error "related pull request evidence is invalid, truncated, or ambiguous"; return 1; }
  local candidate_prs_json='[]' candidate_pr_evidence_json related_pr related_refs related_body
  local candidate_pr_record candidate_body_oid
  local related_directives related_issues_json related_has_target
  while IFS= read -r related_pr; do
    related_refs=$(printf '%s\n' "$related_pr" | jq -c '.closingIssuesReferences')
    related_body=$(printf '%s\n' "$related_pr" | jq -r '.body // ""')
    related_has_target=0
    if printf '%s\n' "$related_refs" | jq -e \
      --argjson issue "$ISSUE_NUMBER" \
      --arg repo "$REPO" '
        any(.[];
          .number == $issue
          and .url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
          and ((.repository.owner.login + "/" + .repository.name) == $repo)
        )
        and all(.[];
          if .number == $issue
          then
            .url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
            and ((.repository.owner.login + "/" + .repository.name) == $repo)
          else true
          end
        )
      ' >/dev/null 2>&1; then
      related_has_target=1
    else
      if [[ "$related_body" != *"#$ISSUE_NUMBER"* ]]; then
        continue
      fi
      if ! related_directives=$(printf '%s' "$related_body" \
        | reconcile_closing_directives); then
        error "related PR has unsafe or ambiguous linkage evidence for issue #$ISSUE_NUMBER"
        return 1
      fi
      related_issues_json=$(printf '%s\n' "$related_directives" \
        | reconcile_directive_issues_json) \
        || { error "could not parse related PR closing directives"; return 1; }
      if printf '%s\n' "$related_issues_json" | jq -e \
        --argjson issue "$ISSUE_NUMBER" \
        'any(.[]; . == $issue)' >/dev/null 2>&1; then
        [[ "$(printf '%s\n' "$related_refs" | jq 'length')" -eq 0 \
          && "$(printf '%s\n' "$related_issues_json" | jq 'length')" -eq 1 ]] \
          || { error "related PR has conflicting linkage evidence for issue #$ISSUE_NUMBER"; return 1; }
        related_has_target=1
      fi
    fi
    if [[ "$related_has_target" -eq 1 ]]; then
      candidate_prs_json=$(printf '%s\n' "$candidate_prs_json" | jq -c \
        --argjson pr "$(printf '%s\n' "$related_pr" | jq '.number')" \
        '. + [$pr]')
    fi
  done < <(printf '%s\n' "$related_prs" | jq -c '.[]')
  printf '%s\n' "$related_prs" | jq -e \
    --argjson candidates "$candidate_prs_json" \
    --argjson pr "$PR_NUMBER" \
    --arg branch "$branch" \
    --arg merge_commit "$(printf '%s\n' "$pr_json" | jq -r '.mergeCommit.oid')" '
      $candidates == [$pr]
      and ([.[] | select(.number == $pr)] | length) == 1
      and (
        ([.[] | select(.number == $pr)][0]) as $linked
        | $linked.state == "MERGED"
          and $linked.baseRefName == $branch
          and $linked.mergeCommit.oid == $merge_commit
      )
    ' >/dev/null 2>&1 \
    || { error "linked pull request evidence is missing or conflicting"; return 1; }
  candidate_pr_record=$(printf '%s\n' "$related_prs" | jq -c \
    --argjson pr "$PR_NUMBER" '.[] | select(.number == $pr)')
  candidate_body_oid=$(printf '%s\n' "$candidate_pr_record" \
    | jq -j '.body // ""' \
    | git_proof hash-object --stdin) \
    || { error "could not content-address candidate PR body evidence"; return 1; }
  [[ "$candidate_body_oid" == "$pr_body_oid" ]] \
    || { error "PR body evidence changed or conflicts across GitHub lookups"; return 1; }
  candidate_pr_evidence_json=$(printf '%s\n' "$candidate_pr_record" | jq -c \
    --arg body_oid "$candidate_body_oid" '
      del(.body) + {body_oid: $body_oid}
    ')
  candidate_pr_evidence_json="[$candidate_pr_evidence_json]"

  local merge_commit remote_tip remote_rc=0
  merge_commit=$(printf '%s\n' "$pr_json" | jq -r '.mergeCommit.oid')
  remote_tip=$(prd_remote_branch_tip "$remote" "$branch") || remote_rc=$?
  [[ "$remote_rc" -eq 0 ]] \
    || { error "could not resolve exact remote integration-branch tip"; return 1; }
  git -C "$MAIN_REPO" fetch --quiet --no-tags --no-write-fetch-head \
    "$remote" "$remote_tip" \
    || { error "could not fetch remote integration-branch tip"; return 1; }
  local rechecked_remote_tip
  rechecked_remote_tip=$(prd_remote_branch_tip "$remote" "$branch") \
    || { error "could not recheck remote integration-branch tip"; return 1; }
  [[ "$rechecked_remote_tip" == "$remote_tip" ]] \
    || { error "remote integration-branch tip moved during proof"; return 1; }
  git_proof cat-file -e "${initial_base}^{commit}" 2>/dev/null \
    && git_proof cat-file -e "${owned_tip}^{commit}" 2>/dev/null \
    && git_proof cat-file -e "${merge_commit}^{commit}" 2>/dev/null \
    && git_proof cat-file -e "${remote_tip}^{commit}" 2>/dev/null \
    || { error "ownership, PR, or remote commit evidence is unavailable"; return 1; }
  git_proof merge-base --is-ancestor "$initial_base" "$remote_tip" \
    && git_proof merge-base --is-ancestor "$owned_tip" "$remote_tip" \
    || { error "remote integration history does not descend from owned history"; return 1; }
  if [[ "$owned_tip" == "$merge_commit" ]] \
    || ! git_proof merge-base --is-ancestor "$owned_tip" "$merge_commit"; then
    error "PR merge commit is not a strict descendant of the owned tip"
    return 1
  fi
  local tip_policy="exact-tip"
  local accounted_commits_json='[]'
  if [[ "$merge_commit" != "$remote_tip" ]]; then
    if ! git_proof rev-list --first-parent "$remote_tip" \
      | grep -Fqx "$merge_commit"; then
      error "PR merge commit is not on the remote tip's first-parent integration history"
      return 1
    fi
    local accounted_commits commit
    accounted_commits=$(git_proof rev-list --first-parent --reverse \
      "${merge_commit}..${remote_tip}") \
      || { error "could not inspect descendant integration history"; return 1; }
    [[ -n "$accounted_commits" ]] \
      || { error "remote descendant history is empty or ambiguous"; return 1; }
    while IFS= read -r commit; do
      [[ -n "$commit" ]] || continue
      local accounted_record accounted_issue accounted_pr accounted_issue_json accounted_pr_json
      accounted_record=$(jq -c \
        --arg target "$ISSUE_NUMBER" \
        --arg commit "$commit" '
          [
            .items
            | to_entries[]
            | select(
                .key != $target
                and .value.status == "slice-integrated"
                and .value.integrated_commit == $commit
                and (.value.pr_number
                  | type == "string" and test("^[1-9][0-9]*$"))
                and (.value.integrated_at | type == "string" and length > 0)
              )
          ]
          | if length == 1 then .[0] else empty end
        ' "$status_file") || {
          error "could not inspect canonical evidence for descendant commit '$commit'"
          return 1
        }
      if [[ -z "$accounted_record" ]]; then
        error "remote descendant commit '$commit' lacks unique canonical slice evidence"
        return 1
      fi
      accounted_issue=$(printf '%s\n' "$accounted_record" | jq -r '.key')
      accounted_pr=$(printf '%s\n' "$accounted_record" | jq -r '.value.pr_number')
      if ! jq -e --argjson issue "$accounted_issue" '
        [.[] | select(.number == $issue)] | length == 1
      ' "$run_dir/queue.json" >/dev/null 2>&1; then
        error "accounted descendant issue #$accounted_issue is not uniquely queued in run '$RUN_ID'"
        return 1
      fi
      accounted_issue_json=$("$GH" issue view "$accounted_issue" --repo "$REPO" \
        --json number,state,stateReason,url) \
        || { error "GitHub issue lookup failed for accounted descendant #$accounted_issue"; return 1; }
      printf '%s\n' "$accounted_issue_json" | jq -e \
        --argjson issue "$accounted_issue" '
          type == "object" and .number == $issue and .state == "CLOSED"
        ' >/dev/null 2>&1 \
        || { error "accounted descendant issue #$accounted_issue is not closed"; return 1; }
      accounted_pr_json=$("$GH" pr view "$accounted_pr" --repo "$REPO" \
        --json number,state,mergedAt,baseRefName,mergeCommit,closingIssuesReferences,url) \
        || { error "GitHub PR lookup failed for accounted descendant PR #$accounted_pr"; return 1; }
      printf '%s\n' "$accounted_pr_json" | jq -e \
        --argjson pr "$accounted_pr" \
        --argjson issue "$accounted_issue" \
        --arg repo "$REPO" \
        --arg branch "$branch" \
        --arg commit "$commit" '
          type == "object"
          and .number == $pr
          and .state == "MERGED"
          and .baseRefName == $branch
          and .mergeCommit.oid == $commit
          and any(.closingIssuesReferences[]?;
            .number == $issue
            and .url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
            and ((.repository.owner.login + "/" + .repository.name) == $repo)
          )
          and all(.closingIssuesReferences[]?;
            if .number == $issue
            then
              .url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
              and ((.repository.owner.login + "/" + .repository.name) == $repo)
            else true
            end
          )
        ' >/dev/null 2>&1 \
        || { error "accounted descendant PR #$accounted_pr lacks matching GitHub merge evidence"; return 1; }
      printf '%s\n' "$related_prs" | jq -e \
        --argjson pr "$accounted_pr" \
        --argjson issue "$accounted_issue" \
        --arg repo "$REPO" \
        --arg commit "$commit" '
          [
            .[]
            | select(any(.closingIssuesReferences[]?;
                .number == $issue
                and .url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring))
                and ((.repository.owner.login + "/" + .repository.name) == $repo)
              ))
          ] as $linked
          | ($linked | length) == 1
          and $linked[0].number == $pr
          and $linked[0].state == "MERGED"
          and $linked[0].mergeCommit.oid == $commit
        ' >/dev/null 2>&1 \
        || { error "accounted descendant issue #$accounted_issue has conflicting linked PR evidence"; return 1; }
    done <<<"$accounted_commits"
    accounted_commits_json=$(printf '%s\n' "$accounted_commits" \
      | jq -Rsc 'split("\n") | map(select(length > 0))')
    tip_policy="accounted-first-parent-descendant"
  fi
  if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    [[ "$(git -C "$MAIN_REPO" rev-parse "refs/heads/$branch")" == "$remote_tip" ]] \
      || { error "local integration branch tip conflicts with the remote tip"; return 1; }
  fi

  local prior_status prior_pr prior_commit integrated_at
  prior_status=$(jq -r --arg issue "$ISSUE_NUMBER" '.items[$issue].status' "$status_file")
  prior_pr=$(jq -r --arg issue "$ISSUE_NUMBER" '.items[$issue].pr_number // empty | tostring' "$status_file")
  prior_commit=$(jq -r --arg issue "$ISSUE_NUMBER" '.items[$issue].integrated_commit // empty' "$status_file")
  integrated_at=$(jq -r --arg issue "$ISSUE_NUMBER" '.items[$issue].integrated_at // empty' "$status_file")
  [[ -z "$prior_commit" || "$prior_commit" == "$merge_commit" ]] \
    || { error "existing integrated commit conflicts with PR #$PR_NUMBER"; return 1; }

  jq -n \
    --arg repository "$REPO" \
    --arg run "$RUN_ID" \
    --arg prd "$PRD_NUMBER" \
    --argjson issue "$ISSUE_NUMBER" \
    --arg issue_state "$(printf '%s\n' "$issue_json" | jq -r '.state | ascii_upcase')" \
    --arg issue_url "$(printf '%s\n' "$issue_json" | jq -r '.html_url')" \
    --arg issue_closed_at "$(printf '%s\n' "$issue_json" | jq -r '.closed_at // ""')" \
    --arg issue_closed_by "$(printf '%s\n' "$issue_json" | jq -r '.closed_by.login // ""')" \
    --argjson pr "$PR_NUMBER" \
    --arg pr_state "$(printf '%s\n' "$pr_json" | jq -r '.state')" \
    --arg merged_at "$(printf '%s\n' "$pr_json" | jq -r '.mergedAt')" \
    --arg pr_url "$(printf '%s\n' "$pr_json" | jq -r '.url')" \
    --arg branch "$branch" \
    --arg remote "$remote" \
    --arg remote_url "$remote_url" \
    --arg initial_base "$initial_base" \
    --arg owned_tip "$owned_tip" \
    --arg merge_commit "$merge_commit" \
    --arg remote_tip "$remote_tip" \
    --arg tip_policy "$tip_policy" \
    --argjson accounted_commits "$accounted_commits_json" \
    --arg prior_status "$prior_status" \
    --arg prior_pr "$prior_pr" \
    --arg prior_commit "$prior_commit" \
    --arg integrated_at "$integrated_at" \
    --arg operator_login "$operator_login" \
    --arg linkage_policy "$linkage_policy" \
    --arg closing_directive "$closing_directive" \
    --arg pr_body_oid "$pr_body_oid" \
    --argjson closing_refs "$closing_refs_json" \
    --argjson candidate_prs "$candidate_prs_json" \
    --argjson candidate_pr_evidence "$candidate_pr_evidence_json" \
    --argjson integration_comment "$integration_comment_json" \
    --argjson actor_authorization "$actor_authorization_json" \
    --arg generated_at "$(date -u +%FT%TZ)" '
      {
        schema_version: 1,
        action: "reconcile-slice-integrated",
        mode: "dry-run",
        repository: $repository,
        run_id: $run,
        prd_number: $prd,
        issue: {
          number: $issue,
          state: $issue_state,
          url: $issue_url,
          closed_at: (if $issue_closed_at == "" then null else $issue_closed_at end),
          closed_by: (if $issue_closed_by == "" then null else $issue_closed_by end)
        },
        pull_request: {
          number: $pr,
          state: $pr_state,
          merged_at: $merged_at,
          url: $pr_url,
          base: $branch,
          merge_commit: $merge_commit
        },
        linkage: {
          policy: $linkage_policy,
          closing_directive: (if $closing_directive == "" then null else $closing_directive end),
          closing_issues_references: $closing_refs,
          pull_request_body_oid: $pr_body_oid,
          candidate_prs: $candidate_prs,
          candidate_pr_evidence: $candidate_pr_evidence,
          integration_comment: $integration_comment,
          actor_authorization: $actor_authorization
        },
        ownership: {
          branch: $branch,
          remote: $remote,
          remote_url: $remote_url,
          initial_base_sha: $initial_base,
          owned_tip_sha: $owned_tip
        },
        remote: {
          tip: $remote_tip,
          policy: $tip_policy,
          accounted_commits: $accounted_commits
        },
        operator: {
          login: $operator_login
        },
        prior_evidence: {
          status: $prior_status,
          pr_number: (if $prior_pr == "" then null else $prior_pr end),
          integrated_commit: (if $prior_commit == "" then null else $prior_commit end),
          integrated_at: (if $integrated_at == "" then null else $integrated_at end)
        },
        proof_generated_at: $generated_at
      }
    '
}

if [[ "$MODE" == "dry-run" ]]; then
  reconcile_build_proof
  exit $?
fi

if [[ ! -f "$PROOF_FILE" ]]; then
  error "proof file does not exist or is not a regular file"
  exit 1
fi
supplied_proof=$(jq -cS . "$PROOF_FILE") \
  || { error "proof file contains malformed JSON"; exit 1; }
if ! printf '%s\n' "$supplied_proof" | jq -e \
  --arg repository "$REPO" \
  --arg run "$RUN_ID" \
  --arg prd "$PRD_NUMBER" \
  --argjson issue "$ISSUE_NUMBER" \
  --argjson pr "$PR_NUMBER" '
    type == "object"
    and .schema_version == 1
    and .action == "reconcile-slice-integrated"
    and .mode == "dry-run"
    and .repository == $repository
    and .run_id == $run
    and .prd_number == $prd
    and .issue.number == $issue
    and .pull_request.number == $pr
    and (.proof_generated_at
      | type == "string"
        and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' >/dev/null 2>&1; then
  error "proof file is malformed or does not match the requested reconciliation"
  exit 1
fi

supplied_fingerprint=$(printf '%s\n' "$supplied_proof" \
  | jq -cS 'del(.mode, .proof_generated_at, .prior_evidence)')

reconcile_acquire_setup_locks || exit 1
trap 'reconcile_release_locks' EXIT
state_lock || { error "could not acquire the Ralph state lock"; exit 1; }
RECONCILE_STATE_LOCKED=1

current_proof=$(reconcile_build_proof) \
  || { error "evidence revalidation failed under the state lock"; exit 1; }
current_fingerprint=$(printf '%s\n' "$current_proof" \
  | jq -cS 'del(.mode, .proof_generated_at, .prior_evidence)')
if [[ "$current_fingerprint" != "$supplied_fingerprint" ]]; then
  error "live evidence changed after dry-run; generate and review a new proof"
  exit 1
fi

status_path=$(status_file "$RUN_ID")
previous_status=$(jq -r \
  --arg issue "$ISSUE_NUMBER" \
  '.items[$issue].status' "$status_path")
existing_commit=$(jq -r \
  --arg issue "$ISSUE_NUMBER" \
  '.items[$issue].integrated_commit // empty' "$status_path")
merge_commit=$(printf '%s\n' "$current_proof" \
  | jq -r '.pull_request.merge_commit')
result="recorded"
if [[ "$previous_status" == "slice-integrated" \
  && "$existing_commit" == "$merge_commit" ]]; then
  supplied_prior_status=$(printf '%s\n' "$supplied_proof" \
    | jq -r '.prior_evidence.status')
  if [[ "$supplied_prior_status" != "slice-integrated" ]] \
    && ! jq -e \
      --arg issue "$ISSUE_NUMBER" \
      --argjson proof "$supplied_proof" \
      '.items[$issue].reconciliation.proof == $proof' \
      "$status_path" >/dev/null 2>&1; then
    error "canonical evidence changed after dry-run without matching reconciliation provenance"
    exit 1
  fi
  result="unchanged"
else
  supplied_prior=$(printf '%s\n' "$supplied_proof" \
    | jq -cS '.prior_evidence')
  current_prior=$(printf '%s\n' "$current_proof" \
    | jq -cS '.prior_evidence')
  if [[ "$current_prior" != "$supplied_prior" ]]; then
    error "status evidence changed after dry-run; generate and review a new proof"
    exit 1
  fi
  status_tmp=$(status_mktemp "$RUN_ID") \
    || { error "could not create an atomic status update"; exit 1; }
  applied_at=$(date -u +%FT%TZ)
  if ! jq \
    --arg issue "$ISSUE_NUMBER" \
    --arg pr "$PR_NUMBER" \
    --arg commit "$merge_commit" \
    --arg integrated_at "$applied_at" \
    --arg previous_status "$previous_status" \
    --arg proof_generated_at \
      "$(printf '%s\n' "$supplied_proof" | jq -r '.proof_generated_at')" \
    --arg applied_at "$applied_at" \
    --argjson proof "$supplied_proof" '
      .items[$issue] = (
        .items[$issue]
        + {
          status: "slice-integrated",
          pr_number: $pr,
          integrated_commit: $commit,
          integrated_at: $integrated_at,
          workerId: null,
          pid: null,
          logFile: null,
          startedAt: null,
          error: null,
          reconciliation: {
            schema_version: 1,
            source: "operator-guarded-reconciliation",
            previous_status: $previous_status,
            proof_generated_at: $proof_generated_at,
            applied_at: $applied_at,
            proof: $proof
          }
        }
      )
    ' "$status_path" >"$status_tmp"; then
    rm -f "$status_tmp"
    error "could not prepare canonical status evidence"
    exit 1
  fi
  if ! mv "$status_tmp" "$status_path"; then
    rm -f "$status_tmp"
    error "could not atomically record canonical status evidence"
    exit 1
  fi
fi

jq -n \
  --arg result "$result" \
  --arg run "$RUN_ID" \
  --argjson issue "$ISSUE_NUMBER" \
  --argjson pr "$PR_NUMBER" \
  --arg commit "$merge_commit" '
    {
      schema_version: 1,
      action: "reconcile-slice-integrated",
      mode: "apply",
      result: $result,
      run_id: $run,
      issue_number: $issue,
      pr_number: $pr,
      status: "slice-integrated",
      integrated_commit: $commit
    }
  '
