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
#   .ralph/launch.sh --once       # run one worker iteration, then exit
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
PARALLELISM="${RALPH_PARALLELISM:-1}"

# Compute a stable 12-char token from $MAIN_REPO's realpath. Used as the
# default loop branch suffix so two worktrees of the same repo each get
# their own branch (avoiding `git worktree add -B` failures on a shared
# `ralph-loop` ref). The hash is path-derived — NOT branch-derived — so it
# survives host worktree renames or detached-HEAD states. shasum is
# preferred over sha256sum for macOS/Linux portability; both ship in base
# installs and we slice the hex prefix the same way either way.
_default_branch_token() {
  local hash_input hash
  hash_input="$(cd "$MAIN_REPO" && pwd -P)"
  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$hash_input" | shasum -a 256 | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$hash_input" | sha256sum | awk '{print $1}')"
  else
    # Worst-case fallback: a deterministic awk hash of the path. Lower
    # entropy than sha256 but still unique enough across a handful of
    # worktrees on one repo.
    hash="$(printf '%s' "$hash_input" | awk '{h=0; for(i=1;i<=length($0);i++) h=(h*31+rdc(substr($0,i,1)))%1000000007; printf "%012x", h} function rdc(c){return index("abcdefghijklmnopqrstuvwxyz_-/.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",c)+1}')"
  fi
  printf '%s' "${hash:0:12}"
}
LOOP_BRANCH_BASE="${RALPH_LOOP_BRANCH:-ralph-loop-$(_default_branch_token)}"

RALPH_SCRIPT="$(cd "$MAIN_REPO/.ralph" && pwd -P)/ralph.sh"

# Strip launcher-level flags from $@ early so all sub-commands benefit.
FORCE=0
ONCE=0
_filtered_args=()
for _a in "$@"; do
  case "$_a" in
    --force)
      FORCE=1
      ;;
    --once)
      ONCE=1
      ;;
    *)
      _filtered_args+=("$_a")
      ;;
  esac
done
set -- "${_filtered_args[@]:-}"
unset _filtered_args _a

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
# shellcheck source=lib/status.sh
_status_lib="$MAIN_REPO/.ralph/lib/status.sh"
if [[ -f "$_status_lib" ]]; then
  # shellcheck disable=SC1090
  . "$_status_lib"
fi
unset _status_lib
# shellcheck source=lib/copilot-session.sh
_copilot_session_lib="$MAIN_REPO/.ralph/lib/copilot-session.sh"
if [[ -f "$_copilot_session_lib" ]]; then
  # shellcheck disable=SC1090
  . "$_copilot_session_lib"
fi
unset _copilot_session_lib
# shellcheck source=lib/labels.sh
_labels_lib="$MAIN_REPO/.ralph/lib/labels.sh"
if [[ -f "$_labels_lib" ]]; then
  # shellcheck disable=SC1090
  . "$_labels_lib"
fi
unset _labels_lib
# shellcheck source=lib/preflight.sh
# Preflight library is optional in older installs; only source if present so a
# stale installer doesn't break --enqueue/--status (operator gets a hint to
# re-run install.sh).
_preflight_lib="$MAIN_REPO/.ralph/lib/preflight.sh"
if [[ -f "$_preflight_lib" ]]; then
  # shellcheck disable=SC1090
  . "$_preflight_lib"
fi
unset _preflight_lib

# Terminal CLI helper (optional). Provides resolve_terminal_cli /
# invoke_terminal_cli for --status augmentation and the new --watch / --follow
# commands. Sourcing is conditional so older installs still work.
_terminal_cli_lib="$MAIN_REPO/.ralph/lib/terminal-cli.sh"
if [[ -f "$_terminal_cli_lib" ]]; then
  # shellcheck disable=SC1090
  . "$_terminal_cli_lib"
fi
unset _terminal_cli_lib

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
  # macOS/Linux use `ps -axww`; Cygwin/MSYS ps doesn't accept the BSD flags
  # and exits non-zero, which would abort callers under `set -euo pipefail`.
  # Fall back to an empty list when ps can't run our query so --status/--stop
  # stay usable in any shell environment.
  local ps_out
  if ! ps_out=$(ps -axww -o pid=,ppid=,command= 2>/dev/null); then
    return 0
  fi
  printf '%s\n' "$ps_out" | awk -v script="$RALPH_SCRIPT" '
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

