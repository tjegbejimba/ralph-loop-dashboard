# Template Hardening Re-sync Guide

## Issue #112: Ralph Template Hardening

This document describes the template fixes applied in issue #112 and how to re-sync installed repos.

## Fixes Applied

1. **Worktree-safe git commands** (`RALPH.md.template` line 22)
   - **Before**: `git checkout main && git pull --ff-only origin main`
   - **After**: `git fetch origin && git pull --ff-only origin/main`
   - **Impact**: Workers in dedicated worktrees no longer fail with "main is already checked out"

2. **Correct gh field** (`RALPH.md.template` lines 72, 83, 113)
   - **Before**: `closedByPullRequests`
   - **After**: `closedByPullRequestsReferences`
   - **Impact**: Verification commands now use the correct GitHub API field

3. **Templated PRD reference** (`RALPH.md.template` line 24)
   - **Before**: `gh issue view 1 --repo {{REPO}}`
   - **After**: Uses `{{PRD_REFERENCE}}` without hardcoded issue number
   - **Impact**: Workers correctly read the parent PRD specified by the enqueue operation

4. **macOS timeout documented** (`ralph/ralph.sh` lines 273-281)
   - **Status**: Already documented; `gtimeout` is preferred, Perl fallback is best-effort
   - **Impact**: No change needed; existing code is correct

5. **Enqueue mutation documented** (`ralph/launch.sh` help text)
   - **Status**: Already documented; `--enqueue` writes to `.ralph/config.json`
   - **Impact**: No change needed; help text already mentions this

## Re-sync Installed Repos

To apply these fixes to repos that have already installed Ralph:

### For alisterr, kindleflow, Glasswork

Run from the Ralph source repo (`ralph-loop-dashboard`):

```bash
# Re-sync scripts only — keeps repo-specific .ralph/RALPH.md and config.json.
# NOTE: --scripts-only deliberately does NOT touch an existing .ralph/RALPH.md,
# so the template-hardening fixes do NOT reach an already-installed RALPH.md
# this way. Use the "Regenerate RALPH.md" steps below to update it.
./install.sh /path/to/target/repo --scripts-only

# Verify the SOURCE template carries the fixes (an installed RALPH.md only
# picks them up after a regenerate — see below):
grep -q "git fetch origin" ralph/RALPH.md.template && echo "✓ Worktree-safe commands in template"
grep -q "closedByPullRequestsReferences" ralph/RALPH.md.template && echo "✓ Correct gh field in template"
```

### Regenerate RALPH.md (to pull template fixes into an installed repo)

`install.sh` leaves an existing `.ralph/RALPH.md` untouched and only renders it
from the template when the file is absent. To refresh an installed RALPH.md,
delete it first, then re-run install:

```bash
cd /path/to/target/repo
rm .ralph/RALPH.md
/path/to/ralph-loop-dashboard/install.sh /path/to/target/repo --scripts-only
# Then re-apply any repo-specific PRD reference / customization
```

## Affected Repos

- **alisterr**: macOS worker (TJ's Mac) — high priority for timeout fix
- **kindleflow**: macOS worker (TJ's Mac) — high priority for timeout fix
- **Glasswork**: Windows worker (no macOS timeout concern) — lower priority

## Verification

After re-syncing, verify each repo (the RALPH.md greps assume you regenerated
it per "Regenerate RALPH.md" above — `--scripts-only` alone won't update it):

```bash
cd /path/to/repo
bash -n .ralph/ralph.sh .ralph/launch.sh  # Syntax check
grep "git fetch origin" .ralph/RALPH.md   # Worktree-safe
grep "closedByPullRequestsReferences" .ralph/RALPH.md  # Correct field
```

## Timeline

- **Before**: These issues were dormant (no Ralph workers actively running)
- **After this PR**: Template is fixed at source
- **Next step**: Re-sync alisterr, kindleflow, Glasswork before enabling auto-launch
