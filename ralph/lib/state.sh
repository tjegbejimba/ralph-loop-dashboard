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

# is_pid_alive PID
# Cheap liveness check via signal 0. True iff the PID currently exists.
# Use this for short-lived ownership checks (e.g. lock holders) where PID
# reuse is essentially impossible because the window is sub-second.
is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" && "$pid" != "0" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# is_pid_alive_and_ralph PID
# Stronger check: PID exists AND its command line still mentions ralph.sh,
# launch.sh, or copilot. Use this for long-lived ownership checks (claim
# reaping, worker singleton lock takeover) where the lock can survive long
# enough for the OS to recycle the PID for an unrelated process.
is_pid_alive_and_ralph() {
  local pid="$1"
  is_pid_alive "$pid" || return 1
  local cmd
  cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$cmd" in
    *ralph.sh*|*launch.sh*|*copilot*) return 0 ;;
    *) return 1 ;;
  esac
}

# Acquire a directory-based lock with stale-takeover semantics.
# Used by state_lock and the per-worker singleton lock in ralph.sh. Writes
# the holder's PID into <lockdir>/owner so a crashed holder can be detected
# and reaped. Polls every 200ms up to ~10s.
#
# Liveness is checked via is_pid_alive (NOT the stricter ralph-cmd match)
# because lock holders are short-lived (sub-second jq ops). PID reuse during
# such a tiny window is effectively impossible, and using the strict match
# would let competing acquirers reap each other's freshly-acquired locks
# (any pid whose command happens not to match ralph/launch/copilot —
# e.g. during install.sh or external test harnesses — would falsely look
# "stale"). Worker-singleton and claim reaping use the stricter check
# because those *do* live long enough to matter.
acquire_lockdir() {
  local lockdir="$1"
  local check="${2:-is_pid_alive}"  # liveness predicate
  local i=0
  local owner_pid
  while true; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lockdir/owner" 2>/dev/null || true
      return 0
    fi
    # Held — check whether the holder is alive.
    owner_pid=""
    [[ -f "$lockdir/owner" ]] && owner_pid=$(cat "$lockdir/owner" 2>/dev/null || echo "")
    if [[ -n "$owner_pid" ]] && ! "$check" "$owner_pid"; then
      echo "⚠️  acquire_lockdir: reaping stale lock $lockdir (owner pid=$owner_pid dead)" >&2
      rm -rf "$lockdir" 2>/dev/null || true
      continue
    fi
    if [[ -z "$owner_pid" ]]; then
      # Holder won the mkdir race but hasn't written owner yet. Wait
      # generously — even on a heavily loaded box, owner is written within
      # microseconds of mkdir succeeding. If still missing after 6s the
      # holder must be wedged; reap and retry.
      if [[ $i -gt 30 ]]; then
        echo "⚠️  acquire_lockdir: lock $lockdir has no owner file after 6s; reaping" >&2
        rm -rf "$lockdir" 2>/dev/null || true
        continue
      fi
    fi
    sleep 0.2
    i=$((i + 1))
    if [[ $i -gt 50 ]]; then
      echo "⚠️  acquire_lockdir: timed out waiting for $lockdir (live owner pid=$owner_pid)" >&2
      return 1
    fi
  done
}

release_lockdir() {
  rm -rf "$1" 2>/dev/null || true
}

state_lock() {
  acquire_lockdir "$STATE_LOCK"
}

state_unlock() {
  release_lockdir "$STATE_LOCK"
}

# Same-filesystem mktemp — guarantees mv into STATE_FILE is an atomic rename
# (mv across filesystems degenerates to copy+unlink, defeating atomicity).
state_mktemp() {
  mktemp "$STATE_DIR/.state.XXXXXX"
}

