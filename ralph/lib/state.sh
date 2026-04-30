#!/usr/bin/env bash
# state.sh — shared state for parallel Ralph workers.
#
# Coordinates issue claims across N concurrent workers via a single state file
# (.ralph/state.json) guarded by a portable mkdir-based lock. Stale claims
# (worker process no longer running) are reaped on every read.
#
# This file is sourced — not executed — by ralph.sh. All functions assume:
#   $LOG_DIR    — directory holding .ralph/logs/ (parent of state.json)
#   $REPO       — owner/repo for gh calls (only used by eligibility helper)

# Path conventions. STATE_FILE lives next to logs so a single .ralph/ symlink
# in the worktree picks up state, locks, and logs together.
STATE_DIR="$(dirname "$LOG_DIR")"
STATE_FILE="$STATE_DIR/state.json"
STATE_LOCK="$STATE_DIR/state.lock"

# Acquire the state lock. Polls every 200ms up to ~10s, then gives up.
# Returns 0 on success, 1 on timeout. Caller must call state_unlock on exit.
state_lock() {
  local i=0
  while ! mkdir "$STATE_LOCK" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
    if [[ $i -gt 50 ]]; then
      echo "⚠️  state_lock: timed out waiting for $STATE_LOCK" >&2
      return 1
    fi
  done
  return 0
}

state_unlock() {
  rmdir "$STATE_LOCK" 2>/dev/null || true
}

# Initialize state.json if missing. Safe to call without holding the lock —
# only writes if the file doesn't exist.
state_init() {
  [[ -f "$STATE_FILE" ]] && return 0
  echo '{"claims":{}}' >"$STATE_FILE"
}

# Reap claims whose pid is no longer running. Caller MUST hold the state lock.
# Mutates state.json in place.
state_reap_stale() {
  local tmp
  tmp=$(mktemp)
  # Build a list of currently-running pids (one per line).
  ps -axo pid= | tr -d ' ' >"$tmp.alive"
  jq --slurpfile alive <(jq -R . "$tmp.alive" | jq -s .) '
    .claims = (
      .claims
      | to_entries
      | map(select(
          ([.value.pid | tostring] | inside($alive[0]))
        ))
      | from_entries
    )
  ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
  rm -f "$tmp.alive"
}

# Print the JSON object of currently-claimed issues. Caller should hold the
# lock if reading-and-deciding (otherwise data races possible).
state_claims() {
  jq '.claims' "$STATE_FILE"
}

# Print one issue number per line for currently-claimed issues.
state_claimed_issues() {
  jq -r '.claims | keys[]' "$STATE_FILE"
}

# Add a claim. Caller MUST hold the lock.
# Args: issue_number worker_id pid log_file
state_claim() {
  local issue="$1" worker="$2" pid="$3" logfile="$4"
  local tmp started_at
  tmp=$(mktemp)
  started_at="$(date -u +%FT%TZ)"
  jq --arg issue "$issue" --argjson worker "$worker" --argjson pid "$pid" \
    --arg started "$started_at" --arg logfile "$logfile" '
      .claims[$issue] = {
        workerId: $worker,
        pid: $pid,
        startedAt: $started,
        logFile: $logfile
      }
    ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
}

# Remove a claim. Caller MUST hold the lock.
state_release() {
  local issue="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg issue "$issue" 'del(.claims[$issue])' "$STATE_FILE" >"$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

# Parse the "## Blocked by" section of an issue body and emit blocker issue
# numbers, one per line. Empty output = no blockers.
#
# Recognizes:
#   ## Blocked by
#   - #125 (Slice 0)
#   - #126
#
# And short-circuits on:
#   ## Blocked by
#   None — can start immediately.
parse_blockers() {
  local body="$1"
  # Extract the section between "## Blocked by" and the next "##" header.
  local section
  section=$(printf '%s\n' "$body" \
    | awk '/^## Blocked by/{flag=1; next} /^## /{flag=0} flag')
  # If the section says "None", treat as no blockers.
  if printf '%s' "$section" | grep -qiE '^[[:space:]]*-?[[:space:]]*none\b'; then
    return 0
  fi
  printf '%s' "$section" | grep -oE '#[0-9]+' | tr -d '#' | sort -u
}

# Check whether a single issue number is CLOSED on the configured repo.
# Echoes "1" if closed, "0" otherwise. Network-touching; cached by caller.
is_issue_closed() {
  local n="$1"
  local state
  state=$(gh issue view "$n" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  [[ "$state" == "CLOSED" ]] && echo 1 || echo 0
}
