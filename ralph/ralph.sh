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
#   RALPH_MODEL                   model passed to copilot (default: claude-sonnet-4.5)
#   RALPH_TIMEOUT_SEC             per-iteration timeout in seconds (default: 7200)
#   RALPH_AUTOPILOT_CONTINUES     copilot --max-autopilot-continues value (default: 15).
#                                 Copilot CLI's default is 5, which is enough for short TDD
#                                 cycles but runs out before commit/push/PR if the agent has
#                                 to debug a build, re-run tests, etc. Bump this if you see
#                                 iterations halt after staging changes but before opening
#                                 a PR.
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
ISSUE_SEARCH="${RALPH_ISSUE_SEARCH:-$(config_get '.issue.issueSearch')}"

# Direct-numbers queue. When `.issue.numbers` is non-empty and no RUN_ID is
# set, the worker treats this list as the candidate set instead of running an
# issueSearch. Closes the "--enqueue wrote config that workers ignore" gap
# reported in issue #64: previously, operators ran `launch.sh --enqueue 5 6 7`,
# saw the numbers in config.json, and assumed workers would pick them up — but
# the legacy code path only ran `gh issue list --search "$ISSUE_SEARCH"` and
# silently ignored `.issue.numbers` entirely.
NUMBERS_QUEUE=()
if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r _n; do
    [[ -n "$_n" && "$_n" =~ ^[0-9]+$ ]] && NUMBERS_QUEUE+=("$_n")
  done < <(jq -r '(.issue.numbers // [])[]' "$CONFIG_FILE" 2>/dev/null | tr -d '\r' || true)
  unset _n
fi
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
AUTOPILOT_CONTINUES="${RALPH_AUTOPILOT_CONTINUES:-15}"
POLL_SEC="${RALPH_POLL_SEC:-30}"
RUN_ID="${RALPH_RUN_ID:-}"
# Release-branch flow (opt-in). When RALPH_RELEASE_BRANCH is set, the verifier
# also accepts PRs merged into that branch as closing their referenced issue,
# and may call `gh pr merge` + `gh issue close` itself if copilot left a green
# PR open or pushed a branch without opening a PR. See docs/release-branch.md.
RELEASE_BRANCH="${RALPH_RELEASE_BRANCH:-}"
BRANCH_PREFIX="${RALPH_BRANCH_PREFIX:-$(config_get '.issue.branchPrefix')}"

# Source state.sh early so the boolean-normalisation helper is available
# before we resolve the verbose / acceptManuallyClosed / resume flags below.
# state_init() (which has side effects) is invoked further down after cd.
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"

# Resume-incomplete-iterations feature (issue #60). Maximum retries per issue
# when copilot exits 0 but no merged PR is produced (most often: autopilot
# continues exhausted mid-implementation). Set to 0 to disable resume.
_cfg_resume_max=$(config_get '.worker.resumeMax')
RESUME_MAX="${RALPH_RESUME_MAX:-${_cfg_resume_max:-2}}"
if ! [[ "$RESUME_MAX" =~ ^[0-9]+$ ]]; then
  echo "❌ RALPH_RESUME_MAX must be a non-negative integer (got: $RESUME_MAX)" >&2
  exit 1
fi
unset _cfg_resume_max

# Opt-in: resume even when an open PR exists for the slice branch. Default
# off — when humans are reviewing a PR, Ralph should not keep pushing.
_cfg_resume_open_pr=$(config_get '.worker.resumeOnOpenPR')
RALPH_RESUME_ON_OPEN_PR=$(normalize_bool "${RALPH_RESUME_ON_OPEN_PR:-${_cfg_resume_open_pr:-}}") || exit 1
unset _cfg_resume_open_pr

ONCE=0

# Idle-exit threshold: number of consecutive "no claimable issue" polls before
# the worker exits cleanly. 0 = disabled (legacy "sleep forever" behaviour).
_cfg_idle=$(config_get '.worker.idleExitAfterPolls')
IDLE_EXIT_POLLS="${RALPH_IDLE_EXIT_POLLS:-${_cfg_idle:-20}}"
if ! [[ "$IDLE_EXIT_POLLS" =~ ^[0-9]+$ ]]; then
  echo "❌ RALPH_IDLE_EXIT_POLLS must be a non-negative integer (got: $IDLE_EXIT_POLLS)" >&2
  exit 1
