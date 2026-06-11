#!/usr/bin/env bash
# Canonical Ralph label helpers shared by launcher, preflight, and workers.

RALPH_STATE_LABELS=(
  "ralph:needs-triage"
  "ralph:evaluated"
  "ralph:ready"
  "ralph:blocked"
  "ralph:hitl"
  "ralph:queued"
  "ralph:running"
  "ralph:done"
  "ralph:failed"
)
RALPH_PRIORITY_LABELS=("priority:P0" "priority:P1" "priority:P2" "priority:P3")
RALPH_WORK_LABELS=("work:prd" "work:slice" "work:standalone")
RALPH_LEGACY_SAFETY_LABELS=("hitl" "needs-triage")

ralph_default_issue_search() {
  printf '%s\n' 'is:open no:assignee label:ralph:ready (label:work:slice OR label:work:standalone)'
}

ralph_labels_csv() {
  local record="$1"
  printf '%s' "$record" | jq -r '
    (.labels // [])
    | map(if type == "string" then . else .name end)
    | map(select(type == "string" and length > 0))
    | join(",")
  ' 2>/dev/null || true
}

ralph_assignee_count() {
  local record="$1"
  printf '%s' "$record" | jq -r '(.assignees // []) | length' 2>/dev/null || echo 0
}

ralph_has_label() {
  local labels_csv="$1" label="$2"
  [[ ",${labels_csv}," == *",${label},"* ]]
}

_ralph_dimension_result() {
  local labels_csv="$1"; shift
  local count=0 value="" all=() label
  for label in "$@"; do
    if ralph_has_label "$labels_csv" "$label"; then
      count=$((count + 1))
      value="$label"
      all+=("$label")
    fi
  done
  printf '%s|%s|%s\n' "$count" "$value" "$(IFS=,; printf '%s' "${all[*]:-}")"
}

ralph_state_result() {
  _ralph_dimension_result "$1" "${RALPH_STATE_LABELS[@]}"
}

ralph_priority_result() {
  _ralph_dimension_result "$1" "${RALPH_PRIORITY_LABELS[@]}"
}

ralph_work_result() {
  _ralph_dimension_result "$1" "${RALPH_WORK_LABELS[@]}"
}

ralph_issue_body() {
  local record="$1"
  printf '%s' "$record" | jq -r '.body // ""' 2>/dev/null || true
}

ralph_issue_state() {
  local record="$1"
  printf '%s' "$record" | jq -r '.state // ""' 2>/dev/null || true
}

ralph_parent_number() {
  local body="$1"
  printf '%s\n' "$body" | sed -nE 's/^Parent #([1-9][0-9]*).*$/\1/p' | head -1
}

_ralph_append_tag() {
  local current="$1" tag="$2"
  if [[ -z "$current" ]]; then
    printf '%s' "$tag"
  else
    printf '%s,%s' "$current" "$tag"
  fi
}

ralph_legacy_safety_blocker_tags() {
  local record="$1"
  local tags="" labels legacy_label
  labels=$(ralph_labels_csv "$record")
  for legacy_label in "${RALPH_LEGACY_SAFETY_LABELS[@]}"; do
    if ralph_has_label "$labels" "$legacy_label"; then
      tags=$(_ralph_append_tag "$tags" "legacy_safety_label(${legacy_label})")
    fi
  done
  printf '%s' "$tags"
}

_ralph_runnable_blocker_tags_for_states() {
  local record="$1"
  shift
  local allowed_states=("$@")
  local tags="" labels state_count state_label states priority_count priority_label priorities work_count work_label works state body
  labels=$(ralph_labels_csv "$record")
  IFS='|' read -r state_count state_label states <<<"$(ralph_state_result "$labels")"
  IFS='|' read -r priority_count priority_label priorities <<<"$(ralph_priority_result "$labels")"
  IFS='|' read -r work_count work_label works <<<"$(ralph_work_result "$labels")"
  state=$(ralph_issue_state "$record")
  body=$(ralph_issue_body "$record")

  [[ "$state" != "OPEN" ]] && tags=$(_ralph_append_tag "$tags" "not_open(${state:-unknown})")
  [[ "$(ralph_assignee_count "$record")" -gt 0 ]] && tags=$(_ralph_append_tag "$tags" "assigned")
  [[ "$state_count" -gt 1 ]] && tags=$(_ralph_append_tag "$tags" "state_conflict(${states})")
  [[ "$priority_count" -gt 1 ]] && tags=$(_ralph_append_tag "$tags" "priority_conflict(${priorities})")
  [[ "$work_count" -gt 1 ]] && tags=$(_ralph_append_tag "$tags" "work_conflict(${works})")
  local legacy_tags
  legacy_tags=$(ralph_legacy_safety_blocker_tags "$record")
  [[ -n "$legacy_tags" ]] && tags=$(_ralph_append_tag "$tags" "$legacy_tags")
  [[ "$state_count" -eq 0 ]] && tags=$(_ralph_append_tag "$tags" "missing_state")
  [[ "$work_count" -eq 0 ]] && tags=$(_ralph_append_tag "$tags" "missing_work_type")

  if [[ "$state_count" -eq 1 ]]; then
    local state_allowed=0 allowed_state
    for allowed_state in "${allowed_states[@]}"; do
      if [[ "$state_label" == "$allowed_state" ]]; then
        state_allowed=1
        break
      fi
    done
    if [[ "$state_allowed" -ne 1 ]]; then
    tags=$(_ralph_append_tag "$tags" "not_runnable_state(${state_label})")
    fi
  fi
  if [[ "$work_count" -eq 1 && "$work_label" != "work:slice" && "$work_label" != "work:standalone" ]]; then
    tags=$(_ralph_append_tag "$tags" "not_runnable_work(${work_label})")
  fi
  if [[ "$work_label" == "work:slice" && -z "$(ralph_parent_number "$body")" ]]; then
    tags=$(_ralph_append_tag "$tags" "missing_parent")
  fi

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
      tags=$(_ralph_append_tag "$tags" "unresolved_blocker(#$(IFS=,; printf '%s' "${unresolved[*]}" | sed 's/,/,#/g'))")
    fi
  fi

  printf '%s' "$tags"
}

ralph_enqueueable_blocker_tags() {
  _ralph_runnable_blocker_tags_for_states "$1" "ralph:ready" "ralph:blocked"
}

ralph_claimable_blocker_tags() {
  _ralph_runnable_blocker_tags_for_states "$1" "ralph:ready" "ralph:blocked" "ralph:queued"
}

ralph_runnable_blocker_tags() {
  ralph_claimable_blocker_tags "$1"
}

ralph_runnable_warning_tags() {
  local record="$1" labels priority_count priority_label priorities
  labels=$(ralph_labels_csv "$record")
  IFS='|' read -r priority_count priority_label priorities <<<"$(ralph_priority_result "$labels")"
  if [[ "$priority_count" -eq 0 ]]; then
    printf '%s' "missing_priority(default:priority:P2)"
  fi
}

ralph_prd_blocker_tags() {
  local record="$1"
  local tags="" labels state_count state_label states priority_count priority_label priorities work_count work_label works state
  labels=$(ralph_labels_csv "$record")
  IFS='|' read -r state_count state_label states <<<"$(ralph_state_result "$labels")"
  IFS='|' read -r priority_count priority_label priorities <<<"$(ralph_priority_result "$labels")"
  IFS='|' read -r work_count work_label works <<<"$(ralph_work_result "$labels")"
  state=$(ralph_issue_state "$record")

  [[ "$state" != "OPEN" ]] && tags=$(_ralph_append_tag "$tags" "not_open(${state:-unknown})")
  [[ "$state_count" -gt 1 ]] && tags=$(_ralph_append_tag "$tags" "state_conflict(${states})")
  [[ "$priority_count" -gt 1 ]] && tags=$(_ralph_append_tag "$tags" "priority_conflict(${priorities})")
  [[ "$work_count" -gt 1 ]] && tags=$(_ralph_append_tag "$tags" "work_conflict(${works})")
  [[ "$state_label" != "ralph:evaluated" ]] && tags=$(_ralph_append_tag "$tags" "prd_not_evaluated")
  [[ "$work_label" != "work:prd" ]] && tags=$(_ralph_append_tag "$tags" "not_work_prd")
  printf '%s' "$tags"
}

ralph_apply_label_transition() {
  local issue="$1" transition="$2"
  local add_csv="" remove_csv=""
  case "$transition" in
    enqueue)
      add_csv="ralph:queued"; remove_csv="ralph:ready,ralph:blocked" ;;
    claim)
      add_csv="ralph:running"; remove_csv="ralph:queued" ;;
    done)
      add_csv="ralph:done"; remove_csv="ralph:running" ;;
    fail)
      add_csv="ralph:failed"; remove_csv="ralph:running,ralph:queued" ;;
    retry)
      add_csv="ralph:queued"; remove_csv="ralph:running,ralph:failed" ;;
    *)
      echo "⚠️  unknown Ralph label transition: $transition" >&2
      return 1 ;;
  esac

  [[ -n "${RALPH_DISABLE_LABEL_TRANSITIONS:-}" ]] && return 0
  [[ -n "${GH:-}" && -n "${REPO:-}" ]] || return 0

  local args=("issue" "edit" "$issue" "--repo" "$REPO")
  local label
  IFS=, read -ra _adds <<<"$add_csv"
  for label in "${_adds[@]}"; do
    [[ -n "$label" ]] && args+=("--add-label" "$label")
  done
  IFS=, read -ra _removes <<<"$remove_csv"
  for label in "${_removes[@]}"; do
    [[ -n "$label" ]] && args+=("--remove-label" "$label")
  done
  unset _adds _removes

  if ! "$GH" "${args[@]}" >/dev/null 2>&1; then
    echo "⚠️  Could not apply Ralph label transition '$transition' to #$issue" >&2
    return 1
  fi
}