print_usage() {
  cat <<'USAGE'
Usage:
  .ralph/launch.sh                          # background, logs to .ralph/logs/
  .ralph/launch.sh --foreground             # attached (parallelism=1 only)
  .ralph/launch.sh --status                 # show running workers + claims + rich snapshot
  .ralph/launch.sh --watch [SEC]            # live local-only refresh (default 2s, Ctrl-C to exit)
  .ralph/launch.sh --follow [N]             # tail the active worker N's iteration log
  .ralph/launch.sh --stop                   # SIGTERM all workers
  .ralph/launch.sh --cleanup                # stop workers + remove worktrees
  .ralph/launch.sh --enqueue <N>...         # write issue numbers to config.json
  .ralph/launch.sh --enqueue-prd <N>        # resolve PRD slices and enqueue them
  .ralph/launch.sh --once                   # run one worker iteration, then exit
  .ralph/launch.sh --help | -h              # print this message

Options:
  --enqueue <N>...
      Updates .ralph/config.json issue.numbers to the provided list, preserving
      all other fields. N must be positive integers. Idempotent.

  --enqueue-prd <N>
      Given a PRD issue number, finds all canonical runnable child slices
      (ralph:ready, work:slice, exact Parent #N marker, unassigned) via GitHub
      search, enqueues them via --enqueue, and updates the {{PRD_REFERENCE}} in
      .ralph/RALPH.md. Mutually exclusive with --enqueue.

  --foreground    Run the worker loop in the foreground (RALPH_PARALLELISM=1 only).
  --once          Ask each worker to run one iteration, then exit.
  --status        Print running workers and issue claims, followed by a rich
                  snapshot (current iterations, queue progress, loop.out tail).
  --watch [SEC]   Re-render the local snapshot every SEC seconds (default 2).
                  No gh API calls — purely reads .ralph/ state. Ctrl-C exits.
  --follow [N]    Tail worker N's iteration log; with no arg, picks the
                  lowest-numbered active worker. Re-tails when the worker
                  rolls to the next iteration.
  --stop          Send SIGTERM to all scoped Ralph workers.
  --cleanup       Stop workers and remove clean loop worktrees.
  --help, -h      Print this message and exit.
  --force         Override stale-script check (see below).

Stale-script check:
  When both ralph/ralph.sh (source) and .ralph/ralph.sh (installed) are present
  and the source is newer, launch refuses with a hint to run:
    ./install.sh <repo> --scripts-only
  Pass --force to bypass this check.

Environment:
  RALPH_PARALLELISM   Number of concurrent workers (default: 1)
  RALPH_MAIN_REPO     Path to main checkout
  RALPH_LOOP_REPO     Base path for loop worktree(s)
  RALPH_LOOP_BRANCH   Base branch name for loop worktree(s)
  RALPH_REPO          owner/repo slug for gh calls (auto-detected from git remote)
  RALPH_GH_BIN        Path to gh binary (default: gh)
  RALPH_TERMINAL_CLI  Override path to the terminal CLI (extension/cli.mjs)
                      Defaults to ~/.copilot/extensions/ralph-dashboard/cli.mjs
                      then the source checkout next to this script.
USAGE
}

# --help / -h: print usage and exit.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_usage
  exit 0
fi

if [[ "${1:-}" == "--status" ]]; then
  state_file="$MAIN_REPO/.ralph/state.json"
  
  # Reconcile stale workers across all active runs
  if declare -F status_reconcile_stale_workers >/dev/null 2>&1; then
    if [[ -d "$MAIN_REPO/.ralph/runs" ]]; then
      for run_dir in "$MAIN_REPO/.ralph/runs/"*; do
        [[ ! -d "$run_dir" ]] && continue
        run_id=$(basename "$run_dir")
        status_file_path="$run_dir/status.json"
        [[ ! -f "$status_file_path" ]] && continue
        
        # Reconcile this run's stale workers
        state_lock
        RUN_ID="$run_id" status_reconcile_stale_workers "$run_id" || true
        state_unlock
      done
    fi
  fi
  
  echo "Parallelism: $PARALLELISM"
  echo
  echo "Workers for $MAIN_REPO (from ps):"
  workers="$(scoped_ralph_processes)"
  workers_live=0
  if [[ -n "$workers" ]]; then
    # Truncate the giant `copilot -p '<RALPH.md prompt>'` argv to a single-line
    # readable form. The prompt is enormous (~10 KB) and full of escaped
    # newlines, drowning the rest of the status output in noise. We keep PID
    # and command name, replace the prompt argv with `<prompt N chars>`, and
    # preserve any trailing CLI flag run (e.g. `--allow-all --model …`).
    #
    # The trailing-flag region is detected by tokenising from the right and
    # walking left as long as we keep seeing flag tokens (`--foo`) or their
    # immediate values. The prompt body itself contains many literal `--flag`
    # strings (e.g. `gh pr list --repo`) so neither the first nor last ` --`
    # in isolation works — we need the consecutive run at the end of line.
    workers_live=1
    echo "$workers" | awk '
      {
        pid=$1
        cmd=""
        for (i=2; i<=NF; i++) cmd = cmd (i==2 ? "" : " ") $i
        marker = "copilot -p "
        idx = index(cmd, marker)
        if (idx > 0) {
          prefix = substr(cmd, 1, idx + length(marker) - 1)
          rest   = substr(cmd, idx + length(marker))
          # Tokenise rest on whitespace; walk left across the trailing flag run.
          n_tok = split(rest, toks, /[ \t]+/)
          cut = n_tok + 1   # 1-based index of first trailing-flag token
          # Sweep right-to-left: include `--flag` tokens and one value after.
          i = n_tok
          while (i >= 1) {
            if (toks[i] ~ /^--[a-zA-Z]/) {
              cut = i
              i--
            } else if (i > 1 && toks[i-1] ~ /^--[a-zA-Z]/) {
              # toks[i] is the value for the preceding --flag; include both.
              cut = i - 1
              i -= 2
            } else {
              break
            }
          }
          if (cut <= n_tok) {
            prompt_part = ""
            for (j = 1; j < cut; j++) prompt_part = prompt_part (j == 1 ? "" : " ") toks[j]
            trailing = ""
            for (j = cut; j <= n_tok; j++) trailing = trailing " " toks[j]
          } else {
            prompt_part = rest
            trailing = ""
          }
          printf "  %s %s<prompt %d chars>%s\n", pid, prefix, length(prompt_part), trailing
        } else {
          printf "  %s %s\n", pid, cmd
        }
      }
    '
  else
    echo "  (none)"
  fi
  echo
  claims_count=0
  if [[ -f "$state_file" ]]; then
    claims_count=$(jq -r '(.claims // {}) | length' "$state_file" 2>/dev/null || echo 0)
    echo "Claims (from state.json):"
    if [[ "$claims_count" -gt 0 ]]; then
      jq -r '
        .claims | to_entries[]
        | "  #\(.key)  worker=\(.value.workerId)  pid=\(.value.pid)  log=\(.value.logFile)"
      ' "$state_file" 2>/dev/null || echo "  (state.json unreadable)"
    else
      echo "  (none)"
    fi
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
      elif [[ "$workers_live" -eq 1 || "$claims_count" -gt 0 ]]; then
        # A worker is running but its caffeinate helper died — that's worth
        # surfacing because the machine may sleep mid-iteration.
        echo "  worker $worker_n: caffeinate not running (stale pidfile)"
      else
        # No live workers — a stale pidfile is just leftover state.
        echo "  worker $worker_n: not running"
      fi
    done
  fi
  if declare -F preflight_run >/dev/null 2>&1; then
    echo
    # --status always exits 0 — preflight returns non-zero on blockers, but
    # operators use --status to inspect rather than gate; absorb the rc.
    # Export loop-active context so preflight can compute a smarter verdict:
    # a running loop is allowed to dirty the tree and shouldn't be flagged.
    if [[ "$workers_live" -eq 1 || "$claims_count" -gt 0 ]]; then
      RALPH_LOOP_ACTIVE=1 preflight_run || true
    else
      preflight_run || true
    fi
  fi
  # Rich snapshot from the terminal CLI (current iterations, queue progress,
  # loop.out tail). Silent fallback when node or the CLI isn't available so
  # legacy installs still print the sections above.
  if declare -F invoke_terminal_cli >/dev/null 2>&1; then
    echo
    invoke_terminal_cli status 2>/dev/null || true
  fi
  exit 0
fi

# --watch: live local-only refresh. Delegates entirely to the terminal CLI.
if [[ "${1:-}" == "--watch" ]]; then
  if ! declare -F invoke_terminal_cli >/dev/null 2>&1; then
    echo "--watch requires the Ralph terminal CLI. Re-run install.sh --both to install it, " >&2
    echo "or set RALPH_TERMINAL_CLI to point at extension/cli.mjs." >&2
    exit 2
  fi
  shift
  invoke_terminal_cli watch "$@"
  exit $?
fi

# --follow: tail an active worker's iteration log. Delegates to the CLI.
if [[ "${1:-}" == "--follow" ]]; then
  if ! declare -F invoke_terminal_cli >/dev/null 2>&1; then
    echo "--follow requires the Ralph terminal CLI. Re-run install.sh --both to install it, " >&2
    echo "or set RALPH_TERMINAL_CLI to point at extension/cli.mjs." >&2
    exit 2
  fi
  shift
  invoke_terminal_cli follow "$@"
  exit $?
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
  if declare -F copilot_session_archive_completed >/dev/null 2>&1; then
    copilot_session_archive_completed
  fi
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
  enq_rc=$?
  if [[ "$enq_rc" -ne 0 ]]; then
    exit "$enq_rc"
  fi
  if declare -F ralph_apply_label_transition >/dev/null 2>&1; then
    for _enq_issue in "$@"; do
      ralph_apply_label_transition "$_enq_issue" enqueue || true
    done
    unset _enq_issue
  fi
  if declare -F preflight_run >/dev/null 2>&1; then
    echo
    preflight_run || true
  fi
  exit 0
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

  # Verify PRD exists and is a canonical, evaluated PRD parent.
  _prd_record=$("$GH" issue view "$_prd_n" --repo "$REPO" --json number,state,title,body,labels 2>/dev/null | tr -d '\r' || echo "")
  if [[ -z "$_prd_record" ]]; then
    echo "❌ PRD issue #$_prd_n not found in $REPO" >&2
    exit 1
  fi
  if declare -F ralph_prd_blocker_tags >/dev/null 2>&1; then
    _prd_blockers=$(ralph_prd_blocker_tags "$_prd_record")
    if [[ -n "$_prd_blockers" ]]; then
      echo "❌ PRD issue #$_prd_n is not enqueueable: $_prd_blockers" >&2
      exit 1
    fi
  fi

  # Find canonical runnable child slices (open, unassigned, work:slice,
  # ralph:ready or ralph:blocked with satisfied blockers).
  _runnable_json=$("$GH" issue list \
    --repo "$REPO" \
    --search "\"Parent #${_prd_n}\" label:work:slice is:open no:assignee" \
    --json number,title,body,state,labels,assignees \
    --limit 100 2>/dev/null || echo "[]")

  # Count HITL issues separately for the summary line.
  _hitl_count=$("$GH" issue list \
    --repo "$REPO" \
    --search "\"Parent #${_prd_n}\" label:ralph:hitl is:open" \
    --json number \
    --limit 100 2>/dev/null | jq 'length' 2>/dev/null || echo 0)

  # Collect enqueueable issue numbers.
  _runnable_numbers=()
  if declare -F ralph_enqueueable_blocker_tags >/dev/null 2>&1; then
    while IFS= read -r _row; do
      [[ -z "$_row" ]] && continue
      _record=$(echo "$_row" | base64 --decode | tr -d '\r')
      _num=$(echo "$_record" | jq -r '.number')
      _blockers=$(ralph_enqueueable_blocker_tags "$_record")
      [[ -z "$_blockers" && -n "$_num" ]] && _runnable_numbers+=("$_num")
    done < <(echo "$_runnable_json" | jq -r '.[] | @base64' 2>/dev/null || true)
    unset _row _record _num _blockers
  else
    while IFS= read -r _num; do
      [[ -n "$_num" ]] && _runnable_numbers+=("$_num")
    done < <(echo "$_runnable_json" | jq -r '.[].number' 2>/dev/null || true)
  fi

  if [[ ${#_runnable_numbers[@]} -eq 0 ]]; then
    echo "❌ No canonical runnable child slices found for PRD #$_prd_n (${_hitl_count} HITL issues skipped)" >&2
    exit 1
  fi

  # Topo-sort via dependency parser if available; otherwise preserve gh order.
  _dep_parser="$MAIN_REPO/extension/lib/dependency-parser.mjs"
  _blocker_count=0
  if [[ -f "$_dep_parser" ]]; then
    _sorted_result=$(
      RALPH_DEP_PARSER="$_dep_parser" RALPH_RUNNABLE_JSON="$_runnable_json" \
      node --input-type=module 2>/dev/null <<'NODEEOF' || echo '{"sorted":[],"blockers":0}'
import { pathToFileURL } from 'node:url';
const { parseDependencies } = await import(pathToFileURL(process.env.RALPH_DEP_PARSER).href);
const numbers = JSON.parse(process.env.RALPH_RUNNABLE_JSON || "[]");
const sorted = parseDependencies(numbers);
const sortedNums = sorted.map(i => i.number ?? i);
const blockers = sorted.filter(i => i.blocked === true).length;
console.log(JSON.stringify({sorted: sortedNums, blockers}));
NODEEOF
    )
    _sorted_json=$(echo "$_sorted_result" | jq '.sorted // []' 2>/dev/null || echo "[]")
    _runnable_numbers=()
    while IFS= read -r _num; do
      [[ -n "$_num" ]] && _runnable_numbers+=("$_num")
    done < <(echo "$_sorted_json" | jq -r '.[]' 2>/dev/null || true)
    # Restore original order if parser returned empty (error fallback).
    if [[ ${#_runnable_numbers[@]} -eq 0 ]]; then
      echo "⚠️  Warning: dependency parser returned no results — using original order" >&2
      _runnable_numbers=()
      while IFS= read -r _num; do
        [[ -n "$_num" ]] && _runnable_numbers+=("$_num")
      done < <(echo "$_runnable_json" | jq -r '.[].number' 2>/dev/null || true)
      _blocker_count=0
    else
      _blocker_count=$(echo "$_sorted_result" | jq '.blockers // 0' 2>/dev/null || echo 0)
    fi
  fi

  # Write issue numbers to config via shared enqueue function.
  do_enqueue "$MAIN_REPO/.ralph/config.json" "${_runnable_numbers[@]}"
  if declare -F ralph_apply_label_transition >/dev/null 2>&1; then
    for _enq_issue in "${_runnable_numbers[@]}"; do
      ralph_apply_label_transition "$_enq_issue" enqueue || true
    done
    unset _enq_issue
  fi

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
  _runnable_count=${#_runnable_numbers[@]}
  _issues_display=$(printf '#%s ' "${_runnable_numbers[@]}" | sed 's/ $//')
  echo "Enqueued PRD #${_prd_n} (${_runnable_count} canonical runnable slices, ${_hitl_count} HITL skipped, ${_blocker_count} unresolved blockers): ${_issues_display}"

  if declare -F preflight_run >/dev/null 2>&1; then
    echo
    preflight_run || true
  fi
  exit 0
fi

# Stale-script detection: when both ralph/ralph.sh (source) and
# .ralph/ralph.sh (installed copy) exist, warn if the source content differs
# from the installed copy. Per ADR 0004 decision 3, enforcement is now via CI
# (install.sh --check), so this runtime guard is warn-only to avoid
# hard-stopping unattended workers. Use --force to suppress the warning.
_src_ralph="$MAIN_REPO/ralph/ralph.sh"
_ins_ralph="$MAIN_REPO/.ralph/ralph.sh"
if [[ -f "$_src_ralph" && -f "$_ins_ralph" ]]; then
  # Compare by content, not mtime. Git rewrites working-tree mtimes on
  # checkout/merge even when content is unchanged, which trips mtime-based
  # guards in self-hosting repos. Use cmp -s for byte-wise comparison.
  if ! cmp -s "$_src_ralph" "$_ins_ralph"; then
    if [[ "$FORCE" -eq 1 ]]; then
      echo "⚠️  Installed scripts are stale but --force override active." >&2
    else
      echo "⚠️  Your installed scripts may be stale — run ./install.sh <repo> --scripts-only" >&2
      echo "   (this is a warning; workers will continue — CI enforces content match at PR time)" >&2
    fi
  fi
fi
unset _src_ralph _ins_ralph
unset _src_ralph _ins_ralph _src_mtime _ins_mtime

# --foreground only meaningful with single worker — fan-out doesn't have
# anywhere to attach.
if [[ "${1:-}" == "--foreground" && "$PARALLELISM" -ne 1 ]]; then
  echo "❌ --foreground only valid with RALPH_PARALLELISM=1" >&2
  exit 1
fi

# Reject any remaining unknown flags before touching filesystem state.
# Iterate all args: --foreground is the only valid positional at this point.
for _flag in "$@"; do
  [[ "$_flag" == "--foreground" ]] && continue
  if [[ "$_flag" == -* ]]; then
    echo "unknown option: $_flag" >&2
    print_usage >&2
    exit 1
  fi
done
unset _flag

# Launcher-level mutex — prevents two concurrent `launch.sh` invocations from
# both running setup (which mutates .git/info/exclude, worktrees, and branch
# state). Workers never need to touch this lock.
#
# We acquire TWO locks:
#   1. The per-.ralph SETUP_LOCK guards against double-invocation from the
#      same .ralph/ (e.g., dashboard double-click).
#   2. A common-gitdir setup lock guards against simultaneous launches from
#      *different* worktrees of the same repo. Both worktrees share refs,
#      packed-refs, and `git worktree add`'s worktree registry, so
#      uncoordinated setup phases can race.
SETUP_LOCK="$MAIN_REPO/.ralph/launch.lock"
if ! acquire_lockdir "$SETUP_LOCK"; then
  echo "❌ Another launch.sh is in flight (lock at $SETUP_LOCK). Aborting." >&2
  exit 1
fi
COMMON_GIT_DIR="$(git -C "$MAIN_REPO" rev-parse --git-common-dir 2>/dev/null || echo "$MAIN_REPO/.git")"
# rev-parse returns a path relative to MAIN_REPO when the repo is a
# regular checkout; absolutize so the lock lives in the same place
# regardless of which worktree invoked launch.
if [[ "$COMMON_GIT_DIR" != /* ]]; then
  COMMON_GIT_DIR="$MAIN_REPO/$COMMON_GIT_DIR"
fi
COMMON_GIT_DIR="$(cd "$COMMON_GIT_DIR" 2>/dev/null && pwd -P || echo "$COMMON_GIT_DIR")"
COMMON_SETUP_LOCK="$COMMON_GIT_DIR/ralph-launch.lock"
if ! acquire_lockdir "$COMMON_SETUP_LOCK"; then
  release_lockdir "$SETUP_LOCK"
  echo "❌ Another launch.sh is in flight against this repo's common gitdir (lock at $COMMON_SETUP_LOCK). Aborting." >&2
  exit 1
fi
trap 'release_lockdir "$COMMON_SETUP_LOCK"; release_lockdir "$SETUP_LOCK"' EXIT

# Setup phase: create N worktrees and symlink .ralph in each.
# Resolve the exclude file via git so worktree targets (where MAIN_REPO/.git
# is a gitlink file) write to the common gitdir's info/exclude. The common
# exclude is shared across all worktrees of the repo, which is what we
# want — .ralph/ should be ignored everywhere once any worktree opts in.
_exclude_rel="$(git -C "$MAIN_REPO" rev-parse --git-path info/exclude 2>/dev/null || echo "")"
if [[ -n "$_exclude_rel" ]]; then
  if [[ "$_exclude_rel" = /* ]]; then
    EXCLUDE_FILE="$_exclude_rel"
  else
    EXCLUDE_FILE="$MAIN_REPO/$_exclude_rel"
  fi
else
  EXCLUDE_FILE="$MAIN_REPO/.git/info/exclude"
fi
unset _exclude_rel
mkdir -p "$(dirname "$EXCLUDE_FILE")"
if ! grep -qxF ".ralph" "$EXCLUDE_FILE" 2>/dev/null; then
  echo "🙈 Adding .ralph to $EXCLUDE_FILE"
  echo ".ralph" >> "$EXCLUDE_FILE"
fi

# Retry git fetch — independent loops from sibling worktrees share the
# common gitdir's refs/remotes/origin/main.lock; a single collision under
# `set -e` would abort the entire setup. Mirrors the worker-side retry
# loop in ralph/ralph.sh::sync_to_origin_main.
_launch_git_fetch() {
  local repo="$1"
  local attempt rc=1
  for attempt in 1 2 3 4 5; do
    git -C "$repo" fetch origin main >/dev/null 2>&1 && return 0
    rc=$?
    sleep "$(awk -v a="$attempt" 'BEGIN{srand(); printf "%.2f", a*(0.5+rand())}')"
  done
  return "$rc"
}

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
    _launch_git_fetch "$MAIN_REPO" \
      || { echo "❌ git fetch origin main failed after 5 attempts; aborting setup." >&2; exit 1; }
    git worktree add -B "$loop_branch" "$loop_repo" origin/main
    cd "$loop_repo"
    git branch --set-upstream-to=origin/main "$loop_branch"
  fi

  if [[ ! -L "$loop_repo/.ralph" ]]; then
    echo "🔗 Worker $i: linking $loop_repo/.ralph -> $MAIN_REPO/.ralph"
    ln -s "$MAIN_REPO/.ralph" "$loop_repo/.ralph"
  fi

  cd "$loop_repo"
  _launch_git_fetch "$loop_repo" \
    || { echo "❌ git fetch origin main failed after 5 attempts; aborting setup." >&2; exit 1; }
  # Legacy migration: pre-existing single-worktree installs may already be
  # checked out on the old default `ralph-loop` branch. If the expected
  # hash-derived branch doesn't exist yet, create it from origin/main
  # in-place rather than failing the checkout. Idempotent on re-launch.
  if ! git rev-parse --verify --quiet "refs/heads/$loop_branch" >/dev/null; then
    git checkout -B "$loop_branch" origin/main >/dev/null
  else
    git checkout "$loop_branch" >/dev/null
  fi
  git reset --hard origin/main >/dev/null
  echo "✅ Worker $i: on $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"
done

# Launch phase.
LOG="$MAIN_REPO/.ralph/loop.out"
RALPH_WORKER_ARGS=()
if [[ "$ONCE" -eq 1 ]]; then
  RALPH_WORKER_ARGS+=(--once)
fi

if [[ "${1:-}" == "--foreground" ]]; then
  cd "$(worker_repo 1)"
  release_lockdir "$COMMON_SETUP_LOCK"
  release_lockdir "$SETUP_LOCK"
  trap - EXIT
  spawn_caffeinate 1 "$$"
  RALPH_WORKER_ID=1 exec "$MAIN_REPO/.ralph/ralph.sh" "${RALPH_WORKER_ARGS[@]}"
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
  RALPH_WORKER_ID=$i nohup "$MAIN_REPO/.ralph/ralph.sh" "${RALPH_WORKER_ARGS[@]}" \
    >>"$worker_log" 2>&1 < /dev/null &
  worker_pid=$!
  disown
  echo "  worker $i PID: $worker_pid  → $worker_log"
  spawn_caffeinate "$i" "$worker_pid"
done

# Aggregate startup line into shared loop.out for backward-compat dashboard.
echo "[$(date -u +%FT%TZ)] launched $PARALLELISM worker(s)" >> "$LOG"
