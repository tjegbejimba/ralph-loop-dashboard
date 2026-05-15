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

# Echo "needs_triage,not_ready_for_agent,hitl" subset based on the labels
# JSON array piped in via stdin (output of `gh issue view ... --json labels`
# `.labels` field).
_preflight_label_warnings() {
  local labels_json="$1"
  local warnings=()
  local names
  names=$(echo "$labels_json" | jq -r '.[].name' 2>/dev/null || echo "")
  local has_ready=0 has_hitl=0 has_triage=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    case "$name" in
      needs-triage)    has_triage=1 ;;
      ready-for-agent) has_ready=1 ;;
      hitl)            has_hitl=1 ;;
    esac
  done <<< "$names"
  [[ "$has_triage" -eq 1 ]] && warnings+=("needs_triage")
  [[ "$has_ready"  -eq 0 ]] && warnings+=("not_ready_for_agent")
  [[ "$has_hitl"   -eq 1 ]] && warnings+=("hitl")
  printf '%s' "$(IFS=, ; echo "${warnings[*]:-}")"
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
# (state, labels, body fields) or the empty string on failure. Strips CR so
# Windows-native jq's CRLF output doesn't poison downstream parsing.
_preflight_fetch_issue() {
  local n="$1"
  "$GH" issue view "$n" --repo "$REPO" \
    --json number,state,labels,body 2>/dev/null \
    | tr -d '\r' \
    || echo ""
}

# Scan a single queued issue and emit its row. Updates the counter at
# $1 (nameref-style via global) when warnings are present.
# Args: issue_number
# Echoes the row to stdout. Sets PREFLIGHT_BLOCKERS_FOUND to 1 on warnings.
_preflight_scan_issue() {
  local n="$1"
  local record state labels body
  record=$(_preflight_fetch_issue "$n")
  if [[ -z "$record" ]]; then
    _preflight_emit_issue "$n" "lookup_failed" "?"
    PREFLIGHT_BLOCKERS_FOUND=1
    return
  fi
  state=$(echo "$record" | jq -r .state)
  labels=$(echo "$record" | jq -c '.labels // []')
  body=$(echo "$record" | jq -r '.body // ""')

  local warnings_csv
  warnings_csv=$(_preflight_label_warnings "$labels")

  # Closed issues can never be claimed; flag them.
  if [[ "$state" != "OPEN" ]]; then
    if [[ -n "$warnings_csv" ]]; then
      warnings_csv="closed,${warnings_csv}"
    else
      warnings_csv="closed"
    fi
  fi

  # Unresolved blockers: any "#N" in "## Blocked by" that is not satisfied
  # (closed by a merged PR). Quiet failure if state.sh isn't sourced.
  if declare -F parse_blockers >/dev/null 2>&1; then
    local blockers b unresolved=()
    blockers=$(parse_blockers "$body" || true)
    for b in $blockers; do
      local sat=0
      if declare -F is_issue_satisfied >/dev/null 2>&1; then
        sat=$(is_issue_satisfied "$b" 2>/dev/null || echo 0)
      fi
      if [[ "$sat" != "1" ]]; then
        unresolved+=("$b")
      fi
    done
    if [[ "${#unresolved[@]}" -gt 0 ]]; then
      local bl
      bl="unresolved_blocker(#$(IFS=,; printf '%s' "${unresolved[*]}" | sed 's/,/,#/g'))"
      if [[ -n "$warnings_csv" ]]; then
        warnings_csv="${warnings_csv},${bl}"
      else
        warnings_csv="$bl"
      fi
    fi
  fi

  [[ -n "$warnings_csv" ]] && PREFLIGHT_BLOCKERS_FOUND=1
  _preflight_emit_issue "$n" "$warnings_csv" "$state"
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

  echo "Preflight:"

  # Repo working tree
  local repo_state
  repo_state=$(_preflight_repo_state)
  echo "  Repo: $repo_state"
  if [[ "$repo_state" != "clean" ]]; then
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
    local n
    while IFS= read -r n; do
      [[ -z "$n" ]] && continue
      _preflight_scan_issue "$n"
    done < <(echo "$numbers_json" | jq -r '.[]')
  else
    echo "  Queue mode: issueSearch: ${issue_search}"
    if [[ -z "$issue_search" ]]; then
      echo "  Issues: (no queue configured — neither issue.numbers nor issue.issueSearch is set)"
      PREFLIGHT_BLOCKERS_FOUND=1
    else
      echo "  Issues: (will be discovered at run time via gh search)"
    fi
  fi

  # Verdict
  if [[ "$PREFLIGHT_BLOCKERS_FOUND" -eq 0 ]]; then
    echo "  Verdict: ✅ Ready to launch"
    return 0
  else
    echo "  Verdict: ⚠️  preflight blockers found — review warnings above before launching"
    return 1
  fi
}