fi
unset _cfg_idle

# Manually-closed blocker fallback (opt-in). When enabled, is_issue_satisfied
# accepts CLOSED + stateReason=COMPLETED as satisfied even without a PR
# linkage. See docs/manually-closed-blockers.md.
_cfg_accept_manual=$(config_get '.worker.acceptManuallyClosed')
RALPH_ACCEPT_MANUALLY_CLOSED=$(normalize_bool "${RALPH_ACCEPT_MANUALLY_CLOSED:-${_cfg_accept_manual:-}}") || exit 1
unset _cfg_accept_manual

# Verbose diagnostics. When enabled, the candidate-selection loop emits a
# per-rejection skip line so a stalled worker is debuggable in seconds.
_cfg_verbose=$(config_get '.worker.verbose')
RALPH_VERBOSE=$(normalize_bool "${RALPH_VERBOSE:-${_cfg_verbose:-}}") || exit 1
unset _cfg_verbose

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

# state.sh was sourced earlier so normalize_bool was available during config
# resolution; now that cwd and LOG_DIR are settled, initialise state.json.
state_init

# Per-run status tracking (status.json). Only needed in run-aware mode.
# shellcheck source=lib/status.sh
. "$SCRIPT_DIR/lib/status.sh"
# PR merge fallback helpers.
# shellcheck source=lib/pr-merge.sh
. "$SCRIPT_DIR/lib/pr-merge.sh"
# Resume-incomplete-iterations helpers (issue #60).
# shellcheck source=lib/resume.sh
. "$SCRIPT_DIR/lib/resume.sh"
if [[ -n "$RUN_ID" ]]; then
  status_init
fi

# Record the worker's "home" branch — the one we want to be on when
# sync_to_origin_main runs. Normally this is the dedicated worker branch
# created by launch.sh (e.g. ralph-loop-1). Allows the preflight
# dirty-tree rescue to return here before the hard-reset in
# sync_to_origin_main wipes a slice branch.
INITIAL_BRANCH="${RALPH_INITIAL_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

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

# Counts consecutive poll cycles where no claimable issue was found.
# Reset to 0 whenever a worker successfully claims an issue.
_idle_polls=0

