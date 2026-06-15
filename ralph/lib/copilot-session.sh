#!/usr/bin/env bash
# copilot-session.sh - conservative cleanup for Ralph-created Copilot sessions.
#
# This file is sourced by launch.sh/ralph.sh after state.sh, so STATE_DIR is
# available. The cleanup path only acts on session IDs recorded in Ralph ledgers.

if [[ -z "${STATE_DIR:-}" ]]; then
  echo "Warning: copilot-session.sh requires state.sh to be sourced first (STATE_DIR undefined)" >&2
  return 1
fi

copilot_session_state_dir() {
  printf '%s\n' "${RALPH_COPILOT_SESSION_STATE_DIR:-${COPILOT_SESSION_STATE_DIR:-$HOME/.copilot/session-state}}"
}

copilot_session_archive_dir() {
  printf '%s\n' "${RALPH_COPILOT_SESSION_ARCHIVE_DIR:-$STATE_DIR/copilot-session-archive}"
}

copilot_session_new_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}

copilot_session_name() {
  local issue="$1" worker="$2" run_id="${3:-}"
  if [[ -n "$run_id" ]]; then
    printf 'Ralph #%s w%s %s\n' "$issue" "$worker" "$run_id"
  else
    printf 'Ralph #%s w%s legacy\n' "$issue" "$worker"
  fi
}

copilot_session_ledger_path() {
  local run_id="${1:-${RUN_ID:-}}"
  if [[ -n "$run_id" ]]; then
    printf '%s\n' "$STATE_DIR/runs/$run_id/copilot-sessions.jsonl"
  else
    printf '%s\n' "$STATE_DIR/copilot-sessions.jsonl"
  fi
}

copilot_session_append_event() {
  local json="$1" run_id="${2:-${RUN_ID:-}}"
  local ledger
  ledger="$(copilot_session_ledger_path "$run_id")"
  mkdir -p "$(dirname "$ledger")"
  if declare -F state_lock >/dev/null 2>&1; then
    state_lock || return 1
    printf '%s\n' "$json" >>"$ledger"
    state_unlock || true
  else
    printf '%s\n' "$json" >>"$ledger"
  fi
}

copilot_session_record_start() {
  local session_id="$1" issue="$2" worker="$3" name="$4" cwd="$5" logfile="$6" started="$7" run_id="${8:-${RUN_ID:-}}"
  local json
  json="$(jq -nc \
    --arg event "start" \
    --arg sessionId "$session_id" \
    --argjson issue "$issue" \
    --argjson workerId "$worker" \
    --arg runId "$run_id" \
    --arg name "$name" \
    --arg cwd "$cwd" \
    --arg logFile "$logfile" \
    --arg startedAt "$started" \
    '{
      event: $event,
      sessionId: $sessionId,
      issue: $issue,
      workerId: $workerId,
      runId: $runId,
      name: $name,
      cwd: $cwd,
      logFile: $logFile,
      startedAt: $startedAt
    }')"
  copilot_session_append_event "$json" "$run_id"
}

copilot_session_record_terminal() {
  local session_id="$1" issue="$2" worker="$3" terminal_status="$4" run_id="${5:-${RUN_ID:-}}"
  local json
  json="$(jq -nc \
    --arg event "terminal" \
    --arg sessionId "$session_id" \
    --argjson issue "$issue" \
    --argjson workerId "$worker" \
    --arg runId "$run_id" \
    --arg terminalStatus "$terminal_status" \
    --arg completedAt "$(date -u +%FT%TZ)" \
    '{
      event: $event,
      sessionId: $sessionId,
      issue: $issue,
      workerId: $workerId,
      runId: $runId,
      terminalStatus: $terminalStatus,
      completedAt: $completedAt
    }')"
  copilot_session_append_event "$json" "$run_id"
}

copilot_session_ledger_files() {
  [[ -f "$STATE_DIR/copilot-sessions.jsonl" ]] && printf '%s\n' "$STATE_DIR/copilot-sessions.jsonl"
  shopt -s nullglob
  local f
  for f in "$STATE_DIR"/runs/*/copilot-sessions.jsonl; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  shopt -u nullglob
}

copilot_session_has_live_lock() {
  local session_dir="$1"
  shopt -s nullglob
  local lock pid
  for lock in "$session_dir"/inuse.*.lock; do
    pid="$(basename "$lock" | sed -nE 's/^inuse\.([0-9]+)\.lock$/\1/p')"
    if [[ -z "$pid" ]]; then
      shopt -u nullglob
      return 0
    fi
    if is_pid_alive "$pid"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

copilot_session_workspace_value() {
  local workspace="$1" key="$2"
  local value
  value="$(awk -v key="$key" '
    $0 ~ "^" key ": " {
      sub("^" key ": ", "")
      print
      exit
    }
  ' "$workspace" 2>/dev/null)"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      value="${value//\\\"/\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s\n' "$value"
}

copilot_session_archive_id() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return 0

  local state_root session_dir archive_root archive_target workspace workspace_id workspace_name
  state_root="$(copilot_session_state_dir)"
  session_dir="$state_root/$session_id"
  archive_root="$(copilot_session_archive_dir)"
  archive_target="$archive_root/$session_id"

  [[ -d "$session_dir" ]] || return 0
  if [[ -e "$archive_target" ]]; then
    echo "Warning: Ralph Copilot session archive already exists for $session_id; leaving live state untouched." >&2
    return 0
  fi
  if copilot_session_has_live_lock "$session_dir"; then
    echo "Warning: Ralph Copilot session $session_id still appears in-use; leaving it." >&2
    return 0
  fi

  workspace="$session_dir/workspace.yaml"
  if [[ ! -f "$workspace" ]]; then
    echo "Warning: Ralph Copilot session $session_id has no workspace.yaml; leaving it." >&2
    return 0
  fi
  workspace_id="$(copilot_session_workspace_value "$workspace" "id")"
  workspace_name="$(copilot_session_workspace_value "$workspace" "name")"
  if [[ "$workspace_id" != "$session_id" ]]; then
    echo "Warning: Ralph Copilot session $session_id workspace id mismatch; leaving it." >&2
    return 0
  fi
  if [[ "$workspace_name" != Ralph\ * ]]; then
    echo "Warning: Ralph Copilot session $session_id name is not Ralph-owned; leaving it." >&2
    return 0
  fi

  mkdir -p "$archive_root"
  mv "$session_dir" "$archive_target"
  echo "Archived Ralph Copilot session: $session_id"
}

copilot_session_archive_completed() {
  local ledgers
  ledgers="$(copilot_session_ledger_files)"
  [[ -n "$ledgers" ]] || return 0

  local session_ids session_id
  session_ids="$(
    while IFS= read -r ledger; do
      jq -r '
        select(.event == "terminal")
        | select(.terminalStatus == "merged" or .terminalStatus == "skipped" or .terminalStatus == "resumed")
        | .sessionId // empty
      ' "$ledger" 2>/dev/null || true
    done <<<"$ledgers" | sort -u
  )"
  [[ -n "$session_ids" ]] || return 0

  while IFS= read -r session_id; do
    [[ -n "$session_id" ]] && copilot_session_archive_id "$session_id"
  done <<<"$session_ids"
}
