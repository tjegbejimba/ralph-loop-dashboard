#!/usr/bin/env bash
# Launches the Ralph loop in a dedicated git worktree alongside your main
# checkout so loop work never conflicts with local edits. Setup is idempotent.
#
# Usage:
#   .ralph/launch.sh              # background, logs to .ralph/loop.out
#   .ralph/launch.sh --foreground # attached (for debugging)
#
# Configuration (env vars, all optional):
#   RALPH_MAIN_REPO    Path to your main checkout (default: $(git rev-parse --show-toplevel) of caller)
#   RALPH_LOOP_REPO    Path to the loop worktree (default: <MAIN_REPO>-ralph)
#   RALPH_LOOP_BRANCH  Branch name for the loop worktree (default: ralph-loop)

set -euo pipefail

# Ensure homebrew tools (gh, git, etc.) are on PATH even when launched from
# minimal-PATH contexts (nohup, launchd, dashboard, etc.)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Resolve the script's parent .ralph directory's containing repo.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
DEFAULT_MAIN="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MAIN_REPO="${RALPH_MAIN_REPO:-$DEFAULT_MAIN}"
LOOP_REPO="${RALPH_LOOP_REPO:-${MAIN_REPO}-ralph}"
LOOP_BRANCH="${RALPH_LOOP_BRANCH:-ralph-loop}"

# 1. Worktree exists?
if [[ ! -d "$LOOP_REPO" ]]; then
  echo "🌱 Creating loop worktree at $LOOP_REPO on branch $LOOP_BRANCH"
  cd "$MAIN_REPO"
  git fetch origin main
  git worktree add -B "$LOOP_BRANCH" "$LOOP_REPO" origin/main
  cd "$LOOP_REPO"
  git branch --set-upstream-to=origin/main "$LOOP_BRANCH"
fi

# 2. .ralph symlink exists in worktree?
if [[ ! -L "$LOOP_REPO/.ralph" ]]; then
  echo "🔗 Linking $LOOP_REPO/.ralph -> $MAIN_REPO/.ralph"
  ln -s "$MAIN_REPO/.ralph" "$LOOP_REPO/.ralph"
fi

# 3. Make sure the symlink is excluded from git so the preflight tree-clean
#    check doesn't trip over it.
EXCLUDE_FILE="$MAIN_REPO/.git/info/exclude"
if ! grep -qxF ".ralph" "$EXCLUDE_FILE" 2>/dev/null; then
  echo "🙈 Adding .ralph to $EXCLUDE_FILE"
  echo ".ralph" >> "$EXCLUDE_FILE"
fi

# 4. Sync worktree to latest main (loop expects clean main checkout)
cd "$LOOP_REPO"
git fetch origin main
git checkout "$LOOP_BRANCH" >/dev/null
git reset --hard origin/main >/dev/null
echo "✅ Worktree on $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"

# 5. Launch
LOG="$MAIN_REPO/.ralph/loop.out"
if [[ "${1:-}" == "--foreground" ]]; then
  exec "$MAIN_REPO/.ralph/ralph.sh"
fi

echo "🚀 Launching loop in background. Tail: tail -f $LOG"
nohup "$MAIN_REPO/.ralph/ralph.sh" >> "$LOG" 2>&1 < /dev/null &
disown
echo "PID: $!"
