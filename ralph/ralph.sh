#!/usr/bin/env bash
# TDD Ralph loop.
# Iterates the lowest-numbered open issue matching $TITLE_REGEX whose declared
# blockers are all closed, runs Copilot CLI non-interactively with RALPH.md as
# the prompt, and waits for the issue to close via merged PR.
#
# Workers coordinate through .ralph/state.json so multiple copies of this script
# (one per dedicated worktree) can run safely in parallel without claiming the
# same issue. See .ralph/launch.sh for the parallel spawn entry point.
#
# Usage:
#   .ralph/ralph.sh           # loop until no eligible open issues remain
#   .ralph/ralph.sh --once    # run a single iteration then exit
#
# Env:
#   RALPH_MODEL          model passed to copilot (default: claude-sonnet-4.5)
#   RALPH_TIMEOUT_SEC    per-iteration timeout in seconds (default: 7200)
#   RALPH_WORKER_ID      this worker's identity (default: 1) — must be unique
#                        across concurrent workers; controls lock + log naming
#   RALPH_POLL_SEC       sleep between selection attempts when no work is
#                        eligible (default: 30)
#   RALPH_RUN_ID         run identifier for queue-based mode (optional)
#                        When set, worker consumes .ralph/runs/<RUN_ID>/queue.json
#                        instead of searching GitHub with TITLE_REGEX

set -euo pipefail

# Ensure homebrew tools (gh, etc.) are on PATH even when launched from
# minimal-PATH contexts (nohup, launchd, dashboard, etc.)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

config_get() {
  local jq_path="$1"
  if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    jq -r "${jq_path} // empty" "$CONFIG_FILE" 2>/dev/null || true
  fi
}

REPO="${RALPH_REPO:-$(git -C "$(git rev-parse --show-toplevel)" config --get remote.origin.url 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')}"
TITLE_REGEX="${RALPH_TITLE_REGEX:-$(config_get '.issue.titleRegex')}"
TITLE_REGEX="${TITLE_REGEX:-^Slice [0-9]+:}"
TITLE_NUM_RE="${RALPH_TITLE_NUM_REGEX:-$(config_get '.issue.titleNumRegex')}"
TITLE_NUM_RE="${TITLE_NUM_RE:-^Slice (?<x>[0-9]+):}"
if ! jq -nr --arg re "$TITLE_REGEX" '"" | test($re)' >/dev/null 2>&1; then
  echo "⚠️  Invalid issue.titleRegex \"$TITLE_REGEX\"; using default Slice pattern." >&2
  TITLE_REGEX="^Slice [0-9]+:"
fi
if ! jq -nr --arg re "$TITLE_NUM_RE" '"Slice 1:" | capture($re)' >/dev/null 2>&1; then
  echo "⚠️  Invalid issue.titleNumRegex \"$TITLE_NUM_RE\"; using default Slice number pattern." >&2
  TITLE_NUM_RE="^Slice (?<x>[0-9]+):"
fi
PROMPT_FILE="$SCRIPT_DIR/RALPH.md"
LOG_DIR="$SCRIPT_DIR/logs"
WORKER_ID="${RALPH_WORKER_ID:-1}"
LOCK_DIR="$SCRIPT_DIR/lock/worker-${WORKER_ID}"
MODEL="${RALPH_MODEL:-claude-sonnet-4.5}"
TIMEOUT_SEC="${RALPH_TIMEOUT_SEC:-7200}"
POLL_SEC="${RALPH_POLL_SEC:-30}"
RUN_ID="${RALPH_RUN_ID:-}"
ONCE=0

# Parse --run-id flag (overrides RALPH_RUN_ID env var)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)
      ONCE=1
      shift
      ;;
    --run-id)
      if [[ -z "${2:-}" ]]; then
        echo "⚠️  --run-id requires an argument" >&2
        exit 1
      fi
      RUN_ID="$2"
      shift 2
      ;;
    *)
      echo "⚠️  Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done
export RUN_ID

if [[ -z "$REPO" ]]; then
  echo "⚠️  Could not determine target repo. Set RALPH_REPO=owner/repo." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"
