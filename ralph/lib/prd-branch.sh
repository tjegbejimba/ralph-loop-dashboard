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
    '.run_id == $run_id
     and .branch_name == $branch_name
     and .retired_at == null' \
    "$ownership_file" >/dev/null 2>&1
}

# prd_run_is_terminal RUN_ID
# Proves that every queued item in a prior run has a terminal status.
prd_run_is_terminal() {
  local run_id="$1"
  local run_dir="$STATE_DIR/runs/$run_id"
  local queue_file="$run_dir/queue.json"
  local status_file="$run_dir/status.json"

  [[ -f "$queue_file" && -f "$status_file" ]] || return 1
  jq -e -s --slurpfile status_doc "$status_file" '
    length == 1
    and (.[0] | type == "array")
    and (.[0] | length > 0)
    and ($status_doc | length == 1)
    and ($status_doc[0] | type == "object")
    and ($status_doc[0].items | type == "object")
    and all($status_doc[0].items[];
     type == "object"
     and (.pid == null
       or ((.pid | type) == "number" and .pid > 0 and .pid == (.pid | floor)))
     and ((.status // "") as $item_status
       | (["merged", "slice-integrated", "failed", "skipped", "rejected"]
         | index($item_status)) != null)
    )
    and all(.[0][];
     (.number | tostring) as $number
     | ($status_doc[0].items[$number].status // "") as $item_status
     | (["merged", "slice-integrated", "failed", "skipped", "rejected"]
        | index($item_status)) != null
    )
  ' "$queue_file" >/dev/null 2>&1
}

# prd_pid_is_live_ralph PID
# Conservatively verifies a recorded Ralph PID across supported shells.
prd_pid_is_live_ralph() {
  local pid="$1"
  if is_pid_alive_and_ralph "$pid"; then
    return 0
  fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # Git Bash ps cannot expose command lines. Treat any still-live recorded
      # PID as active rather than risk deleting a branch under a worker.
      is_pid_alive "$pid"
      ;;
    *)
      return 1
      ;;
  esac
}

# prd_run_has_live_worker RUN_ID
# Returns 0 when a prior run status still references a live Ralph process.
prd_run_has_live_worker() {
  local run_id="$1"
  local status_file="$STATE_DIR/runs/$run_id/status.json"
  local pids pid

  pids=$(jq -r '.items[] | .pid // empty' "$status_file") || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if prd_pid_is_live_ralph "$pid"; then
     return 0
    fi
  done <<<"$pids"
  return 1
}

# prd_state_has_live_claim
# Returns 0 when state.json contains a claim backed by a live Ralph process.
prd_state_has_live_claim() {
  [[ -f "$STATE_FILE" ]] || return 1

  local pids pid
  pids=$(jq -r '
    if type == "object" and ((.claims // {}) | type == "object")
      and all((.claims // {})[]; (.pid | type == "number") and .pid > 0)
    then (.claims // {} | .[] | .pid // empty)
    else error("invalid state")
    end
  ' "$STATE_FILE" 2>/dev/null) || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if prd_pid_is_live_ralph "$pid"; then
     return 0
    fi
  done <<<"$pids"
  return 1
}

# prd_branch_worktree BRANCH_NAME
# Prints the worktree path using BRANCH_NAME, if any.
prd_branch_worktree() {
  local branch_name="$1"
  local worktrees
  worktrees=$(git worktree list --porcelain) || return 2
  printf '%s\n' "$worktrees" | awk -v branch="refs/heads/$branch_name" '
    $1 == "worktree" { path=substr($0, 10) }
    $1 == "branch" && $2 == branch { print path; exit }
  '
}

# prd_validate_ownership_records
# Refuses recovery if any ownership record is malformed, before any mutation.
prd_validate_ownership_records() {
  local ownership_file
  shopt -s nullglob
  for ownership_file in "$STATE_DIR/runs/"*/ownership.json; do
    if ! jq -e -s '
      length == 1
      and (.[0] | type == "object")
      and (.[0].run_id | type == "string" and length > 0)
      and (.[0].prd_number | type == "string" and test("^[1-9][0-9]*$"))
      and (.[0].branch_name | type == "string" and length > 0)
      and (.[0].remote | type == "string" and length > 0)
      and (.[0].delivery_branch | type == "string" and length > 0)
      and (.[0].initial_base_sha | type == "string" and length > 0)
      and (.[0].retired_at == null or (.[0].retired_at | type == "string"))
    ' "$ownership_file" >/dev/null 2>&1; then
      shopt -u nullglob
      echo "ERROR: Could not validate PRD ownership evidence at '$ownership_file'" >&2
      return 1
    fi
  done
  shopt -u nullglob
}

# prd_active_ownership_files BRANCH_NAME
# Prints non-retired ownership files for BRANCH_NAME.
prd_active_ownership_files() {
  local branch_name="$1"
  local ownership_file
  shopt -s nullglob
  for ownership_file in "$STATE_DIR/runs/"*/ownership.json; do
    if jq -e \
     --arg branch_name "$branch_name" \
     '.branch_name == $branch_name and .retired_at == null' \
     "$ownership_file" >/dev/null 2>&1; then
     printf '%s\n' "$ownership_file"
    fi
  done
  shopt -u nullglob
}

# retire_owned_prd_branch OWNER_RUN_ID RETIRED_BY_RUN_ID
# Retires a stale local PRD branch only after every safety predicate is proven.
retire_owned_prd_branch() {
  local owner_run_id="$1"
  local retired_by_run_id="$2"
  local ownership_file="$STATE_DIR/runs/$owner_run_id/ownership.json"

  if ! [[ "$owner_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
    && "$retired_by_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: Invalid run identity for PRD branch retirement" >&2
    return 1
  fi
  prd_validate_ownership_records || return 1
  if [[ ! -f "$ownership_file" ]]; then
    echo "ERROR: Missing ownership evidence for run '$owner_run_id'" >&2
    return 1
  fi
  if ! jq -e \
    --arg run_id "$owner_run_id" \
    '.run_id == $run_id
    and (.prd_number | type == "string" and length > 0)
    and (.branch_name | type == "string" and length > 0)
    and (.remote | type == "string" and length > 0)
    and (.delivery_branch | type == "string" and length > 0)
    and (.initial_base_sha | type == "string" and length > 0)
    and .retired_at == null' \
    "$ownership_file" >/dev/null 2>&1; then
    echo "ERROR: Ownership evidence for run '$owner_run_id' is invalid or already retired" >&2
    return 1
  fi

  local prd_number branch_name remote frozen_base
  prd_number=$(jq -r '.prd_number' "$ownership_file")
  branch_name=$(jq -r '.branch_name' "$ownership_file")
  remote=$(jq -r '.remote' "$ownership_file")
  frozen_base=$(jq -r '.initial_base_sha' "$ownership_file")

  if ! [[ "$prd_number" =~ ^[1-9][0-9]*$ \
    && "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ \
    && "$frozen_base" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] \
    || ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Ownership evidence for run '$owner_run_id' contains invalid identifiers" >&2
    return 1
  fi

  local owner_files=()
  while IFS= read -r owner_file; do
    [[ -n "$owner_file" ]] && owner_files+=("$owner_file")
  done < <(prd_active_ownership_files "$branch_name")
  if [[ ${#owner_files[@]} -ne 1 || "${owner_files[0]}" != "$ownership_file" ]]; then
    echo "ERROR: Branch '$branch_name' does not have exactly one active ownership record" >&2
    return 1
  fi

  if ! prd_run_is_terminal "$owner_run_id"; then
    echo "ERROR: Run '$owner_run_id' is not terminal; refusing to retire '$branch_name'" >&2
    return 1
  fi
  if prd_run_has_live_worker "$owner_run_id"; then
    echo "ERROR: Run '$owner_run_id' still has a live worker; refusing to retire '$branch_name'" >&2
    return 1
  fi
  if prd_state_has_live_claim; then
    echo "ERROR: Repository still has a live claim; refusing to retire '$branch_name'" >&2
    return 1
  fi

  local worktree_path worktree_rc=0
  worktree_path=$(prd_branch_worktree "$branch_name") || worktree_rc=$?
  if [[ "$worktree_rc" -ne 0 ]]; then
    echo "ERROR: Could not inspect worktrees for '$branch_name'" >&2
    return 1
  fi
  if [[ -n "$worktree_path" ]]; then
    echo "ERROR: Branch '$branch_name' is checked out by a worktree at '$worktree_path'" >&2
    return 1
  fi

  local pr_json
  if ! pr_json=$("$GH" pr list --repo "$REPO" --state all --head "$branch_name" --json number); then
    echo "ERROR: Ralph could not verify pull requests for '$branch_name'" >&2
    return 1
  fi
  if ! printf '%s\n' "$pr_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "ERROR: Ralph could not verify pull requests for '$branch_name': invalid response" >&2
    return 1
  fi
  if [[ "$(printf '%s\n' "$pr_json" | jq 'length')" -ne 0 ]]; then
    echo "ERROR: Branch '$branch_name' still has a pull request; refusing retirement" >&2
    return 1
  fi

  local remote_branch_rc=0
  git ls-remote --exit-code --heads "$remote" "refs/heads/$branch_name" \
    >/dev/null 2>&1 || remote_branch_rc=$?
  if [[ "$remote_branch_rc" -eq 0 ]]; then
    echo "ERROR: Branch '$branch_name' still exists on remote '$remote'; refusing retirement" >&2
    return 1
  elif [[ "$remote_branch_rc" -ne 2 ]]; then
    echo "ERROR: Could not verify remote branch '$remote/$branch_name'" >&2
    return 1
  fi

  local branch_present=0 branch_tip=""
  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    branch_present=1
    branch_tip=$(git rev-parse "refs/heads/$branch_name") || return 1
  fi
  if ! git cat-file -e "${frozen_base}^{commit}" 2>/dev/null; then
    echo "ERROR: Frozen base '$frozen_base' for run '$owner_run_id' is unavailable" >&2
    return 1
  fi
  if [[ "$branch_present" -eq 1 && "$branch_tip" != "$frozen_base" ]]; then
    echo "ERROR: Branch '$branch_name' contains delivery beyond frozen base '$frozen_base'; refusing retirement" >&2
    return 1
  fi

  # Recheck state under the worker state lock, then commit ownership, ref, and
  # active-run retirement without exposing a partially-cleared active guard.
  state_lock || return 1
  if ! prd_run_is_terminal "$owner_run_id" \
    || prd_run_has_live_worker "$owner_run_id" \
    || prd_state_has_live_claim; then
    state_unlock
    echo "ERROR: Run '$owner_run_id' became active during retirement; refusing '$branch_name'" >&2
    return 1
  fi

  local active_run="" active_prd=""
  if [[ -f "$STATE_FILE" ]]; then
    active_run=$(jq -r '.active_run_id // empty' "$STATE_FILE" 2>/dev/null) || {
      state_unlock
      return 1
    }
    active_prd=$(jq -r '.active_prd // empty' "$STATE_FILE" 2>/dev/null) || {
      state_unlock
      return 1
    }
    if [[ -n "$active_run" \
      && ("$active_run" != "$owner_run_id" || "$active_prd" != "$prd_number") ]]; then
      state_unlock
      echo "ERROR: Repository records a different active PRD run '$active_run'; refusing stale branch retirement" >&2
      return 1
    fi
  fi

  local timestamp tmp state_tmp=""
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp=$(mktemp "$(dirname "$ownership_file")/.ownership-retired.XXXXXX") || {
    state_unlock
    return 1
  }
  if ! jq \
    --arg retired_at "$timestamp" \
    --arg retired_by_run_id "$retired_by_run_id" \
    '.retired_at = $retired_at
    | .retired_by_run_id = $retired_by_run_id
    | .retirement_reason = "terminal stale PRD integration branch"' \
    "$ownership_file" >"$tmp"; then
    rm -f "$tmp"
    state_unlock
    return 1
  fi

  if [[ "$branch_present" -eq 1 ]] \
    && ! git update-ref -d "refs/heads/$branch_name" "$branch_tip"; then
    rm -f "$tmp"
    state_unlock
    echo "ERROR: Branch '$branch_name' changed during retirement; ownership was preserved" >&2
    return 1
  fi

  if [[ "$active_run" == "$owner_run_id" ]]; then
    state_tmp=$(state_mktemp) || true
    if [[ -z "$state_tmp" ]] \
      || ! jq 'del(.active_prd, .active_run_id)' "$STATE_FILE" >"$state_tmp" \
      || ! mv "$state_tmp" "$STATE_FILE"; then
      rm -f "$state_tmp"
      rm -f "$tmp"
      state_unlock
      echo "ERROR: Failed to clear terminal PRD activation; branchless ownership remains recoverable" >&2
      return 1
    fi
  fi

  if ! mv "$tmp" "$ownership_file"; then
    rm -f "$tmp"
    state_unlock
    echo "ERROR: Failed to record branch retirement; branchless ownership remains recoverable" >&2
    return 1
  fi

  state_unlock
  echo "Retired terminal stale PRD integration branch '$branch_name' from run '$owner_run_id'."
}

# recover_stale_prd_branch NEW_RUN_ID PRD_NUMBER BRANCH_NAME REMOTE DELIVERY_BRANCH
# Recovers only a same-PRD, same-repository branch owned by one terminal run.
recover_stale_prd_branch() {
  local new_run_id="$1"
  local prd_number="$2"
  local branch_name="$3"
  local remote="$4"
  local delivery_branch="$5"

  prd_validate_ownership_records || return 1

  local owner_files=()
  while IFS= read -r owner_file; do
    [[ -n "$owner_file" ]] && owner_files+=("$owner_file")
  done < <(prd_active_ownership_files "$branch_name")
  if [[ ${#owner_files[@]} -eq 0 ]]; then
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      echo "ERROR: Existing branch '$branch_name' has unprovable ownership" >&2
      return 1
    fi
    return 0
  fi
  if [[ ${#owner_files[@]} -ne 1 ]]; then
    echo "ERROR: Existing branch '$branch_name' has unprovable or ambiguous ownership" >&2
    return 1
  fi

  local owner_file="${owner_files[0]}"
  local owner_run_id
  owner_run_id=$(jq -r '.run_id' "$owner_file")
  if [[ "$owner_run_id" == "$new_run_id" ]]; then
    if verify_prd_ownership "$new_run_id" "$branch_name"; then
      return 0
    fi
    echo "ERROR: Current run '$new_run_id' has invalid ownership for '$branch_name'" >&2
    return 1
  fi

  if ! jq -e \
    --arg prd_number "$prd_number" \
    --arg remote "$remote" \
    --arg delivery_branch "$delivery_branch" \
    '.prd_number == $prd_number
    and .remote == $remote
    and .delivery_branch == $delivery_branch' \
    "$owner_file" >/dev/null 2>&1; then
    echo "ERROR: Existing branch '$branch_name' belongs to different PRD or repository settings" >&2
    return 1
  fi

  retire_owned_prd_branch "$owner_run_id" "$new_run_id"
}

# cleanup_stale_prd_branches
# Retires every locally-present PRD branch whose ownership passes all gates.
cleanup_stale_prd_branches() {
  local ownership_file branch_name run_id failed=0
  prd_validate_ownership_records || return 1
  shopt -s nullglob
  for ownership_file in "$STATE_DIR/runs/"*/ownership.json; do
    if ! branch_name=$(jq -r '
     if type == "object" and .retired_at == null
     then .branch_name // empty
     else empty
     end
    ' "$ownership_file" 2>/dev/null); then
     echo "ERROR: Could not inspect PRD ownership evidence at '$ownership_file'" >&2
     failed=1
     continue
    fi
    [[ -n "$branch_name" ]] || continue
    run_id=$(jq -r '.run_id // empty' "$ownership_file" 2>/dev/null)
    if [[ -z "$run_id" ]] || ! retire_owned_prd_branch "$run_id" "cleanup"; then
     failed=1
    fi
  done
  shopt -u nullglob
  [[ "$failed" -eq 0 ]]
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
       and (.initial_base_sha | type == "string" and length > 0)
       and .retired_at == null' \
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
