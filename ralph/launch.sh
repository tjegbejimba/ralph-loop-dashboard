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
#   .ralph/launch.sh --cleanup    # stop workers and remove clean loop worktrees
#   .ralph/launch.sh --enqueue <N>... # set issue.numbers in .ralph/config.json
#   .ralph/launch.sh --help       # show this usage text
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

# --help: print usage and exit.
if [[ "${1:-}" == "--help" ]]; then
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# --enqueue: write issue numbers into .ralph/config.json and exit.
if [[ "${1:-}" == "--enqueue" ]]; then
  shift
  if [[ $# -eq 0 ]]; then
    echo "❌ --enqueue requires at least one issue number" >&2
    exit 1
  fi
  # Validate: all must be positive integers; reject duplicates.
  seen=()
  for n in "$@"; do
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
      echo "❌ Invalid issue number: '$n' (must be a positive integer)" >&2
      exit 1
    fi
    for s in "${seen[@]:-}"; do
      if [[ "$s" == "$n" ]]; then
        echo "❌ Duplicate issue number: $n" >&2
        exit 1
      fi
    done
    seen+=("$n")
  done
  config_file="$MAIN_REPO/.ralph/config.json"
  if [[ ! -f "$config_file" ]]; then
    echo "❌ .ralph/config.json not found at: $config_file" >&2
    exit 1
  fi
  # Build new numbers array (compact JSON).
  new_nums=$(printf '%s\n' "$@" | jq -R 'tonumber' | jq -sc '.')
  # Read current numbers for idempotency check and display.
  if ! current_nums=$(jq -c '(.issue.numbers // [])' "$config_file"); then
    echo "❌ Failed to parse .ralph/config.json — not valid JSON" >&2
    exit 1
  fi
  old_display=$(jq -r '(.issue.numbers // []) | map("#" + tostring) | join(" ")' "$config_file")
  # Idempotency: skip write if numbers already match.
  if [[ "$current_nums" == "$new_nums" ]]; then
    echo "No change: issue.numbers already [$(printf '#%s ' "$@" | sed 's/ $//' )]"
    exit 0
  fi
  # Atomic write: write to a temp file in the same directory then rename.
  tmp_file=$(mktemp "${config_file}.XXXXXX")
  trap 'rm -f "$tmp_file"' EXIT
  jq --argjson nums "$new_nums" '.issue.numbers = $nums' "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"
  trap - EXIT
  new_display=$(printf '%s\n' "$@" | sed 's/^/#/' | tr '\n' ' ' | sed 's/ $//')
  echo "Enqueued $# issue(s): $new_display (was: $old_display)"
  exit 0
fi

RALPH_SCRIPT="$(cd "$MAIN_REPO/.ralph" && pwd -P)/ralph.sh"

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

# Source the state-lock helpers so we can use the same PID-stamped lockdir
# primitive for worker locks and the launcher setup mutex.
LOG_DIR="$MAIN_REPO/.ralph/logs"
mkdir -p "$LOG_DIR" "$MAIN_REPO/.ralph/lock"
# shellcheck source=lib/state.sh
. "$MAIN_REPO/.ralph/lib/state.sh"

# Keep-awake (macOS): per-worker caffeinate processes are tracked in
# .ralph/lock/caffeinate-<N>.pid so --status, --stop, and --cleanup can
# manage them explicitly. Defense-in-depth against PID-reuse and missed
# kqueue notifications: caffeinate runs with `-w <worker_pid>` (primary)
# AND `-t 21600` (6h hard cap), so even if `-w` misbehaves, caffeinate
# self-terminates within 6 hours.
CAFFEINATE_TIMEOUT_SEC="${RALPH_CAFFEINATE_TIMEOUT:-21600}"

caffeinate_pidfile() {
  echo "$MAIN_REPO/.ralph/lock/caffeinate-$1.pid"
}

# Spawn a caffeinate watching $worker_pid; record its PID. macOS-only; no-op
# elsewhere.
spawn_caffeinate() {
  local worker_n="$1" worker_pid="$2"
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  command -v caffeinate >/dev/null 2>&1 || return 0
  caffeinate -i -m -w "$worker_pid" -t "$CAFFEINATE_TIMEOUT_SEC" \
    >/dev/null 2>&1 < /dev/null &
  local caf_pid=$!
  disown
  echo "$caf_pid" > "$(caffeinate_pidfile "$worker_n")"
  echo "  worker $worker_n caffeinate PID: $caf_pid (idle+disk sleep blocked, ${CAFFEINATE_TIMEOUT_SEC}s cap)"
}

# Kill all tracked caffeinate processes and remove their pidfiles.
stop_all_caffeinate() {
  local pidfile cpid
  shopt -s nullglob
  for pidfile in "$MAIN_REPO/.ralph/lock/"caffeinate-*.pid; do
    cpid=$(cat "$pidfile" 2>/dev/null || echo "")
    if [[ -n "$cpid" ]] && kill -0 "$cpid" 2>/dev/null; then
      echo "  SIGTERM caffeinate $cpid"
      kill "$cpid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  done
  shopt -u nullglob
}

scoped_ralph_processes() {
  ps -axww -o pid=,ppid=,command= | awk -v script="$RALPH_SCRIPT" '
    {
      pid=$1
      ppid=$2
      cmd=""
      for (i=3; i<=NF; i++) cmd = cmd (i==3 ? "" : " ") $i
      pids[++n]=pid
      parent[pid]=ppid
      command[pid]=cmd
      script_pos=index(cmd, script)
      if (script_pos > 0) {
        prefix=substr(cmd, 1, script_pos - 1)
        gsub(/[ \t]+$/, "", prefix)
        if (prefix == "" || prefix ~ /(bash|sh|zsh|nohup|timeout)$/) scoped[pid]=1
      }
    }
    END {
      changed=1
      while (changed) {
        changed=0
        for (i=1; i<=n; i++) {
          pid=pids[i]
          if (!scoped[pid] && scoped[parent[pid]]) {
            scoped[pid]=1
            changed=1
          }
        }
      }
      for (i=1; i<=n; i++) {
        pid=pids[i]
        if (!scoped[pid]) continue
        if (command[pid] ~ /ralph\.sh|copilot -p/) {
          print pid " " command[pid]
        }
      }
    }
  '
}

# --status: print active workers + claims and exit.
if [[ "${1:-}" == "--status" ]]; then
  state_file="$MAIN_REPO/.ralph/state.json"
  echo "Parallelism: $PARALLELISM"
  echo
  echo "Workers for $MAIN_REPO (from ps):"
  workers="$(scoped_ralph_processes)"
  if [[ -n "$workers" ]]; then
    echo "$workers"
  else
    echo "  (none)"
  fi
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
  echo
  echo "Keep-awake (caffeinate):"
  shopt -s nullglob
  caf_files=("$MAIN_REPO/.ralph/lock/"caffeinate-*.pid)
  shopt -u nullglob
  if [[ ${#caf_files[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    for pidfile in "${caf_files[@]}"; do
      pid=$(cat "$pidfile" 2>/dev/null || echo "")
      worker_n=$(basename "$pidfile" .pid | sed 's/^caffeinate-//')
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "  worker $worker_n: PID $pid (alive)"
      else
        echo "  worker $worker_n: PID $pid (dead, stale pidfile — will be cleaned on --stop/--cleanup)"
      fi
    done
  fi
  exit 0
fi

# --stop: SIGTERM every worker for this repo.
if [[ "${1:-}" == "--stop" ]]; then
  pids=$(scoped_ralph_processes | awk '{print $1}')
  if [[ -z "$pids" ]]; then
    echo "No ralph workers running for $MAIN_REPO."
    stop_all_caffeinate
    exit 0
  fi
  for pid in $pids; do
    echo "  SIGTERM $pid"
    kill "$pid" 2>/dev/null || true
  done
  stop_all_caffeinate
  exit 0
fi

# Helper: is worker $1 currently running? Reads its singleton lockdir's owner
# PID and validates it. Used to skip setup of worktrees that an active worker
# is using — the previous version unconditionally `git reset --hard origin/main`
# in every worker worktree, which would clobber an in-flight copilot iteration.
is_worker_running() {
  local n="$1"
  local lockdir="$MAIN_REPO/.ralph/lock/worker-$n"
  [[ -d "$lockdir" ]] || return 1
  local pid
  pid=$(cat "$lockdir/owner" 2>/dev/null || echo "")
  is_pid_alive_and_ralph "$pid"
}

cleanup_worktrees() {
  local removed=0 skipped=0
  for ((i = 1; i <= PARALLELISM; i++)); do
    local loop_repo
    loop_repo=$(worker_repo "$i")
    if is_worker_running "$i"; then
      echo "⚠️  Worker $i is still running; leaving $loop_repo."
      skipped=$((skipped + 1))
      continue
    fi
    if [[ ! -d "$loop_repo" ]]; then
      continue
    fi
    if [[ -n "$(git -C "$loop_repo" status --porcelain 2>/dev/null || true)" ]]; then
      echo "⚠️  Worker $i worktree is dirty; leaving $loop_repo."
      skipped=$((skipped + 1))
      continue
    fi
    echo "🧹 Removing worker $i worktree: $loop_repo"
    if git -C "$MAIN_REPO" worktree remove "$loop_repo"; then
      rm -rf "$MAIN_REPO/.ralph/lock/worker-$i" 2>/dev/null || true
      removed=$((removed + 1))
    else
      echo "⚠️  Failed to remove worker $i worktree: $loop_repo"
      skipped=$((skipped + 1))
    fi
  done
  echo "✅ Cleanup complete: removed=$removed skipped=$skipped"
  [[ "$skipped" -eq 0 ]]
}

# --cleanup: stop scoped workers and remove clean loop worktrees.
if [[ "${1:-}" == "--cleanup" ]]; then
  pids=$(scoped_ralph_processes | awk '{print $1}')
  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      echo "  SIGTERM $pid"
      kill "$pid" 2>/dev/null || true
    done
    sleep 2
  fi
  stop_all_caffeinate
  cleanup_worktrees
  exit $?
fi

# --foreground only meaningful with single worker — fan-out doesn't have
# anywhere to attach.
if [[ "${1:-}" == "--foreground" && "$PARALLELISM" -ne 1 ]]; then
  echo "❌ --foreground only valid with RALPH_PARALLELISM=1" >&2
  exit 1
fi

# Launcher-level mutex — prevents two concurrent `launch.sh` invocations from
# both running setup (which mutates .git/info/exclude, worktrees, and branch
# state). Workers never need to touch this lock.
SETUP_LOCK="$MAIN_REPO/.ralph/launch.lock"
if ! acquire_lockdir "$SETUP_LOCK"; then
  echo "❌ Another launch.sh is in flight (lock at $SETUP_LOCK). Aborting." >&2
  exit 1
fi
trap 'release_lockdir "$SETUP_LOCK"' EXIT

# Setup phase: create N worktrees and symlink .ralph in each.
EXCLUDE_FILE="$MAIN_REPO/.git/info/exclude"
if ! grep -qxF ".ralph" "$EXCLUDE_FILE" 2>/dev/null; then
  echo "🙈 Adding .ralph to $EXCLUDE_FILE"
  echo ".ralph" >> "$EXCLUDE_FILE"
fi

for ((i = 1; i <= PARALLELISM; i++)); do
  loop_repo=$(worker_repo "$i")
  loop_branch=$(worker_branch "$i")

  if is_worker_running "$i"; then
    echo "ℹ️  Worker $i: already running — leaving its worktree at $loop_repo untouched."
    continue
  fi

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
  release_lockdir "$SETUP_LOCK"
  trap - EXIT
  spawn_caffeinate 1 "$$"
  RALPH_WORKER_ID=1 exec "$MAIN_REPO/.ralph/ralph.sh"
fi

echo "🚀 Launching $PARALLELISM worker(s) in background. Tail: tail -f $LOG"
for ((i = 1; i <= PARALLELISM; i++)); do
  if is_worker_running "$i"; then
    echo "  worker $i: already running — skipping spawn."
    continue
  fi
  loop_repo=$(worker_repo "$i")
  cd "$loop_repo"
  worker_log="$MAIN_REPO/.ralph/logs/worker-${i}.out"
  mkdir -p "$(dirname "$worker_log")"
  RALPH_WORKER_ID=$i nohup "$MAIN_REPO/.ralph/ralph.sh" \
    >>"$worker_log" 2>&1 < /dev/null &
  worker_pid=$!
  disown
  echo "  worker $i PID: $worker_pid  → $worker_log"
  spawn_caffeinate "$i" "$worker_pid"
done

# Aggregate startup line into shared loop.out for backward-compat dashboard.
echo "[$(date -u +%FT%TZ)] launched $PARALLELISM worker(s)" >> "$LOG"
