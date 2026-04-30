#!/usr/bin/env bash
# Launches the Ralph loop in dedicated git worktree(s) alongside your main
# checkout so loop work never conflicts with local edits. Setup is idempotent.
#
# Supports parallelism: with RALPH_PARALLELISM>1, N workers run concurrently,
# each in its own worktree, coordinating issue claims via .ralph/state.json.
#
# Usage:
#   .ralph/launch.sh              # background, logs to .ralph/loop.out
#   .ralph/launch.sh --foreground # attached (only valid for parallelism=1)
#   .ralph/launch.sh --status     # show running workers + claims
#   .ralph/launch.sh --stop       # SIGTERM all workers
#
# Configuration (env vars, all optional):
#   RALPH_PARALLELISM  Number of concurrent workers (default: 1)
#   RALPH_MAIN_REPO    Path to your main checkout (default: $(git rev-parse --show-toplevel) of caller)
#   RALPH_LOOP_REPO    Base path for loop worktree(s) (default: <MAIN_REPO>-ralph)
#                      Worker N's worktree is "<LOOP_REPO>-<N>" when parallelism>1,
#                      or just "<LOOP_REPO>" when parallelism=1 (back-compat).
#   RALPH_LOOP_BRANCH  Base branch name for loop worktree(s) (default: ralph-loop)
#                      Worker N's branch is "<LOOP_BRANCH>-<N>" when parallelism>1.

set -euo pipefail

# Ensure homebrew tools (gh, git, etc.) are on PATH even when launched from
# minimal-PATH contexts (nohup, launchd, dashboard, etc.)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Resolve the script's parent .ralph directory's containing repo.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
DEFAULT_MAIN="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MAIN_REPO="${RALPH_MAIN_REPO:-$DEFAULT_MAIN}"
LOOP_REPO_BASE="${RALPH_LOOP_REPO:-${MAIN_REPO}-ralph}"
LOOP_BRANCH_BASE="${RALPH_LOOP_BRANCH:-ralph-loop}"
PARALLELISM="${RALPH_PARALLELISM:-1}"

# Validate parallelism
if ! [[ "$PARALLELISM" =~ ^[1-9][0-9]*$ ]]; then
  echo "❌ RALPH_PARALLELISM must be a positive integer (got: $PARALLELISM)" >&2
  exit 1
fi

# When running just one worker, preserve original naming (no -1 suffix) so
# existing single-worker setups keep working.
worker_repo() {
  local n="$1"
  if [[ "$PARALLELISM" -eq 1 ]]; then
    echo "$LOOP_REPO_BASE"
  else
    echo "${LOOP_REPO_BASE}-${n}"
  fi
}
worker_branch() {
  local n="$1"
  if [[ "$PARALLELISM" -eq 1 ]]; then
    echo "$LOOP_BRANCH_BASE"
  else
    echo "${LOOP_BRANCH_BASE}-${n}"
  fi
}

# --status: print active workers + claims and exit.
if [[ "${1:-}" == "--status" ]]; then
  state_file="$MAIN_REPO/.ralph/state.json"
  echo "Parallelism: $PARALLELISM"
  echo
  echo "Workers (from ps):"
  ps -axww -o pid=,command= | grep -E 'ralph\.sh|copilot -p' | grep -v grep || echo "  (none)"
  echo
  if [[ -f "$state_file" ]]; then
    echo "Claims (from state.json):"
    jq -r '
      .claims | to_entries[]
      | "  #\(.key)  worker=\(.value.workerId)  pid=\(.value.pid)  log=\(.value.logFile)"
    ' "$state_file" 2>/dev/null || echo "  (state.json unreadable)"
  else
    echo "Claims: (no state.json yet)"
  fi
  exit 0
fi

# --stop: SIGTERM every worker we can find.
if [[ "${1:-}" == "--stop" ]]; then
  pids=$(ps -axww -o pid=,command= | grep -E 'ralph\.sh|copilot -p' | grep -v grep | awk '{print $1}')
  if [[ -z "$pids" ]]; then
    echo "No ralph workers running."
    exit 0
  fi
  for pid in $pids; do
    echo "  SIGTERM $pid"
    kill "$pid" 2>/dev/null || true
  done
  exit 0
fi

# --foreground only meaningful with single worker — fan-out doesn't have
# anywhere to attach.
if [[ "${1:-}" == "--foreground" && "$PARALLELISM" -ne 1 ]]; then
  echo "❌ --foreground only valid with RALPH_PARALLELISM=1" >&2
  exit 1
fi

# Setup phase: create N worktrees and symlink .ralph in each.
EXCLUDE_FILE="$MAIN_REPO/.git/info/exclude"
if ! grep -qxF ".ralph" "$EXCLUDE_FILE" 2>/dev/null; then
  echo "🙈 Adding .ralph to $EXCLUDE_FILE"
  echo ".ralph" >> "$EXCLUDE_FILE"
fi

for ((i = 1; i <= PARALLELISM; i++)); do
  loop_repo=$(worker_repo "$i")
  loop_branch=$(worker_branch "$i")

  if [[ ! -d "$loop_repo" ]]; then
    echo "🌱 Worker $i: creating worktree at $loop_repo on branch $loop_branch"
    cd "$MAIN_REPO"
    git fetch origin main
    git worktree add -B "$loop_branch" "$loop_repo" origin/main
    cd "$loop_repo"
    git branch --set-upstream-to=origin/main "$loop_branch"
  fi

  if [[ ! -L "$loop_repo/.ralph" ]]; then
    echo "🔗 Worker $i: linking $loop_repo/.ralph -> $MAIN_REPO/.ralph"
    ln -s "$MAIN_REPO/.ralph" "$loop_repo/.ralph"
  fi

  cd "$loop_repo"
  git fetch origin main
  git checkout "$loop_branch" >/dev/null
  git reset --hard origin/main >/dev/null
  echo "✅ Worker $i: on $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"
done

# Launch phase.
LOG="$MAIN_REPO/.ralph/loop.out"

if [[ "${1:-}" == "--foreground" ]]; then
  cd "$(worker_repo 1)"
  RALPH_WORKER_ID=1 exec "$MAIN_REPO/.ralph/ralph.sh"
fi

echo "🚀 Launching $PARALLELISM worker(s) in background. Tail: tail -f $LOG"
for ((i = 1; i <= PARALLELISM; i++)); do
  loop_repo=$(worker_repo "$i")
  cd "$loop_repo"
  worker_log="$MAIN_REPO/.ralph/logs/worker-${i}.out"
  mkdir -p "$(dirname "$worker_log")"
  RALPH_WORKER_ID=$i nohup "$MAIN_REPO/.ralph/ralph.sh" \
    >>"$worker_log" 2>&1 < /dev/null &
  disown
  echo "  worker $i PID: $!  → $worker_log"
done

# Aggregate startup line into shared loop.out for backward-compat dashboard.
echo "[$(date -u +%FT%TZ)] launched $PARALLELISM worker(s)" >> "$LOG"
