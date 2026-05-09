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
#   .ralph/launch.sh --enqueue <N>... # write issue numbers to config.json
#   .ralph/launch.sh --enqueue-prd <N> # resolve PRD slices and enqueue
#   .ralph/launch.sh --help       # show usage
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

RALPH_SCRIPT="$(cd "$MAIN_REPO/.ralph" && pwd -P)/ralph.sh"

# Repo slug for gh calls; respects RALPH_REPO override.
REPO="${RALPH_REPO:-$(git -C "$MAIN_REPO" config --get remote.origin.url 2>/dev/null \
  | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//' || true)}"

# gh binary — override via RALPH_GH_BIN for tests/CI environments where PATH
# is manipulated before the script prepends /opt/homebrew/bin.
GH="${RALPH_GH_BIN:-gh}"

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

# do_enqueue CONFIG_PATH N1 [N2 ...]
# Writes issue numbers to config.json's issue.numbers, preserving all other
# fields. Prints a short summary. Returns non-zero on error.
do_enqueue() {
  local config="$1"; shift
  local numbers=("$@")

  if [[ ! -f "$config" ]]; then
    echo "❌ .ralph/config.json not found at $config" >&2
    return 1
  fi

  # Deduplicate while preserving order (defense-in-depth for callers).
  local _seen_dedup=() _deduped=() _dup_n
  for _dup_n in "${numbers[@]}"; do
    local _already=0
    local _s
    for _s in "${_seen_dedup[@]:-}"; do [[ "$_s" == "$_dup_n" ]] && _already=1 && break; done
    if [[ "$_already" -eq 0 ]]; then
      _seen_dedup+=("$_dup_n")
      _deduped+=("$_dup_n")
    fi
  done
  numbers=("${_deduped[@]:-}")

  local nums_json current old_display new_display tmp
  nums_json=$(printf '%s\n' "${numbers[@]}" | jq -R 'tonumber' | jq -sc '.')
  current=$(jq -c '.issue.numbers // []' "$config")
  old_display=$(jq -r '(.issue.numbers // []) | map("#\(.)") | join(" ")' "$config")
  new_display=$(printf '#%s ' "${numbers[@]}" | sed 's/ $//')

  if [[ "$current" == "$nums_json" ]]; then
    echo "Enqueued ${#numbers[@]} issues: $new_display (unchanged)"
    return 0
  fi

  tmp=$(mktemp)
  jq --argjson nums "$nums_json" '.issue.numbers = $nums' "$config" > "$tmp"
  mv "$tmp" "$config"
  echo "Enqueued ${#numbers[@]} issues: $new_display (was: $old_display)"
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
if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage:
  .ralph/launch.sh                          # background, logs to .ralph/logs/
  .ralph/launch.sh --foreground             # attached (parallelism=1 only)
  .ralph/launch.sh --status                 # show running workers + claims
  .ralph/launch.sh --stop                   # SIGTERM all workers
  .ralph/launch.sh --cleanup                # stop workers + remove worktrees
  .ralph/launch.sh --enqueue <N>...         # write issue numbers to config.json
  .ralph/launch.sh --enqueue-prd <N>        # resolve PRD slices and enqueue them

Options:
  --enqueue <N>...
      Updates .ralph/config.json issue.numbers to the provided list, preserving
      all other fields. N must be positive integers. Idempotent.

  --enqueue-prd <N>
      Given a PRD issue number, finds all open AFK child slices (label:ready-for-
      agent, not label:hitl, unassigned) via GitHub search, enqueues them via
      --enqueue, and updates the {{PRD_REFERENCE}} in .ralph/RALPH.md.
      Mutually exclusive with --enqueue.

  --foreground    Run the worker loop in the foreground (RALPH_PARALLELISM=1 only).
  --status        Print running workers and issue claims.
  --stop          Send SIGTERM to all scoped Ralph workers.
  --cleanup       Stop workers and remove clean loop worktrees.

Environment:
  RALPH_PARALLELISM   Number of concurrent workers (default: 1)
  RALPH_MAIN_REPO     Path to main checkout
  RALPH_LOOP_REPO     Base path for loop worktree(s)
  RALPH_LOOP_BRANCH   Base branch name for loop worktree(s)
  RALPH_REPO          owner/repo slug for gh calls (auto-detected from git remote)
  RALPH_GH_BIN        Path to gh binary (default: gh)
USAGE
  exit 0
fi

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

# Mutual exclusivity: --enqueue and --enqueue-prd cannot appear together.
_has_enqueue=0; _has_enqueue_prd=0
for _a in "$@"; do
  [[ "$_a" == "--enqueue" ]]     && _has_enqueue=1
  [[ "$_a" == "--enqueue-prd" ]] && _has_enqueue_prd=1
done
if [[ "$_has_enqueue" -eq 1 && "$_has_enqueue_prd" -eq 1 ]]; then
  echo "❌ --enqueue and --enqueue-prd are mutually exclusive" >&2
  exit 1
fi
unset _has_enqueue _has_enqueue_prd _a

# --enqueue <N>...: write issue numbers into .ralph/config.json
if [[ "${1:-}" == "--enqueue" ]]; then
  shift
  if [[ $# -eq 0 ]]; then
    echo "❌ --enqueue requires at least one issue number" >&2
    exit 1
  fi
  for _n in "$@"; do
    if ! [[ "$_n" =~ ^[1-9][0-9]*$ ]]; then
      echo "❌ Invalid issue number: $_n (must be a positive integer)" >&2
      exit 1
    fi
  done
  _seen_enq=()
  for _n in "$@"; do
    for _s in "${_seen_enq[@]:-}"; do
      if [[ "$_s" == "$_n" ]]; then
        echo "❌ Duplicate issue number: $_n" >&2
        exit 1
      fi
    done
    _seen_enq+=("$_n")
  done
  unset _n _s _seen_enq
  do_enqueue "$MAIN_REPO/.ralph/config.json" "$@"
  exit $?
fi

# --enqueue-prd <N>: resolve PRD child slices, enqueue them, update RALPH.md
if [[ "${1:-}" == "--enqueue-prd" ]]; then
  shift
  if [[ $# -ne 1 ]]; then
    echo "❌ --enqueue-prd requires exactly one PRD issue number" >&2
    exit 1
  fi
  _prd_n="$1"
  if ! [[ "$_prd_n" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ Invalid PRD issue number: $_prd_n (must be a positive integer)" >&2
    exit 1
  fi

  # Verify PRD exists.
  if ! "$GH" issue view "$_prd_n" --repo "$REPO" --json number >/dev/null 2>&1; then
    echo "❌ PRD issue #$_prd_n not found in $REPO" >&2
    exit 1
  fi

  # Find AFK child slices (ready-for-agent, not hitl, open, unassigned).
  _afk_json=$("$GH" issue list \
    --repo "$REPO" \
    --search "\"Parent #${_prd_n}\" label:ready-for-agent -label:hitl is:open no:assignee" \
    --json number,labels \
    --limit 100 2>/dev/null || echo "[]")

  # Count HITL issues separately for the summary line.
  _hitl_count=$("$GH" issue list \
    --repo "$REPO" \
    --search "\"Parent #${_prd_n}\" label:hitl is:open" \
    --json number \
    --limit 100 2>/dev/null | jq 'length' 2>/dev/null || echo 0)

  # Collect AFK issue numbers.
  _afk_numbers=()
  while IFS= read -r _num; do
    [[ -n "$_num" ]] && _afk_numbers+=("$_num")
  done < <(echo "$_afk_json" | jq -r '.[].number' 2>/dev/null || true)

  if [[ ${#_afk_numbers[@]} -eq 0 ]]; then
    echo "❌ No AFK child slices found for PRD #$_prd_n (${_hitl_count} HITL issues skipped)" >&2
    exit 1
  fi

  # Topo-sort via dependency parser if available; otherwise preserve gh order.
  _dep_parser="$MAIN_REPO/extension/lib/dependency-parser.mjs"
  _blocker_count=0
  if [[ -f "$_dep_parser" ]]; then
    _sorted_result=$(
      node --input-type=module 2>/dev/null <<NODEEOF || echo '{"sorted":[],"blockers":0}'
import { parseDependencies } from '${_dep_parser}';
const numbers = ${_afk_json};
const sorted = parseDependencies(numbers);
const sortedNums = sorted.map(i => i.number ?? i);
const blockers = sorted.filter(i => i.blocked === true).length;
console.log(JSON.stringify({sorted: sortedNums, blockers}));
NODEEOF
    )
    _sorted_json=$(echo "$_sorted_result" | jq '.sorted // []' 2>/dev/null || echo "[]")
    _afk_numbers=()
    while IFS= read -r _num; do
      [[ -n "$_num" ]] && _afk_numbers+=("$_num")
    done < <(echo "$_sorted_json" | jq -r '.[]' 2>/dev/null || true)
    # Restore original order if parser returned empty (error fallback).
    if [[ ${#_afk_numbers[@]} -eq 0 ]]; then
      echo "⚠️  Warning: dependency parser returned no results — using original order" >&2
      _afk_numbers=()
      while IFS= read -r _num; do
        [[ -n "$_num" ]] && _afk_numbers+=("$_num")
      done < <(echo "$_afk_json" | jq -r '.[].number' 2>/dev/null || true)
      _blocker_count=0
    else
      _blocker_count=$(echo "$_sorted_result" | jq '.blockers // 0' 2>/dev/null || echo 0)
    fi
  fi

  # Write issue numbers to config via shared enqueue function.
  do_enqueue "$MAIN_REPO/.ralph/config.json" "${_afk_numbers[@]}"

  # Update RALPH.md: replace {{PRD_REFERENCE}} placeholder and/or the
  # existing reference following the RALPH_PRD_REF marker comment.
  _ralph_md="$MAIN_REPO/.ralph/RALPH.md"
  if [[ ! -f "$_ralph_md" ]]; then
    echo "⚠️  Warning: .ralph/RALPH.md not found — skipping RALPH.md update"
  elif ! grep -qF '<!-- RALPH_PRD_REF:' "$_ralph_md"; then
    echo "⚠️  Warning: .ralph/RALPH.md lacks PRD reference marker (<!-- RALPH_PRD_REF: -->) — skipping RALPH.md update"
  else
    # Extract the current reference value from the marker line.
    _cur_ref=$(sed -nE 's/.*<!-- RALPH_PRD_REF: ([^ >]+) -->.*/\1/p' "$_ralph_md" | head -1)
    if [[ -z "$_cur_ref" ]]; then
      echo "⚠️  Warning: RALPH_PRD_REF marker has no value — skipping RALPH.md update"
    elif [[ "$_cur_ref" != "#${_prd_n}" ]]; then
      # Escape for use as a sed literal-string pattern (| delimiter).
      # Curly braces are not special in BRE, so {{PRD_REFERENCE}} is safe as-is.
      _escaped=$(printf '%s' "$_cur_ref" | sed 's/[.[\*^$]/\\&/g')
      _tmp=$(mktemp)
      sed "s|${_escaped}|#${_prd_n}|g" "$_ralph_md" > "$_tmp"
      mv "$_tmp" "$_ralph_md"
    fi
  fi

  # Print summary.
  _afk_count=${#_afk_numbers[@]}
  _issues_display=$(printf '#%s ' "${_afk_numbers[@]}" | sed 's/ $//')
  echo "Enqueued PRD #${_prd_n} (${_afk_count} AFK slices, ${_hitl_count} HITL skipped, ${_blocker_count} unresolved blockers): ${_issues_display}"
  exit 0
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
