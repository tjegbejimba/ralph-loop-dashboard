#!/usr/bin/env bash
# terminal-cli.sh — resolve and invoke the Ralph terminal CLI (extension/cli.mjs).
#
# Sourced by launch.sh so --status / --watch / --follow can delegate the rich
# rendering to the same Node-based data layer the dashboard uses. Falls back
# silently when neither Node nor the CLI is available so terminal users on
# minimal hosts still get the legacy --status output.

# Find the cli.mjs file. Honour RALPH_TERMINAL_CLI for overrides; otherwise
# check the user-level extension install, then the source checkout (handy
# when developing this repo).
resolve_terminal_cli() {
  if [[ -n "${RALPH_TERMINAL_CLI:-}" && -f "${RALPH_TERMINAL_CLI}" ]]; then
    printf '%s' "${RALPH_TERMINAL_CLI}"
    return 0
  fi
  local user_cli="${HOME}/.copilot/extensions/ralph-dashboard/cli.mjs"
  if [[ -f "$user_cli" ]]; then
    printf '%s' "$user_cli"
    return 0
  fi
  # Source-checkout fallback. SCRIPT_DIR is set by launch.sh before this
  # helper is sourced; it's visible inside this function's $(...) subshell
  # because bash command substitutions inherit non-exported variables.
  # SCRIPT_DIR points at .../<repo>/.ralph for installed targets, or
  # .../ralph-loop-dashboard/ralph for in-source runs. The latter has the
  # extension next to it.
  local src_cli
  src_cli="$(cd "${SCRIPT_DIR}/../extension" 2>/dev/null && pwd -P)/cli.mjs"
  if [[ -f "$src_cli" ]]; then
    printf '%s' "$src_cli"
    return 0
  fi
  return 1
}

# Invoke the terminal CLI with $@. Sets RALPH_REPO_ROOT so the CLI doesn't
# have to walk up looking for .ralph/. Returns 0 if the CLI ran, 1 if it
# couldn't be found or node is missing.
invoke_terminal_cli() {
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi
  local cli
  if ! cli="$(resolve_terminal_cli)"; then
    return 1
  fi
  RALPH_REPO_ROOT="$MAIN_REPO" node "$cli" "$@"
}
