#!/usr/bin/env bash
# install.sh — bootstrap the Ralph TDD loop into a target repo.
#
# Two things happen here:
#   1. The .ralph/ scripts (ralph.sh, launch.sh, RALPH.md) get copied into
#      the target repo so the loop is git-tracked per-project.
#   2. The dashboard extension gets copied into ~/.copilot/extensions/
#      so it's available in every Copilot CLI session, not just one repo.
#   3. The to-ralph skill gets symlinked into ~/.agents/skills/to-ralph
#      so the global agent gains the "publish PRD → load Ralph" capability.
#
# Usage (from inside this repo):
#   ./install.sh /path/to/your/project
#   ./install.sh /path/to/your/project --profile python
#   ./install.sh /path/to/your/project --extension-only
#   ./install.sh /path/to/your/project --scripts-only --profile bun
#   ./install.sh --skills-only          # symlink skills only, no repo required
#   ./install.sh --help                 # show this help

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh <target-repo-dir> [OPTIONS]
       ./install.sh --skills-only
       ./install.sh --help

Modes (default: --both):
  --both            Install loop scripts, dashboard extension, and skills (default)
  --scripts-only    Install only the .ralph/ loop scripts into the target repo
  --extension-only  Install only the dashboard extension into ~/.copilot/extensions/
  --skills-only     Symlink agent skills (e.g. to-ralph) into ~/.agents/skills/
                    No target repo is required for this mode.

Options:
  --profile <name>  Use a specific config profile (bun | python | generic).
                    Auto-detected from package.json if omitted.
  --force-config    Overwrite an existing .ralph/config.json from the profile.
  --help, -h        Show this help message and exit.

Skills (installed in --both and --skills-only modes):
  to-ralph          Symlinked to ~/.agents/skills/to-ralph.
                    Enables the agent to enqueue a PRD into Ralph and surface
                    preflight warnings before you launch workers.

  If ~/.agents/skills/ does not exist, install.sh prints an actionable hint
  instead of erroring. Skills are best-effort in --both mode.
EOF
}

# Handle --help / -h before any positional argument parsing.
for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    usage
    exit 0
  fi
done

TARGET="${1:-}"
MODE="--both"
PROFILE=""
FORCE_CONFIG=0

# --skills-only does not require a target repo directory.
if [[ "$TARGET" == "--skills-only" ]]; then
  MODE="--skills-only"
  TARGET=""
  shift || true
elif [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <target-repo-dir> [--both | --extension-only | --scripts-only | --skills-only] [--profile bun|python|generic] [--force-config]" >&2
  exit 1
else
  shift || true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --both|--extension-only|--scripts-only)
      MODE="$1"
      shift
      ;;
    --skills-only)
      MODE="--skills-only"
      shift
      ;;
    --profile)
      PROFILE="${2:-}"
      if [[ -z "$PROFILE" ]]; then
        echo "❌ --profile requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --force-config)
      FORCE_CONFIG=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Target repo validation is only required for modes that touch the repo.
if [[ "$MODE" != "--skills-only" ]]; then
  if [[ ! -d "$TARGET" ]]; then
    echo "❌ Target repo not found: $TARGET" >&2
    exit 1
  fi

  if [[ ! -d "$TARGET/.git" ]]; then
    echo "❌ Target is not a git repo: $TARGET" >&2
    exit 1
  fi
fi

detect_profile() {
  local target="$1"
  if [[ -n "$PROFILE" ]]; then
    echo "$PROFILE"
    return
  fi
  if [[ -f "$target/package.json" ]] && grep -q '"bun' "$target/package.json" 2>/dev/null; then
    echo "bun"
    return
  fi
  echo "generic"
}

install_config() {
  local target="$1"
  local ralph_dir="$target/.ralph"
  local profile
  profile="$(detect_profile "$target")"
  local profile_file="$REPO_DIR/ralph/profiles/${profile}.json"

  if [[ ! -f "$profile_file" ]]; then
    echo "❌ Unknown Ralph profile: $profile" >&2
    echo "   Available profiles:" >&2
    find "$REPO_DIR/ralph/profiles" -maxdepth 1 -name '*.json' -exec basename {} .json \; | sort >&2
    exit 1
  fi

  mkdir -p "$ralph_dir"
  if [[ -f "$ralph_dir/config.json" && "$FORCE_CONFIG" -ne 1 ]]; then
    echo "⚠️  $ralph_dir/config.json already exists — leaving untouched."
    echo "   Re-run with --force-config to replace it from profile '$profile'."
    return 0
  fi

  cp "$profile_file" "$ralph_dir/config.json"
  echo "✅ Config installed: $ralph_dir/config.json (profile: $profile)"
}