# Initialize state.json if missing. Acquires the state lock to prevent
# parallel first-launch from racing on truncating writes.
state_init() {
  [[ -f "$STATE_FILE" ]] && return 0
  state_lock || return 1
  if [[ ! -f "$STATE_FILE" ]]; then
    local tmp
    tmp=$(state_mktemp)
    printf '%s\n' '{"claims":{}}' >"$tmp"
    mv "$tmp" "$STATE_FILE"
  fi
  state_unlock
}

# Reap claims whose worker process is no longer alive. Stronger than a
# bare PID-exists check — also requires the command line to look like a
# ralph worker so PID reuse doesn't keep dead claims forever.
# Caller MUST hold the state lock.
state_reap_stale() {
  local tmp claims_json issue pid
  claims_json=$(jq -r '.claims | to_entries[] | "\(.key) \(.value.pid)"' "$STATE_FILE" 2>/dev/null || true)
  local dead_issues=()
  while IFS=' ' read -r issue pid; do
    [[ -z "$issue" ]] && continue
    if ! is_pid_alive_and_ralph "$pid"; then
      dead_issues+=("$issue")
    fi
  done <<<"$claims_json"
  if [[ ${#dead_issues[@]} -eq 0 ]]; then
    return 0
  fi
  tmp=$(state_mktemp)
  local del_args=()
  for issue in "${dead_issues[@]}"; do
    del_args+=(--arg "i_$issue" "$issue")
  done
  # Build the deletion expression dynamically.
  local jq_filter='.'
  for issue in "${dead_issues[@]}"; do
    jq_filter="$jq_filter | del(.claims[\"$issue\"])"
  done
  jq "$jq_filter" "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
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
  tmp=$(state_mktemp)
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
  tmp=$(state_mktemp)
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

# Check whether an issue is closed by a *merged PR* — the same predicate the
# loop uses to verify its own iteration succeeded. Stronger than just
# checking issue.state == CLOSED, which can be true for wontfix/duplicate
# closures whose code never landed on main. Echoes "1" if closed by merged
# PR, "0" otherwise. Caller is responsible for caching across the candidate
# loop to avoid O(N) gh calls per blocker per worker.
is_issue_satisfied() {
  local n="$1"
  local closure state pr_numbers pr merged_at
  closure=$(gh issue view "$n" --repo "$REPO" \
    --json state,closedByPullRequestsReferences 2>/dev/null || echo "")
  [[ -z "$closure" ]] && { echo 0; return; }
  state=$(echo "$closure" | jq -r .state)
  [[ "$state" != "CLOSED" ]] && { echo 0; return; }
  pr_numbers=$(echo "$closure" | jq -r '(.closedByPullRequestsReferences // [])[].number')
  for pr in $pr_numbers; do
    merged_at=$(gh pr view "$pr" --repo "$REPO" --json mergedAt -q .mergedAt 2>/dev/null || echo "")
    if [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
      echo 1
      return
    fi
  done
  # Release-branch fallback: GitHub does not populate
  # closedByPullRequestsReferences for PRs whose base != default branch.
  # When RALPH_RELEASE_BRANCH is set, accept state=CLOSED + a merged PR with
  # closing-keyword body match into the release branch as satisfied. See
  # docs/release-branch.md.
  if [[ -n "${RALPH_RELEASE_BRANCH:-}" ]]; then
    local found
    found=$(gh pr list --repo "$REPO" --state merged --base "$RALPH_RELEASE_BRANCH" \
      --search "in:body \"Closes #${n}\" OR in:body \"Fixes #${n}\" OR in:body \"Resolves #${n}\"" \
      --json number -q '.[0].number' 2>/dev/null || echo "")
    if [[ -n "$found" && "$found" != "null" ]]; then
      echo 1
      return
    fi
  fi
  echo 0
}

# Backward-compat alias for code that just wants the loose "issue is CLOSED"
# semantics. Currently unused after the merged-PR upgrade above; retained
# for potential future opt-out scenarios.
is_issue_closed() {
  local n="$1"
  local state
  state=$(gh issue view "$n" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  [[ "$state" == "CLOSED" ]] && echo 1 || echo 0
}
