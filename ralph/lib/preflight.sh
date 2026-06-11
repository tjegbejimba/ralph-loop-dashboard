#!/usr/bin/env bash
# Ralph preflight: inspect the configured queue + target repo and emit a
# structured readiness report.
#
# Callers source this file then invoke `preflight_run`. The function prints a
# "Preflight:" section to stdout and exits 0 (no blockers) or non-zero
# (blockers found) so callers can chain it after enqueue/status without
# adding a separate exit-code surface.
#
# Required variables when invoked:
#   MAIN_REPO   absolute path to the target repo (.git lives here)
#   REPO        owner/repo slug for gh calls
#   GH          path to the gh binary (default: gh; overridable for tests)

# parse_blockers + is_issue_satisfied live in lib/state.sh and are sourced
# alongside this file by the launcher.

# Emit one warning row for an issue. Args: issue_number warning_csv state
_preflight_emit_issue() {
  local n="$1" warnings_csv="$2" state="$3"
  if [[ -z "$warnings_csv" ]]; then
    printf '    #%s %s ready\n' "$n" "$state"
  else
    printf '    #%s %s %s\n' "$n" "$state" "$warnings_csv"
  fi
}

# Inspect target repo working tree. Echoes "clean" or "dirty (N files)".
_preflight_repo_state() {
  local porcelain
  porcelain=$(git -C "$MAIN_REPO" status --porcelain 2>/dev/null | tr -d '\r' || echo "")
  if [[ -z "$porcelain" ]]; then
    echo "clean"
  else
    local n
    n=$(printf '%s\n' "$porcelain" | wc -l | tr -d ' ')
    echo "dirty (${n} files)"
  fi
}

# Inspect .ralph/RALPH.md PRD reference. Echoes one of:
#   "missing"                       — file does not exist
#   "marker missing"                — file present, no RALPH_PRD_REF marker
#   "placeholder {{PRD_REFERENCE}}" — marker still carries the install-time
#                                     placeholder (never enqueued via --enqueue-prd)
#   "ref <value>"                   — concrete PRD reference (e.g. "#4")
_preflight_ralph_md_state() {
  local ralph_md="$MAIN_REPO/.ralph/RALPH.md"
  if [[ ! -f "$ralph_md" ]]; then
    echo "missing"
    return
  fi
  if ! grep -qF '<!-- RALPH_PRD_REF:' "$ralph_md"; then
    echo "marker missing"
    return
  fi
  local val
  val=$(sed -nE 's/.*<!-- RALPH_PRD_REF: ([^ >]+) -->.*/\1/p' "$ralph_md" | head -1)
  case "$val" in
    '{{PRD_REFERENCE}}'|'')
      echo "placeholder {{PRD_REFERENCE}}"
      ;;
    *)
      echo "ref ${val}"
      ;;
  esac
}

# Fetch a single issue's JSON record via gh. Echoes the JSON object on stdout
# (state, labels, assignees, body fields) or the empty string on failure. Strips CR so
# Windows-native jq's CRLF output doesn't poison downstream parsing.
_preflight_fetch_issue() {
  local n="$1"
  "$GH" issue view "$n" --repo "$REPO" \
    --json number,state,title,labels,assignees,body 2>/dev/null \
    | tr -d '\r' \
    || echo ""
}

# Scan a single queued issue and emit its row. Updates the counter at
# $1 (nameref-style via global) when warnings are present.
# Args: issue_number
# Echoes the row to stdout. Sets PREFLIGHT_BLOCKERS_FOUND to 1 on warnings.
_preflight_scan_issue() {
  local n="$1"
  local record state body
  record=$(_preflight_fetch_issue "$n")
  if [[ -z "$record" ]]; then
    _preflight_emit_issue "$n" "lookup_failed" "?"
    PREFLIGHT_BLOCKERS_FOUND=1
    return
  fi
  state=$(echo "$record" | jq -r .state)
  body=$(echo "$record" | jq -r '.body // ""')

  # Closed issues can never be claimed. Track count separately so the verdict
  # can distinguish "all queued issues closed" (queue drained — informational)
  # from "some closed, some open" (mixed — blocker). The CLOSED state is
  # already visible in the row, so we don't add a redundant "closed" tag.
  if [[ "$state" != "OPEN" ]]; then
    PREFLIGHT_CLOSED_COUNT=$((PREFLIGHT_CLOSED_COUNT + 1))
    _preflight_emit_issue "$n" "" "$state"
    return
  fi

  local blockers_csv warnings_csv display_csv
  blockers_csv=""
  warnings_csv=""
  if declare -F ralph_runnable_blocker_tags >/dev/null 2>&1; then
    blockers_csv=$(ralph_runnable_blocker_tags "$record")
  fi
  if declare -F ralph_runnable_warning_tags >/dev/null 2>&1; then
    warnings_csv=$(ralph_runnable_warning_tags "$record")
  fi
  display_csv="$blockers_csv"
  if [[ -n "$warnings_csv" ]]; then
    if [[ -n "$display_csv" ]]; then
      display_csv="${display_csv},${warnings_csv}"
    else
      display_csv="$warnings_csv"
    fi
  fi

  [[ -n "$blockers_csv" ]] && PREFLIGHT_BLOCKERS_FOUND=1
  _preflight_emit_issue "$n" "$display_csv" "$state"
}

