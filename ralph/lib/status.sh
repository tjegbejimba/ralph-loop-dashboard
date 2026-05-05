#!/usr/bin/env bash
# status.sh — per-run status tracking for queue-based workers
#
# Coordinates issue lifecycle states within a single run. Workers update
# status.json atomically under the same state lock used for state.json
# (no separate lock to avoid deadlock). All status operations assume:
#   $RUN_ID     — run identifier (corresponds to .ralph/runs/<RUN_ID>/)
#   $LOG_DIR    — directory holding .ralph/logs/ (inherited from state.sh)
#   state_lock/unlock — already sourced from state.sh

# Requires state.sh to be sourced first for STATE_DIR and locking primitives
if [[ -z "${STATE_DIR:-}" ]]; then
  echo "⚠️  status.sh requires state.sh to be sourced first (STATE_DIR undefined)" >&2
  return 1
fi

# Path to this run's status file
status_file() {
  local run_id="${1:-$RUN_ID}"
  [[ -z "$run_id" ]] && { echo "⚠️  RUN_ID not set" >&2; return 1; }
  echo "$STATE_DIR/runs/$run_id/status.json"
}

# Same-filesystem mktemp for atomic mv into status.json
status_mktemp() {
  local run_id="${1:-$RUN_ID}"
  local run_dir="$STATE_DIR/runs/$run_id"
  mktemp "$run_dir/.status.XXXXXX"
}

# Initialize status.json if missing (empty items map)
# Caller should hold state_lock if racing with other workers
status_init() {
  local run_id="${1:-$RUN_ID}"
  local file
  file=$(status_file "$run_id")
  [[ -f "$file" ]] && return 0
  
  # Create run directory if missing (shouldn't happen — createRun does this)
  local run_dir
  run_dir=$(dirname "$file")
  mkdir -p "$run_dir"
  
  local tmp
  tmp=$(status_mktemp "$run_id")
  printf '%s\n' '{"items":{}}' >"$tmp"
  mv "$tmp" "$file"
}

# Load a single field from an item's status
# Args: issue_number field_name [run_id]
# Returns field value or empty string if item/field doesn't exist
status_load_item() {
  local issue="$1" field="$2" run_id="${3:-$RUN_ID}"
  local file
  file=$(status_file "$run_id")
  [[ ! -f "$file" ]] && return 0
  jq -r ".items[\"$issue\"].$field // empty" "$file" 2>/dev/null || true
}

# Atomically update a single item's status
# Caller MUST hold state_lock
# Args: issue_number status worker_id pid log_file started_at [run_id]
status_update_item() {
  local issue="$1" status="$2" worker="$3" pid="$4" logfile="$5" started="$6" run_id="${7:-$RUN_ID}"
  local file tmp
  file=$(status_file "$run_id")
  tmp=$(status_mktemp "$run_id")
  
  # Ensure file exists before jq
  [[ ! -f "$file" ]] && printf '%s\n' '{"items":{}}' >"$file"
  
  jq --arg issue "$issue" --arg status "$status" --argjson worker "$worker" \
     --argjson pid "$pid" --arg logfile "$logfile" --arg started "$started" '
    .items[$issue] = {
      status: $status,
      workerId: $worker,
      pid: $pid,
      logFile: $logfile,
      startedAt: $started,
      error: null
    }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# Mark an item as failed with optional error message
# Caller MUST hold state_lock
# Args: issue_number error_message [run_id]
status_mark_failed() {
  local issue="$1" error="${2:-}" run_id="${3:-$RUN_ID}"
  local file tmp
  file=$(status_file "$run_id")
  tmp=$(status_mktemp "$run_id")
  
  [[ ! -f "$file" ]] && printf '%s\n' '{"items":{}}' >"$file"
  
  jq --arg issue "$issue" --arg error "$error" '
    .items[$issue].status = "failed" |
    .items[$issue].error = $error
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# Mark an item as skipped (already closed before worker could claim)
# Caller MUST hold state_lock
# Args: issue_number [run_id]
status_mark_skipped() {
  local issue="$1" run_id="${2:-$RUN_ID}"
  local file tmp
  file=$(status_file "$run_id")
  tmp=$(status_mktemp "$run_id")
  
  [[ ! -f "$file" ]] && printf '%s\n' '{"items":{}}' >"$file"
  
  jq --arg issue "$issue" '
    .items[$issue] = {
      status: "skipped",
      workerId: null,
      pid: null,
      logFile: null,
      startedAt: null,
      error: null
    }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# Reap stale "running" items whose PIDs are no longer alive
# Uses the strict ralph-cmd check (same as state_reap_stale)
# Caller MUST hold state_lock
# Args: [run_id]
status_reap_stale() {
  local run_id="${1:-$RUN_ID}"
  local file
  file=$(status_file "$run_id")
  [[ ! -f "$file" ]] && return 0
  
  local items_json issue pid
  items_json=$(jq -r '.items | to_entries[] | select(.value.status == "running") | "\(.key) \(.value.pid)"' "$file" 2>/dev/null || true)
  local dead_issues=()
  
  while IFS=' ' read -r issue pid; do
    [[ -z "$issue" ]] && continue
    if ! is_pid_alive_and_ralph "$pid"; then
      dead_issues+=("$issue")
    fi
  done <<<"$items_json"
  
  if [[ ${#dead_issues[@]} -eq 0 ]]; then
    return 0
  fi
  
  local tmp
  tmp=$(status_mktemp "$run_id")
  local jq_filter='.'
  for issue in "${dead_issues[@]}"; do
    jq_filter="$jq_filter | .items[\"$issue\"].status = \"failed\" | .items[\"$issue\"].error = \"Worker process died\""
  done
  jq "$jq_filter" "$file" >"$tmp" && mv "$tmp" "$file"
}

# Check if an issue is in a terminal state (merged/failed/skipped)
# Args: issue_number [run_id]
# Returns 0 (true) if terminal, 1 (false) otherwise
status_is_terminal() {
  local issue="$1" run_id="${2:-$RUN_ID}"
  local status
  status=$(status_load_item "$issue" "status" "$run_id")
  case "$status" in
    merged|failed|skipped) return 0 ;;
    *) return 1 ;;
  esac
}

# Get all items in status.json
# Args: [run_id]
# Returns: JSON object of all items
status_all_items() {
  local run_id="${1:-$RUN_ID}"
  local file
  file=$(status_file "$run_id")
  [[ ! -f "$file" ]] && { echo '{}'; return 0; }
  jq -r '.items' "$file" 2>/dev/null || echo '{}'
}
