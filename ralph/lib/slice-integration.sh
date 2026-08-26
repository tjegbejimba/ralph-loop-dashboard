#!/usr/bin/env bash
# slice-integration.sh — PRD slice integration lifecycle management.
#
# Provides functions for managing slice PR integration into PRD branches,
# including base verification, lifecycle recording, and dependency tracking.
#
# This file is sourced by ralph.sh. Functions assume:
#   $STATE_DIR  — directory holding .ralph/state.json and runs/
#   $RUN_ID     — current run identifier
#   gh          — GitHub CLI (function or command)

# resolve_slice_pr_base RUN_ID DELIVERY_BRANCH
# Returns the target base branch for slice PRs in the given run.
# For PRD runs with ownership, returns the integration branch.
# For non-PRD runs, returns the delivery branch.
#
# Args:
#   RUN_ID          — run identifier
#   DELIVERY_BRANCH — default delivery branch (e.g., "main")
#
# Outputs: branch name
resolve_slice_pr_base() {
  local run_id="$1"
  local delivery_branch="$2"
  
  local ownership_file="$STATE_DIR/runs/$run_id/ownership.json"
  if [[ -f "$ownership_file" ]]; then
    jq -r '.branch_name' "$ownership_file" 2>/dev/null || echo "$delivery_branch"
  else
    echo "$delivery_branch"
  fi
}

# verify_slice_pr_base RUN_ID ACTUAL_BASE
# Verifies that the actual PR base matches the expected base for this run.
#
# Args:
#   RUN_ID      — run identifier
#   ACTUAL_BASE — the base branch of the merged PR
#
# Returns: 0 if base is correct, 1 otherwise
verify_slice_pr_base() {
  local run_id="$1"
  local actual_base="$2"
  
  local ownership_file="$STATE_DIR/runs/$run_id/ownership.json"
  if [[ -f "$ownership_file" ]]; then
    local expected_base
    expected_base=$(jq -r '.branch_name' "$ownership_file" 2>/dev/null)
    if [[ "$actual_base" == "$expected_base" ]]; then
      return 0
    else
      echo "ERROR: PR base '$actual_base' does not match expected PRD integration branch '$expected_base'" >&2
      return 1
    fi
  else
    # Non-PRD run: accept any base (legacy behavior)
    return 0
  fi
}

