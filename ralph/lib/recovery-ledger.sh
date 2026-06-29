#!/usr/bin/env bash
# recovery-ledger.sh — durable recovery ledger for parked Ralph work
#
# Coordinates recoverable issues that have durable PR/branch evidence but
# exited before merge. The ledger prevents immediate re-claiming and tracks
# retry budget, cooldowns, and lease expiry.

# Requires state.sh to be sourced first for STATE_DIR
if [[ -z "${STATE_DIR:-}" ]]; then
  echo "⚠️  recovery-ledger.sh requires state.sh to be sourced first (STATE_DIR undefined)" >&2
  return 1
fi

# Path to the recovery ledger file
ledger_file() {
  echo "$STATE_DIR/recovery-ledger.json"
}

# Same-filesystem mktemp for atomic mv into ledger
ledger_mktemp() {
  mktemp "$STATE_DIR/.recovery-ledger.XXXXXX"
}

# Initialize ledger if missing (empty object)
ledger_init() {
  local file
  file=$(ledger_file)
  [[ -f "$file" ]] && return 0
  
  local tmp
  tmp=$(ledger_mktemp)
  printf '%s\n' '{}' >"$tmp"
  mv "$tmp" "$file"
}

# Record a recoverable entry for an issue
# Args: issue pr branch attempt next_retry_at reason
ledger_record_recoverable() {
  local issue="$1" pr="$2" branch="$3" attempt="$4" next_retry="$5" reason="$6"
  local file
  file=$(ledger_file)
  
  ledger_init
  
  local tmp
  tmp=$(ledger_mktemp)
  jq --arg issue "$issue" \
     --arg pr "$pr" \
     --arg branch "$branch" \
     --arg attempt "$attempt" \
     --arg next_retry "$next_retry" \
     --arg reason "$reason" \
     '.[$issue] = {
       pr: $pr,
       branch: $branch,
       attempt: ($attempt | tonumber),
       nextRetryAt: $next_retry,
       reason: $reason,
       status: "recoverable",
       recordedAt: (now | todateiso8601)
     }' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Load recovery entry for an issue
# Args: issue
# Returns: JSON object or empty string if not found
ledger_load_entry() {
  local issue="$1"
  local file
  file=$(ledger_file)
  [[ ! -f "$file" ]] && return 1
  
  jq -r --arg issue "$issue" '.[$issue] // empty' "$file"
}

# Check if issue has a recoverable entry
# Args: issue
# Returns: 0 if recoverable, 1 otherwise
ledger_is_recoverable() {
  local issue="$1"
  local entry
  entry=$(ledger_load_entry "$issue")
  [[ -n "$entry" ]]
}

# Check if recovery lease has expired (recovery is due)
# Args: issue
# Returns: 0 if due, 1 if lease active or not found
ledger_is_recovery_due() {
  local issue="$1"
  local entry
  entry=$(ledger_load_entry "$issue")
  [[ -z "$entry" ]] && return 1
  
  local next_retry
  next_retry=$(echo "$entry" | jq -r '.nextRetryAt')
  [[ -z "$next_retry" || "$next_retry" == "null" ]] && return 1
  
  local now_ts
  now_ts=$(date -u +%s)
  local retry_ts
  retry_ts=$(date -u -d "$next_retry" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$next_retry" +%s 2>/dev/null || echo "0")
  
  [[ "$now_ts" -ge "$retry_ts" ]]
}
