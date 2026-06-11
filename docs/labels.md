# Ralph Label Vocabulary

Ralph uses GitHub labels as additive automation metadata. Repo/domain labels stay
owned by the repo; Ralph only reads and writes labels in the `ralph:`,
`priority:`, and `work:` dimensions.

## Canonical dimensions

Every issue that Ralph evaluates should have exactly one state label, one
priority label, and one work label. Multiple labels in the same dimension are a
conflict and fail closed until repaired.

### State labels

| Label | Meaning |
| --- | --- |
| `ralph:needs-triage` | Not yet scoped for Ralph. |
| `ralph:evaluated` | Reviewed, but not runnable by workers. Used for PRD parent issues. |
| `ralph:ready` | Runnable by Ralph when paired with a runnable work type and no blockers. |
| `ralph:blocked` | Explicitly blocked before worker pickup. |
| `ralph:hitl` | Human-in-the-loop; not safe for autonomous work. |
| `ralph:queued` | Enqueued by `launch.sh --enqueue` or `--enqueue-prd`. |
| `ralph:running` | Claimed by a worker. |
| `ralph:done` | Completed by Ralph. |
| `ralph:failed` | Worker failed and left the issue as a blocker for dependents. |

### Priority labels

`priority:P0`, `priority:P1`, `priority:P2`, and `priority:P3` order ready
work. Missing priority is treated as `priority:P2` with a warning; backfill
plans should add the explicit label.

### Work labels

| Label | Meaning |
| --- | --- |
| `work:prd` | Parent PRD/spec issue. Must use `ralph:evaluated`, not runnable states. |
| `work:slice` | Child implementation slice. Body must contain an exact `Parent #N` marker. |
| `work:standalone` | Independent runnable issue without a PRD parent. |

## Runtime eligibility

Workers are canonical-only by default. A runnable issue must be:

1. Open.
2. `ralph:ready`, `work:slice` or `work:standalone`, and exactly one label per dimension.
3. Unassigned.
4. Free of unresolved `Blocked by #N` dependencies, including `ralph:failed` dependencies.

Compatibility aliases for the old labels (`ready-for-agent`, `needs-triage`,
`hitl`) are only accepted by explicit compatibility code paths and always emit
warnings. New automation should use canonical labels only.

## Default search

Profile defaults search for canonical runnable work:

```text
label:ralph:ready (label:work:slice OR label:work:standalone) is:open no:assignee
```

Preflight and status are read-only. Normal enqueue and worker transitions are
the only paths that mutate labels.

## Label management

Mutating label-management commands must be dry-run by default and require an
explicit apply flag. Dry-run output should show the exact add/remove operations
without changing GitHub.

Example setup commands for a repo that has not created Ralph labels yet:

```bash
gh label create ralph:needs-triage --color E4E669 --description "Needs human triage before Ralph work"
gh label create ralph:evaluated    --color C5DEF5 --description "Reviewed PRD or issue, not worker-runnable"
gh label create ralph:ready        --color 0E8A16 --description "Ready for Ralph workers"
gh label create ralph:blocked      --color D93F0B --description "Blocked before Ralph pickup"
gh label create ralph:hitl         --color B60205 --description "Human-in-the-loop; not autonomous"
gh label create ralph:queued       --color 1D76DB --description "Queued for Ralph"
gh label create ralph:running      --color 5319E7 --description "Claimed by Ralph"
gh label create ralph:done         --color 0E8A16 --description "Completed by Ralph"
gh label create ralph:failed       --color B60205 --description "Ralph failed; blocks dependents"
gh label create priority:P0        --color B60205 --description "Highest Ralph priority"
gh label create priority:P1        --color D93F0B --description "High Ralph priority"
gh label create priority:P2        --color FBCA04 --description "Default Ralph priority"
gh label create priority:P3        --color C2E0C6 --description "Low Ralph priority"
gh label create work:prd           --color 0052CC --description "Ralph PRD parent"
gh label create work:slice         --color 1D76DB --description "Ralph PRD child slice"
gh label create work:standalone    --color 5319E7 --description "Standalone Ralph issue"
```