# record_slice_integrated ISSUE_NUMBER PR_NUMBER COMMIT_SHA [RUN_ID]
# Records that a slice has been integrated into the PRD branch.
# Updates status.json with slice-integrated status, PR number, and commit SHA.
#
# Args:
#   ISSUE_NUMBER — slice issue number
#   PR_NUMBER    — pull request number
#   COMMIT_SHA   — merge commit SHA
#   RUN_ID       — run identifier (optional, uses $RUN_ID if not provided)
#
# Returns: 0 on success, 1 on failure
record_slice_integrated() {
  local issue="$1"
  local pr_number="$2"
  local commit_sha="$3"
  local run_id="${4:-$RUN_ID}"
  
  local file
  file=$(status_file "$run_id")
  local tmp
  tmp=$(status_mktemp "$run_id")
  
  [[ ! -f "$file" ]] && printf '%s\n' '{"items":{}}' >"$file"
  
  jq --arg issue "$issue" \
     --arg pr "$pr_number" \
     --arg commit "$commit_sha" \
     --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
    .items[$issue] = {
      status: "slice-integrated",
      pr_number: $pr,
      integrated_commit: $commit,
      integrated_at: $timestamp,
      workerId: null,
      pid: null,
      logFile: null,
      startedAt: null,
      error: null
    }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# reconcile_slice_integration_evidence RUN_ID ISSUE PR PRD BRANCH REPO_ROOT REPO
# Repairs a missing slice-integrated lifecycle fact only after independently
# proving the immutable GitHub delivery and the local run ownership.
reconcile_slice_integration_evidence() {
  local run_id="$1"
  local issue="$2"
  local pr_number="$3"
  local prd_number="$4"
  local branch_name="$5"
  local repo_root="$6"
  local repo="$7"

  if ! [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
    && "$issue" =~ ^[1-9][0-9]*$ \
    && "$pr_number" =~ ^[1-9][0-9]*$ \
    && "$prd_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid guarded slice-reconciliation identity" >&2
    return 1
  fi
  if ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Invalid PRD integration branch '$branch_name'" >&2
    return 1
  fi

  local run_dir="$STATE_DIR/runs/$run_id"
  local queue_file="$run_dir/queue.json"
  local metadata_file="$run_dir/metadata.json"
  local status_file="$run_dir/status.json"
  local ownership_file="$run_dir/ownership.json"
  local config_file="$STATE_DIR/config.json"
  local canonical_root metadata_root metadata_canonical_root
  canonical_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || {
    echo "ERROR: Could not resolve repository root '$repo_root'" >&2
    return 1
  }

  if [[ ! -f "$queue_file" || ! -f "$metadata_file" || ! -f "$status_file" \
    || ! -f "$ownership_file" || ! -f "$config_file" ]]; then
    echo "ERROR: Run '$run_id' lacks required queue, metadata, status, ownership, or config evidence" >&2
    return 1
  fi
  if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || ! jq -e --arg repo "$repo" \
      '(.repo | type == "string")
       and ((.repo | ascii_downcase) == ($repo | ascii_downcase))' \
      "$config_file" >/dev/null 2>&1; then
    echo "ERROR: Repository '$repo' does not match canonical Ralph config" >&2
    return 1
  fi
  metadata_root=$(jq -r '.repoRoot // empty' "$metadata_file") || return 1
  metadata_canonical_root=$(cd "$metadata_root" 2>/dev/null && pwd -P) || {
    echo "ERROR: Run '$run_id' has an unresolvable repository root" >&2
    return 1
  }
  if [[ "$metadata_canonical_root" != "$canonical_root" ]]; then
    echo "ERROR: Run '$run_id' does not belong to repository '$canonical_root'" >&2
    return 1
  fi
  if ! jq -e --argjson issue "$issue" \
    'type == "array" and any(.[]; .number == $issue)' \
    "$queue_file" >/dev/null 2>&1; then
    echo "ERROR: Issue #$issue is not in run '$run_id'" >&2
    return 1
  fi

  if ! declare -F prd_validate_ownership_records >/dev/null 2>&1 \
    || ! prd_validate_ownership_records; then
    echo "ERROR: PRD ownership evidence cannot be validated" >&2
    return 1
  fi
  if ! jq -e \
    --arg run "$run_id" \
    --arg prd "$prd_number" \
    --arg branch "$branch_name" \
    '.run_id == $run
     and .prd_number == $prd
     and .branch_name == $branch
     and (.remote | type == "string" and length > 0)
     and (.delivery_branch | type == "string" and length > 0)
     and (.initial_base_sha
       | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
     and (.owned_tip_sha == null or
       (.owned_tip_sha
         | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$")))
     and .transfer_pending == null
     and .retirement_pending == null
     and .retired_at == null' \
    "$ownership_file" >/dev/null 2>&1; then
    echo "ERROR: Run '$run_id' does not own PRD #$prd_number branch '$branch_name'" >&2
    return 1
  fi
  local configured_remote configured_delivery configured_prefix config_prefix
  local ownership_remote ownership_delivery
  configured_remote=$(jq -r '.prd.remote // "origin"' "$config_file") || return 1
  configured_delivery=$(jq -r '.prd.deliveryBranch // "main"' "$config_file") || return 1
  config_prefix=$(jq -r '.issue.branchPrefix // empty' "$config_file") || return 1
  configured_prefix="${RALPH_BRANCH_PREFIX:-${config_prefix:-slice-}}"
  ownership_remote=$(jq -r '.remote' "$ownership_file") || return 1
  ownership_delivery=$(jq -r '.delivery_branch' "$ownership_file") || return 1
  if ! [[ "$configured_remote" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
    echo "ERROR: Invalid configured PRD remote '$configured_remote'" >&2
    return 1
  fi
  if ! [[ "$configured_prefix" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[-_/]$ ]]; then
    echo "ERROR: Invalid configured issue branch prefix '$configured_prefix'" >&2
    return 1
  fi
  if [[ "$ownership_remote" != "$configured_remote" ]]; then
    echo "ERROR: Ownership remote '$ownership_remote' does not match configured PRD remote '$configured_remote'" >&2
    return 1
  fi
  if [[ "$ownership_delivery" != "$configured_delivery" ]]; then
    echo "ERROR: Ownership delivery branch '$ownership_delivery' does not match configured PRD delivery branch '$configured_delivery'" >&2
    return 1
  fi

  local owner_files=()
  local owner_file other_prd other_branch
  while IFS= read -r owner_file; do
    [[ -n "$owner_file" ]] && owner_files+=("$owner_file")
  done < <(prd_active_ownership_files "$branch_name")
  if [[ ${#owner_files[@]} -ne 1 || "${owner_files[0]}" != "$ownership_file" ]]; then
    echo "ERROR: Branch '$branch_name' does not have exactly one matching active owner" >&2
    return 1
  fi
  shopt -s nullglob
  for owner_file in "$STATE_DIR/runs/"*/ownership.json; do
    [[ "$owner_file" == "$ownership_file" ]] && continue
    other_prd=$(jq -r 'select(.retired_at == null) | .prd_number // empty' \
      "$owner_file" 2>/dev/null) || {
      shopt -u nullglob
      echo "ERROR: Could not inspect competing ownership '$owner_file'" >&2
      return 1
    }
    other_branch=$(jq -r 'select(.retired_at == null) | .branch_name // empty' \
      "$owner_file" 2>/dev/null) || {
      shopt -u nullglob
      echo "ERROR: Could not inspect competing ownership '$owner_file'" >&2
      return 1
    }
    if [[ "$other_prd" == "$prd_number" || "$other_branch" == "$branch_name" ]]; then
      shopt -u nullglob
      echo "ERROR: Conflicting active PRD ownership exists at '$owner_file'" >&2
      return 1
    fi
  done
  shopt -u nullglob

  if ! jq -e \
    --arg run "$run_id" \
    --arg prd "$prd_number" \
    'type == "object"
     and ((.claims // {}) | type == "object" and length == 0)
     and ((.active_run_id == null and .active_prd == null)
       or (.active_run_id == $run and (.active_prd | tostring) == $prd))' \
    "$STATE_FILE" >/dev/null 2>&1; then
    echo "ERROR: Repository has a claim or conflicting active-run ownership" >&2
    return 1
  fi
  if prd_run_has_live_worker "$run_id"; then
    echo "ERROR: Run '$run_id' still has a live worker" >&2
    return 1
  fi
  if declare -F scoped_ralph_processes >/dev/null 2>&1; then
    local live_processes
    live_processes=$(scoped_ralph_processes strict) || {
      echo "ERROR: Could not inspect repository-scoped Ralph processes" >&2
      return 1
    }
    if [[ -n "$live_processes" ]]; then
      echo "ERROR: Repository still has a live Ralph worker" >&2
      return 1
    fi
  else
    echo "ERROR: Could not inspect repository-scoped Ralph processes" >&2
    return 1
  fi

  local item_status
  item_status=$(jq -r --arg issue "$issue" '.items[$issue].status // empty' \
    "$status_file") || return 1
  if [[ "$item_status" != "merged" && "$item_status" != "slice-integrated" ]]; then
    echo "ERROR: Issue #$issue is not in a reconcilable terminal state" >&2
    return 1
  fi

  local remote issue_json pr_json branch_prs open_prs remote_tip remote_rc=0
  local frozen_base owned_tip fetched_tip
  remote="$ownership_remote"
  frozen_base=$(jq -r '.initial_base_sha' "$ownership_file") || return 1
  owned_tip=$(jq -r '.owned_tip_sha // .initial_base_sha' "$ownership_file") || return 1
  remote_tip=$(prd_remote_branch_tip "$remote" "$branch_name") || remote_rc=$?
  if [[ "$remote_rc" -ne 0 ]]; then
    echo "ERROR: Could not prove remote branch '$remote/$branch_name'" >&2
    return 1
  fi
  if ! git fetch "$remote" \
    "refs/heads/$branch_name:refs/remotes/$remote/$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Failed to fetch remote branch '$remote/$branch_name'" >&2
    return 1
  fi
  fetched_tip=$(git rev-parse "refs/remotes/$remote/$branch_name") || return 1
  if [[ "$fetched_tip" != "$remote_tip" ]]; then
    echo "ERROR: Remote branch '$remote/$branch_name' moved while recovery evidence was fetched" >&2
    return 1
  fi
  if ! git cat-file -e "${frozen_base}^{commit}" 2>/dev/null \
    || ! git cat-file -e "${owned_tip}^{commit}" 2>/dev/null \
    || ! git merge-base --is-ancestor "$frozen_base" "$remote_tip" \
    || ! git merge-base --is-ancestor "$owned_tip" "$remote_tip"; then
    echo "ERROR: Remote branch '$remote/$branch_name' does not descend from run-owned history" >&2
    return 1
  fi
  issue_json=$(gh issue view "$issue" --repo "$repo" \
    --json number,state,closedAt,closedByPullRequestsReferences,comments) || {
    echo "ERROR: Could not inspect issue #$issue" >&2
    return 1
  }
  if ! jq -e --argjson issue "$issue" \
    '.number == $issue
     and .state == "CLOSED"
     and (.closedAt | type == "string" and length > 0)' \
    <<<"$issue_json" >/dev/null 2>&1; then
    echo "ERROR: Issue #$issue is not CLOSED" >&2
    return 1
  fi
  pr_json=$(gh pr view "$pr_number" --repo "$repo" \
    --json number,state,mergedAt,baseRefName,headRefName,headRepository,mergeCommit,closingIssuesReferences,body) || {
    echo "ERROR: Could not inspect PR #$pr_number" >&2
    return 1
  }
  if ! jq -e \
    --argjson pr "$pr_number" \
    --arg issue "$issue" \
    --arg branch "$branch_name" \
    --arg repo "$repo" \
    --arg head_prefix "${configured_prefix}${issue}-" \
    '.number == $pr
     and .state == "MERGED"
     and (.mergedAt | type == "string" and length > 0)
     and .baseRefName == $branch
     and ((.headRepository.nameWithOwner | ascii_downcase)
       == ($repo | ascii_downcase))
     and (.headRefName
       | type == "string"
       and startswith($head_prefix))
     and (.mergeCommit.oid
       | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
     and (
       any((.closingIssuesReferences // [])[]?; (.number | tostring) == $issue)
       or ((.body // "")
         | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s+#" + $issue + "\\b"))
     )' <<<"$pr_json" >/dev/null 2>&1; then
    echo "ERROR: PR #$pr_number is not a merged, issue-linked delivery to '$branch_name'" >&2
    return 1
  fi
  local pr_merged_at issue_closed_at
  pr_merged_at=$(jq -r '.mergedAt' <<<"$pr_json") || return 1
  issue_closed_at=$(jq -r '.closedAt' <<<"$issue_json") || return 1
  if ! jq -e \
    --argjson pr "$pr_number" \
    --arg branch "$branch_name" \
    --arg pr_merged_at "$pr_merged_at" \
    --arg issue_closed_at "$issue_closed_at" \
    'any((.closedByPullRequestsReferences // [])[]?;
       .number == $pr)
     or any((.comments // [])[]?;
       (.authorAssociation // "") as $association
       | (.body // "") as $body
       | (.createdAt // "") as $created_at
       | ((["OWNER", "MEMBER", "COLLABORATOR"]
             | index($association)) != null)
         and ($created_at >= $pr_merged_at)
         and ($created_at <= $issue_closed_at)
         and (
           $body == ("Integrated via PR #" + ($pr | tostring)
             + " into PRD integration branch."
             + " (Ralph explicit closure for non-default-base PR.)")
           or $body == ("Merged via PR #" + ($pr | tostring)
             + " into `" + $branch + "`.")
         ))' \
    <<<"$issue_json" >/dev/null 2>&1; then
    echo "ERROR: Issue #$issue lacks canonical closure provenance for PR #$pr_number" >&2
    return 1
  fi

  local merge_commit
  merge_commit=$(jq -r '.mergeCommit.oid' <<<"$pr_json") || return 1
  if [[ "$merge_commit" != "$remote_tip" ]]; then
    echo "ERROR: PR #$pr_number merge commit '$merge_commit' does not equal remote tip '$remote_tip'" >&2
    return 1
  fi
  branch_prs=$(gh pr list --repo "$repo" --state all --head "$branch_name" \
    --json number) || {
    echo "ERROR: Could not inspect branch pull requests for '$branch_name'" >&2
    return 1
  }
  if ! jq -e 'type == "array" and length == 0' <<<"$branch_prs" >/dev/null 2>&1; then
    echo "ERROR: Integration branch '$branch_name' has a branch PR" >&2
    return 1
  fi
  open_prs=$(gh api --paginate --slurp \
    -H "Accept: application/vnd.github+json" \
    "repos/$repo/pulls?state=open&per_page=100") || {
    echo "ERROR: Could not inspect conflicting open pull requests" >&2
    return 1
  }
  if ! jq -e '
    type == "array"
    and all(.[]; type == "array")
    and all(.[][];
      type == "object"
      and (.number | type == "number")
      and .number > 0
      and (.base.ref | type == "string" and length > 0)
      and (.head.ref | type == "string" and length > 0)
      and (.body == null or (.body | type == "string")))
  ' <<<"$open_prs" >/dev/null 2>&1; then
    echo "ERROR: Could not validate conflicting open pull requests" >&2
    return 1
  fi
  if ! jq -e \
    --arg issue "$issue" \
    --arg head_prefix "${configured_prefix}${issue}-" '
    all(.[][];
      (((.body // "")
          | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s+#" + $issue + "\\b"))
        or ((.head.ref // "")
          | startswith($head_prefix)))
        | not)
  ' <<<"$open_prs" >/dev/null 2>&1; then
    echo "ERROR: Issue #$issue has another open delivery PR" >&2
    return 1
  fi

  local current_pr current_commit current_integrated_at
  current_pr=$(jq -r --arg issue "$issue" '.items[$issue].pr_number // empty' \
    "$status_file") || return 1
  current_commit=$(jq -r --arg issue "$issue" '.items[$issue].integrated_commit // empty' \
    "$status_file") || return 1
  current_integrated_at=$(jq -r --arg issue "$issue" '.items[$issue].integrated_at // empty' \
    "$status_file") || return 1
  if [[ "$item_status" == "slice-integrated" ]]; then
    if [[ "$current_pr" != "$pr_number" || "$current_commit" != "$merge_commit" \
      || -z "$current_integrated_at" ]] \
      || ! jq -e \
        --arg issue "$issue" \
        --arg pr "$pr_number" \
        --arg commit "$merge_commit" \
        '(.items[$issue]) as $item
         | $item == {
             status:"slice-integrated",
             pr_number:$pr,
             integrated_commit:$commit,
             integrated_at:$item.integrated_at,
             workerId:null,
             pid:null,
             logFile:null,
             startedAt:null,
             error:null
           }
         and ($item.integrated_at | type == "string" and length > 0)' \
        "$status_file" >/dev/null 2>&1; then
      echo "ERROR: Existing slice-integrated evidence conflicts with requested provenance" >&2
      return 1
    fi
    echo "Issue #$issue already has canonical slice-integrated evidence for PR #$pr_number at $merge_commit."
    return 0
  fi

  state_lock || return 1
  local locked_status
  locked_status=$(jq -r --arg issue "$issue" '.items[$issue].status // empty' \
    "$status_file" 2>/dev/null) || {
    state_unlock
    return 1
  }
  if [[ "$locked_status" != "merged" ]] \
    || ! jq -e '((.claims // {}) | type == "object" and length == 0)' \
      "$STATE_FILE" >/dev/null 2>&1 \
    || prd_run_has_live_worker "$run_id"; then
    state_unlock
    echo "ERROR: Reconciliation evidence changed or became active before mutation" >&2
    return 1
  fi
  local rechecked_tip rechecked_rc=0
  rechecked_tip=$(prd_remote_branch_tip "$remote" "$branch_name") || rechecked_rc=$?
  if [[ "$rechecked_rc" -ne 0 || "$rechecked_tip" != "$merge_commit" ]]; then
    state_unlock
    echo "ERROR: Remote branch '$remote/$branch_name' moved before reconciliation" >&2
    return 1
  fi
  if ! record_slice_integrated "$issue" "$pr_number" "$merge_commit" "$run_id"; then
    state_unlock
    echo "ERROR: Failed to record canonical slice-integrated evidence" >&2
    return 1
  fi
  state_unlock

  echo "Reconciled issue #$issue in run '$run_id' from PR #$pr_number at $merge_commit."
}

# close_slice_issue ISSUE_NUMBER PR_NUMBER REPO
# Explicitly closes a slice issue after integration.
# Required because GitHub doesn't auto-close from non-default-branch PRs.
#
# Args:
#   ISSUE_NUMBER — slice issue number
#   PR_NUMBER    — pull request number
#   REPO         — repository in owner/repo format
#
# Returns: 0 on success, 1 on failure
close_slice_issue() {
  local issue="$1"
  local pr_number="$2"
  local repo="$3"
  
  local comment
  comment="Integrated via PR #$pr_number into PRD integration branch. (Ralph explicit closure for non-default-base PR.)"
  
  gh issue close "$issue" --repo "$repo" --reason completed --comment "$comment"
}

# is_slice_dependency_satisfied BLOCKER_ISSUE_NUMBER DEPENDENT_RUN_ID
# Checks if a slice dependency is satisfied.
# For same-PRD dependencies: satisfied when blocker is slice-integrated.
# For cross-PRD dependencies: satisfied when blocker's PRD is delivered to main.
#
# Args:
#   BLOCKER_ISSUE_NUMBER — issue number of the blocking slice
#   DEPENDENT_RUN_ID     — run ID of the dependent slice
#
# Returns: 0 if satisfied, 1 otherwise
is_slice_dependency_satisfied() {
  local blocker_issue="$1"
  local dependent_run_id="$2"
  
  # Find the run that owns the blocker issue
  local blocker_run_id
  blocker_run_id=$(find_run_for_issue "$blocker_issue")
  [[ -z "$blocker_run_id" ]] && return 1
  
  # Get PRD numbers for both runs
  local blocker_prd dependent_prd
  blocker_prd=$(get_run_prd_number "$blocker_run_id")
  dependent_prd=$(get_run_prd_number "$dependent_run_id")
  
  if [[ "$blocker_prd" == "$dependent_prd" && -n "$blocker_prd" ]]; then
    # Same PRD: check if blocker is integrated
    local blocker_status
    blocker_status=$(status_load_item "$blocker_issue" "status" "$blocker_run_id")
    [[ "$blocker_status" == "slice-integrated" ]] && return 0
    return 1
  else
    # Cross-PRD or non-PRD: require delivery to main (not implemented yet)
    # For now, return false
    return 1
  fi
}

# find_run_for_issue ISSUE_NUMBER
# Finds the run ID that contains the given issue in its queue.
#
# Args:
#   ISSUE_NUMBER — issue number to find
#
# Outputs: run ID or empty string
find_run_for_issue() {
  local issue="$1"
  
  # Search all run status files for this issue
  local run_dir status_file run_id
  for status_file in "$STATE_DIR/runs"/*/status.json; do
    [[ -f "$status_file" ]] || continue
    if jq -e ".items[\"$issue\"] // false" "$status_file" >/dev/null 2>&1; then
      run_dir=$(dirname "$status_file")
      run_id=$(basename "$run_dir")
      echo "$run_id"
      return 0
    fi
  done
  
  return 1
}

# get_run_prd_number RUN_ID
# Returns the PRD number for the given run, or empty string for non-PRD runs.
#
# Args:
#   RUN_ID — run identifier
#
# Outputs: PRD number or empty string
get_run_prd_number() {
  local run_id="$1"
  
  local ownership_file="$STATE_DIR/runs/$run_id/ownership.json"
  if [[ -f "$ownership_file" ]]; then
    jq -r '.prd_number // empty' "$ownership_file" 2>/dev/null || true
  fi
}
