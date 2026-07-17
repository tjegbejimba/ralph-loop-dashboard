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

  if ! [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: Invalid run ID '$run_id'" >&2
    return 1
  fi
  if ! [[ "$prd_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid PRD number '$prd_number'" >&2
    return 1
  fi

  local run_dir="$STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir" || return 1

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local ownership_file="$run_dir/ownership.json"
  local tmp
  tmp=$(mktemp "$run_dir/.ownership.XXXXXX") || return 1
  if ! jq -n \
    --arg run_id "$run_id" \
    --arg prd_number "$prd_number" \
    --arg branch_name "$branch_name" \
    --arg remote "$remote" \
    --arg delivery_branch "$delivery_branch" \
    --arg initial_base_sha "$base_sha" \
    --arg created_at "$timestamp" \
    '{
      run_id: $run_id,
      prd_number: $prd_number,
      branch_name: $branch_name,
      remote: $remote,
      delivery_branch: $delivery_branch,
      initial_base_sha: $initial_base_sha,
      created_at: $created_at
    }' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$ownership_file"; then
    rm -f "$tmp"
    return 1
  fi
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
  
  jq -e \
    --arg run_id "$run_id" \
    --arg branch_name "$branch_name" \
    '.run_id == $run_id and .branch_name == $branch_name' \
    "$ownership_file" >/dev/null 2>&1
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
  
  local ownership_file="$STATE_DIR/runs/$run_id/ownership.json"
  local branch_name frozen_base=""
  local has_ownership=0

  if [[ -f "$ownership_file" ]]; then
    has_ownership=1
    if ! jq -e \
      --arg run_id "$run_id" \
      --arg prd_number "$prd_number" \
      --arg remote "$remote" \
      --arg delivery_branch "$delivery_branch" \
      '.run_id == $run_id
       and .prd_number == $prd_number
       and .remote == $remote
       and .delivery_branch == $delivery_branch
       and (.branch_name | type == "string" and length > 0)
       and (.initial_base_sha | type == "string" and length > 0)' \
      "$ownership_file" >/dev/null 2>&1; then
      echo "ERROR: Ownership record for run '$run_id' conflicts with requested PRD or repository settings" >&2
      return 1
    fi
    branch_name=$(jq -r '.branch_name' "$ownership_file")
    frozen_base=$(jq -r '.initial_base_sha' "$ownership_file")
  else
    branch_name=$(resolve_prd_branch_name "$prd_number" "$prd_title" "$template")
  fi

  if ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Resolved PRD branch name is invalid: '$branch_name'" >&2
    return 1
  fi

  # Check if local branch already exists
  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    if ! verify_prd_ownership "$run_id" "$branch_name"; then
      echo "ERROR: Branch '$branch_name' already exists but is not owned by run '$run_id'" >&2
      return 1
    fi
    return 0
  fi

  local remote_branch_rc=0
  git ls-remote --exit-code --heads "$remote" "refs/heads/$branch_name" \
    >/dev/null 2>&1 || remote_branch_rc=$?
  if [[ "$remote_branch_rc" -eq 0 ]]; then
    if ! verify_prd_ownership "$run_id" "$branch_name"; then
      echo "ERROR: Remote branch '$remote/$branch_name' already exists but is not owned by run '$run_id'" >&2
      return 1
    fi
    git fetch "$remote" \
      "refs/heads/$branch_name:refs/remotes/$remote/$branch_name" >/dev/null 2>&1 || {
      echo "ERROR: Failed to fetch owned branch $remote/$branch_name" >&2
      return 1
    }
    git branch "$branch_name" "refs/remotes/$remote/$branch_name" >/dev/null 2>&1 || {
      echo "ERROR: Failed to restore owned branch '$branch_name'" >&2
      return 1
    }
    return 0
  elif [[ "$remote_branch_rc" -ne 2 ]]; then
    echo "ERROR: Failed to verify whether remote branch '$remote/$branch_name' exists" >&2
    return 1
  fi

  # Fetch latest remote and update remote-tracking ref
  git fetch "$remote" \
    "refs/heads/$delivery_branch:refs/remotes/$remote/$delivery_branch" >/dev/null 2>&1 || {
    echo "ERROR: Failed to fetch $remote/$delivery_branch" >&2
    return 1
  }

  local branch_base
  if [[ "$has_ownership" -eq 1 ]]; then
    branch_base="$frozen_base"
    if ! git cat-file -e "${branch_base}^{commit}" 2>/dev/null; then
      echo "ERROR: Frozen base '$branch_base' for run '$run_id' is unavailable" >&2
      return 1
    fi
  else
    branch_base=$(git rev-parse "refs/remotes/$remote/$delivery_branch") || {
      echo "ERROR: Failed to resolve $remote/$delivery_branch" >&2
      return 1
    }
    create_prd_ownership_record \
      "$run_id" "$prd_number" "$branch_name" "$remote" "$delivery_branch" "$branch_base" || {
      echo "ERROR: Failed to create ownership record" >&2
      return 1
    }
  fi

  git branch "$branch_name" "$branch_base" >/dev/null 2>&1 || {
    echo "ERROR: Failed to create branch '$branch_name'" >&2
    if [[ "$has_ownership" -eq 0 ]]; then
      rm -f "$ownership_file"
    fi
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
  local run_id="${2:-}"

  [[ -f "$STATE_FILE" ]] || return 0

  local active_prd active_run_id
  active_prd=$(jq -r '.active_prd // empty' "$STATE_FILE" 2>/dev/null)
  active_run_id=$(jq -r '.active_run_id // empty' "$STATE_FILE" 2>/dev/null)

  [[ -z "$active_prd" ]] && return 0
  if [[ "$active_prd" == "$prd_number" && -n "$run_id" && "$active_run_id" == "$run_id" ]]; then
    return 0
  fi

  echo "ERROR: Cannot start PRD #$prd_number: PRD #$active_prd is already active in run '$active_run_id'" >&2
  return 1
}

# activate_prd_run RUN_ID PRD_NUMBER
# Atomically records the one active PRD after its owned branch is ready.
activate_prd_run() {
  local run_id="$1"
  local prd_number="$2"
  local state_dir
  state_dir=$(dirname "$STATE_FILE")
  mkdir -p "$state_dir" || return 1

  local current="{}"
  if [[ -f "$STATE_FILE" ]]; then
    current=$(cat "$STATE_FILE") || return 1
    printf '%s\n' "$current" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  fi

  local tmp
  tmp=$(mktemp "$state_dir/.state.XXXXXX") || return 1
  if ! printf '%s\n' "$current" | jq \
    --arg prd_number "$prd_number" \
    --arg run_id "$run_id" \
    '.claims //= {}
     | .active_prd = $prd_number
     | .active_run_id = $run_id' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$STATE_FILE"; then
    rm -f "$tmp"
    return 1
  fi
}