mkdir -p "$LOG_DIR" "$SCRIPT_DIR/lock"

# Coordination helpers (state.json, blocker parsing, claim management).
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
state_init

# Per-run status tracking (status.json). Only needed in run-aware mode.
# shellcheck source=lib/status.sh
. "$SCRIPT_DIR/lib/status.sh"
# PR merge fallback helpers.
# shellcheck source=lib/pr-merge.sh
. "$SCRIPT_DIR/lib/pr-merge.sh"
if [[ -n "$RUN_ID" ]]; then
  status_init
fi

# Sync the current branch to origin/main. Works both when run on `main` itself
# (legacy single-checkout mode) and in a dedicated worktree on a non-main branch
# (preferred — see .ralph/launch.sh, prevents collisions with local edits).
#
# Wraps git fetch in a retry loop because N concurrent workers share a single
# .git/ and can race on refs/remotes/origin/main.lock. With set -euo pipefail,
# a single ref-lock collision would kill the worker; nohup launches don't
# respawn, silently degrading parallelism.
sync_to_origin_main() {
  local branch attempt rc
  branch=$(git rev-parse --abbrev-ref HEAD)
  for attempt in 1 2 3 4 5; do
    if git fetch origin main >/dev/null 2>&1; then
      rc=0
      break
    fi
    rc=$?
    # Jittered backoff: 0.5–1.5s × attempt
    sleep "$(awk -v a="$attempt" 'BEGIN{srand(); printf "%.2f", a*(0.5+rand())}')"
  done
  if [[ "${rc:-1}" -ne 0 ]]; then
    echo "⚠️  git fetch origin main failed after 5 attempts (rc=$rc). Halting." >&2
    return "$rc"
  fi
  if [[ "$branch" == "main" ]]; then
    git checkout main >/dev/null
    git pull --ff-only origin main >/dev/null
  else
    # Dedicated loop worktree — force-sync the branch to origin/main.
    git reset --hard origin/main >/dev/null
  fi
}

# Per-worker singleton lock — prevents the same WORKER_ID from running twice.
# Uses acquire_lockdir with the strict ralph-cmd predicate because this lock
# can live for hours (an entire worker session), long enough for PID reuse
# to be a real concern if a worker crashes ungracefully. The default
# bare-liveness predicate would risk handing the lock to a recycled PID
# inheriting some unrelated process.
if ! acquire_lockdir "$LOCK_DIR" is_pid_alive_and_ralph; then
  echo "⚠️  Worker $WORKER_ID already running (lock at $LOCK_DIR held by live ralph process). Exiting." >&2
  exit 1
fi
# Release lock on exit. Also release any in-flight claim — see
# CURRENT_CLAIM tracking below. (SIGKILL bypasses this trap; that's why
# acquire_lockdir does stale-takeover on next launch.)
CURRENT_CLAIM=""
cleanup() {
  if [[ -n "$CURRENT_CLAIM" ]]; then
    state_lock && state_release "$CURRENT_CLAIM" && state_unlock || true
  fi
  release_lockdir "$LOCK_DIR"
}
trap cleanup EXIT

# Portable timeout wrapper (macOS-safe)
run_with_timeout() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --foreground "$secs" "$@"
  else
    perl -e 'my $secs = shift; $SIG{ALRM} = sub { kill "TERM", -$$; exit 124 }; alarm $secs; setpgrp(0,0); exec @ARGV or die "exec: $!"' "$secs" "$@"
  fi
}

