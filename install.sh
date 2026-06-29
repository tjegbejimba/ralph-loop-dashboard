#!/usr/bin/env bash
# install.sh — bootstrap the Ralph TDD loop into a target repo.
#
# Two things happen here:
#   1. The .ralph/ scripts (ralph.sh, launch.sh, RALPH.md) get copied into
#      the target repo so the loop is git-tracked per-project.
#   2. The dashboard extension gets copied into ~/.copilot/extensions/
#      so it's available in every Copilot CLI session, not just one repo.
#   3. Bundled skills get symlinked into ~/.agents/skills/
#      so the global agent gains Ralph-specific workflows.
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
       ./install.sh <target-repo-dir> --check
       ./install.sh --skills-only
       ./install.sh --help

Modes (default: --both):
  --both            Install loop scripts, dashboard extension, and skills (default)
  --scripts-only    Install only the .ralph/ loop scripts into the target repo
  --extension-only  Install only the dashboard extension into ~/.copilot/extensions/
  --skills-only     Symlink bundled agent skills into ~/.agents/skills/
                    No target repo is required for this mode.
  --check           Verify installed .ralph/* scripts match ralph/* source by content.
                    Exits 0 if content matches, non-zero if diverged (reports files).
                    Read-only; used by CI drift gate.

Options:
  --profile <name>  Use a specific config profile (bun | python | generic).
                    Auto-detected from package.json if omitted.
  --force-config    Overwrite an existing .ralph/config.json from the profile.
  --help, -h        Show this help message and exit.

Skills (installed in --both and --skills-only modes):
  to-ralph          Symlinked to ~/.agents/skills/to-ralph.
                    Enables the agent to enqueue a PRD into Ralph and surface
                    preflight warnings before you launch workers.
  ralph-issue-triage-agent
                    Symlinked to ~/.agents/skills/ralph-issue-triage-agent.
                    Enables dry-run-only advisory triage from frozen issue evidence.
  ralph-orchestrator
                    Symlinked to ~/.agents/skills/ralph-orchestrator.
                    Control-plane orchestrator that drives a PRD (prd-run) or a
                    scheduled repo sweep (repo-maintain) through the Ralph loop.

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
    --both|--extension-only|--scripts-only|--check)
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

# --check mode: verify installed scripts match source by content.
if [[ "$MODE" == "--check" ]]; then
  if [[ ! -d "$TARGET" ]]; then
    echo "❌ Target repo not found: $TARGET" >&2
    exit 1
  fi
  
  ralph_src="$REPO_DIR/ralph"
  ralph_dst="$TARGET/.ralph"
  
  if [[ ! -d "$ralph_dst" ]]; then
    echo "❌ No .ralph/ directory found in $TARGET" >&2
    exit 1
  fi
  
  # Files to check: ralph.sh, launch.sh, lib/*, profiles/* (not config.json, RALPH.md)
  drift_found=0
  
  for file in ralph.sh launch.sh; do
    if [[ ! -f "$ralph_src/$file" ]]; then
      continue
    fi
    if [[ ! -f "$ralph_dst/$file" ]]; then
      echo "❌ Missing in installed copy: $file" >&2
      drift_found=1
      continue
    fi
    if ! cmp -s "$ralph_src/$file" "$ralph_dst/$file"; then
      echo "❌ Content diverged: $file" >&2
      drift_found=1
    fi
  done
  
  for dir in lib profiles; do
    if [[ ! -d "$ralph_src/$dir" ]]; then
      continue
    fi
    if [[ ! -d "$ralph_dst/$dir" ]]; then
      echo "❌ Missing directory in installed copy: $dir" >&2
      drift_found=1
      continue
    fi
    while IFS= read -r -d '' src_file; do
      rel_path="${src_file#$ralph_src/$dir/}"
      dst_file="$ralph_dst/$dir/$rel_path"
      if [[ ! -f "$dst_file" ]]; then
        echo "❌ Missing in installed copy: $dir/$rel_path" >&2
        drift_found=1
        continue
      fi
      if ! cmp -s "$src_file" "$dst_file"; then
        echo "❌ Content diverged: $dir/$rel_path" >&2
        drift_found=1
      fi
    done < <(find "$ralph_src/$dir" -type f -print0)
  done
  
  if [[ $drift_found -eq 0 ]]; then
    echo "✅ All installed scripts match source"
    exit 0
  else
    echo "❌ Drift detected — run ./install.sh $TARGET --scripts-only to refresh" >&2
    exit 1
  fi
fi

# Target repo validation is only required for modes that touch the repo.
if [[ "$MODE" != "--skills-only" ]]; then
  if [[ ! -d "$TARGET" ]]; then
    echo "❌ Target repo not found: $TARGET" >&2
    exit 1
  fi

  # Accept both regular checkouts (.git directory) and linked worktrees
  # (.git gitlink file). Defer to git rather than path-shape sniffing so
  # future git layouts stay supported.
  if ! git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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

  if [[ -f "$instructions_file" ]] && { grep -qF "$marker" "$instructions_file" || grep -qE '^[[:space:]]{0,3}##[[:space:]]+Ralph Loop[[:space:]]*#*[[:space:]]*$' "$instructions_file"; }; then
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

  # Hide .ralph/ from the target repo's porcelain so subsequent --enqueue
  # writes to config.json (or runtime state under .ralph/) do not dirty the
  # working tree and trip up the worker preflight that aborts on a non-clean
  # tree. The launcher does this lazily during its setup phase, but we need
  # it earlier so `--enqueue` / `--status` work cleanly from a fresh install.
  #
  # Resolve the exclude file via `git rev-parse --git-path` so worktrees
  # (where $target/.git is a gitlink file) write to the common gitdir's
  # info/exclude instead of a non-existent path. The common exclude is
  # shared across all worktrees of the repo — that's intentional: .ralph/
  # should be ignored in every worktree once any worktree installs Ralph.
  if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local exclude_rel exclude_file
    exclude_rel="$(git -C "$target" rev-parse --git-path info/exclude)"
    if [[ "$exclude_rel" = /* ]]; then
      exclude_file="$exclude_rel"
    else
      exclude_file="$target/$exclude_rel"
    fi
    mkdir -p "$(dirname "$exclude_file")"
    if ! grep -qxF ".ralph" "$exclude_file" 2>/dev/null; then
      echo ".ralph" >> "$exclude_file"
      echo "🙈 Added .ralph to $exclude_file (keeps runtime state out of git porcelain)"
    fi
  fi

  # Detect self-hosting: when installing Ralph source into itself, symlink the
  # executable surface to the tracked sources instead of copying (ADR 0004
  # decision 2). Then source ≡ installed by construction and the stale guard
  # can never trip in the dogfooding repo. Foreign repos keep the `cp` vendoring.
  local target_resolved
  target_resolved="$(cd "$target" && pwd -P)"
  local repo_resolved
  repo_resolved="$(cd "$REPO_DIR" && pwd -P)"
  
  if [[ "$target_resolved" -ef "$repo_resolved" ]]; then
    # Self-hosting: symlink executables, keep config/prompt/runtime as real files
    echo "🔗 Self-hosting checkout detected — symlinking executables to source..."
    mkdir -p "$ralph_dir"
    
    # Remove existing files/symlinks to ensure clean symlink creation
    rm -f "$ralph_dir/ralph.sh" "$ralph_dir/launch.sh"
    rm -rf "$ralph_dir/lib" "$ralph_dir/profiles"
    
    # Symlink executable surface
    ln -s "../ralph/ralph.sh" "$ralph_dir/ralph.sh"
    ln -s "../ralph/launch.sh" "$ralph_dir/launch.sh"
    ln -s "../ralph/lib" "$ralph_dir/lib"
    ln -s "../ralph/profiles" "$ralph_dir/profiles"
  else
    # Foreign target: copy executables as before
    mkdir -p "$ralph_dir/lib"
    cp "$REPO_DIR/ralph/ralph.sh" "$ralph_dir/ralph.sh"
    cp "$REPO_DIR/ralph/launch.sh" "$ralph_dir/launch.sh"
    cp "$REPO_DIR/ralph/lib/state.sh" "$ralph_dir/lib/state.sh"
    cp "$REPO_DIR/ralph/lib/labels.sh" "$ralph_dir/lib/labels.sh"
    cp "$REPO_DIR/ralph/lib/status.sh" "$ralph_dir/lib/status.sh"
    cp "$REPO_DIR/ralph/lib/pr-merge.sh" "$ralph_dir/lib/pr-merge.sh"
    cp "$REPO_DIR/ralph/lib/preflight.sh" "$ralph_dir/lib/preflight.sh"
    cp "$REPO_DIR/ralph/lib/resume.sh" "$ralph_dir/lib/resume.sh"
    cp "$REPO_DIR/ralph/lib/recovery-ledger.sh" "$ralph_dir/lib/recovery-ledger.sh"
    cp "$REPO_DIR/ralph/lib/copilot-session.sh" "$ralph_dir/lib/copilot-session.sh"
    cp "$REPO_DIR/ralph/lib/terminal-cli.sh" "$ralph_dir/lib/terminal-cli.sh"
    rm -rf "$ralph_dir/profiles"
    cp -R "$REPO_DIR/ralph/profiles" "$ralph_dir/profiles"
    chmod +x "$ralph_dir/ralph.sh" "$ralph_dir/launch.sh"
  fi
  install_config "$target"
  install_agent_instructions "$target"

  if [[ "$has_prompt" -eq 1 ]]; then
    echo "⚠️  $ralph_dir/RALPH.md already exists — leaving prompt customization untouched."
    echo "   Delete it first if you want to re-render from the template."
    echo ""
    echo "ℹ️  Reminder: create the canonical Ralph labels in your target repo if not done yet."
    echo "   Ralph-owned labels are namespaced: ralph:* (for example ralph:ready), priority:P* (priority:P2), and work:* (work:slice)."
    echo "   Mutating label-management commands should be run in dry-run mode first; see docs/labels.md."
    echo ""
    print_dirty_tree_warning "$target"
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
  echo "⚠️  Remember to create the canonical Ralph labels in your target repo:"
  echo "   Ralph-owned labels are namespaced: ralph:* (for example ralph:ready), priority:P* (priority:P2), and work:* (work:slice)."
  echo "   Mutating label-management commands should be run in dry-run mode first; see docs/labels.md."
  echo ""
  print_dirty_tree_warning "$target"
}

# Emit a stronger dirty-tree reminder. Workers abort on a dirty working tree
# (see ralph.sh preflight), so a fresh install that left files staged or
# unstaged would silently halt the loop on first launch. Surface this as
# soon as we know about it (issue #64 follow-up #1).
#
# Note: `.ralph/` is already added to `.git/info/exclude` above, so the only
# files that should still show as dirty are the ones the operator IS meant
# to commit (notably `.github/copilot-instructions.md`).
print_dirty_tree_warning() {
  local target="$1"
  local porcelain
  porcelain=$(git -C "$target" status --porcelain 2>/dev/null || echo "")
  if [[ -z "$porcelain" ]]; then
    return 0
  fi
  echo "⚠️  Target repo is dirty after install. Ralph workers abort on a"
  echo "    dirty working tree, so commit these files before launching:"
  echo
  printf '%s\n' "$porcelain" | sed 's/^/      /'
  echo
  echo "    git -C \"$target\" add .github/copilot-instructions.md"
  echo "    git -C \"$target\" commit -m 'Install Ralph loop scripts'"
  echo
  echo "    (.ralph/ is excluded via .git/info/exclude so its runtime files"
  echo "     and config.json are kept out of git porcelain automatically.)"
}

install_extension() {
  local user_ext_dir="$HOME/.copilot/extensions"
  mkdir -p "$user_ext_dir"
  install_user_extension "extension" "ralph-dashboard"
  install_user_extension "extension-pipeline" "ralph-pipeline"
  echo "   Restart Copilot CLI (or reload extensions) to load refreshed extensions."
}

install_user_extension() {
  local source_dir="$1"
  local extension_name="$2"
  local install_target="$HOME/.copilot/extensions/$extension_name"

  if [[ -L "$install_target" || -d "$install_target" ]]; then
    echo "📦 Refreshing extension at $install_target"
    rm -rf "$install_target"
  elif [[ -e "$install_target" ]]; then
    echo "⚠️  $install_target exists and is not a directory/symlink." >&2
    echo "   Move/delete it manually then re-run." >&2
    return 1
  fi

  mkdir -p "$install_target"
  cp -R "$REPO_DIR/$source_dir/." "$install_target/"
  if [[ -f "$install_target/package.json" ]]; then
    (cd "$install_target" && npm install --no-audit --no-fund)
  fi
  echo "✅ Extension installed: $install_target"
}

install_skills() {
  local skills_dir="$HOME/.agents/skills"
  local skill_sources=()
  local source skill_name install_target

  if [[ ! -d "$skills_dir" ]]; then
    echo "ℹ️  ~/.agents/skills/ not found — bundled skills not installed."
    echo "   Create the directory and re-run to install skills:"
    echo "   mkdir -p ~/.agents/skills && $0 --skills-only"
    return 0
  fi

  for source in "$REPO_DIR"/skills/*; do
    [[ -d "$source" && -f "$source/SKILL.md" ]] || continue
    skill_sources+=("$source")
  done

  if [[ "${#skill_sources[@]}" -eq 0 ]]; then
    echo "ℹ️  No bundled skills found in $REPO_DIR/skills."
    return 0
  fi

  for source in "${skill_sources[@]}"; do
    skill_name="$(basename "$source")"
    install_target="$skills_dir/$skill_name"
    if [[ -e "$install_target" && ! -L "$install_target" ]]; then
      echo "⚠️  $install_target exists and is not a symlink — leaving untouched." >&2
      echo "   Remove it manually to install the $skill_name skill." >&2
      return 1
    fi
  done

  for source in "${skill_sources[@]}"; do
    skill_name="$(basename "$source")"
    install_target="$skills_dir/$skill_name"

    # Remove stale symlink before re-creating (idempotent).
    if [[ -L "$install_target" ]]; then
      rm "$install_target"
    fi

    ln -s "$source" "$install_target"
    echo "✅ $skill_name skill symlinked: $install_target -> $source"
  done
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
    install_skills
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
