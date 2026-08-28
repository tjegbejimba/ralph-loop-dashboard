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

# record_slice_integrated ISSUE_NUMBER PR_NUMBER COMMIT_SHA [RUN_ID] [RECONCILIATION_JSON]
# Records that a slice has been integrated into the PRD branch.
# Atomically replaces its status item with canonical integration evidence.
#
# Args:
#   ISSUE_NUMBER — slice issue number
#   PR_NUMBER    — pull request number
#   COMMIT_SHA   — merge commit SHA
#   RUN_ID       — run identifier (optional, uses $RUN_ID if not provided)
#   RECONCILIATION_JSON — optional guarded-recovery provenance object
#
# Returns: 0 on success, 1 on failure
record_slice_integrated() {
  local issue="$1"
  local pr_number="$2"
  local commit_sha="$3"
  local run_id="${4:-$RUN_ID}"
  local reconciliation_json="${5:-null}"

  if ! printf '%s\n' "$reconciliation_json" \
    | jq -e 'type == "object" or . == null' >/dev/null 2>&1; then
    echo "ERROR: Slice integration reconciliation provenance must be an object" >&2
    return 1
  fi
  
  local file timestamp
  file=$(status_file "$run_id")
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp
  tmp=$(status_mktemp "$run_id") || return 1
  
  [[ ! -f "$file" ]] && printf '%s\n' '{"items":{}}' >"$file"
  
  jq --arg issue "$issue" \
     --arg pr "$pr_number" \
     --arg commit "$commit_sha" \
     --arg timestamp "$timestamp" \
     --argjson reconciliation "$reconciliation_json" '
    .items[$issue] = (
      {
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
      + if $reconciliation == null then {}
        else {
          reconciliation: (
            $reconciliation + {applied_at: $timestamp}
          )
        }
        end
    )
  ' "$file" >"$tmp" && mv "$tmp" "$file" || {
    rm -f "$tmp"
    return 1
  }
}

# close_slice_issue ISSUE_NUMBER PR_NUMBER REPO INTEGRATION_BRANCH
# Explicitly closes a slice issue after integration.
# Required because GitHub doesn't auto-close from non-default-branch PRs.
#
# Args:
#   ISSUE_NUMBER — slice issue number
#   PR_NUMBER    — pull request number
#   REPO         — repository in owner/repo format
#   INTEGRATION_BRANCH — exact owned non-default PRD branch
#
# Returns: 0 on success, 1 on failure
close_slice_issue() {
  local issue="$1"
  local pr_number="$2"
  local repo="$3"
  local integration_branch="$4"

  if [[ -z "$integration_branch" \
    || "$integration_branch" == *'`'* \
    || "$integration_branch" == *$'\r'* \
    || "$integration_branch" == *$'\n'* ]]; then
    return 1
  fi
  
  local comment
  comment="Merged via PR #$pr_number into \`$integration_branch\`."
  
  gh issue close "$issue" --repo "$repo" --reason completed --comment "$comment"
}

# close_and_record_slice_integration ISSUE_NUMBER PR_NUMBER MERGE_COMMIT RUN_ID REPO INTEGRATION_BRANCH
# Closes the issue first, then records canonical local evidence under the state lock.
close_and_record_slice_integration() {
  local issue="$1"
  local pr_number="$2"
  local merge_commit="$3"
  local run_id="$4"
  local repo="$5"
  local integration_branch="$6"

  close_slice_issue \
    "$issue" "$pr_number" "$repo" "$integration_branch" || return 1
  state_lock || return 1

  local result=0
  record_slice_integrated \
    "$issue" "$pr_number" "$merge_commit" "$run_id" || result=1
  state_unlock || result=1
  return "$result"
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
