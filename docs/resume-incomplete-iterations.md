# Resume incomplete iterations

When Ralph's autopilot continues budget runs out mid-implementation, the
worker historically halted with `⚠️ Issue #N not closed by a merged PR …`,
forcing a human relaunch. `ralph.sh` now detects this and resumes the
same issue with the existing branch instead of failing.

This document describes the detection rules, retry cap, dirty-tree
rescue, and configuration knobs introduced for [issue
#60](https://github.com/tjegbejimba/ralph-loop-dashboard/issues/60).

## When a resume fires

After copilot exits cleanly but no merged PR exists, the verifier
checks:

1. A slice branch named `${RALPH_BRANCH_PREFIX}${num}-…` exists locally
   or on origin.
2. That branch is ahead of the default branch (has new commits).
3. The branch's HEAD commit was authored after this iteration started
   (rules out stale branches from prior runs).
4. No open PR exists for the branch (humans should review open PRs).
5. The per-issue resume counter has not exceeded `RALPH_RESUME_MAX`.

If all five hold, the worker:

- Persists `resumeAttempt` + `resumeBranch` on the existing claim
  record in `state.json`.
- Keeps the run-aware status at `running` (not `failed`, which would
  be terminal).
- Re-enters the loop with `RESUME_NUM` set, bypassing
  preflight/sync/selection/claim.
- Exports `RALPH_RESUME=1`, `RALPH_RESUME_ATTEMPT=N`,
  `RALPH_RESUME_BRANCH=…` into the copilot subprocess.
- Appends a `--- RALPH_RESUME ---` section to the prompt instructing
  copilot to check out the existing branch and finish.

If any of the five fail, the iteration halts as before (with the
reason logged for debugging).

## Dirty-tree rescue at preflight

If the working tree is dirty at preflight time and the current branch
is a slice branch (`${RALPH_BRANCH_PREFIX}*`), the worker now:

1. Refuses if any porcelain path is potentially sensitive (`.env*`,
   `*.pem`, `*.key`, `id_rsa*`, `*.p12/pfx/crt/cer`, `.netrc`,
   `.npmrc`, `.pypirc`, `credentials*`, anything under `secrets/`).
2. Otherwise commits with `wip: ralph auto-commit before resume` plus
   a `Co-authored-by: Copilot` trailer.
3. Pushes the slice branch to origin (so it survives the upcoming
   `sync_to_origin_main` hard reset).
4. Checks out the worker's home branch (recorded at startup) before
   sync runs.

On the worker branch or main, dirty trees still halt — the operator
must review.

## Configuration

Env vars (override config keys):

| Env var | Config key | Default |
|---------|-----------|---------|
| `RALPH_RESUME_MAX` | `worker.resumeMax` | `2` |
| `RALPH_RESUME_ON_OPEN_PR` | `worker.resumeOnOpenPR` | `false` |
| `RALPH_INITIAL_BRANCH` | — | `git rev-parse --abbrev-ref HEAD` at startup |

Set `RALPH_RESUME_MAX=0` to disable resume entirely (old halt
behaviour). Set `RALPH_RESUME_ON_OPEN_PR=1` to resume even when a PR is
already open on the slice branch (useful if you want Ralph to keep
pushing after a stalled review).

## What this does NOT do

- Bump `RALPH_AUTOPILOT_CONTINUES` per issue — out of scope.
- Auto-stash dirty trees on the worker branch or main — these still
  halt; operator must clean up.
- Auto-resume after `copilot exited 1` — exit codes still halt.
- Survive worker process restart between iterations. The persisted
  `resumeAttempt` field is informational; loading it on restart is a
  potential follow-up.