render_validation_commands() {
  local config_file="$1"
  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "$config_file" ]]; then
    echo "   - Run the relevant checks documented by this repo."
    return
  fi
  jq -r '
    (.validation.commands // []) as $commands
    | if ($commands | length) == 0 then
        "   - Run the relevant checks documented by this repo."
      else
        $commands[]
        | "   - " + (.name // "Check") + ": `" + (.command // "") + "`"
      end
  ' "$config_file"
}

install_agent_instructions() {
  local target="$1"
  local github_dir="$target/.github"
  local instructions_file="$github_dir/copilot-instructions.md"
  local marker="<!-- ralph-loop-instructions -->"

  mkdir -p "$github_dir"

  if [[ -f "$instructions_file" ]] && grep -qF "$marker" "$instructions_file"; then
    echo "ℹ️  Ralph agent instructions already present: $instructions_file"
    return 0
  fi

  if [[ -f "$instructions_file" ]]; then
    {
      printf '\n'
      printf '%s\n' "$marker"
      printf '## Ralph Loop\n\n'
      printf 'This repo may use Ralph Loop. If an agent needs to understand, install, refresh, operate, or troubleshoot Ralph here, load the `ralph-loop` skill.\n\n'
      printf -- '- Ralph source checkout on this machine: `%s`\n' "$REPO_DIR"
      printf -- '- Repo worker prompt: `.ralph/RALPH.md`\n'
      printf -- '- Repo config: `.ralph/config.json`\n'
      printf -- '- Refresh scripts: `%s/install.sh "%s" --scripts-only`\n' "$REPO_DIR" "$target"
      printf -- '- Check/stop/cleanup workers: `.ralph/launch.sh --status`, `--stop`, or `--cleanup`\n\n'
      printf 'Do not overwrite `.ralph/RALPH.md` or `.ralph/config.json` unless explicitly asked.\n'
    } >> "$instructions_file"
    echo "✅ Ralph agent instructions appended: $instructions_file"
    return 0
  fi

  {
    printf '%s\n' "$marker"
    printf '# Copilot instructions\n\n'
    printf '## Ralph Loop\n\n'
    printf 'This repo may use Ralph Loop. If an agent needs to understand, install, refresh, operate, or troubleshoot Ralph here, load the `ralph-loop` skill.\n\n'
    printf -- '- Ralph source checkout on this machine: `%s`\n' "$REPO_DIR"
    printf -- '- Repo worker prompt: `.ralph/RALPH.md`\n'
    printf -- '- Repo config: `.ralph/config.json`\n'
    printf -- '- Refresh scripts: `%s/install.sh "%s" --scripts-only`\n' "$REPO_DIR" "$target"
    printf -- '- Check/stop/cleanup workers: `.ralph/launch.sh --status`, `--stop`, or `--cleanup`\n\n'
    printf 'Do not overwrite `.ralph/RALPH.md` or `.ralph/config.json` unless explicitly asked.\n'
  } > "$instructions_file"
  echo "✅ Ralph agent instructions installed: $instructions_file"
}

install_scripts() {
  local target="$1"
  local ralph_dir="$target/.ralph"
  local has_prompt=0

  if [[ -d "$ralph_dir" ]]; then
    echo "🔄 Refreshing loop scripts -> $ralph_dir"
    [[ -f "$ralph_dir/RALPH.md" ]] && has_prompt=1
  else
    echo "📋 Copying loop scripts -> $ralph_dir"
  fi

  mkdir -p "$ralph_dir/lib"
  cp "$REPO_DIR/ralph/ralph.sh" "$ralph_dir/ralph.sh"
  cp "$REPO_DIR/ralph/launch.sh" "$ralph_dir/launch.sh"
  cp "$REPO_DIR/ralph/lib/state.sh" "$ralph_dir/lib/state.sh"
  cp "$REPO_DIR/ralph/lib/status.sh" "$ralph_dir/lib/status.sh"
  cp "$REPO_DIR/ralph/lib/pr-merge.sh" "$ralph_dir/lib/pr-merge.sh"
  rm -rf "$ralph_dir/profiles"
  cp -R "$REPO_DIR/ralph/profiles" "$ralph_dir/profiles"
  chmod +x "$ralph_dir/ralph.sh" "$ralph_dir/launch.sh"
  install_config "$target"
  install_agent_instructions "$target"

  if [[ "$has_prompt" -eq 1 ]]; then
    echo "⚠️  $ralph_dir/RALPH.md already exists — leaving prompt customization untouched."
    echo "   Delete it first if you want to re-render from the template."
    echo ""
    echo "ℹ️  Reminder: create the required Ralph labels in your target repo if not done yet:"
    echo "   gh label create needs-triage    --color E4E669 --description 'Needs human triage before agent work'"
    echo "   gh label create ready-for-agent --color 0075CA --description 'Safe for AFK Ralph workers to pick up'"
    echo "   gh label create hitl            --color B60205 --description 'Requires human interaction; not safe for AFK Ralph workers'"
    echo "   See docs/labels.md for full label vocabulary."
    return 0
  fi

  # Render RALPH.md from template using detected target repo slug.
  local repo_slug
  repo_slug="$(git -C "$target" config --get remote.origin.url 2>/dev/null \
    | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//' \
    || echo "OWNER/REPO")"
  local prd_ref="${RALPH_PRD_REFERENCE:-the parent PRD}"
  local validation_commands
  validation_commands="$(render_validation_commands "$ralph_dir/config.json")"

  REPO_SLUG="$repo_slug" PRD_REF="$prd_ref" VALIDATION_COMMANDS="$validation_commands" \
    perl -0pe '
      s/\{\{REPO\}\}/$ENV{REPO_SLUG}/g;
      s/\{\{PRD_REFERENCE\}\}/$ENV{PRD_REF}/g;
      s/\{\{VALIDATION_COMMANDS\}\}/$ENV{VALIDATION_COMMANDS}/g;
    ' "$REPO_DIR/ralph/RALPH.md.template" > "$ralph_dir/RALPH.md"

  cat > "$ralph_dir/.gitignore" <<'EOF'
# Per-iteration logs and runtime state — never commit.
loop.out
logs/
lock/
state.json
state.lock/
runs/
EOF

  echo "✅ Loop scripts installed. Customize $ralph_dir/RALPH.md if needed."
  echo "   To start the loop: $ralph_dir/launch.sh"
  echo ""
  echo "⚠️  Remember to create the required Ralph labels in your target repo:"
  echo "   gh label create needs-triage    --color E4E669 --description 'Needs human triage before agent work'"
  echo "   gh label create ready-for-agent --color 0075CA --description 'Safe for AFK Ralph workers to pick up'"
  echo "   gh label create hitl            --color B60205 --description 'Requires human interaction; not safe for AFK Ralph workers'"
  echo "   See docs/labels.md for full label vocabulary."
}

install_extension() {
  local user_ext_dir="$HOME/.copilot/extensions"
  mkdir -p "$user_ext_dir"
  local install_target="$user_ext_dir/ralph-dashboard"

  if [[ -L "$install_target" || -d "$install_target" ]]; then
    echo "📦 Refreshing extension at $install_target"
    rm -rf "$install_target"
  elif [[ -e "$install_target" ]]; then
    echo "⚠️  $install_target exists and is not a directory/symlink." >&2
    echo "   Move/delete it manually then re-run." >&2
    return 1
  fi

  mkdir -p "$install_target"
  cp -R "$REPO_DIR/extension/." "$install_target/"
  if [[ -f "$install_target/package.json" ]]; then
    (cd "$install_target" && npm install --no-audit --no-fund)
  fi
  echo "✅ Extension installed: $install_target"
  echo "   Restart Copilot CLI (or reload extensions) to load it."
}

install_skills() {
  local skills_dir="$HOME/.agents/skills"
  local install_target="$skills_dir/to-ralph"
  local source="$REPO_DIR/skills/to-ralph"
  local strict="${1:-0}"   # 1 = fail on missing dir, 0 = hint only

  if [[ ! -d "$skills_dir" ]]; then
    echo "ℹ️  ~/.agents/skills/ not found — to-ralph skill not installed."
    echo "   Create the directory and re-run to install the skill:"
    echo "   mkdir -p ~/.agents/skills && $0 --skills-only"
    if [[ "$strict" -eq 1 ]]; then
      return 0
    fi
    return 0
  fi

  if [[ -e "$install_target" && ! -L "$install_target" ]]; then
    echo "⚠️  $install_target exists and is not a symlink — leaving untouched." >&2
    echo "   Remove it manually to install the to-ralph skill." >&2
    return 1
  fi

  # Remove stale symlink before re-creating (idempotent).
  if [[ -L "$install_target" ]]; then
    rm "$install_target"
  fi

  ln -s "$source" "$install_target"
  echo "✅ to-ralph skill symlinked: $install_target -> $source"
}

case "$MODE" in
  --both|"")
    install_scripts "$TARGET"
    install_extension
    install_skills 0 || true   # best-effort in --both; never fail the overall install
    ;;
  --scripts-only)
    install_scripts "$TARGET"
    ;;
  --extension-only)
    install_extension
    ;;
  --skills-only)
    install_skills 1
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
