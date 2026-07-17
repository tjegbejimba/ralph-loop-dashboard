#!/usr/bin/env bash
# prd-branch.sh — PRD integration branch ownership and lifecycle management.
#
# Provides functions for creating, verifying, and resuming PRD integration branches
# with durable ownership records to support safe concurrent execution.
#
# This file is sourced by ralph.sh. Functions assume:
#   $STATE_DIR  — directory holding .ralph/state.json and runs/
#   $STATE_FILE — path to .ralph/state.json

# resolve_prd_branch_name PRD_NUMBER PRD_TITLE [TEMPLATE]
# Resolves the PRD integration branch name using the configured template.
# Default template: ralph/prd/{feature-slug}-{prd_number}
#
# Args:
#   PRD_NUMBER — GitHub issue number for the PRD
#   PRD_TITLE  — GitHub issue title for the PRD
#   TEMPLATE   — optional branch name template (uses default if empty)
#
# Template placeholders:
#   {prd_number}    — replaced with PRD_NUMBER
#   {feature-slug}  — replaced with slugified PRD_TITLE
#
# Outputs: resolved branch name
resolve_prd_branch_name() {
  local prd_number="$1"
  local prd_title="$2"
  local template="$3"
  
  # Use default template if not provided
  if [[ -z "$template" ]]; then
    template="ralph/prd/{feature-slug}-{prd_number}"
  fi
  
  # Slugify the title: lowercase, replace spaces/special chars with hyphens, collapse multiple hyphens
  local slug
  slug=$(echo "$prd_title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g')
  
  # Replace template placeholders
  local result="$template"
  result="${result//\{feature-slug\}/$slug}"
  result="${result//\{prd_number\}/$prd_number}"
  
  echo "$result"
}

# create_prd_ownership_record RUN_ID PRD_NUMBER BRANCH_NAME REMOTE DELIVERY_BRANCH BASE_SHA
# Creates a durable ownership record for a PRD integration branch.
# Record is stored at .ralph/runs/$RUN_ID/ownership.json
#
# Args:
#   RUN_ID          — unique run identifier
#   PRD_NUMBER      — GitHub issue number for the PRD
#   BRANCH_NAME     — resolved integration branch name
#   REMOTE          — Git remote name (e.g., "origin")
#   DELIVERY_BRANCH — target branch for final delivery (e.g., "main")
#   BASE_SHA        — initial base commit SHA
#
# Returns: 0 on success, 1 on failure
create_prd_ownership_record() {
  local run_id="$1"
  local prd_number="$2"
  local branch_name="$3"
  local remote="$4"
  local delivery_branch="$5"
  local base_sha="$6"
  
  local run_dir="$STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir" || return 1
  
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  cat > "$run_dir/ownership.json" <<EOF
{
  "run_id": "$run_id",
  "prd_number": "$prd_number",
  "branch_name": "$branch_name",
  "remote": "$remote",
  "delivery_branch": "$delivery_branch",
  "initial_base_sha": "$base_sha",
  "created_at": "$timestamp"
}
EOF
  
  [[ $? -eq 0 ]]
}

# verify_prd_ownership RUN_ID BRANCH_NAME
# Verifies that the given run owns the given branch.
#
# Args:
#   RUN_ID      — unique run identifier
#   BRANCH_NAME — branch name to verify
#
# Returns: 0 if ownership is verified, 1 otherwise
verify_prd_ownership() {
  local run_id="$1"
  local branch_name="$2"
  
  local ownership_file="$STATE_DIR/runs/$run_id/ownership.json"
  [[ -f "$ownership_file" ]] || return 1
  
  local stored_branch
  stored_branch=$(jq -r '.branch_name' "$ownership_file" 2>/dev/null) || return 1
  
  [[ "$stored_branch" == "$branch_name" ]]
}

# create_prd_branch RUN_ID PRD_NUMBER PRD_TITLE REMOTE DELIVERY_BRANCH [TEMPLATE]
# Creates a PRD integration branch from the latest remote delivery branch.
# Atomically records ownership before creating the branch.
#
# Args:
#   RUN_ID          — unique run identifier
#   PRD_NUMBER      — GitHub issue number for the PRD
#   PRD_TITLE       — GitHub issue title
#   REMOTE          — Git remote name
#   DELIVERY_BRANCH — base branch to create from
#   TEMPLATE        — optional branch name template
#
# Returns: 0 on success, 1 on failure
create_prd_branch() {
  local run_id="$1"
  local prd_number="$2"
  local prd_title="$3"
  local remote="$4"
  local delivery_branch="$5"
  local template="${6:-}"
  
  # Resolve branch name
  local branch_name
  branch_name=$(resolve_prd_branch_name "$prd_number" "$prd_title" "$template")
  
  # Check if branch already exists
  if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    # Branch exists - check if we own it
    if ! verify_prd_ownership "$run_id" "$branch_name"; then
      echo "ERROR: Branch '$branch_name' already exists but is not owned by run '$run_id'" >&2
      return 1
    fi
    # We own it, safe to proceed
    return 0
  fi
  
  # Fetch latest remote
  git fetch "$remote" "$delivery_branch" >/dev/null 2>&1 || {
    echo "ERROR: Failed to fetch $remote/$delivery_branch" >&2
    return 1
  }
  
  # Get remote SHA
  local remote_sha
  remote_sha=$(git rev-parse "$remote/$delivery_branch") || {
    echo "ERROR: Failed to resolve $remote/$delivery_branch" >&2
    return 1
  }
  
  # Create ownership record atomically before creating branch
  create_prd_ownership_record "$run_id" "$prd_number" "$branch_name" "$remote" "$delivery_branch" "$remote_sha" || {
    echo "ERROR: Failed to create ownership record" >&2
    return 1
  }
  
  # Create the branch
  git branch "$branch_name" "$remote_sha" >/dev/null 2>&1 || {
    echo "ERROR: Failed to create branch '$branch_name'" >&2
    # Clean up ownership record on failure
    rm -f "$STATE_DIR/runs/$run_id/ownership.json"
    return 1
  }
  
  return 0
}

# can_resume_prd_branch RUN_ID BRANCH_NAME
# Checks if a PRD branch can be safely resumed by verifying ownership.
#
# Args:
#   RUN_ID      — unique run identifier
#   BRANCH_NAME — branch name to resume
#
# Returns: 0 if resumption is safe, 1 otherwise
can_resume_prd_branch() {
  local run_id="$1"
  local branch_name="$2"
  
  # Must have ownership record
  verify_prd_ownership "$run_id" "$branch_name"
}

# can_start_prd PRD_NUMBER
# Checks if a new PRD can be started (one-active-PRD guard).
# Enforces that only one PRD can be active per repository.
#
# Args:
#   PRD_NUMBER — GitHub issue number for the PRD to start
#
# Returns: 0 if PRD can start, 1 if blocked by another active PRD
can_start_prd() {
  local prd_number="$1"
  
  [[ -f "$STATE_FILE" ]] || {
    echo "{}" > "$STATE_FILE"
    return 0
  }
  
  local active_prd
  active_prd=$(jq -r '.active_prd // empty' "$STATE_FILE" 2>/dev/null)
  
  # No active PRD, can start
  [[ -z "$active_prd" ]] && return 0
  
  # Another PRD is active
  echo "ERROR: Cannot start PRD #$prd_number: PRD #$active_prd is already active" >&2
  return 1
}
