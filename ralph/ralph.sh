#!/usr/bin/env bash
# TDD Ralph loop for alisterr.
# Iterates lowest-numbered open "Slice N:" issue, runs Copilot CLI non-interactively
# with RALPH.md as the prompt, and waits for the issue to close via merged PR.
#
# Usage:
#   .ralph/ralph.sh           # loop until no open Slice issues
#   .ralph/ralph.sh --once    # run a single iteration then exit
#
# Env:
#   RALPH_MODEL          model passed to copilot (default: claude-sonnet-4.5)
#   RALPH_TIMEOUT_SEC    per-iteration timeout in seconds (default: 7200)

set -euo pipefail

# Ensure homebrew tools (gh, etc.) are on PATH even when launched from
# minimal-PATH contexts (nohup, launchd, dashboard, etc.)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO="${RALPH_REPO:-$(git -C "$(git rev-parse --show-toplevel)" config --get remote.origin.url 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')}"
TITLE_REGEX="${RALPH_TITLE_REGEX:-^Slice [0-9]+:}"
TITLE_NUM_RE="${RALPH_TITLE_NUM_REGEX:-^Slice (?<x>[0-9]+):}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
PROMPT_FILE="$SCRIPT_DIR/RALPH.md"
LOCK_DIR="$SCRIPT_DIR/lock"
LOG_DIR="$SCRIPT_DIR/logs"
MODEL="${RALPH_MODEL:-claude-sonnet-4.5}"
TIMEOUT_SEC="${RALPH_TIMEOUT_SEC:-7200}"
ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1

if [[ -z "$REPO" ]]; then
  echo "⚠️  Could not determine target repo. Set RALPH_REPO=owner/repo." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"
mkdir -p "$LOG_DIR"

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

# Single-runner lock
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "⚠️  Another ralph loop is running (lock at $LOCK_DIR). Exiting." >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

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

  # Find lowest-numbered open issue matching $TITLE_REGEX
  next=$(gh issue list --repo "$REPO" --state open --limit 50 \
      --json number,title \
    | TITLE_REGEX="$TITLE_REGEX" TITLE_NUM_RE="$TITLE_NUM_RE" jq -r '
        [ .[]
          | select(.title | test(env.TITLE_REGEX))
          | . + {n: (.title | capture(env.TITLE_NUM_RE).x | tonumber)} ]
        | sort_by(.n)
        | .[0] // empty
        | "\(.number)\t\(.title)"
      ')

  if [[ -z "$next" ]]; then
    echo "✅ No open issues match \"$TITLE_REGEX\". Done."
    exit 0
  fi

  num="${next%%$'\t'*}"
  title="${next#*$'\t'}"
  ts="$(date +%Y%m%d-%H%M%S)"
  log_file="$LOG_DIR/iter-${ts}-issue-${num}.log"

  echo ""
  echo "============================================================"
  echo "▶️  $(date -u +%FT%TZ)  Working on #$num — $title"
  echo "    log: $log_file"
  echo "    model: $MODEL    timeout: ${TIMEOUT_SEC}s"
  echo "============================================================"

  issue_json=$(gh issue view "$num" --repo "$REPO" --json title,body)
  issue_text=$(echo "$issue_json" | jq -r '.title + "\n\n" + .body')

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
  sync_to_origin_main

  if [[ "$ONCE" -eq 1 ]]; then
    echo "🛑 --once: exiting after one iteration."
    exit 0
  fi
done