wait_for_issue_closed_by_merged_pr() {
  local issue="$1"
  local context="$2"
  local closure state pr_numbers merged_count pr merged_at attempt
  for attempt in 1 2 3 4 5 6; do
    closure=$(gh issue view "$issue" --repo "$REPO" \
      --json state,closedByPullRequestsReferences)
    state=$(echo "$closure" | jq -r .state)
    pr_numbers=$(echo "$closure" | jq -r '(.closedByPullRequestsReferences // [])[].number')
    merged_count=0
    for pr in $pr_numbers; do
      merged_at=$(gh pr view "$pr" --repo "$REPO" --json mergedAt -q .mergedAt 2>/dev/null || echo "")
      if [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
        merged_count=$((merged_count + 1))
      fi
    done
    if [[ "$state" == "CLOSED" && "$merged_count" -ge 1 ]]; then
      return 0
    fi
    if [[ "$attempt" -lt 6 ]]; then
      echo "ℹ️  Issue #$issue closure metadata not yet propagated $context (state=$state, merged_prs=$merged_count); retry $attempt/5 in 5s..." >&2
      sleep 5
    fi
  done
  return 1
}

while true; do
  # Preflight: clean tree, on main, up to date
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "⚠️  Working tree is dirty. Halting." >&2
    git status --short
    exit 1
  fi
  sync_to_origin_main

  # Run-aware mode: consume queue.json instead of searching GitHub
  if [[ -n "$RUN_ID" ]]; then
    queue_file="$SCRIPT_DIR/runs/$RUN_ID/queue.json"
    if [[ ! -f "$queue_file" ]]; then
      echo "❌ Worker $WORKER_ID: run $RUN_ID queue file not found: $queue_file" >&2
      exit 1
    fi
    
    state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
    state_reap_stale
    status_reap_stale
    claimed_set="$(state_claimed_issues | sort -u)"
    state_unlock
    
    # Find next unclaimed issue from queue
    queue_json=$(cat "$queue_file")
    num=""; title=""; body=""; chosen_blockers=""
    
    for row in $(echo "$queue_json" | jq -r '.[] | @base64'); do
      decoded=$(echo "$row" | tr -d '\r' | base64 --decode)
      cand_num=$(echo "$decoded" | jq -r .number)
      cand_title=$(echo "$decoded" | jq -r .title)
      
      # Skip if already claimed in state.json
      if printf '%s\n' "$claimed_set" | grep -qx "$cand_num"; then
        continue
      fi
      
      # Skip if in terminal state in status.json
      if status_is_terminal "$cand_num"; then
        continue
      fi
      
      # Check if issue is already CLOSED on GitHub before claiming
      current_state=$(gh issue view "$cand_num" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
      if [[ "$current_state" != "OPEN" ]]; then
        # Mark as skipped and continue to next
        state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
        status_mark_skipped "$cand_num"
        state_unlock
        echo "ℹ️  Worker $WORKER_ID: #$cand_num already closed (state=$current_state); marked as skipped."
        continue
      fi
      
      # Fetch issue body for prompt construction
      cand_body=$(gh issue view "$cand_num" --repo "$REPO" --json body -q .body 2>/dev/null || echo "")
      
      num="$cand_num"
      title="$cand_title"
      body="$cand_body"
      break
    done
    
    if [[ -z "$num" ]]; then
      # No unclaimed issues remain — check if any are still running
      remaining=$(echo "$queue_json" | jq -r 'length')
      if [[ "$remaining" -eq 0 ]]; then
        echo "✅ Worker $WORKER_ID: run $RUN_ID queue is empty. Done."
        exit 0
      fi
      echo "⏸  Worker $WORKER_ID: no unclaimed issues in run $RUN_ID queue (total=$remaining); sleeping ${POLL_SEC}s."
      sleep "$POLL_SEC"
      continue
    fi
  else
    # Legacy mode: search GitHub for issues matching TITLE_REGEX
    # Fetch open issues matching the title regex along with their bodies so we
    # can evaluate "Blocked by" sections without an extra round-trip per issue.
    open_json=$(gh issue list --repo "$REPO" --state open --limit 100 \
      --json number,title,body)

    # Sort eligible issues by slice number ascending; pick the first one whose
    # blockers are all closed AND that no other worker has already claimed.
    state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
    state_reap_stale
    claimed_set="$(state_claimed_issues | sort -u)"
    state_unlock

    # Build a sorted list of (number, title, body) for matching issues.
    candidates=$(echo "$open_json" \
      | TITLE_REGEX="$TITLE_REGEX" TITLE_NUM_RE="$TITLE_NUM_RE" jq -r '
          [ .[]
            | select(.title | test(env.TITLE_REGEX))
            | . + {n: (.title | capture(env.TITLE_NUM_RE).x | tonumber)} ]
          | sort_by(.n)
          | .[]
          | @base64
        ')

    # Memoize blocker satisfaction across this selection round so M candidates
    # × K blockers don't translate into M×K `gh issue view`/`gh pr view` calls.
    # Cache lives only until the next polling cycle to stay fresh.
    declare -A BLOCKER_CACHE=()
    blocker_satisfied() {
      local b="$1"
      if [[ -n "${BLOCKER_CACHE[$b]+x}" ]]; then
        printf '%s' "${BLOCKER_CACHE[$b]}"
        return
      fi
      local v
      v=$(is_issue_satisfied "$b")
      BLOCKER_CACHE[$b]="$v"
      printf '%s' "$v"
    }

    num=""; title=""; body=""; chosen_blockers=""
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      decoded=$(echo "$row" | tr -d '\r' | base64 --decode)
      cand_num=$(echo "$decoded" | jq -r .number)
      cand_title=$(echo "$decoded" | jq -r .title)
      cand_body=$(echo "$decoded" | jq -r .body)

      # Skip issues other workers have claimed.
      if printf '%s\n' "$claimed_set" | grep -qx "$cand_num"; then
        continue
      fi

      # Evaluate blockers — every #N referenced in the "## Blocked by" section
      # must be closed by a merged PR (same predicate the iteration uses for
      # itself, so manually-closed wontfix/duplicate blockers don't unblock
      # downstream slices whose code never landed).
      blockers=$(parse_blockers "$cand_body")
      all_satisfied=1
      for b in $blockers; do
        if [[ "$(blocker_satisfied "$b")" != "1" ]]; then
          all_satisfied=0
          break
        fi
      done
      if [[ "$all_satisfied" -ne 1 ]]; then
        continue
      fi

      num="$cand_num"
      title="$cand_title"
      body="$cand_body"
      chosen_blockers="$blockers"
      break
    done <<<"$candidates"

    if [[ -z "$num" ]]; then
      # Nothing actionable right now. If any issues are still open and not
      # claimed, we're waiting on dependencies; sleep and retry. If everything
      # is claimed by other workers, also sleep.
      remaining=$(echo "$open_json" \
        | TITLE_REGEX="$TITLE_REGEX" jq -r '
            [.[] | select(.title | test(env.TITLE_REGEX))] | length')
      if [[ "$remaining" -eq 0 ]]; then
        echo "✅ Worker $WORKER_ID: no open issues match \"$TITLE_REGEX\". Done."
        exit 0
      fi
      echo "⏸  Worker $WORKER_ID: no eligible issue (remaining=$remaining, claimed=$(echo "$claimed_set" | wc -l | tr -d ' ')); sleeping ${POLL_SEC}s."
      sleep "$POLL_SEC"
      continue
    fi
  fi
  # End of legacy/run-aware mode branching — both paths set num, title, body
  iter_start_ts=$(date -u +%FT%TZ)

  ts="$(date +%Y%m%d-%H%M%S)"
  log_file="$LOG_DIR/iter-${ts}-w${WORKER_ID}-issue-${num}.log"
  # Touch so dashboards pointing at logFile see a real (empty) file before
  # the iteration body's tee starts writing.
  : >"$log_file"

  # Atomic claim: re-acquire lock, re-check that nobody else grabbed this
  # issue between selection and now, AND re-validate blockers (a blocker
  # could have been reopened, or the issue itself could have been closed).
  state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
  state_reap_stale
  if state_claimed_issues | grep -qx "$num"; then
    state_unlock
    echo "↪️  Worker $WORKER_ID: #$num was claimed by another worker between selection and claim; retrying."
    continue
  fi
  # Re-fetch this issue's state and re-check blockers under the lock. If
  # anything changed, drop the candidate and re-poll.
  current_state=$(gh issue view "$num" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  if [[ "$current_state" != "OPEN" ]]; then
    state_unlock
    echo "↪️  Worker $WORKER_ID: #$num is no longer OPEN (state=$current_state); retrying."
    continue
  fi
  blockers_still_satisfied=1
  for b in $chosen_blockers; do
    if [[ "$(is_issue_satisfied "$b")" != "1" ]]; then
      blockers_still_satisfied=0
      break
    fi
  done
  if [[ "$blockers_still_satisfied" -ne 1 ]]; then
    state_unlock
    echo "↪️  Worker $WORKER_ID: #$num blocker became unsatisfied during selection; retrying."
    continue
  fi
  state_claim "$num" "$WORKER_ID" "$$" "$(basename "$log_file")"
  CURRENT_CLAIM="$num"
  # In run-aware mode, also update status.json atomically under same lock
  if [[ -n "$RUN_ID" ]]; then
    status_update_item "$num" "claimed" "$WORKER_ID" "$$" "$(basename "$log_file")" "$iter_start_ts"
  fi
  state_unlock

  default_branch=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
  if ralph_merge_ready_open_pr_for_issue "$num" "$default_branch"; then
    if wait_for_issue_closed_by_merged_pr "$num" "after pre-claim fallback merge"; then
      if [[ -n "$RUN_ID" ]]; then
        state_lock || true
        status_update_item "$num" "merged" "$WORKER_ID" "$$" "$(basename "$log_file")" "$iter_start_ts"
        state_unlock || true
      fi
      echo "✅ Worker $WORKER_ID: merged ready PR for #$num before launching Copilot."
      state_lock && state_release "$num" && state_unlock || true
      CURRENT_CLAIM=""
      sync_to_origin_main
      if [[ "$ONCE" -eq 1 ]]; then
        echo "🛑 --once: exiting after one iteration."
        exit 0
      fi
      continue
    fi
  fi

  echo ""
  echo "============================================================"
  echo "▶️  $(date -u +%FT%TZ)  Worker $WORKER_ID — #$num: $title"
  echo "    log: $log_file"
  echo "    model: $MODEL    timeout: ${TIMEOUT_SEC}s"
  echo "============================================================"

  # Reuse the title+body we already fetched while evaluating candidates.
  issue_text="${title}

${body}"

  full_prompt="$(cat "$PROMPT_FILE")

---
ISSUE #${num}
---
${issue_text}"

  # Update status to "running" before calling copilot (run-aware mode only)
  if [[ -n "$RUN_ID" ]]; then
    state_lock || { echo "⚠️  Couldn't acquire state lock before copilot" >&2; exit 1; }
    status_update_item "$num" "running" "$WORKER_ID" "$$" "$(basename "$log_file")" "$iter_start_ts"
    state_unlock
  fi

  set +e
  run_with_timeout "$TIMEOUT_SEC" \
    copilot -p "$full_prompt" \
      --allow-all \
      --model "$MODEL" \
      2>&1 | tee "$log_file"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    # Mark as failed in status.json (run-aware mode only)
    if [[ -n "$RUN_ID" ]]; then
      state_lock || true
      status_mark_failed "$num" "Copilot exited with code $rc"
      state_unlock || true
    fi
    echo "⚠️  copilot exited $rc on #$num. See $log_file. Halting." >&2
    exit 1
  fi

  # Verify issue closed by a merged PR (not just manually closed).
  # closedByPullRequestsReferences items contain {number, url, ...} but not .state,
  # so we look up each referenced PR and require at least one with mergedAt != null.
  #
  # The closedByPullRequestsReferences link is eventually consistent — GitHub can
  # take 1-30s to attach the PR after the merge commit lands. Retry with backoff,
  # and as a final fallback scan recent merged PRs for "Closes #N" / "Fixes #N".
  state=""
  merged_count=0
  for attempt in 1 2 3 4 5 6; do
    closure=$(gh issue view "$num" --repo "$REPO" \
      --json state,closedByPullRequestsReferences)
    state=$(echo "$closure" | jq -r .state)
    pr_numbers=$(echo "$closure" | jq -r '(.closedByPullRequestsReferences // [])[].number')
    merged_count=0
    for pr in $pr_numbers; do
      merged_at=$(gh pr view "$pr" --repo "$REPO" --json mergedAt -q .mergedAt 2>/dev/null || echo "")
      if [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
        merged_count=$((merged_count + 1))
      fi
    done
    if [[ "$state" == "CLOSED" && "$merged_count" -ge 1 ]]; then
      break
    fi
    if [[ "$attempt" -lt 6 ]]; then
      echo "ℹ️  Issue #$num closure metadata not yet propagated (state=$state, merged_prs=$merged_count); retry $attempt/5 in 5s..." >&2
      sleep 5
    fi
  done

  # Fallback: scan recent merged PRs for one whose body closes this issue.
  # Runs whenever the issue link still shows zero merged PRs — including the
  # case where the issue is still OPEN because state propagation is slow but
  # the squash-merge has already landed. We only halt if no merged PR exists;
  # the issue state itself is eventually consistent and not load-bearing here.
  #
  # Two guards prevent false positives:
  #  - mergedAt > iter_start_ts: rejects historical merges (e.g., a regression
  #    on a reopened issue would otherwise match the original closing PR).
  #  - baseRefName == default branch: GitHub only auto-closes via "Closes #N"
  #    when the PR merged into the default branch, so non-default merges
  #    couldn't have closed the issue and must not be credited here.
  if [[ "$merged_count" -lt 1 ]]; then
    if [[ "$state" != "CLOSED" ]] && ralph_merge_ready_open_pr_for_issue "$num" "$default_branch"; then
      if wait_for_issue_closed_by_merged_pr "$num" "after fallback merge"; then
        merged_count=1
      fi
    fi

    if [[ "$merged_count" -lt 1 ]]; then
      echo "ℹ️  Issue #$num closure link empty after retries (state=$state); checking recent merged PRs for 'Closes #$num' on $default_branch since $iter_start_ts..." >&2
      fallback_pr=$(gh pr list --repo "$REPO" --state merged --limit 20 --base "$default_branch" \
        --search "in:body \"#$num\"" \
        --json number,body,mergedAt,baseRefName \
        --jq ".[] | select(.mergedAt > \"$iter_start_ts\") | select(.baseRefName == \"$default_branch\") | select(.body | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\\\s+#$num\\\\b\")) | .number" \
        | head -1)
      if [[ -n "$fallback_pr" ]]; then
        echo "✅ Found merged PR #$fallback_pr referencing 'Closes #$num' — accepting." >&2
        merged_count=1
      fi
    fi
  fi

  if [[ "$merged_count" -lt 1 ]]; then
    # Mark as failed in status.json (run-aware mode only)
    if [[ -n "$RUN_ID" ]]; then
      state_lock || true
      status_mark_failed "$num" "No merged PR found after copilot completed"
      state_unlock || true
    fi
    echo "⚠️  Issue #$num not closed by a merged PR (state=$state, merged_prs=$merged_count). Halting." >&2
    exit 1
  fi

  # Success! Update status to merged (run-aware mode only)
  if [[ -n "$RUN_ID" ]]; then
    state_lock || true
    status_update_item "$num" "merged" "$WORKER_ID" "$$" "$(basename "$log_file")" "$iter_start_ts"
    state_unlock || true
  fi

  # Optional Slice 1 postcondition (alisterr-specific guard) — skipped when
  # title doesn't match the legacy Slice format.
  if [[ "$title" =~ ^Slice\ 1: ]]; then
    if ! gh workflow list --repo "$REPO" --limit 20 | grep -qi 'ci'; then
      echo "⚠️  Slice 1 merged but no CI workflow found. Halting." >&2
      exit 1
    fi
    echo "✅ Slice 1 postcondition: CI workflow present."
  fi

  echo "✅ #$num closed via merged PR."
  # Release this issue's claim so other workers don't see it as in-flight.
  state_lock && state_release "$num" && state_unlock || true
  CURRENT_CLAIM=""
  sync_to_origin_main

  if [[ "$ONCE" -eq 1 ]]; then
    echo "🛑 --once: exiting after one iteration."
    exit 0
  fi
done
