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

# create_prd_ownership_record RUN_ID PRD_NUMBER BRANCH_NAME REMOTE DELIVERY_BRANCH BASE_SHA [OWNED_TIP_SHA] [RESUMED_FROM_RUN_ID]
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
#   OWNED_TIP_SHA   — branch tip at ownership acquisition (defaults to BASE_SHA)
#   RESUMED_FROM_RUN_ID — prior run that transferred ownership, when applicable
#
# Returns: 0 on success, 1 on failure
create_prd_ownership_record() {
  local run_id="$1"
  local prd_number="$2"
  local branch_name="$3"
  local remote="$4"
  local delivery_branch="$5"
  local base_sha="$6"
  local owned_tip_sha="${7:-$base_sha}"
  local resumed_from_run_id="${8:-}"

  if ! [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: Invalid run ID '$run_id'" >&2
    return 1
  fi
  if ! [[ "$prd_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid PRD number '$prd_number'" >&2
    return 1
  fi
  if ! [[ "$base_sha" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ \
    && "$owned_tip_sha" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]]; then
    echo "ERROR: Invalid PRD ownership commit identity" >&2
    return 1
  fi
  if [[ -n "$resumed_from_run_id" \
    && ! "$resumed_from_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: Invalid prior run ID '$resumed_from_run_id'" >&2
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
    --arg owned_tip_sha "$owned_tip_sha" \
    --arg resumed_from_run_id "$resumed_from_run_id" \
    --arg created_at "$timestamp" \
    '{
      run_id: $run_id,
      prd_number: $prd_number,
      branch_name: $branch_name,
      remote: $remote,
      delivery_branch: $delivery_branch,
      initial_base_sha: $initial_base_sha,
      owned_tip_sha: $owned_tip_sha,
      created_at: $created_at
    }
    | if $resumed_from_run_id != ""
      then .resumed_from_run_id = $resumed_from_run_id
      else .
      end' > "$tmp"; then
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

# prd_transferred_ownership_is_proven RUN_ID BRANCH_NAME OWNED_TIP
# Proves that a run acquired this exact tip through a completed predecessor
# transfer. This permits a lagging local ref to remain untouched until the
# normal branch-setup seam compare-and-swap fast-forwards it.
prd_transferred_ownership_is_proven() {
  local run_id="$1"
  local branch_name="$2"
  local owned_tip="$3"
  local ownership_file="$STATE_DIR/runs/$run_id/ownership.json"
  local resumed_from_run_id remote delivery_branch prior_ownership_file

  if ! [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
    && "$owned_tip" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] \
    || [[ ! -f "$ownership_file" ]]; then
    return 1
  fi
  resumed_from_run_id=$(jq -r '.resumed_from_run_id // empty' "$ownership_file") \
    || return 1
  remote=$(jq -r '.remote // empty' "$ownership_file") || return 1
  delivery_branch=$(jq -r '.delivery_branch // empty' "$ownership_file") || return 1
  if ! [[ "$resumed_from_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    return 1
  fi
  prior_ownership_file="$STATE_DIR/runs/$resumed_from_run_id/ownership.json"
  [[ -f "$prior_ownership_file" ]] || return 1

  jq -e \
    --arg run_id "$run_id" \
    --arg branch_name "$branch_name" \
    --arg remote "$remote" \
    --arg delivery_branch "$delivery_branch" \
    --arg owned_tip "$owned_tip" \
    '.retired_by_run_id == $run_id
    and (.retirement_reason
      | . == "terminal PRD ownership transferred"
        or . == "zero-registration PRD ownership transferred")
    and .transferred_tip_sha == $owned_tip
    and .branch_name == $branch_name
    and .remote == $remote
    and .delivery_branch == $delivery_branch
    and .retired_at != null' \
    "$prior_ownership_file" >/dev/null 2>&1
}

# prd_remote_branch_tip REMOTE BRANCH_NAME
# Prints the exact remote branch tip. Returns 2 when the ref is absent and 1
# when remote evidence cannot be inspected unambiguously.
prd_remote_branch_tip() {
  local remote="$1"
  local branch_name="$2"
  local output
  if ! output=$(git ls-remote --heads "$remote" "refs/heads/$branch_name"); then
    return 1
  fi
  if [[ -z "$output" ]]; then
    return 2
  fi

  local count tip ref
  count=$(printf '%s\n' "$output" | awk 'NF { count++ } END { print count + 0 }')
  [[ "$count" -eq 1 ]] || return 1
  read -r tip ref <<<"$output"
  [[ "$ref" == "refs/heads/$branch_name" \
    && "$tip" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] || return 1
  printf '%s\n' "$tip"
}

# prd_publish_owned_branch REMOTE BRANCH_NAME EXPECTED_TIP
# Publishes only when the remote ref is absent, guarded by an expected-empty
# lease, then proves the resulting remote tip.
prd_publish_owned_branch() {
  local remote="$1"
  local branch_name="$2"
  local expected_tip="$3"
  local local_tip remote_tip remote_rc=0

  local_tip=$(git rev-parse "refs/heads/$branch_name") || return 1
  if [[ "$local_tip" != "$expected_tip" ]]; then
    echo "ERROR: Owned branch '$branch_name' moved from expected tip '$expected_tip'" >&2
    return 1
  fi

  remote_tip=$(prd_remote_branch_tip "$remote" "$branch_name") || remote_rc=$?
  if [[ "$remote_rc" -eq 0 ]]; then
    if [[ "$remote_tip" != "$expected_tip" ]]; then
      echo "ERROR: Remote branch '$remote/$branch_name' moved to unexpected tip '$remote_tip'" >&2
      return 1
    fi
    return 0
  elif [[ "$remote_rc" -ne 2 ]]; then
    echo "ERROR: Failed to verify whether remote branch '$remote/$branch_name' exists" >&2
    return 1
  fi

  if ! git push --atomic \
    --force-with-lease="refs/heads/$branch_name:" \
    "$remote" \
    "refs/heads/$branch_name:refs/heads/$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Failed to publish owned branch '$remote/$branch_name'" >&2
    return 1
  fi

  remote_rc=0
  remote_tip=$(prd_remote_branch_tip "$remote" "$branch_name") || remote_rc=$?
  if [[ "$remote_rc" -ne 0 || "$remote_tip" != "$expected_tip" ]]; then
    echo "ERROR: Could not prove published branch '$remote/$branch_name' at '$expected_tip'" >&2
    return 1
  fi
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

prd_git_proof() {
  GIT_NO_REPLACE_OBJECTS=1 git "$@"
}

prd_assert_unmodified_graph() {
  local repo_root common_git_dir replacement_ref shallow
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  common_git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common_git_dir" in
    /*|[A-Za-z]:/*) ;;
    *) common_git_dir="$repo_root/$common_git_dir" ;;
  esac
  common_git_dir=$(cd "$common_git_dir" 2>/dev/null && pwd -P) || return 1
  replacement_ref=$(prd_git_proof for-each-ref \
    --format='%(refname)' refs/replace 2>/dev/null) || return 1
  [[ -z "$replacement_ref" ]] || {
    echo "ERROR: Replacement refs are not permitted during PRD ownership proof" >&2
    return 1
  }
  [[ ! -e "$common_git_dir/info/grafts" ]] || {
    echo "ERROR: Legacy grafts are not permitted during PRD ownership proof" >&2
    return 1
  }
  shallow=$(prd_git_proof rev-parse --is-shallow-repository 2>/dev/null) || return 1
  [[ "$shallow" == "false" ]] || {
    echo "ERROR: Shallow history is not permitted during PRD ownership proof" >&2
    return 1
  }
}

# prd_terminal_remote_tip_is_proven RUN_ID REMOTE_TIP
# Proves that every first-parent advancement from the run-owned tip to the exact
# remote tip has one canonical Ralph or operator-guarded HITL attribution.
prd_terminal_remote_tip_is_proven() {
  local run_id="$1"
  local remote_tip="$2"
  local run_dir="$STATE_DIR/runs/$run_id"
  local ownership_file="$run_dir/ownership.json"
  local status_file="$run_dir/status.json"
  local hitl_file="$run_dir/hitl-integrations.json"
  local hitl_doc='{"schema_version":1,"records":[]}'
  local owned_tip prd_number branch commits commit attribution_count

  [[ -f "$status_file" && -f "$ownership_file" ]] || return 1
  prd_assert_unmodified_graph || return 1
  owned_tip=$(jq -r '.owned_tip_sha // empty' "$ownership_file" 2>/dev/null) || return 1
  prd_number=$(jq -r '.prd_number // empty' "$ownership_file" 2>/dev/null) || return 1
  branch=$(jq -r '.branch_name // empty' "$ownership_file" 2>/dev/null) || return 1
  [[ "$owned_tip" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] || return 1
  if [[ -f "$hitl_file" ]]; then
    hitl_doc=$(jq -cS . "$hitl_file") || return 1
  fi
  jq -e '
    type == "object"
    and (.items | type == "object")
    and all(.items[] | select(.status == "slice-integrated");
      (.integrated_commit
        | type == "string"
          and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$")))
  ' "$status_file" >/dev/null 2>&1 || return 1
  printf '%s\n' "$hitl_doc" | jq -e \
    --arg repository "$REPO" \
    --arg run "$run_id" \
    --arg prd "$prd_number" \
    --arg branch "$branch" '
    type == "object"
    and .schema_version == 1
    and (.records | type == "array")
    and all(.records[];
      type == "object"
      and .source == "operator-guarded-hitl-integration"
      and .repository == $repository
      and .run_id == $run
      and .prd_number == $prd
      and .branch == $branch
      and (.issue_number | type == "number" and . > 0)
      and (.pr_number | type == "number" and . > 0)
      and (.integrated_commit
        | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
      and (.proof_oid
        | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
      and (.proof | type == "object")
      and .proof.action == "record-hitl-slice-integrated"
      and .proof.mode == "dry-run"
      and .proof.issue.state == "CLOSED"
      and (.proof.issue.labels | type == "array")
      and (.proof.issue.labels | index("work:slice") != null)
      and (.proof.issue.labels | index("ralph:hitl") != null)
      and .proof.run_id == .run_id
      and .proof.repository == .repository
      and .proof.prd_number == .prd_number
      and .proof.issue.number == .issue_number
      and .proof.pull_request.number == .pr_number
      and .proof.pull_request.merge_commit == .integrated_commit
      and .proof.pull_request.base == .branch
      and .proof.remote.tip == .integrated_commit
      and .proof.ownership.branch == .branch)
    and ((.records | map(.issue_number) | length)
      == (.records | map(.issue_number) | unique | length))
    and ((.records | map(.pr_number) | length)
      == (.records | map(.pr_number) | unique | length))
    and ((.records | map(.integrated_commit) | length)
      == (.records | map(.integrated_commit) | unique | length))
  ' >/dev/null 2>&1 || return 1

  local record stored_oid actual_oid
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    stored_oid=$(printf '%s\n' "$record" | jq -r '.proof_oid') || return 1
    actual_oid=$(printf '%s\n' "$record" | jq -cSj '.proof' \
      | git hash-object --stdin) || return 1
    [[ "$actual_oid" == "$stored_oid" ]] || return 1
  done < <(printf '%s\n' "$hitl_doc" | jq -c '.records[]')

  prd_git_proof cat-file -e "${owned_tip}^{commit}" 2>/dev/null || return 1
  prd_git_proof cat-file -e "${remote_tip}^{commit}" 2>/dev/null || return 1
  prd_git_proof merge-base --is-ancestor "$owned_tip" "$remote_tip" || return 1
  commits=$(prd_git_proof rev-list --first-parent --reverse \
    "$owned_tip..$remote_tip") || return 1
  [[ -n "$commits" ]] || return 1
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    attribution_count=$(
      jq -n \
        --slurpfile status "$status_file" \
        --argjson hitl "$hitl_doc" \
        --arg commit "$commit" '
          ([$status[0].items[]
            | select(.status == "slice-integrated"
              and .integrated_commit == $commit)] | length)
          + ([$hitl.records[]
            | select(.integrated_commit == $commit)] | length)
        '
    ) || return 1
    [[ "$attribution_count" -eq 1 ]] || return 1
  done <<<"$commits"
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

# prd_launcher_setup_is_exclusive
# Proves that this process owns both launcher setup locks and that no separate
# controller-owned launcher pidfile belongs to another process.
prd_launcher_pid_is_current() {
  local launcher_pid="$1"
  [[ "$launcher_pid" == "$$" ]] && return 0
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      local current_winpid
      current_winpid=$(ps -p "$$" -l 2>/dev/null | awk '
        NR > 1 && $1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $4; exit }
      ') || return 1
      [[ -n "$current_winpid" && "$launcher_pid" == "$current_winpid" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

prd_launcher_setup_is_exclusive() {
  local repo_root common_git_dir expected_token owner token lockdir
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  common_git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common_git_dir" in
    /*|[A-Za-z]:/*) ;;
    *) common_git_dir="$repo_root/$common_git_dir" ;;
  esac
  common_git_dir=$(cd "$common_git_dir" 2>/dev/null && pwd -P) || return 1
  expected_token="${RALPH_LAUNCH_TOKEN:-}"

  for lockdir in "$STATE_DIR/launch.lock" "$common_git_dir/ralph-launch.lock"; do
    [[ -d "$lockdir" && -f "$lockdir/owner" ]] || return 1
    owner=$(cat "$lockdir/owner" 2>/dev/null) || return 1
    [[ "$owner" =~ ^[1-9][0-9]*$ && "$owner" == "$$" ]] || return 1

    if [[ -n "$expected_token" ]]; then
      [[ -f "$lockdir/token" ]] || return 1
      token=$(cat "$lockdir/token" 2>/dev/null) || return 1
      [[ "$token" == "$expected_token" ]] || return 1
    elif [[ -e "$lockdir/token" ]]; then
      return 1
    fi
  done

  local launcher_pid_file="$STATE_DIR/launcher.pid"
  if [[ -e "$launcher_pid_file" ]]; then
    local launcher_pid
    [[ -f "$launcher_pid_file" ]] || return 1
    launcher_pid=$(cat "$launcher_pid_file" 2>/dev/null) || return 1
    [[ "$launcher_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    prd_launcher_pid_is_current "$launcher_pid" || return 1
  fi
}

# prd_run_has_worker_worktree
# Returns 0 when any linked worktree exists, 1 when none exists, and 2 when
# worktree evidence cannot be inspected. Zero-registration recovery cannot
# safely distinguish an unregistered worker worktree from an unrelated one.
prd_run_has_worker_worktree() {
  local repo_root worktrees worktree_path branch_ref
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 2
  repo_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || return 2
  worktrees=$(git worktree list --porcelain 2>/dev/null) || return 2

  while IFS=$'\t' read -r worktree_path branch_ref; do
    [[ -n "$worktree_path" ]] || continue
    worktree_path=$(cd "$worktree_path" 2>/dev/null && pwd -P) || return 2
    [[ "$worktree_path" != "$repo_root" ]] || continue
    return 0
  done < <(
    printf '%s\n' "$worktrees" | awk '
      $1 == "worktree" {
        if (path != "") print path "\t" branch
        path=substr($0, 10)
        branch=""
        next
      }
      $1 == "branch" { branch=$2 }
      END { if (path != "") print path "\t" branch }
    '
  )
  return 1
}

# prd_zero_registration_retirement_reason RUN_ID
# Prints the explicit retirement reason only after proving the run crashed
# before any worker, claim, session, worktree, or separate launcher registered.
prd_zero_registration_retirement_reason() {
  local run_id="$1"
  local run_dir="$STATE_DIR/runs/$run_id"
  local status_file="$run_dir/status.json"
  local session_ledger="$run_dir/copilot-sessions.jsonl"

  if [[ ! -f "$status_file" ]] || ! jq -e '
    type == "object"
    and (.items | type == "object")
    and (.items | length == 0)
  ' "$status_file" >/dev/null 2>&1; then
    echo "ERROR: Run '$run_id' has worker registration evidence or invalid status evidence" >&2
    return 1
  fi
  if [[ ! -f "$STATE_FILE" ]] || ! jq -e '
    type == "object"
    and (.claims | type == "object")
    and (.claims | length == 0)
  ' "$STATE_FILE" >/dev/null 2>&1; then
    echo "ERROR: Run '$run_id' lacks explicit empty claim evidence" >&2
    return 1
  fi
  if [[ -e "$session_ledger" ]]; then
    echo "ERROR: Run '$run_id' has Copilot session registration evidence" >&2
    return 1
  fi
  if ! prd_launcher_setup_is_exclusive; then
    echo "ERROR: Run '$run_id' lacks exclusive launcher shutdown evidence" >&2
    return 1
  fi
  if ! declare -F scoped_ralph_processes >/dev/null 2>&1; then
    echo "ERROR: Run '$run_id' cannot inspect Ralph process evidence" >&2
    return 1
  fi
  local live_processes
  live_processes=$(scoped_ralph_processes strict) || {
    echo "ERROR: Run '$run_id' could not inspect Ralph process evidence" >&2
    return 1
  }
  if [[ -n "$live_processes" ]]; then
    echo "ERROR: Run '$run_id' still has a live Ralph process" >&2
    return 1
  fi

  local worktree_rc=0
  prd_run_has_worker_worktree || worktree_rc=$?
  if [[ "$worktree_rc" -eq 0 ]]; then
    echo "ERROR: Run '$run_id' still has a Ralph worker worktree" >&2
    return 1
  elif [[ "$worktree_rc" -ne 1 ]]; then
    echo "ERROR: Run '$run_id' could not inspect Ralph worker worktrees" >&2
    return 1
  fi

  printf '%s\n' "abandoned before worker registration (zero-item guarded recovery)"
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
      and (.[0].owned_tip_sha == null
        or (.[0].owned_tip_sha
          | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$")))
      and (.[0].resumed_from_run_id == null
        or (.[0].resumed_from_run_id
          | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
      and (.[0].transfer_pending == null or (
        (.[0].transfer_pending | type == "object")
        and (.[0].transfer_pending.new_run_id
          | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and (.[0].transfer_pending.expected_remote_tip
          | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
        and (.[0].transfer_pending.reason
          | . == "terminal PRD ownership transferred"
            or . == "zero-registration PRD ownership transferred")
        and (.[0].transfer_pending.recorded_at
          | type == "string" and length > 0)
      ))
      and (.[0].retirement_pending == null or (
        (.[0].retirement_pending | type == "object")
        and .[0].retirement_pending.reason
          == "abandoned before worker registration (zero-item guarded recovery)"
        and (.[0].retirement_pending.retired_by_run_id
          | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and (.[0].retirement_pending.expected_branch_tip
          | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
        and (.[0].retirement_pending.recorded_at | type == "string" and length > 0)
      ))
      and (.[0].transferred_tip_sha == null
        or (.[0].transferred_tip_sha
          | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$")))
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
    and .transfer_pending == null
    and (.retirement_pending == null or (
      (.retirement_pending | type == "object")
      and .retirement_pending.reason
        == "abandoned before worker registration (zero-item guarded recovery)"
      and (.retirement_pending.retired_by_run_id
        | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
      and (.retirement_pending.expected_branch_tip
        | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
      and (.retirement_pending.recorded_at | type == "string" and length > 0)
    ))
    and .retired_at == null' \
    "$ownership_file" >/dev/null 2>&1; then
    echo "ERROR: Ownership evidence for run '$owner_run_id' is invalid or already retired" >&2
    return 1
  fi

  local ownership_expected
  ownership_expected=$(jq -cS . "$ownership_file") || return 1

  local prd_number branch_name remote frozen_base
  prd_number=$(printf '%s\n' "$ownership_expected" | jq -r '.prd_number')
  branch_name=$(printf '%s\n' "$ownership_expected" | jq -r '.branch_name')
  remote=$(printf '%s\n' "$ownership_expected" | jq -r '.remote')
  frozen_base=$(printf '%s\n' "$ownership_expected" | jq -r '.initial_base_sha')

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

  local retirement_reason pending_reason pending_retired_by pending_expected_tip
  pending_reason=$(printf '%s\n' "$ownership_expected" | jq -r '.retirement_pending.reason // empty')
  pending_retired_by=$(printf '%s\n' "$ownership_expected" | jq -r '.retirement_pending.retired_by_run_id // empty')
  pending_expected_tip=$(printf '%s\n' "$ownership_expected" | jq -r '.retirement_pending.expected_branch_tip // empty')
  if [[ -n "$pending_reason" ]]; then
    if ! retirement_reason=$(prd_zero_registration_retirement_reason "$owner_run_id") \
      || [[ "$retirement_reason" != "$pending_reason" \
        || "$pending_expected_tip" != "$frozen_base" ]]; then
      echo "ERROR: Pending retirement evidence for run '$owner_run_id' is no longer safe" >&2
      return 1
    fi
    retired_by_run_id="$pending_retired_by"
  elif prd_run_is_terminal "$owner_run_id"; then
    retirement_reason="terminal stale PRD integration branch"
  elif ! retirement_reason=$(prd_zero_registration_retirement_reason "$owner_run_id"); then
    echo "ERROR: Run '$owner_run_id' is not terminal and does not qualify for guarded abandonment; refusing to retire '$branch_name'" >&2
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
  if [[ "$retirement_reason" != "terminal stale PRD integration branch" \
    && "$branch_present" -eq 0 && -z "$pending_reason" ]]; then
    echo "ERROR: Guarded abandonment requires local branch '$branch_name' at its frozen base" >&2
    return 1
  fi

  # Recheck state under the worker state lock, then commit ownership, ref, and
  # active-run retirement without exposing a partially-cleared active guard.
  state_lock || return 1
  local rechecked_reason=""
  if [[ "$retirement_reason" == "terminal stale PRD integration branch" ]]; then
    prd_run_is_terminal "$owner_run_id" && rechecked_reason="$retirement_reason"
  else
    rechecked_reason=$(prd_zero_registration_retirement_reason "$owner_run_id") || true
  fi
  if [[ "$rechecked_reason" != "$retirement_reason" ]] \
    || prd_run_has_live_worker "$owner_run_id" \
    || prd_state_has_live_claim; then
    state_unlock
    echo "ERROR: Run '$owner_run_id' became active during retirement; refusing '$branch_name'" >&2
    return 1
  fi
  local ownership_current
  ownership_current=$(jq -cS . "$ownership_file" 2>/dev/null) || true
  if [[ "$ownership_current" != "$ownership_expected" ]]; then
    state_unlock
    echo "ERROR: Ownership evidence for run '$owner_run_id' changed during retirement" >&2
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

  local timestamp tmp state_tmp="" pending_tmp="" partial_failure_state
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [[ "$retirement_reason" == "terminal stale PRD integration branch" ]]; then
    partial_failure_state="branchless ownership remains recoverable"
  else
    partial_failure_state="pending ownership remains recoverable"
  fi
  if [[ "$retirement_reason" != "terminal stale PRD integration branch" \
    && -z "$pending_reason" ]]; then
    pending_tmp=$(mktemp "$(dirname "$ownership_file")/.ownership-pending.XXXXXX") || {
      state_unlock
      return 1
    }
    if ! jq \
      --arg reason "$retirement_reason" \
      --arg retired_by_run_id "$retired_by_run_id" \
      --arg expected_branch_tip "$branch_tip" \
      --arg recorded_at "$timestamp" \
      '.retirement_pending = {
        reason: $reason,
        retired_by_run_id: $retired_by_run_id,
        expected_branch_tip: $expected_branch_tip,
        recorded_at: $recorded_at
      }' "$ownership_file" >"$pending_tmp" \
      || ! mv "$pending_tmp" "$ownership_file"; then
      rm -f "$pending_tmp"
      state_unlock
      echo "ERROR: Failed to durably stage guarded branch retirement" >&2
      return 1
    fi
    pending_reason="$retirement_reason"
    pending_expected_tip="$branch_tip"
  fi

  tmp=$(mktemp "$(dirname "$ownership_file")/.ownership-retired.XXXXXX") || {
    state_unlock
    return 1
  }
  if ! jq \
    --arg retired_at "$timestamp" \
    --arg retired_by_run_id "$retired_by_run_id" \
    --arg retirement_reason "$retirement_reason" \
    '.retired_at = $retired_at
    | .retired_by_run_id = $retired_by_run_id
    | .retirement_reason = $retirement_reason
    | del(.retirement_pending)' \
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
      echo "ERROR: Failed to clear PRD activation; $partial_failure_state" >&2
      return 1
    fi
  fi

  if ! mv "$tmp" "$ownership_file"; then
    rm -f "$tmp"
    state_unlock
    echo "ERROR: Failed to record branch retirement; $partial_failure_state" >&2
    return 1
  fi

  state_unlock
  echo "Retired PRD integration branch '$branch_name' from run '$owner_run_id': $retirement_reason."
}

# transfer_owned_prd_branch OWNER_RUN_ID NEW_RUN_ID
# Transfers a published same-PRD branch without deleting or rewriting either ref.
# The prior record stages transfer intent before the new record is created, so an
# interrupted transfer can be completed idempotently by the intended new run.
prd_report_startup_phase() {
  if declare -F write_startup_phase >/dev/null 2>&1; then
    write_startup_phase "$1"
  fi
}

transfer_owned_prd_branch() {
  local owner_run_id="$1"
  local new_run_id="$2"
  local ownership_file="$STATE_DIR/runs/$owner_run_id/ownership.json"
  local new_ownership_file="$STATE_DIR/runs/$new_run_id/ownership.json"

  if ! [[ "$owner_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
    && "$new_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
    && "$owner_run_id" != "$new_run_id" ]]; then
    echo "ERROR: Invalid run identity for PRD branch ownership transfer" >&2
    return 1
  fi
  prd_validate_ownership_records || return 1
  [[ -f "$ownership_file" ]] || {
    echo "ERROR: Missing ownership evidence for run '$owner_run_id'" >&2
    return 1
  }

  local ownership_expected
  ownership_expected=$(jq -cS . "$ownership_file") || return 1
  if ! printf '%s\n' "$ownership_expected" | jq -e \
    --arg run_id "$owner_run_id" \
    '.run_id == $run_id
     and (.prd_number | type == "string" and test("^[1-9][0-9]*$"))
     and (.branch_name | type == "string" and length > 0)
     and (.remote | type == "string" and length > 0)
     and (.delivery_branch | type == "string" and length > 0)
     and (.initial_base_sha
       | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$"))
     and .retirement_pending == null
     and .retired_at == null' >/dev/null 2>&1; then
    echo "ERROR: Ownership evidence for run '$owner_run_id' cannot be transferred" >&2
    return 1
  fi

  local prd_number branch_name remote delivery_branch frozen_base owned_tip
  prd_number=$(printf '%s\n' "$ownership_expected" | jq -r '.prd_number')
  branch_name=$(printf '%s\n' "$ownership_expected" | jq -r '.branch_name')
  remote=$(printf '%s\n' "$ownership_expected" | jq -r '.remote')
  delivery_branch=$(printf '%s\n' "$ownership_expected" | jq -r '.delivery_branch')
  frozen_base=$(printf '%s\n' "$ownership_expected" | jq -r '.initial_base_sha')
  owned_tip=$(printf '%s\n' "$ownership_expected" | jq -r '.owned_tip_sha // .initial_base_sha')

  if ! [[ "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    || ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Ownership evidence for run '$owner_run_id' contains invalid identifiers" >&2
    return 1
  fi

  local owner_files=() owner_file
  while IFS= read -r owner_file; do
    [[ -n "$owner_file" ]] && owner_files+=("$owner_file")
  done < <(prd_active_ownership_files "$branch_name")
  if [[ ${#owner_files[@]} -lt 1 || ${#owner_files[@]} -gt 2 ]]; then
    echo "ERROR: Branch '$branch_name' has ambiguous ownership during transfer" >&2
    return 1
  fi
  local saw_prior=0
  for owner_file in "${owner_files[@]}"; do
    if [[ "$owner_file" == "$ownership_file" ]]; then
      saw_prior=1
    elif [[ "$owner_file" != "$new_ownership_file" ]]; then
      echo "ERROR: Branch '$branch_name' has conflicting ownership during transfer" >&2
      return 1
    fi
  done
  [[ "$saw_prior" -eq 1 ]] || {
    echo "ERROR: Prior ownership for '$branch_name' disappeared during transfer" >&2
    return 1
  }

  local transfer_reason status_expected="" hitl_expected="" hitl_present=0
  if prd_run_is_terminal "$owner_run_id"; then
    transfer_reason="terminal PRD ownership transferred"
    status_expected=$(jq -cS . "$STATE_DIR/runs/$owner_run_id/status.json") || return 1
  elif transfer_reason=$(prd_zero_registration_retirement_reason "$owner_run_id"); then
    transfer_reason="zero-registration PRD ownership transferred"
  else
    echo "ERROR: Run '$owner_run_id' is not terminal and cannot transfer '$branch_name'" >&2
    return 1
  fi
  if [[ -f "$STATE_DIR/runs/$owner_run_id/hitl-integrations.json" ]]; then
    hitl_present=1
    hitl_expected=$(jq -cS . \
      "$STATE_DIR/runs/$owner_run_id/hitl-integrations.json") || return 1
  fi
  if prd_run_has_live_worker "$owner_run_id"; then
    echo "ERROR: Run '$owner_run_id' still has a live worker; refusing transfer" >&2
    return 1
  fi
  if prd_state_has_live_claim; then
    echo "ERROR: Repository still has a live claim; refusing transfer" >&2
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
  prd_report_startup_phase "prd-transfer-checking-pull-requests"
  if ! pr_json=$("$GH" pr list --repo "$REPO" --state all --head "$branch_name" --json number); then
    echo "ERROR: Ralph could not verify pull requests for '$branch_name'" >&2
    return 1
  fi
  if ! printf '%s\n' "$pr_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "ERROR: Ralph could not verify pull requests for '$branch_name': invalid response" >&2
    return 1
  fi
  if [[ "$(printf '%s\n' "$pr_json" | jq 'length')" -ne 0 ]]; then
    echo "ERROR: Branch '$branch_name' still has a pull request; refusing transfer" >&2
    return 1
  fi

  local remote_tip remote_rc=0 fetched_tip
  prd_report_startup_phase "prd-transfer-reading-remote"
  remote_tip=$(prd_remote_branch_tip "$remote" "$branch_name") || remote_rc=$?
  if [[ "$remote_rc" -ne 0 ]]; then
    echo "ERROR: Published branch '$remote/$branch_name' is unavailable for ownership transfer" >&2
    return 1
  fi
  prd_report_startup_phase "prd-transfer-fetching-remote"
  if ! git fetch "$remote" \
    "refs/heads/$branch_name:refs/remotes/$remote/$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Failed to fetch published branch '$remote/$branch_name'" >&2
    return 1
  fi
  fetched_tip=$(git rev-parse "refs/remotes/$remote/$branch_name") || return 1
  if [[ "$fetched_tip" != "$remote_tip" ]]; then
    echo "ERROR: Remote branch '$remote/$branch_name' moved while transfer evidence was fetched" >&2
    return 1
  fi
  prd_report_startup_phase "prd-transfer-verifying-history"
  prd_assert_unmodified_graph || return 1
  if ! prd_git_proof cat-file -e "${frozen_base}^{commit}" 2>/dev/null \
    || ! prd_git_proof cat-file -e "${owned_tip}^{commit}" 2>/dev/null \
    || ! prd_git_proof merge-base --is-ancestor "$frozen_base" "$remote_tip" \
    || ! prd_git_proof merge-base --is-ancestor "$owned_tip" "$remote_tip"; then
    echo "ERROR: Remote branch '$remote/$branch_name' does not descend from owned history" >&2
    return 1
  fi
  if [[ "$remote_tip" != "$owned_tip" ]]; then
    if [[ "$transfer_reason" == "zero-registration PRD ownership transferred" ]]; then
      echo "ERROR: Zero-registration branch '$remote/$branch_name' moved beyond its owned tip" >&2
      return 1
    fi
    if ! prd_terminal_remote_tip_is_proven "$owner_run_id" "$remote_tip"; then
      echo "ERROR: Remote branch '$remote/$branch_name' lacks exact terminal slice-delivery evidence" >&2
      return 1
    fi
  fi
  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    local local_tip
    local_tip=$(git rev-parse "refs/heads/$branch_name") || return 1
    if [[ "$local_tip" != "$remote_tip" ]]; then
      local local_lag_is_proven=0
      if [[ "$transfer_reason" == "terminal PRD ownership transferred" ]] \
        && prd_git_proof merge-base --is-ancestor "$owned_tip" "$local_tip" \
        && prd_git_proof merge-base --is-ancestor "$local_tip" "$remote_tip"; then
        local_lag_is_proven=1
      elif [[ "$transfer_reason" == "zero-registration PRD ownership transferred" ]] \
        && prd_transferred_ownership_is_proven \
          "$owner_run_id" "$branch_name" "$owned_tip" \
        && prd_git_proof merge-base --is-ancestor "$local_tip" "$owned_tip"; then
        local_lag_is_proven=1
      fi
      if [[ "$local_lag_is_proven" -ne 1 ]]; then
        echo "ERROR: Local branch '$branch_name' differs from remote tip '$remote_tip' without proven delivery history; refusing transfer" >&2
        return 1
      fi
    fi
  fi

  local pending_new pending_tip pending_reason
  pending_new=$(printf '%s\n' "$ownership_expected" | jq -r '.transfer_pending.new_run_id // empty')
  pending_tip=$(printf '%s\n' "$ownership_expected" | jq -r '.transfer_pending.expected_remote_tip // empty')
  pending_reason=$(printf '%s\n' "$ownership_expected" | jq -r '.transfer_pending.reason // empty')
  if [[ -n "$pending_new" \
    && ("$pending_new" != "$new_run_id" \
      || "$pending_tip" != "$remote_tip" \
      || "$pending_reason" != "$transfer_reason") ]]; then
    echo "ERROR: Ownership transfer for '$branch_name' is already pending with different evidence" >&2
    return 1
  fi

  prd_report_startup_phase "prd-transfer-rechecking-evidence"
  state_lock || return 1

  local rechecked_reason
  if prd_run_is_terminal "$owner_run_id"; then
    rechecked_reason="terminal PRD ownership transferred"
  elif prd_zero_registration_retirement_reason "$owner_run_id" >/dev/null; then
    rechecked_reason="zero-registration PRD ownership transferred"
  else
    rechecked_reason=""
  fi
  if [[ "$rechecked_reason" != "$transfer_reason" ]] \
    || prd_run_has_live_worker "$owner_run_id" \
    || prd_state_has_live_claim; then
    state_unlock
    echo "ERROR: Run '$owner_run_id' became active during ownership transfer" >&2
    return 1
  fi
  if [[ -n "$status_expected" \
    && "$(jq -cS . "$STATE_DIR/runs/$owner_run_id/status.json" 2>/dev/null)" != "$status_expected" ]]; then
    state_unlock
    echo "ERROR: Terminal delivery evidence for run '$owner_run_id' changed during transfer" >&2
    return 1
  fi
  if [[ "$hitl_present" -eq 1 \
    && "$(jq -cS . "$STATE_DIR/runs/$owner_run_id/hitl-integrations.json" 2>/dev/null)" != "$hitl_expected" ]] \
    || [[ "$hitl_present" -eq 0 \
      && -e "$STATE_DIR/runs/$owner_run_id/hitl-integrations.json" ]]; then
    state_unlock
    echo "ERROR: HITL delivery evidence for run '$owner_run_id' changed during transfer" >&2
    return 1
  fi

  local ownership_current rechecked_remote_tip rechecked_remote_rc=0
  ownership_current=$(jq -cS . "$ownership_file" 2>/dev/null) || true
  if [[ "$ownership_current" != "$ownership_expected" ]]; then
    state_unlock
    echo "ERROR: Ownership evidence for run '$owner_run_id' changed during transfer" >&2
    return 1
  fi
  rechecked_remote_tip=$(prd_remote_branch_tip "$remote" "$branch_name") \
    || rechecked_remote_rc=$?
  if [[ "$rechecked_remote_rc" -ne 0 || "$rechecked_remote_tip" != "$remote_tip" ]]; then
    state_unlock
    echo "ERROR: Remote branch '$remote/$branch_name' moved during ownership transfer" >&2
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
      echo "ERROR: Repository records a different active PRD run '$active_run'; refusing ownership transfer" >&2
      return 1
    fi
  fi

  local timestamp pending_tmp retired_tmp state_tmp=""
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [[ -z "$pending_new" ]]; then
    pending_tmp=$(mktemp "$(dirname "$ownership_file")/.ownership-transfer.XXXXXX") || {
      state_unlock
      return 1
    }
    if ! jq \
      --arg new_run_id "$new_run_id" \
      --arg expected_remote_tip "$remote_tip" \
      --arg reason "$transfer_reason" \
      --arg recorded_at "$timestamp" \
      '.transfer_pending = {
        new_run_id: $new_run_id,
        expected_remote_tip: $expected_remote_tip,
        reason: $reason,
        recorded_at: $recorded_at
      }' "$ownership_file" >"$pending_tmp" \
      || ! mv "$pending_tmp" "$ownership_file"; then
      rm -f "$pending_tmp"
      state_unlock
      echo "ERROR: Failed to stage PRD ownership transfer" >&2
      return 1
    fi
  fi

  if [[ -f "$new_ownership_file" ]]; then
    if ! jq -e \
      --arg run_id "$new_run_id" \
      --arg prd_number "$prd_number" \
      --arg branch_name "$branch_name" \
      --arg remote "$remote" \
      --arg delivery_branch "$delivery_branch" \
      --arg initial_base_sha "$frozen_base" \
      --arg owned_tip_sha "$remote_tip" \
      --arg resumed_from_run_id "$owner_run_id" \
      '.run_id == $run_id
       and .prd_number == $prd_number
       and .branch_name == $branch_name
       and .remote == $remote
       and .delivery_branch == $delivery_branch
       and .initial_base_sha == $initial_base_sha
       and .owned_tip_sha == $owned_tip_sha
       and .resumed_from_run_id == $resumed_from_run_id
       and .retired_at == null' \
      "$new_ownership_file" >/dev/null 2>&1; then
      state_unlock
      echo "ERROR: New run '$new_run_id' has conflicting ownership evidence" >&2
      return 1
    fi
  elif ! create_prd_ownership_record \
    "$new_run_id" "$prd_number" "$branch_name" "$remote" "$delivery_branch" \
    "$frozen_base" "$remote_tip" "$owner_run_id"; then
    state_unlock
    echo "ERROR: Failed to create transferred ownership for run '$new_run_id'" >&2
    return 1
  fi

  if [[ "$active_run" == "$owner_run_id" ]]; then
    state_tmp=$(state_mktemp) || true
    if [[ -z "$state_tmp" ]] \
      || ! jq 'del(.active_prd, .active_run_id)' "$STATE_FILE" >"$state_tmp" \
      || ! mv "$state_tmp" "$STATE_FILE"; then
      rm -f "$state_tmp"
      state_unlock
      echo "ERROR: Failed to clear prior PRD activation; ownership transfer remains pending" >&2
      return 1
    fi
  fi

  retired_tmp=$(mktemp "$(dirname "$ownership_file")/.ownership-transferred.XXXXXX") || {
    state_unlock
    return 1
  }
  if ! jq \
    --arg retired_at "$timestamp" \
    --arg retired_by_run_id "$new_run_id" \
    --arg retirement_reason "$transfer_reason" \
    --arg transferred_tip_sha "$remote_tip" \
    '.retired_at = $retired_at
     | .retired_by_run_id = $retired_by_run_id
     | .retirement_reason = $retirement_reason
     | .transferred_tip_sha = $transferred_tip_sha
     | del(.transfer_pending)' \
    "$ownership_file" >"$retired_tmp" \
    || ! mv "$retired_tmp" "$ownership_file"; then
    rm -f "$retired_tmp"
    state_unlock
    echo "ERROR: Failed to finalize PRD ownership transfer; staged evidence was preserved" >&2
    return 1
  fi

  state_unlock
  echo "Transferred PRD integration branch '$branch_name' from run '$owner_run_id' to '$new_run_id' at '$remote_tip'."
}

# recover_stale_prd_branch NEW_RUN_ID PRD_NUMBER BRANCH_NAME REMOTE DELIVERY_BRANCH
# Recovers only a same-PRD, same-repository branch owned by one terminal run.
recover_stale_prd_branch() {
  local new_run_id="$1"
  local prd_number="$2"
  local branch_name="$3"
  local remote="$4"
  local delivery_branch="$5"

  if ! [[ "$new_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
    && "$prd_number" =~ ^[1-9][0-9]*$ \
    && "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    || ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1 \
    || ! git check-ref-format --branch "$delivery_branch" >/dev/null 2>&1; then
    echo "ERROR: Invalid PRD recovery identifiers or repository settings" >&2
    return 1
  fi

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
    local unowned_remote_rc=0
    prd_remote_branch_tip "$remote" "$branch_name" >/dev/null \
      || unowned_remote_rc=$?
    if [[ "$unowned_remote_rc" -eq 0 ]]; then
      echo "ERROR: Existing remote branch '$remote/$branch_name' has unprovable ownership" >&2
      return 1
    elif [[ "$unowned_remote_rc" -ne 2 ]]; then
      echo "ERROR: Could not verify remote ownership for '$remote/$branch_name'" >&2
      return 1
    fi
    return 0
  fi

  if [[ ${#owner_files[@]} -eq 2 ]]; then
    local pending_owner_file="" pending_target_file="" candidate_file
    local pending_owner_run_id="" pending_target_run_id=""
    for candidate_file in "${owner_files[@]}"; do
      if jq -e \
        --arg branch_name "$branch_name" \
        '.branch_name == $branch_name
         and (.transfer_pending.new_run_id
           | type == "string" and length > 0)
         and .retired_at == null' \
        "$candidate_file" >/dev/null 2>&1; then
        pending_owner_file="$candidate_file"
      fi
    done
    if [[ -n "$pending_owner_file" ]]; then
      pending_owner_run_id=$(jq -r '.run_id' "$pending_owner_file")
      pending_target_run_id=$(jq -r '.transfer_pending.new_run_id' "$pending_owner_file")
      for candidate_file in "${owner_files[@]}"; do
        if [[ "$candidate_file" != "$pending_owner_file" ]] \
          && jq -e \
            --arg run_id "$pending_target_run_id" \
            --arg prior_run_id "$pending_owner_run_id" \
            --arg branch_name "$branch_name" \
            '.run_id == $run_id
             and .resumed_from_run_id == $prior_run_id
             and .branch_name == $branch_name
             and .retired_at == null' \
            "$candidate_file" >/dev/null 2>&1; then
          pending_target_file="$candidate_file"
        fi
      done
    fi
    if [[ -n "$pending_owner_file" && -n "$pending_target_file" ]]; then
      if ! jq -e \
        --arg prd_number "$prd_number" \
        --arg remote "$remote" \
        --arg delivery_branch "$delivery_branch" \
        '.prd_number == $prd_number
         and .remote == $remote
         and .delivery_branch == $delivery_branch' \
        "$pending_owner_file" >/dev/null 2>&1; then
        echo "ERROR: Pending ownership transfer belongs to different PRD or repository settings" >&2
        return 1
      fi
      if [[ "$pending_target_run_id" != "$new_run_id" ]] \
        && { prd_run_has_live_worker "$pending_target_run_id" \
          || prd_state_has_live_claim; }; then
        echo "ERROR: Pending successor run '$pending_target_run_id' still has live execution evidence" >&2
        return 1
      fi
      transfer_owned_prd_branch "$pending_owner_run_id" "$pending_target_run_id" \
        || return 1
      if [[ "$pending_target_run_id" == "$new_run_id" ]]; then
        return 0
      fi
      recover_stale_prd_branch \
        "$new_run_id" "$prd_number" "$branch_name" "$remote" "$delivery_branch"
      return
    fi
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

  local pending_target_run_id
  pending_target_run_id=$(jq -r '.transfer_pending.new_run_id // empty' "$owner_file")
  if [[ -n "$pending_target_run_id" ]]; then
    if [[ "$pending_target_run_id" != "$new_run_id" ]] \
      && { prd_run_has_live_worker "$pending_target_run_id" \
        || prd_state_has_live_claim; }; then
      echo "ERROR: Pending successor run '$pending_target_run_id' still has live execution evidence" >&2
      return 1
    fi
    transfer_owned_prd_branch "$owner_run_id" "$pending_target_run_id" || return 1
    if [[ "$pending_target_run_id" == "$new_run_id" ]]; then
      return 0
    fi
    recover_stale_prd_branch \
      "$new_run_id" "$prd_number" "$branch_name" "$remote" "$delivery_branch"
    return
  fi

  local remote_tip_rc=0
  prd_remote_branch_tip "$remote" "$branch_name" >/dev/null \
    || remote_tip_rc=$?
  if [[ "$remote_tip_rc" -eq 0 ]]; then
    transfer_owned_prd_branch "$owner_run_id" "$new_run_id"
  elif [[ "$remote_tip_rc" -eq 2 ]]; then
    # Backwards-compatible recovery for branches created by older installers
    # before publication became part of the ownership interface.
    retire_owned_prd_branch "$owner_run_id" "$new_run_id"
  else
    echo "ERROR: Could not inspect remote branch '$remote/$branch_name' for recovery" >&2
    return 1
  fi
}

# cleanup_stale_prd_branches
# Retires every locally-present PRD branch whose ownership passes all gates.
cleanup_stale_prd_branches() {
  local ownership_file branch_name run_id transfer_target remote remote_rc failed=0
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
    transfer_target=$(jq -r '.transfer_pending.new_run_id // empty' "$ownership_file" 2>/dev/null)
    if [[ -n "$transfer_target" ]]; then
      echo "Skipping PRD branch '$branch_name': ownership transfer to run '$transfer_target' is pending."
      continue
    fi
    remote=$(jq -r '.remote // empty' "$ownership_file" 2>/dev/null)
    if ! [[ "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
      echo "ERROR: Ownership for '$branch_name' contains an invalid remote name" >&2
      failed=1
      continue
    fi
    remote_rc=0
    prd_remote_branch_tip "$remote" "$branch_name" >/dev/null || remote_rc=$?
    if [[ "$remote_rc" -eq 0 ]]; then
      echo "Skipping published PRD branch '$remote/$branch_name'; preserving it for same-PRD recovery."
      continue
    elif [[ "$remote_rc" -ne 2 ]]; then
      echo "ERROR: Could not inspect remote PRD branch '$remote/$branch_name' during cleanup" >&2
      failed=1
      continue
    fi
    if [[ -z "$run_id" ]] || ! retire_owned_prd_branch "$run_id" "cleanup"; then
     failed=1
    fi
  done
  shopt -u nullglob
  [[ "$failed" -eq 0 ]]
}

# create_prd_branch RUN_ID PRD_NUMBER PRD_TITLE REMOTE DELIVERY_BRANCH [TEMPLATE]
# Creates and publishes a PRD integration branch from the latest remote delivery
# branch. Ownership is recorded before local ref creation, and the interface
# returns success only after the configured remote proves the expected tip.
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
  local branch_name frozen_base="" owned_tip="" fresh_ownership_expected=""
  local has_ownership=0

  if ! [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
    && "$prd_number" =~ ^[1-9][0-9]*$ \
    && "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    || ! git check-ref-format --branch "$delivery_branch" >/dev/null 2>&1; then
    echo "ERROR: Invalid PRD branch identifiers or repository settings" >&2
    return 1
  fi

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
       and (.owned_tip_sha == null
         or (.owned_tip_sha
           | type == "string" and test("^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$")))
       and .retired_at == null' \
      "$ownership_file" >/dev/null 2>&1; then
      echo "ERROR: Ownership record for run '$run_id' conflicts with requested PRD or repository settings" >&2
      return 1
    fi
    branch_name=$(jq -r '.branch_name' "$ownership_file")
    frozen_base=$(jq -r '.initial_base_sha' "$ownership_file")
    owned_tip=$(jq -r '.owned_tip_sha // .initial_base_sha' "$ownership_file")
  else
    branch_name=$(resolve_prd_branch_name "$prd_number" "$prd_title" "$template")
  fi

  if ! git check-ref-format --branch "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Resolved PRD branch name is invalid: '$branch_name'" >&2
    return 1
  fi

  local local_present=0 local_tip="" remote_tip="" remote_branch_rc=0
  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    local_present=1
    if ! verify_prd_ownership "$run_id" "$branch_name"; then
      echo "ERROR: Branch '$branch_name' already exists but is not owned by run '$run_id'" >&2
      return 1
    fi
    local_tip=$(git rev-parse "refs/heads/$branch_name") || return 1
  fi

  remote_tip=$(prd_remote_branch_tip "$remote" "$branch_name") \
    || remote_branch_rc=$?
  if [[ "$remote_branch_rc" -eq 0 ]]; then
    if ! verify_prd_ownership "$run_id" "$branch_name"; then
      echo "ERROR: Remote branch '$remote/$branch_name' already exists but is not owned by run '$run_id'" >&2
      return 1
    fi
    if [[ "$remote_tip" != "$owned_tip" ]]; then
      echo "ERROR: Remote branch '$remote/$branch_name' moved from owned tip '$owned_tip' to '$remote_tip'" >&2
      return 1
    fi
    if [[ "$local_present" -eq 1 ]]; then
      if [[ "$local_tip" != "$owned_tip" ]]; then
        if ! prd_transferred_ownership_is_proven \
            "$run_id" "$branch_name" "$owned_tip" \
          || ! git fetch "$remote" \
            "refs/heads/$branch_name:refs/remotes/$remote/$branch_name" >/dev/null 2>&1 \
          || [[ "$(git rev-parse "refs/remotes/$remote/$branch_name")" != "$owned_tip" ]] \
          || ! git merge-base --is-ancestor "$local_tip" "$owned_tip" \
          || ! git update-ref "refs/heads/$branch_name" "$owned_tip" "$local_tip"; then
          echo "ERROR: Local branch '$branch_name' moved from owned tip '$owned_tip' to '$local_tip'" >&2
          return 1
        fi
      fi
      return 0
    fi
    git fetch "$remote" \
      "refs/heads/$branch_name:refs/remotes/$remote/$branch_name" >/dev/null 2>&1 || {
      echo "ERROR: Failed to fetch owned branch $remote/$branch_name" >&2
      return 1
    }
    if [[ "$(git rev-parse "refs/remotes/$remote/$branch_name")" != "$owned_tip" ]]; then
      echo "ERROR: Remote branch '$remote/$branch_name' moved while it was fetched" >&2
      return 1
    fi
    git branch "$branch_name" "refs/remotes/$remote/$branch_name" >/dev/null 2>&1 || {
      echo "ERROR: Failed to restore owned branch '$branch_name'" >&2
      return 1
    }
    return 0
  elif [[ "$remote_branch_rc" -ne 2 ]]; then
    echo "ERROR: Failed to verify whether remote branch '$remote/$branch_name' exists" >&2
    return 1
  fi

  if [[ "$local_present" -eq 1 ]]; then
    if [[ "$local_tip" != "$owned_tip" ]]; then
      echo "ERROR: Local branch '$branch_name' moved from owned tip '$owned_tip' to '$local_tip'" >&2
      return 1
    fi
    prd_publish_owned_branch "$remote" "$branch_name" "$owned_tip"
    return
  fi

  # Fetch latest remote and update remote-tracking ref
  git fetch "$remote" \
    "refs/heads/$delivery_branch:refs/remotes/$remote/$delivery_branch" >/dev/null 2>&1 || {
    echo "ERROR: Failed to fetch $remote/$delivery_branch" >&2
    return 1
  }

  local branch_base
  if [[ "$has_ownership" -eq 1 ]]; then
    branch_base="$owned_tip"
    if ! git cat-file -e "${branch_base}^{commit}" 2>/dev/null; then
      echo "ERROR: Owned tip '$branch_base' for run '$run_id' is unavailable" >&2
      return 1
    fi
  else
    branch_base=$(git rev-parse "refs/remotes/$remote/$delivery_branch") || {
      echo "ERROR: Failed to resolve $remote/$delivery_branch" >&2
      return 1
    }
    create_prd_ownership_record \
      "$run_id" "$prd_number" "$branch_name" "$remote" "$delivery_branch" \
      "$branch_base" "$branch_base" || {
      echo "ERROR: Failed to create ownership record" >&2
      return 1
    }
    fresh_ownership_expected=$(jq -cS . "$ownership_file") || return 1
    owned_tip="$branch_base"
  fi

  git branch "$branch_name" "$branch_base" >/dev/null 2>&1 || {
    echo "ERROR: Failed to create branch '$branch_name'" >&2
    if [[ "$has_ownership" -eq 0 && -n "$fresh_ownership_expected" ]]; then
      local ownership_current rollback_remote_rc=0
      ownership_current=$(jq -cS . "$ownership_file" 2>/dev/null) || true
      prd_remote_branch_tip "$remote" "$branch_name" >/dev/null \
        || rollback_remote_rc=$?
      if [[ "$ownership_current" == "$fresh_ownership_expected" \
        && "$rollback_remote_rc" -eq 2 ]] \
        && ! git show-ref --verify --quiet "refs/heads/$branch_name"; then
        rm -f "$ownership_file" || {
          echo "ERROR: Failed to roll back fresh ownership for '$branch_name'" >&2
          return 1
        }
      fi
    fi
    return 1
  }

  prd_publish_owned_branch "$remote" "$branch_name" "$owned_tip"
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