# Main entry. Prints a "Preflight:" report for the configured queue + repo.
# Returns 0 if no blockers, 1 if any classified blocker is present.
#
# Honors:
#   $MAIN_REPO/.ralph/config.json  .issue.numbers  .issue.issueSearch
#   $MAIN_REPO/.ralph/RALPH.md     <!-- RALPH_PRD_REF: ... -->
preflight_run() {
  local config="$MAIN_REPO/.ralph/config.json"
  PREFLIGHT_BLOCKERS_FOUND=0
  PREFLIGHT_CLOSED_COUNT=0
  PREFLIGHT_ISSUE_COUNT=0

  echo "Preflight:"

  # Repo working tree. A running loop dirties the tree by design (worker is
  # mid-iteration), so don't flag it as a blocker when RALPH_LOOP_ACTIVE=1.
  local repo_state
  repo_state=$(_preflight_repo_state)
  echo "  Repo: $repo_state"
  if [[ "$repo_state" != "clean" && "${RALPH_LOOP_ACTIVE:-0}" != "1" ]]; then
    PREFLIGHT_BLOCKERS_FOUND=1
  fi

  # RALPH.md PRD reference
  local md_state
  md_state=$(_preflight_ralph_md_state)
  echo "  RALPH.md: $md_state"
  case "$md_state" in
    missing|"marker missing"|placeholder*) PREFLIGHT_BLOCKERS_FOUND=1 ;;
  esac

  # Queue mode
  local numbers_json issue_search
  if [[ -f "$config" ]]; then
    numbers_json=$(jq -c '.issue.numbers // []' "$config" 2>/dev/null | tr -d '\r' || echo "[]")
    issue_search=$(jq -r '.issue.issueSearch // ""' "$config" 2>/dev/null | tr -d '\r' || echo "")
  else
    numbers_json="[]"
    issue_search=""
    PREFLIGHT_BLOCKERS_FOUND=1
    echo "  Config: missing (.ralph/config.json)"
  fi

  local nums_count
  nums_count=$(echo "$numbers_json" | jq 'length' 2>/dev/null | tr -d '\r' || echo 0)
  if [[ "$nums_count" -gt 0 ]]; then
    echo "  Queue mode: direct-numbers (${nums_count} issues)"
    echo "  Issues:"
    PREFLIGHT_ISSUE_COUNT="$nums_count"
    local n
    while IFS= read -r n; do
      [[ -z "$n" ]] && continue
      _preflight_scan_issue "$n"
    done < <(echo "$numbers_json" | jq -r '.[]' | tr -d '\r')
  else
    echo "  Queue mode: issueSearch: ${issue_search}"
    if [[ -z "$issue_search" ]]; then
      echo "  Issues: (no queue configured — neither issue.numbers nor issue.issueSearch is set)"
      PREFLIGHT_BLOCKERS_FOUND=1
    else
      echo "  Issues: (will be discovered at run time via gh search)"
    fi
  fi

  # Verdict.
  #   - Loop in progress (workers/claims active) takes priority over blockers
  #     so the operator sees the actual state, not stale "fix me" warnings.
  #   - All queued issues CLOSED with no other blockers → queue drained
  #     (informational, not an error — the loop just has nothing to do).
  #   - Otherwise: existing blockers / ready verdicts.
  if [[ "${RALPH_LOOP_ACTIVE:-0}" == "1" ]]; then
    echo "  Verdict: 🔄 Loop in progress"
    return 0
  fi
  if [[ "$PREFLIGHT_ISSUE_COUNT" -gt 0 \
        && "$PREFLIGHT_CLOSED_COUNT" -eq "$PREFLIGHT_ISSUE_COUNT" \
        && "$PREFLIGHT_BLOCKERS_FOUND" -eq 0 ]]; then
    echo "  Verdict: ℹ️  Queue drained — all queued issues are closed"
    return 0
  fi
  if [[ "$PREFLIGHT_BLOCKERS_FOUND" -eq 0 ]]; then
    echo "  Verdict: ✅ Ready to launch"
    return 0
  else
    echo "  Verdict: ⚠️  preflight blockers found — review warnings above before launching"
    return 1
  fi
}
