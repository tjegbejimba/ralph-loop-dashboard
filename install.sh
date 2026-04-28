#!/usr/bin/env bash
# install.sh — bootstrap the Ralph TDD loop into a target repo.
#
# Two things happen here:
#   1. The .ralph/ scripts (ralph.sh, launch.sh, RALPH.md) get copied into
#      the target repo so the loop is git-tracked per-project.
#   2. The dashboard extension gets symlinked into ~/.copilot/extensions/
#      so it's available in every Copilot CLI session, not just one repo.
#
# Usage (from inside this repo):
#   ./install.sh /path/to/your/project
#   ./install.sh /path/to/your/project --extension-only
#   ./install.sh /path/to/your/project --scripts-only

set -euo pipefail

TARGET="${1:-}"
MODE="${2:---both}"

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <target-repo-dir> [--both | --extension-only | --scripts-only]" >&2
  exit 1
fi

if [[ ! -d "$TARGET" ]]; then
  echo "❌ Target repo not found: $TARGET" >&2
  exit 1
fi

if [[ ! -d "$TARGET/.git" ]]; then
  echo "❌ Target is not a git repo: $TARGET" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd -P)"

install_scripts() {
  local target="$1"
  local ralph_dir="$target/.ralph"

  if [[ -d "$ralph_dir" ]]; then
    echo "⚠️  $ralph_dir already exists — leaving untouched."
    echo "   Delete or rename it first if you want to re-bootstrap."
    return 0
  fi

  echo "📋 Copying loop scripts -> $ralph_dir"
  mkdir -p "$ralph_dir"
  cp "$REPO_DIR/ralph/ralph.sh" "$ralph_dir/ralph.sh"
  cp "$REPO_DIR/ralph/launch.sh" "$ralph_dir/launch.sh"
  chmod +x "$ralph_dir/ralph.sh" "$ralph_dir/launch.sh"

  # Render RALPH.md from template using detected target repo slug.
  local repo_slug
  repo_slug="$(git -C "$target" config --get remote.origin.url 2>/dev/null \
    | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//' \
    || echo "OWNER/REPO")"
  local prd_ref="${RALPH_PRD_REFERENCE:-the parent PRD}"

  sed -e "s|{{REPO}}|$repo_slug|g" -e "s|{{PRD_REFERENCE}}|$prd_ref|g" \
    "$REPO_DIR/ralph/RALPH.md.template" > "$ralph_dir/RALPH.md"

  cat > "$ralph_dir/.gitignore" <<'EOF'
# Per-iteration logs and runtime state — never commit.
loop.out
logs/
lock/
EOF

  echo "✅ Loop scripts installed. Customize $ralph_dir/RALPH.md if needed."
  echo "   To start the loop: $ralph_dir/launch.sh"
}

install_extension() {
  local user_ext_dir="$HOME/.copilot/extensions"
  mkdir -p "$user_ext_dir"
  local link_target="$user_ext_dir/ralph-dashboard"

  if [[ -L "$link_target" ]]; then
    echo "🔗 Existing symlink at $link_target — refreshing."
    rm "$link_target"
  elif [[ -e "$link_target" ]]; then
    echo "⚠️  $link_target exists and is not a symlink." >&2
    echo "   Move/delete it manually then re-run." >&2
    return 1
  fi

  ln -s "$REPO_DIR/extension" "$link_target"
  echo "✅ Extension linked: $link_target -> $REPO_DIR/extension"
  echo "   Restart Copilot CLI (or run /restart) to load it."
}

case "$MODE" in
  --both|"")
    install_scripts "$TARGET"
    install_extension
    ;;
  --scripts-only)
    install_scripts "$TARGET"
    ;;
  --extension-only)
    install_extension
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
