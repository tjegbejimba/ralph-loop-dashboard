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

# Try to claim a recovery lease for a due recoverable item
# Args: issue worker_id pid
# Returns: 0 if claimed, 1 if already leased or not due
ledger_try_claim_recovery() {
  local issue="$1" worker_id="$2" pid="$3"
  local file
  file=$(ledger_file)
  
  # Must be due and exist
  if ! ledger_is_recovery_due "$issue"; then
    return 1
  fi
  
  local entry
  entry=$(ledger_load_entry "$issue")
  
  # Check if already leased
  local leased_by leased_at
  leased_by=$(echo "$entry" | jq -r '.leasedBy // empty')
  leased_at=$(echo "$entry" | jq -r '.leasedAt // empty')
  
  # If leased, check if lease is stale (>30 minutes)
  if [[ -n "$leased_by" && "$leased_by" != "null" ]]; then
    if [[ -n "$leased_at" && "$leased_at" != "null" ]]; then
      local now_ts lease_ts
      now_ts=$(date -u +%s)
      lease_ts=$(date -u -d "$leased_at" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$leased_at" +%s 2>/dev/null || echo "0")
      local lease_age=$((now_ts - lease_ts))
      
      # Lease is fresh (< 30 minutes), cannot claim
      if [[ $lease_age -lt 1800 ]]; then
        return 1
      fi
    else
      # Has leasedBy but no timestamp — treat as active to be safe
      return 1
    fi
  fi
  
  # Claim the lease
  local tmp
  tmp=$(ledger_mktemp)
  jq --arg issue "$issue" \
     --arg worker "$worker_id" \
     --arg pid "$pid" \
     '.[$issue].leasedBy = $worker
     | .[$issue].leasePid = $pid
     | .[$issue].leasedAt = (now | todateiso8601)' "$file" >"$tmp"
  mv "$tmp" "$file"
  
  return 0
}

# Release a recovery lease
# Args: issue
ledger_release_recovery() {
  local issue="$1"
  local file
  file=$(ledger_file)
  
  [[ ! -f "$file" ]] && return 0
  
  local tmp
  tmp=$(ledger_mktemp)
  jq --arg issue "$issue" '
    if .[$issue] then
      .[$issue].leasedBy = null
      | .[$issue].leasePid = null
      | .[$issue].leasedAt = null
    else . end
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Increment attempt counter and update nextRetryAt
# Args: issue
# Returns: 0 if within budget, 1 if budget exhausted
ledger_increment_attempt() {
  local issue="$1"
  local file retry_budget
  file=$(ledger_file)
  retry_budget="${RALPH_RETRY_BUDGET:-2}"
  
  local entry
  entry=$(ledger_load_entry "$issue")
  [[ -z "$entry" ]] && return 1
  
  local current_attempt
  current_attempt=$(echo "$entry" | jq -r '.attempt // 0')
  local next_attempt=$((current_attempt + 1))
  
  # Check if budget exhausted
  if [[ $next_attempt -gt $retry_budget ]]; then
    ledger_mark_terminal_failed "$issue" "retry budget exhausted ($next_attempt > $retry_budget)"
    return 1
  fi
  
  # Increment and set 5-minute cooldown
  local next_retry
  next_retry=$(date -u -d '+5 minutes' +%FT%TZ 2>/dev/null || date -u -v+5M +%FT%TZ)
  
  local tmp
  tmp=$(ledger_mktemp)
  jq --arg issue "$issue" \
     --argjson attempt "$next_attempt" \
     --arg next_retry "$next_retry" \
     '.[$issue].attempt = $attempt
     | .[$issue].nextRetryAt = $next_retry' "$file" >"$tmp"
  mv "$tmp" "$file"
  
  return 0
}

# Mark an entry as terminally failed
# Args: issue reason
ledger_mark_terminal_failed() {
  local issue="$1" reason="$2"
  local file
  file=$(ledger_file)
  
  [[ ! -f "$file" ]] && return 1
  
  local tmp
  tmp=$(ledger_mktemp)
  jq --arg issue "$issue" \
     --arg reason "$reason" \
     '.[$issue].status = "failed"
     | .[$issue].failureReason = $reason
     | .[$issue].failedAt = (now | todateiso8601)' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Remove a recovery ledger entry (called on successful merge)
# Args: issue
ledger_remove_entry() {
  local issue="$1"
  local file
  file=$(ledger_file)
  
  [[ ! -f "$file" ]] && return 0
  
  local tmp
  tmp=$(ledger_mktemp)
  jq --arg issue "$issue" 'del(.[$issue])' "$file" >"$tmp"
  mv "$tmp" "$file"
}
