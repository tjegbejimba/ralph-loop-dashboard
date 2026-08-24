#!/usr/bin/env bash
# Helpers for finishing a ready PR that closes a Ralph issue.

ralph_pr_checks_passed() {
  local pr="$1"
  local checks
  checks=$(gh pr checks "$pr" --repo "$REPO" --json bucket 2>/dev/null || true)
  jq -e '
    length > 0
    and all(.[]; .bucket == "pass" or .bucket == "skipping")
  ' <<<"$checks" >/dev/null 2>&1
}

_ralph_merge_owned_open_pr_for_issue() {
  local issue="$1"
  local expected_base="$2"
  local expected_head="$3"
  local expected_sha="$4"
  local expected_author="$5"
  local closure_mode="$6"
  local prs pr is_draft base_ref mergeable head_ref head_oid head_repo author body

  RALPH_MERGED_PR=""
  [[ -n "$issue" && -n "$expected_base" && -n "$expected_head" && -n "$expected_author" ]] || return 1
  [[ "$expected_sha" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] || return 1

  if [[ "$closure_mode" == "linked" ]]; then
    prs=$(gh pr list --repo "$REPO" --state open --search "linked:issue $issue" \
      --json number,isDraft,baseRefName,mergeable,headRefName,headRefOid,headRepository,author,body \
      --jq '.[] | [.number, .isDraft, .baseRefName, .mergeable, .headRefName, .headRefOid, (.headRepository.nameWithOwner // ""), (.author.login // ""), (.body // "")] | @tsv' 2>/dev/null || true)
  else
    prs=$(gh pr list --repo "$REPO" --state open --base "$expected_base" \
      --search "in:body \"#$issue\"" \
      --json number,isDraft,baseRefName,mergeable,headRefName,headRefOid,headRepository,author,body \
      --jq '.[] | [.number, .isDraft, .baseRefName, .mergeable, .headRefName, .headRefOid, (.headRepository.nameWithOwner // ""), (.author.login // ""), (.body // "")] | @tsv' 2>/dev/null || true)
  fi
  [[ -n "$prs" ]] || return 1

  while IFS=$'\t' read -r pr is_draft base_ref mergeable head_ref head_oid head_repo author body; do
    [[ -n "$pr" ]] || continue
    [[ "$is_draft" == "false" ]] || continue
    [[ "$base_ref" == "$expected_base" ]] || continue
    [[ "$mergeable" == "MERGEABLE" || "$mergeable" == "UNKNOWN" || -z "$mergeable" ]] || continue
    [[ "$head_ref" == "$expected_head" ]] || continue
    [[ "$head_oid" == "$expected_sha" ]] || continue
    [[ "$head_repo" == "$REPO" ]] || continue
    [[ "$author" == "$expected_author" ]] || continue

    if [[ "$closure_mode" == "linked" ]]; then
      if ! gh pr view "$pr" --repo "$REPO" --json closingIssuesReferences \
        -q '.closingIssuesReferences[].number' 2>/dev/null | grep -qx "$issue"; then
        continue
      fi
    elif ! printf '%s\n' "$body" | grep -Eqi "(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#${issue}([^0-9]|$)"; then
      continue
    fi

    if ! ralph_pr_checks_passed "$pr"; then
      echo "ℹ️  PR #$pr closes #$issue but checks are not green yet; not auto-merging." >&2
      continue
    fi

    echo "✅ PR #$pr closes #$issue and checks are green; merging from Ralph fallback." >&2
    if gh pr merge "$pr" --repo "$REPO" --squash --delete-branch \
      --match-head-commit "$head_oid"; then
      RALPH_MERGED_PR="$pr"
      return 0
    fi
    return 1
  done <<<"$prs"

  return 1
}

ralph_merge_ready_open_pr_for_issue() {
  local issue="$1"
  local default_branch="$2"
  local expected_head="${3:-}"
  local expected_sha="${4:-}"
  local expected_author="${5:-}"

  _ralph_merge_owned_open_pr_for_issue \
    "$issue" "$default_branch" "$expected_head" "$expected_sha" "$expected_author" linked
}

# Release-branch fallback: when copilot pushed a green PR into a release
# branch (non-default base) but didn't run `gh pr merge` and `gh issue close`,
# do it for them. Distinct from the default-branch helper because:
#   - GitHub doesn't populate `linked:issue` / `closingIssuesReferences` for
#     PRs whose base != default, so we search by body text instead.
#   - Closure must be done via explicit `gh issue close` after merge — GitHub
#     will not auto-close from a non-default-base PR even with `Closes #N`.
# Opt-in via RALPH_RELEASE_BRANCH; this helper is a no-op for empty input.
ralph_merge_release_branch_pr_for_issue() {
  local issue="$1"
  local release_branch="$2"
  local expected_head="${3:-}"
  local expected_sha="${4:-}"
  local expected_author="${5:-}"
  local pr

  [[ -n "$release_branch" ]] || return 1

  if ! _ralph_merge_owned_open_pr_for_issue \
    "$issue" "$release_branch" "$expected_head" "$expected_sha" "$expected_author" body; then
    return 1
  fi
  pr="$RALPH_MERGED_PR"
  if ! gh issue close "$issue" --repo "$REPO" --reason completed \
    --comment "Merged via PR #$pr into \`$release_branch\` (Ralph release-branch fallback). Auto-close was skipped because PR base is non-default branch."; then
    echo "⚠️  Fallback close of issue #$issue failed (PR was merged though)." >&2
    return 1
  fi
  return 0
}

# Branch-only fallback: copilot pushed the expected worker branch to origin but
# never opened a PR. Open only that exact branch at its approved local SHA.
ralph_open_pr_for_pushed_branch() {
  local issue="$1"
  local release_branch="$2"
  local branch_prefix="$3"
  local expected_branch="${4:-}"
  local expected_sha="${5:-}"
  local remote_sha title body

  [[ -n "$release_branch" && -n "$branch_prefix" && -n "$expected_branch" ]] || return 1
  [[ "$expected_branch" == "${branch_prefix}${issue}-"* ]] || return 1
  [[ "$expected_sha" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$ ]] || return 1

  remote_sha=$(git ls-remote --heads origin "refs/heads/$expected_branch" | awk 'NR == 1 {print $1}')
  [[ "$remote_sha" == "$expected_sha" ]] || return 1

  title=$(gh api "repos/$REPO/commits/$expected_sha" --jq '.commit.message' 2>/dev/null | head -1)
  [[ -n "$title" ]] || title="feat: complete issue #$issue"

  body=$(printf '%s\n\n%s' "Closes #$issue" "(Ralph branch-only fallback: copilot pushed the branch but didn't open the PR. Local checks were green at push time per the iteration log.)")

  echo "ℹ️  Found pushed branch '$expected_branch' for issue #$issue with no PR; creating PR..." >&2
  if ! gh pr create --repo "$REPO" --base "$release_branch" --head "$expected_branch" --title "$title" --body "$body" >/dev/null; then
    echo "⚠️  Failed to create fallback PR for branch '$expected_branch'." >&2
    return 1
  fi
  return 0
}
