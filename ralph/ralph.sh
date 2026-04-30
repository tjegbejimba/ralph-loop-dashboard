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

set -euo pipefail

# Ensure homebrew tools (gh, etc.) are on PATH even when launched from
# minimal-PATH contexts (nohup, launchd, dashboard, etc.)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO="${RALPH_REPO:-$(git -C "$(git rev-parse --show-toplevel)" config --get remote.origin.url 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')}"
TITLE_REGEX="${RALPH_TITLE_REGEX:-^Slice [0-9]+:}"
TITLE_NUM_RE="${RALPH_TITLE_NUM_REGEX:-^Slice (?<x>[0-9]+):}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
PROMPT_FILE="$SCRIPT_DIR/RALPH.md"
LOG_DIR="$SCRIPT_DIR/logs"
WORKER_ID="${RALPH_WORKER_ID:-1}"
LOCK_DIR="$SCRIPT_DIR/lock/worker-${WORKER_ID}"
MODEL="${RALPH_MODEL:-claude-sonnet-4.5}"
TIMEOUT_SEC="${RALPH_TIMEOUT_SEC:-7200}"
POLL_SEC="${RALPH_POLL_SEC:-30}"
ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1

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

# Sync the current branch to origin/main. Works both when run on `main` itself
# (legacy single-checkout mode) and in a dedicated worktree on a non-main branch
# (preferred — see .ralph/launch.sh, prevents collisions with local edits).
sync_to_origin_main() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  git fetch origin main >/dev/null
  if [[ "$branch" == "main" ]]; then
    git checkout main >/dev/null
    git pull --ff-only origin main >/dev/null
  else
    # Dedicated loop worktree — force-sync the branch to origin/main.
    git reset --hard origin/main >/dev/null
  fi
}

# Per-worker lock — prevents the same WORKER_ID from being launched twice.
# Concurrent workers with distinct ids each have their own lock.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "⚠️  Worker $WORKER_ID already running (lock at $LOCK_DIR). Exiting." >&2
  exit 1
fi
# Release lock on exit. Also release any in-flight claim — see
# CURRENT_CLAIM tracking below.
CURRENT_CLAIM=""
cleanup() {
  if [[ -n "$CURRENT_CLAIM" ]]; then
    state_lock && state_release "$CURRENT_CLAIM" && state_unlock || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
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

while true; do
  # Preflight: clean tree, on main, up to date
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "⚠️  Working tree is dirty. Halting." >&2
    git status --short
    exit 1
  fi
  sync_to_origin_main

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

  num=""; title=""; body=""
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    decoded=$(echo "$row" | base64 --decode)
    cand_num=$(echo "$decoded" | jq -r .number)
    cand_title=$(echo "$decoded" | jq -r .title)
    cand_body=$(echo "$decoded" | jq -r .body)

    # Skip issues other workers have claimed.
    if printf '%s\n' "$claimed_set" | grep -qx "$cand_num"; then
      continue
    fi

    # Evaluate blockers — every #N referenced in the "## Blocked by" section
    # must be CLOSED. Manually-closed (wontfix) issues count as satisfied.
    blockers=$(parse_blockers "$cand_body")
    all_closed=1
    for b in $blockers; do
      if [[ "$(is_issue_closed "$b")" != "1" ]]; then
        all_closed=0
        break
      fi
    done
    if [[ "$all_closed" -ne 1 ]]; then
      continue
    fi

    num="$cand_num"
    title="$cand_title"
    body="$cand_body"
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

  ts="$(date +%Y%m%d-%H%M%S)"
  log_file="$LOG_DIR/iter-${ts}-w${WORKER_ID}-issue-${num}.log"

  # Atomic claim: re-acquire lock, re-check (defensive — another worker may
  # have grabbed this same issue in the gap), then claim.
  state_lock || { echo "⚠️  Couldn't acquire state lock; retrying." >&2; sleep "$POLL_SEC"; continue; }
  state_reap_stale
  if state_claimed_issues | grep -qx "$num"; then
    state_unlock
    echo "↪️  Worker $WORKER_ID: #$num was claimed by another worker between selection and claim; retrying."
    continue
  fi
  state_claim "$num" "$WORKER_ID" "$$" "$(basename "$log_file")"
  CURRENT_CLAIM="$num"
  state_unlock

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

  set +e
  run_with_timeout "$TIMEOUT_SEC" \
    copilot -p "$full_prompt" \
      --allow-all-tools \
      --model "$MODEL" \
      2>&1 | tee "$log_file"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
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

  # Fallback: if still no merged PR via the issue link, scan the 10 most recently
  # merged PRs for one whose body or commit closes this issue. Handles the case
  # where GitHub closed the issue via "Closes #N" in a merge commit but never
  # populated closedByPullRequestsReferences.
  if [[ "$state" == "CLOSED" && "$merged_count" -lt 1 ]]; then
    echo "ℹ️  Issue #$num closure link still empty after retries; checking recent merged PRs for 'Closes #$num'..." >&2
    fallback_pr=$(gh pr list --repo "$REPO" --state merged --limit 10 \
      --search "in:body \"#$num\"" \
      --json number,body \
      --jq ".[] | select(.body | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\\\s+#$num\\\\b\")) | .number" \
      | head -1)
    if [[ -n "$fallback_pr" ]]; then
      echo "✅ Found merged PR #$fallback_pr referencing 'Closes #$num' — accepting." >&2
      merged_count=1
    fi
  fi

  if [[ "$state" != "CLOSED" || "$merged_count" -lt 1 ]]; then
    echo "⚠️  Issue #$num not closed by a merged PR (state=$state, merged_prs=$merged_count). Halting." >&2
    exit 1
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