while true; do
  # Resume short-circuit (issue #60). When the previous iteration detected
  # a resumable state (copilot exited 0 but no merged PR + slice branch has
  # commits since iter_start_ts), it set RESUME_NUM and `continue`d. Here we
  # bypass preflight/sync/selection/claim entirely — the claim is already
  # held, status is `running`, and we just need to relaunch copilot for the
  # same issue, telling it to continue from the existing branch.
  if [[ -n "${RESUME_NUM:-}" ]]; then
    num="$RESUME_NUM"
    _iter_resume_attempt="$RESUME_ATTEMPT"
    _iter_resume_branch="$RESUME_BRANCH"

    # Re-fetch title+body — the human may have edited the issue body to
    # add steering between attempts.
    _resume_json=$(gh issue view "$num" --repo "$REPO" --json title,body 2>/dev/null || echo '{}')
    _refreshed_title=$(printf '%s' "$_resume_json" | jq -r '.title // empty')
    if [[ -n "$_refreshed_title" ]]; then
      title="$_refreshed_title"
      body=$(printf '%s' "$_resume_json" | jq -r '.body // ""')
    else
      title="${RESUME_TITLE:-$title}"
      body="${RESUME_BODY:-$body}"
    fi
    chosen_blockers=""
    iter_start_ts=$(date -u +%FT%TZ)
    ts="$(date +%Y%m%d-%H%M%S)"
    log_file="$LOG_DIR/iter-${ts}-w${WORKER_ID}-issue-${num}.log"
    : >"$log_file"
    CURRENT_CLAIM="$num"
    _iter_resume_active=1
    unset RESUME_NUM RESUME_TITLE RESUME_BODY RESUME_BRANCH RESUME_ATTEMPT

    if [[ -n "$RUN_ID" ]]; then
      state_lock || true
      # Status stays `running` (not `failed`) — this is what differentiates
      # a resumable iteration from a terminal halt.
      status_update_item "$num" "running" "$WORKER_ID" "$$" "$(basename "$log_file")" "$iter_start_ts"
      state_unlock || true
    fi
  else
    _iter_resume_active=0
  # Preflight: clean tree, on main, up to date.
  #
  # If the tree is dirty AND we're on a recognised slice branch
  # (BRANCH_PREFIX-prefixed), rescue the leftovers as a wip commit, push,
  # then return to the worker branch — sync_to_origin_main below does a
  # hard reset on the current branch which would otherwise orphan the
  # rescue commit. See docs/resume-incomplete-iterations.md.
  if [[ -n "$(git status --porcelain)" ]]; then
    _cur_branch=$(git rev-parse --abbrev-ref HEAD)
    if should_auto_commit_dirty "$_cur_branch" "$BRANCH_PREFIX"; then
      _porcelain=$(git status --porcelain)
      _sensitive=$(printf '%s\n' "$_porcelain" | any_sensitive_in_porcelain || true)
      if [[ -n "$_sensitive" ]]; then
        echo "⚠️  Refusing to auto-commit dirty tree on $_cur_branch: sensitive paths detected." >&2
        printf '   %s\n' $_sensitive >&2
        git status --short >&2
        exit 1
      fi
      echo "🧹 Auto-committing dirty tree on $_cur_branch before resume..." >&2
      git status --short >&2
      git add -A
      git commit -q -m "wip: ralph auto-commit before resume" \
        --trailer "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
      if ! git push -q -u origin "$_cur_branch"; then
        # Push failed (network / auth / non-FF). Undo our local commit so
        # the working tree returns to its dirty state — that way, on
        # operator-driven restart, the same dirty-tree-rescue path fires
        # again instead of sync_to_origin_main's hard reset silently
        # orphaning our local-only WIP commit.
        git reset --quiet --mixed HEAD~1 || true
        echo "⚠️  Push of wip commit to origin/$_cur_branch failed; reverted local commit so dirty state is preserved. Halting." >&2
        exit 1
      fi
      if [[ -n "$INITIAL_BRANCH" && "$INITIAL_BRANCH" != "$_cur_branch" ]] \
          && git show-ref --verify --quiet "refs/heads/$INITIAL_BRANCH"; then
        git checkout -q "$INITIAL_BRANCH"
      fi
      echo "✅ Auto-committed leftover changes on $_cur_branch; returning to $(git rev-parse --abbrev-ref HEAD) for sync." >&2
    else
      echo "⚠️  Working tree is dirty. Halting." >&2
      git status --short
      exit 1
    fi
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
      # No claimable issue this pass. Decide whether to exit or wait:
      # - If every queue item is in a terminal status (merged/failed/skipped),
      #   the run is done — exit cleanly.
      # - Otherwise some items are claimed/in-progress on other workers; sleep.
      total=$(echo "$queue_json" | jq -r 'length')
      terminal_count=0
      while IFS= read -r qnum; do
        [[ -z "$qnum" ]] && continue
        if status_is_terminal "$qnum"; then
          terminal_count=$((terminal_count + 1))
        fi
      done < <(echo "$queue_json" | jq -r '.[].number')
      if [[ "$total" -eq 0 ]]; then
        echo "✅ Worker $WORKER_ID: run $RUN_ID queue is empty. Done."
        exit 0
      fi
      if [[ "$terminal_count" -eq "$total" ]]; then
        echo "✅ Worker $WORKER_ID: run $RUN_ID queue fully resolved ($terminal_count/$total terminal). Done."
        exit 0
      fi
      echo "⏸  Worker $WORKER_ID: no claimable issues in run $RUN_ID queue (terminal=$terminal_count/$total); sleeping ${POLL_SEC}s."
      _idle_polls=$((_idle_polls + 1))
      if [[ "$IDLE_EXIT_POLLS" -gt 0 && "$_idle_polls" -ge "$IDLE_EXIT_POLLS" ]]; then
        echo "⏸  Worker $WORKER_ID: idle for $_idle_polls polls, exiting."
        exit 0
      fi
      sleep "$POLL_SEC"
      continue
    fi
  elif [[ ${#NUMBERS_QUEUE[@]} -gt 0 ]]; then
    # Direct-numbers mode (issue #64): consume the configured `.issue.numbers`
    # list when no RUN_ID is active. Honors the same AFK guard as legacy
    # issueSearch — must be OPEN, `ready-for-agent`, not `hitl`, and all
    # blockers satisfied — so this mode is safe to enable by default.
    state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
    state_reap_stale
    claimed_set="$(state_claimed_issues | sort -u)"
    state_unlock

    declare -A NUMBER_BLOCKER_CACHE=()
    _nq_blocker_satisfied() {
      local b="$1"
      if [[ -n "${NUMBER_BLOCKER_CACHE[$b]+x}" ]]; then
        printf '%s' "${NUMBER_BLOCKER_CACHE[$b]}"
        return
      fi
      local v
      v=$(is_issue_satisfied "$b")
      NUMBER_BLOCKER_CACHE[$b]="$v"
      printf '%s' "$v"
    }

    # Sort ascending so workers pick the lowest-numbered eligible issue first
    # (matches legacy slice-N ordering when numbers correspond to slice order).
    sorted_numbers=()
    while IFS= read -r _qn; do
      [[ -z "$_qn" ]] && continue
      sorted_numbers+=("$_qn")
    done < <(printf '%s\n' "${NUMBERS_QUEUE[@]}" | sort -n)

    num=""; title=""; body=""; chosen_blockers=""
    skip_reasons=()
    for cand_num in "${sorted_numbers[@]}"; do
      # Skip already-claimed by another worker.
      if printf '%s\n' "$claimed_set" | grep -qx "$cand_num"; then
        continue
      fi

      record=$(gh issue view "$cand_num" --repo "$REPO" \
        --json number,state,title,labels,body 2>/dev/null | tr -d '\r' || echo "")
      if [[ -z "$record" ]]; then
        skip_reasons+=("#${cand_num}: lookup failed")
        continue
      fi
      cand_state=$(echo "$record" | jq -r .state)
      cand_title=$(echo "$record" | jq -r .title)
      cand_body=$(echo "$record" | jq -r '.body // ""')
      cand_labels=$(echo "$record" | jq -r '[.labels[].name] | join(",")')

      if [[ "$cand_state" != "OPEN" ]]; then
        skip_reasons+=("#${cand_num}: not open (${cand_state})")
        continue
      fi
      if [[ ",${cand_labels}," != *",ready-for-agent,"* ]]; then
        skip_reasons+=("#${cand_num}: missing ready-for-agent")
        continue
      fi
      if [[ ",${cand_labels}," == *",hitl,"* ]]; then
        skip_reasons+=("#${cand_num}: hitl")
        continue
      fi
      if [[ ",${cand_labels}," == *",needs-triage,"* ]]; then
        # ready-for-agent and needs-triage can coexist if the operator forgot
        # to remove the triage marker. The AFK contract is "human reviewed
        # AND scoped"; needs-triage says "not yet reviewed". Reject when both
        # are present so the worker matches what preflight already flags.
        skip_reasons+=("#${cand_num}: still needs-triage")
        continue
      fi

      blockers=$(parse_blockers "$cand_body")
      all_satisfied=1
      for b in $blockers; do
        if [[ "$(_nq_blocker_satisfied "$b")" != "1" ]]; then
          all_satisfied=0
          break
        fi
      done
      if [[ "$all_satisfied" -ne 1 ]]; then
        skip_reasons+=("#${cand_num}: unresolved blockers")
        continue
      fi

      num="$cand_num"
      title="$cand_title"
      body="$cand_body"
      chosen_blockers="$blockers"
      break
    done

    if [[ -z "$num" ]]; then
      total=${#NUMBERS_QUEUE[@]}
      echo "⏸  Worker $WORKER_ID: no eligible issue in direct-numbers queue (size=$total)."
      if [[ "${#skip_reasons[@]}" -gt 0 ]]; then
        for _r in "${skip_reasons[@]}"; do
          echo "    - $_r"
        done
        unset _r
      fi
      _idle_polls=$((_idle_polls + 1))
      if [[ "$IDLE_EXIT_POLLS" -gt 0 && "$_idle_polls" -ge "$IDLE_EXIT_POLLS" ]]; then
        echo "⏸  Worker $WORKER_ID: idle for $_idle_polls polls, exiting."
        exit 0
      fi
      sleep "$POLL_SEC"
      continue
    fi
  else
    # Legacy mode: search GitHub for issues matching TITLE_REGEX
    # Fetch open issues matching the title regex along with their bodies so we
    # can evaluate "Blocked by" sections without an extra round-trip per issue.
    _gh_search_args=()
    [[ -n "$ISSUE_SEARCH" ]] && _gh_search_args=(--search "$ISSUE_SEARCH")
    open_json=$(gh issue list --repo "$REPO" --state open --limit 100 \
      "${_gh_search_args[@]}" \
      --json number,title,body)

    # Sort eligible issues by slice number ascending; pick the first one whose
    # blockers are all closed AND that no other worker has already claimed.
    state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
    state_reap_stale
    claimed_set="$(state_claimed_issues | sort -u)"
    state_unlock

    # Build a sorted list of (number, title, body) for matching issues.
    # Use try-style operators (capture? | .x? | tonumber?) so titles whose
    # captured group is missing or non-numeric don't crash jq via `set -e`
    # in the calling shell. Fall back to the issue's GitHub number for
    # ordering instead. Without this, a single issue whose title doesn't
    # match TITLE_NUM_RE silently empties the entire candidate list and
    # the worker prints "no eligible issue (remaining=N)" forever.
    candidates=$(echo "$open_json" \
      | TITLE_REGEX="$TITLE_REGEX" TITLE_NUM_RE="$TITLE_NUM_RE" jq -r '
          [ .[]
            | select(.title | test(env.TITLE_REGEX))
            | . + {n: ((.title | capture(env.TITLE_NUM_RE)? | .x? | tonumber?) // .number)} ]
          | sort_by(.n)
          | .[]
          | @base64
        ')

    # Memoize blocker satisfaction across this selection round so M candidates
    # × K blockers don't translate into M×K `gh issue view`/`gh pr view` calls.
    # Cache lives only until the next polling cycle to stay fresh.
    #
    # BLOCKER_CACHE stores the structured detail line from
    # issue_satisfaction_detail (`<satisfied>|<state>|<reason>|<prs>`) so the
    # verbose skip diagnostic can read state/reason/prs without a second gh
    # round-trip. `blocker_satisfied` returns just field 1.
    declare -A BLOCKER_CACHE=()
    blocker_detail() {
      local b="$1"
      if [[ -n "${BLOCKER_CACHE[$b]+x}" ]]; then
        printf '%s' "${BLOCKER_CACHE[$b]}"
        return
      fi
      local v
      v=$(issue_satisfaction_detail "$b")
      BLOCKER_CACHE[$b]="$v"
      printf '%s' "$v"
    }
    blocker_satisfied() {
      local detail
      detail=$(blocker_detail "$1")
      printf '%s' "${detail%%|*}"
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
        [[ -n "${RALPH_VERBOSE:-}" ]] && echo "  ↳ skipping #$cand_num: claimed by another worker"
        continue
      fi

      # Evaluate blockers — every #N referenced in the "## Blocked by" section
      # must be closed by a merged PR (same predicate the iteration uses for
      # itself, so manually-closed wontfix/duplicate blockers don't unblock
      # downstream slices whose code never landed).
      blockers=$(parse_blockers "$cand_body")
      all_satisfied=1
      unsatisfied_blocker=""
      for b in $blockers; do
        if [[ "$(blocker_satisfied "$b")" != "1" ]]; then
          all_satisfied=0
          unsatisfied_blocker="$b"
          break
        fi
      done
      if [[ "$all_satisfied" -ne 1 ]]; then
        if [[ -n "${RALPH_VERBOSE:-}" ]]; then
          # Cache hit guaranteed because blocker_satisfied just populated it.
          IFS='|' read -r _bs _bstate _breason _bprs <<<"$(blocker_detail "$unsatisfied_blocker")"
          echo "  ↳ skipping #$cand_num: blocker #$unsatisfied_blocker not satisfied (state=$_bstate reason=$_breason prs=$_bprs)"
        fi
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
      claimed_n=$(count_claimed_issues <<<"$claimed_set")
      echo "⏸  Worker $WORKER_ID: no eligible issue (remaining=$remaining, claimed=$claimed_n); sleeping ${POLL_SEC}s."
      if [[ -z "${RALPH_VERBOSE:-}" && -z "${_idle_hint_shown:-}" ]]; then
        echo "   (Set RALPH_VERBOSE=1 — or .worker.verbose:true in .ralph/config.json — to see per-candidate skip reasons.)"
        _idle_hint_shown=1
      fi
      _idle_polls=$((_idle_polls + 1))
      if [[ "$IDLE_EXIT_POLLS" -gt 0 && "$_idle_polls" -ge "$IDLE_EXIT_POLLS" ]]; then
        echo "⏸  Worker $WORKER_ID: idle for $_idle_polls polls, exiting."
        exit 0
      fi
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
  # issue between selection and now, AND re-validate state/labels/blockers
  # against a fresh fetch. The selection-time snapshot can go stale: an
  # operator may have removed `ready-for-agent`, added `hitl`, added a new
  # `## Blocked by`, or closed the issue between scan and claim. Re-fetch
  # everything and re-validate before committing the claim.
  state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
  state_reap_stale
  if state_claimed_issues | grep -qx "$num"; then
    state_unlock
    echo "↪️  Worker $WORKER_ID: #$num was claimed by another worker between selection and claim; retrying."
    continue
  fi
  # Re-fetch state + labels + body so we can re-validate the AFK guard and
  # re-parse blockers from the freshest body, not the stale chosen_blockers.
  fresh_record=$(gh issue view "$num" --repo "$REPO" \
    --json state,title,labels,body 2>/dev/null | tr -d '\r' || echo "")
  if [[ -z "$fresh_record" ]]; then
    state_unlock
    echo "↪️  Worker $WORKER_ID: #$num lookup failed during claim re-check; retrying."
    continue
  fi
  current_state=$(echo "$fresh_record" | jq -r .state)
  if [[ "$current_state" != "OPEN" ]]; then
    state_unlock
    echo "↪️  Worker $WORKER_ID: #$num is no longer OPEN (state=$current_state); retrying."
    continue
  fi
  # Only re-validate labels for direct-numbers mode. Legacy issueSearch mode
  # already filters via the gh search predicate so an issue that came back
  # via the search must have matched the AFK guard at scan time; legacy users
  # who manually crafted custom `issueSearch` queries may not want the
  # `ready-for-agent`/`hitl`/`needs-triage` triple enforced here.
  if [[ -z "$RUN_ID" && ${#NUMBERS_QUEUE[@]} -gt 0 ]]; then
    fresh_labels=$(echo "$fresh_record" | jq -r '[.labels[].name] | join(",")')
    if [[ ",${fresh_labels}," != *",ready-for-agent,"* ]]; then
      state_unlock
      echo "↪️  Worker $WORKER_ID: #$num lost ready-for-agent during selection; retrying."
      continue
    fi
    if [[ ",${fresh_labels}," == *",hitl,"* ]]; then
      state_unlock
      echo "↪️  Worker $WORKER_ID: #$num gained hitl during selection; retrying."
      continue
    fi
    if [[ ",${fresh_labels}," == *",needs-triage,"* ]]; then
      state_unlock
      echo "↪️  Worker $WORKER_ID: #$num gained needs-triage during selection; retrying."
      continue
    fi
  fi
  # Re-parse blockers from the fresh body so newly-added `## Blocked by`
  # entries are honored.
  fresh_body=$(echo "$fresh_record" | jq -r '.body // ""')
  fresh_blockers=$(parse_blockers "$fresh_body")
  blockers_still_satisfied=1
  for b in $fresh_blockers; do
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
  _idle_polls=0  # Reset idle counter: worker successfully claimed an issue
  # In run-aware mode, also update status.json atomically under same lock
  if [[ -n "$RUN_ID" ]]; then
    status_update_item "$num" "claimed" "$WORKER_ID" "$$" "$(basename "$log_file")" "$iter_start_ts"
  fi
  state_unlock

  # Use the freshest title/body for the prompt — the selection-time snapshot
  # may be stale if the operator edited the issue between scan and claim.
  fresh_title=$(echo "$fresh_record" | jq -r .title)
  if [[ -n "$fresh_title" && "$fresh_title" != "null" ]]; then
    title="$fresh_title"
  fi
  if [[ -n "$fresh_body" ]]; then
    body="$fresh_body"
  fi

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

  fi  # end of resume-short-circuit if/else (issue #60)

  echo ""
  echo "============================================================"
  if [[ "$_iter_resume_active" == "1" ]]; then
    echo "🔁 $(date -u +%FT%TZ)  Worker $WORKER_ID — Resuming #$num (attempt $_iter_resume_attempt/$RESUME_MAX, branch=$_iter_resume_branch): $title"
  else
    echo "▶️  $(date -u +%FT%TZ)  Worker $WORKER_ID — #$num: $title"
  fi
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

  if [[ "$_iter_resume_active" == "1" ]]; then
    full_prompt="${full_prompt}

---
RALPH_RESUME
---
A prior iteration on this issue ended without producing a merged PR.
Your previous work is preserved on branch '${_iter_resume_branch}' (already pushed to origin).
This is resume attempt ${_iter_resume_attempt} of ${RESUME_MAX}.

DO NOT re-plan or open a new branch. Instead:
  1. \`git fetch origin && git checkout ${_iter_resume_branch}\`
  2. Inspect existing commits to understand what's done.
  3. Finish the remaining implementation work.
  4. Run lints/tests, then push.
  5. Open a PR (if not already open) and merge once green.
"
    export RALPH_RESUME=1 RALPH_RESUME_ATTEMPT="$_iter_resume_attempt" RALPH_RESUME_BRANCH="$_iter_resume_branch"
  else
    unset RALPH_RESUME RALPH_RESUME_ATTEMPT RALPH_RESUME_BRANCH || true
  fi

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
      --max-autopilot-continues "$AUTOPILOT_CONTINUES" \
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

    # Release-branch flow (opt-in via RALPH_RELEASE_BRANCH). GitHub does not
    # auto-link `Closes #N` for PRs whose base != default branch, so closure
    # has to be done explicitly. We try, in order:
    #   (a) merge an open PR into the release branch + manually close issue;
    #   (b) if BRANCH_PREFIX is set and a `${prefix}${num}-…` branch was pushed
    #       with no PR, open one and retry (a);
    #   (c) accept state=CLOSED + a release-branch PR merged in this iteration.
    if [[ "$merged_count" -lt 1 && -n "$RELEASE_BRANCH" && "$state" != "CLOSED" ]]; then
      if ralph_merge_release_branch_pr_for_issue "$num" "$RELEASE_BRANCH"; then
        state="CLOSED"
        merged_count=1
      elif [[ -n "$BRANCH_PREFIX" ]] && ralph_open_pr_for_pushed_branch "$num" "$RELEASE_BRANCH" "$BRANCH_PREFIX"; then
        sleep 15  # give the new PR a moment to register checks
        if ralph_merge_release_branch_pr_for_issue "$num" "$RELEASE_BRANCH"; then
          state="CLOSED"
          merged_count=1
        fi
      fi
    fi
    if [[ "$merged_count" -lt 1 && -n "$RELEASE_BRANCH" && "$state" == "CLOSED" ]]; then
      echo "ℹ️  Issue #$num: checking recent merged PRs into release branch '$RELEASE_BRANCH' since $iter_start_ts..." >&2
      release_pr=$(gh pr list --repo "$REPO" --state merged --limit 20 --base "$RELEASE_BRANCH" \
        --search "in:body \"#$num\"" \
        --json number,body,mergedAt,baseRefName \
        --jq ".[] | select(.mergedAt > \"$iter_start_ts\") | select(.baseRefName == \"$RELEASE_BRANCH\") | select(.body | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\\\s+#$num\\\\b\")) | .number" \
        | head -1)
      if [[ -n "$release_pr" ]]; then
        echo "✅ Found merged PR #$release_pr into release branch '$RELEASE_BRANCH' referencing #$num — accepting." >&2
        merged_count=1
      fi
    fi
  fi

  if [[ "$merged_count" -lt 1 ]]; then
    # Resume-incomplete-iterations (issue #60). Before marking the issue as
    # terminally failed, check whether this iteration left commits on a
    # slice branch. If so, we likely just hit the autopilot-continues cap
    # mid-implementation — relaunch copilot on the same issue and tell it
    # to finish from the existing branch.
    if [[ -n "$BRANCH_PREFIX" && "$RESUME_MAX" -gt 0 ]]; then
      # Resume counter persists on the state.json claim record. The claim
      # is created in both run-aware and legacy modes, so this works in
      # both. Status updates remain run-aware-only.
      state_lock || true
      _current_attempt=$(state_get_resume_attempt "$num" 2>/dev/null || echo 0)
      state_unlock || true
      _next_attempt=$((_current_attempt + 1))

      _resume_branch=$(resume_branch_for_issue "$num" "$BRANCH_PREFIX" || true)
      _resume_eligible=0
      _resume_reason=""

      if [[ -z "$_resume_branch" ]]; then
        _resume_reason="no slice branch matching ${BRANCH_PREFIX}${num}-* found"
      elif ! resume_branch_ahead_of_base "$_resume_branch" "$default_branch"; then
        _resume_reason="branch '$_resume_branch' has no new commits vs $default_branch"
      elif ! resume_branch_head_after "$_resume_branch" "$iter_start_ts"; then
        _resume_reason="branch '$_resume_branch' HEAD predates this iteration (stale from prior run)"
      else
        _open_pr=$(open_pr_for_branch "$REPO" "$_resume_branch" || true)
        if [[ -n "$_open_pr" && "$RALPH_RESUME_ON_OPEN_PR" != "1" ]]; then
          _resume_reason="open PR #$_open_pr exists on '$_resume_branch' — human review required (set RALPH_RESUME_ON_OPEN_PR=1 to override)"
        elif [[ "$_next_attempt" -gt "$RESUME_MAX" ]]; then
          _resume_reason="resume cap exhausted ($_current_attempt/$RESUME_MAX)"
        else
          _resume_eligible=1
        fi
      fi

      if [[ "$_resume_eligible" == "1" ]]; then
        state_lock || true
        state_set_resume_attempt "$num" "$_next_attempt" "$_resume_branch" || true
        if [[ -n "$RUN_ID" ]]; then
          # Keep status `running` (not `failed`) so this issue isn't skipped
          # as terminal on the next selection pass.
          status_update_item "$num" "running" "$WORKER_ID" "$$" "$(basename "$log_file")" "$iter_start_ts"
        fi
        state_unlock || true
        format_resume_log "$_next_attempt" "$RESUME_MAX" "$_resume_branch" "$num" >&2
        # Stash resume context for the loop-top short-circuit.
        export RESUME_NUM="$num"
        export RESUME_TITLE="$title"
        export RESUME_BODY="$body"
        export RESUME_BRANCH="$_resume_branch"
        export RESUME_ATTEMPT="$_next_attempt"
        continue
      else
        echo "ℹ️  Not resuming #$num: $_resume_reason" >&2
      fi
    fi

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
