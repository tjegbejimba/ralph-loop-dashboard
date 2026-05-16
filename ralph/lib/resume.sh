#!/usr/bin/env bash
# resume.sh — helpers for the "resume incomplete iteration" feature.
#
# Sourced (not executed) by ralph.sh and test/resume.test.sh.
#
# Split into two layers so unit tests can exercise the pure predicates
# without a git/gh fixture:
#
#   * Pure predicates  (no shell-out): should_auto_commit_dirty,
#     is_sensitive_path, format_resume_log.
#   * Git/gh probes    (side-effecting): resume_branch_for_issue,
#     resume_branch_ahead_of_base, resume_branch_head_after,
#     open_pr_for_branch.
#
# Callers MUST source state.sh first if they want the resume_* state
# helpers added there (state_set_resume_attempt / state_get_resume_attempt).

# ---------------------------------------------------------------------------
# Pure predicates
# ---------------------------------------------------------------------------

# should_auto_commit_dirty BRANCH PREFIX
# Returns 0 (true) iff PREFIX is non-empty and BRANCH starts with PREFIX.
# Empty PREFIX always returns 1 (false) — the auto-commit rescue is opt-in
# via .ralph/config.json's issue.branchPrefix / RALPH_BRANCH_PREFIX.
should_auto_commit_dirty() {
  local branch="${1-}" prefix="${2-}"
  [[ -z "$prefix" ]] && return 1
  [[ -z "$branch" ]] && return 1
  case "$branch" in
    "$prefix"*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_sensitive_path PATH
# Returns 0 (true) iff PATH matches one of the well-known secret/config
# patterns we refuse to auto-commit. Case-insensitive on the basename so
# `.ENV` and `Secrets/foo.key` still match. This list is intentionally
# conservative — it's better to halt and let a human review than to
# accidentally commit a credential file.
is_sensitive_path() {
  local path="${1-}"
  [[ -z "$path" ]] && return 1
  local base lower
  base=$(basename -- "$path")
  lower="${base,,}"
  case "$lower" in
    .env|.env.*|*.env) return 0 ;;
    *.pem|*.key|*.p12|*.pfx|*.crt|*.cer) return 0 ;;
    id_rsa|id_rsa.*|id_ecdsa|id_ed25519|id_dsa) return 0 ;;
    .netrc|.npmrc|.pypirc) return 0 ;;
    credentials|credentials.*) return 0 ;;
  esac
  # Path-level: anything under a `secrets/` directory.
  case "$path" in
    secrets/*|*/secrets/*) return 0 ;;
  esac
  return 1
}

# any_sensitive_in_porcelain
# Reads `git status --porcelain` output on stdin and returns 0 (true) iff
# ANY changed/untracked path is sensitive per is_sensitive_path. Emits the
# offending path(s) on stdout so callers can show them in the halt message.
any_sensitive_in_porcelain() {
  local found=1 line path
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    # Porcelain format: 2-char status + space + path. Renames (`R `) use
    # `old -> new`; consider both.
    path="${line:3}"
    case "$path" in
      *' -> '*)
        local oldp newp
        oldp="${path%% -> *}"
        newp="${path#* -> }"
        if is_sensitive_path "$oldp"; then
          printf '%s\n' "$oldp"
          found=0
        fi
        if is_sensitive_path "$newp"; then
          printf '%s\n' "$newp"
          found=0
        fi
        ;;
      *)
        if is_sensitive_path "$path"; then
          printf '%s\n' "$path"
          found=0
        fi
        ;;
    esac
  done
  return "$found"
}

# format_resume_log ATTEMPT MAX BRANCH ISSUE
# Build the canonical "🔁 Resuming #N (attempt M/MAX, branch=X)" line so
# both the in-process logger and downstream parsers agree on format.
format_resume_log() {
  local attempt="${1-?}" max="${2-?}" branch="${3-?}" issue="${4-?}"
  printf '🔁 Resuming #%s (attempt %s/%s, branch=%s)\n' \
    "$issue" "$attempt" "$max" "$branch"
}

# ---------------------------------------------------------------------------
# Git / gh probes (side-effecting)
# ---------------------------------------------------------------------------

# resume_branch_for_issue NUM PREFIX
# Echoes the candidate slice-branch name for issue #NUM if any branch
# named "${PREFIX}${NUM}-*" exists locally or on origin. Prefers the
# local ref when both exist. Empty output (and rc=1) means no candidate.
#
# This is the same naming convention copilot is instructed to use in
# RALPH.md.template (`slice-<N>-<short-kebab-name>`), so PREFIX is
# typically `slice-`.
resume_branch_for_issue() {
  local num="${1-}" prefix="${2-}"
  [[ -z "$num" || -z "$prefix" ]] && return 1
  local pattern="${prefix}${num}-*"

  # Local refs first.
  local local_branch
  local_branch=$(git for-each-ref --format='%(refname:short)' \
    "refs/heads/${pattern}" 2>/dev/null | head -1 || true)
  if [[ -n "$local_branch" ]]; then
    printf '%s\n' "$local_branch"
    return 0
  fi

  # Then remote-tracking refs.
  local remote_branch
  remote_branch=$(git for-each-ref --format='%(refname:short)' \
    "refs/remotes/origin/${pattern}" 2>/dev/null | head -1 || true)
  if [[ -n "$remote_branch" ]]; then
    # Strip "origin/" prefix so callers get the bare branch name.
    printf '%s\n' "${remote_branch#origin/}"
    return 0
  fi

  return 1
}

# resume_branch_ahead_of_base BRANCH BASE
# Returns 0 (true) iff BRANCH has at least one commit not in BASE. Tries
# the local ref first, then falls back to origin/BRANCH so the check works
# in single-checkout setups where the branch only exists on the remote.
resume_branch_ahead_of_base() {
  local branch="${1-}" base="${2-}"
  [[ -z "$branch" || -z "$base" ]] && return 1
  local ref count
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    ref="refs/heads/$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    ref="refs/remotes/origin/$branch"
  else
    return 1
  fi
  # Resolve base — accept either a local branch name or origin/<base>.
  local base_ref="$base"
  if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    base_ref="origin/$base"
    git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || return 1
  fi
  count=$(git rev-list --count "$base_ref..$ref" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]]
}

# resume_branch_head_after BRANCH TIMESTAMP
# Returns 0 (true) iff BRANCH's HEAD commit was authored at or after
# TIMESTAMP (ISO-8601 UTC, e.g. 2026-05-15T00:00:00Z). Used to discriminate
# "this iteration created the branch" from "a stale branch from a previous
# run". Falls back to remote ref like resume_branch_ahead_of_base.
resume_branch_head_after() {
  local branch="${1-}" ts="${2-}"
  [[ -z "$branch" || -z "$ts" ]] && return 1
  local ref
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    ref="refs/heads/$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    ref="refs/remotes/origin/$branch"
  else
    return 1
  fi
  # Use epoch seconds for tz-safe comparison. %ct = committer time (unix
  # epoch). iter_start_ts is an ISO-8601 UTC string ("YYYY-MM-DDTHH:MM:SSZ");
  # `date -u -d` (GNU) and `date -u -j -f` (BSD/macOS) both parse it.
  local commit_epoch ts_epoch
  commit_epoch=$(git log -1 --format=%ct "$ref" 2>/dev/null || true)
  [[ -z "$commit_epoch" ]] && return 1
  if command -v gdate >/dev/null 2>&1; then
    ts_epoch=$(gdate -u -d "$ts" +%s 2>/dev/null || echo "")
  else
    ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
      || echo "")
  fi
  [[ -z "$ts_epoch" ]] && return 1
  [[ "$commit_epoch" -ge "$ts_epoch" ]]
}

# open_pr_for_branch REPO BRANCH
# Echoes the PR number if there's an OPEN PR whose head is BRANCH (and
# whose author/owner is this repo). Empty output (and rc=1) otherwise.
# A separate halt path — we deliberately do not auto-resume when a human
# reviewer might be looking at an open PR.
open_pr_for_branch() {
  local repo="${1-}" branch="${2-}"
  [[ -z "$repo" || -z "$branch" ]] && return 1
  local num
  num=$(gh pr list --repo "$repo" --state open --head "$branch" \
    --json number -q '.[0].number' 2>/dev/null || true)
  if [[ -n "$num" && "$num" != "null" ]]; then
    printf '%s\n' "$num"
    return 0
  fi
  return 1
}
