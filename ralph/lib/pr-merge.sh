#!/usr/bin/env bash
# Helpers for finishing a ready PR that closes a Ralph issue.

ralph_pr_checks_passed() {
  local pr="$1"
  local checks
  checks=$(gh pr checks "$pr" --repo "$REPO" --json bucket 2>/dev/null || true)
  jq -e '
    length == 0
    or all(.[]; .bucket == "pass" or .bucket == "skipping")
  ' <<<"$checks" >/dev/null 2>&1
}

ralph_merge_ready_open_pr_for_issue() {
  local issue="$1"
  local default_branch="$2"
  local prs pr is_draft base_ref mergeable

  prs=$(gh pr list --repo "$REPO" --state open --search "linked:issue $issue" \
    --json number,isDraft,baseRefName,mergeable \
    --jq '.[] | [.number, .isDraft, .baseRefName, .mergeable] | @tsv' 2>/dev/null || true)
  [[ -n "$prs" ]] || return 1

  while IFS=$'\t' read -r pr is_draft base_ref mergeable; do
    [[ -n "$pr" ]] || continue
    [[ "$is_draft" == "false" ]] || continue
    [[ "$base_ref" == "$default_branch" ]] || continue
    [[ "$mergeable" == "MERGEABLE" || "$mergeable" == "UNKNOWN" || -z "$mergeable" ]] || continue

    if ! gh pr view "$pr" --repo "$REPO" --json closingIssuesReferences \
      -q '.closingIssuesReferences[].number' 2>/dev/null | grep -qx "$issue"; then
      continue
    fi

    if ! ralph_pr_checks_passed "$pr"; then
      echo "ℹ️  PR #$pr closes #$issue but checks are not green yet; not auto-merging." >&2
      continue
    fi

    echo "✅ PR #$pr closes #$issue and checks are green; merging from Ralph fallback." >&2
    gh pr merge "$pr" --repo "$REPO" --squash --delete-branch
    return $?
  done <<<"$prs"

  return 1
}
