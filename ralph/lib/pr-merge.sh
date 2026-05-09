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
  local prs pr is_draft base_ref mergeable

  [[ -n "$release_branch" ]] || return 1

  prs=$(gh pr list --repo "$REPO" --state open --base "$release_branch" \
    --search "in:body \"#$issue\"" \
    --json number,isDraft,baseRefName,mergeable,body \
    --jq ".[] | select(.body | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\\\s+#$issue\\\\b\")) | [.number, .isDraft, .baseRefName, .mergeable] | @tsv" 2>/dev/null || true)
  [[ -n "$prs" ]] || return 1

  while IFS=$'\t' read -r pr is_draft base_ref mergeable; do
    [[ -n "$pr" ]] || continue
    [[ "$is_draft" == "false" ]] || continue
    [[ "$base_ref" == "$release_branch" ]] || continue
    [[ "$mergeable" == "MERGEABLE" || "$mergeable" == "UNKNOWN" || -z "$mergeable" ]] || continue

    if ! ralph_pr_checks_passed "$pr"; then
      echo "ℹ️  PR #$pr closes #$issue (release branch '$release_branch') but checks are not green yet; not auto-merging." >&2
      continue
    fi

    echo "✅ PR #$pr closes #$issue into '$release_branch' and checks are green; merging + manually closing issue from Ralph release-branch fallback." >&2
    if ! gh pr merge "$pr" --repo "$REPO" --squash --delete-branch; then
      echo "⚠️  Fallback merge of PR #$pr failed." >&2
      return 1
    fi
    if ! gh issue close "$issue" --repo "$REPO" --reason completed \
      --comment "Merged via PR #$pr into \`$release_branch\` (Ralph release-branch fallback). Auto-close was skipped because PR base is non-default branch."; then
      echo "⚠️  Fallback close of issue #$issue failed (PR was merged though)." >&2
      return 1
    fi
    return 0
  done <<<"$prs"

  return 1
}

# Branch-only fallback: copilot pushed `${branch_prefix}${issue}-…` to origin
# but never opened a PR. Open the PR ourselves so the merge fallback above
# can pick it up. Returns 0 if a PR was created (caller should re-run merge).
# Requires both release_branch and branch_prefix; no-op otherwise.
ralph_open_pr_for_pushed_branch() {
  local issue="$1"
  local release_branch="$2"
  local branch_prefix="$3"
  local branch sha title body

  [[ -n "$release_branch" && -n "$branch_prefix" ]] || return 1

  branch=$(gh api "repos/$REPO/branches" --paginate \
    --jq ".[] | select(.name | startswith(\"${branch_prefix}${issue}-\")) | .name" 2>/dev/null | head -1)
  [[ -n "$branch" ]] || return 1

  sha=$(gh api "repos/$REPO/branches/$branch" --jq '.commit.sha' 2>/dev/null || echo "")
  [[ -n "$sha" ]] || return 1

  title=$(gh api "repos/$REPO/commits/$sha" --jq '.commit.message' 2>/dev/null | head -1)
  [[ -n "$title" ]] || title="feat: complete issue #$issue"

  body=$(printf '%s\n\n%s' "Closes #$issue" "(Ralph branch-only fallback: copilot pushed the branch but didn't open the PR. Local checks were green at push time per the iteration log.)")

  echo "ℹ️  Found pushed branch '$branch' for issue #$issue with no PR; creating PR..." >&2
  if ! gh pr create --repo "$REPO" --base "$release_branch" --head "$branch" --title "$title" --body "$body" >/dev/null; then
    echo "⚠️  Failed to create fallback PR for branch '$branch'." >&2
    return 1
  fi
  return 0
}
