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
| `ralph:fast-lane` | AUTO-eligible candidate; triage marked it but it still needs one-tap promotion to `ralph:ready`. Not runnable. |
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

## Authoring labels at filing time (born-ready rule)

The dimensions above describe **runtime eligibility** — what a worker may pick
up. This section governs the **authoring decision**: what initial state label a
filer applies when an issue is *created*. The gate is **readiness-based, not
provenance-based**. An issue earns `ralph:ready` by being well-specified and
actionable, **not** by where it came from (a grilled PRD is a strong fast-path,
not an automatic pass — see below).

> **Rule.** Agent-authored issues may be born `ralph:ready` only when newly
> created, repo-local, auditable, non-HITL, non-blocked, non-duplicate,
> PR-sized, and test-verifiable. Any uncertainty defaults to
> `ralph:needs-triage`; any human/product/security/destructive decision defaults
> to `ralph:hitl`.

### Authoring-time only (ADR 0003 keystone)

This is a **filing-time** policy — what label a human or agent stamps when
*creating* an issue. It does **not** authorize live promotion:

> LLM authoring may choose initial labels for newly created issues; LLM triage
> must never promote existing live issues or drive queues/launches — the
> deterministic CLI remains the source of truth.

An agent may apply `ralph:ready` **only** when creating a new issue/slice it has
shaped. An agent must **not** flip an existing `ralph:needs-triage` backlog
issue to `ralph:ready` on its own. Promotion of existing issues stays
deterministic and operator-mediated (a human-directed operator action is fine;
autonomous agent self-promotion in the live loop is not). See ADR 0003.

### Born-ready checklist (ALL must hold)

1. **Clear scope / root cause** — states exactly what to change. For bugs, the
   root cause with file/symbol/line citations.
2. **Verifiable acceptance criteria** — at least one criterion tied to
   observable behavior or a failing/regression test. A bare "Acceptance
   criteria" heading does **not** qualify (this closes the weak-clarity gap #107
   documents). For bugs, a concrete regression-test ask.
3. **Runnable, PR-sized work type** — maps to `work:slice` (with an exact
   `Parent #N` marker) or `work:standalone`, and is small enough to land in one
   PR. A worker can build it under `RALPH.md`.
4. **No unresolved open questions** — no TBDs, no "need to decide X".
5. **Not HITL** — none of the HITL carve-outs below apply.
6. **No unresolved blockers** — an explicit `## Blocked by` saying `None` (or all
   blockers closed / loop-handled).
7. **Value / not duplicate** — not a known duplicate, superseded, or
   out-of-scope item, and worth spending automation on. Any uncertainty →
   `ralph:needs-triage`.

### HITL carve-outs (force `ralph:hitl`, even if the issue looks "specified")

Apply `ralph:hitl` (or `ralph:needs-triage` if the repo has no `ralph:hitl`
label) regardless of how well-specified the issue is, when it involves:

- destructive or irreversible changes;
- data migration, deletion, or schema migration;
- auth, permissions, or security-sensitive code;
- credentials, production services, billing, user data, or privacy;
- broad architecture, product, or design decisions (design review needed);
- anything needing owner judgment before implementation.

On a repo with no `ralph:hitl` label, also add a visible `HITL: <reason>` line to
the issue body so the danger signal survives the `ralph:needs-triage` fallback —
both states are non-runnable, but a later operator promotion must not lose the
carve-out reason.

### Auditable evidence (required in the issue body)

Any agent-born `ralph:ready` issue must carry a short **`## Born-ready
checklist`** section in its body with evidence — labels alone are not enough:

```markdown
## Born-ready checklist
- Root cause: <file/symbol/line citation>            # bugs
- Regression test: <what a new failing test will prove>
- Validation command / target test file: `<cmd or path>`
- Acceptance criteria: at least one tied to observable behavior / a failing test
- Blocked by: None  (declared in an explicit `## Blocked by` section)
- Parent #N                                          # slices only
- Not a duplicate / superseded; worth automating
```

For slices, include the exact `Parent #N` marker; the parent is expected to be
`work:prd` + `ralph:evaluated`.

### Filer distinction

- **Human filer via `.github/ISSUE_TEMPLATE/structured-intake.yml`** — the form
  keeps defaulting to `ralph:needs-triage`. An unreviewed human submission has
  not been triaged, so this default is correct and unchanged.
- **Agent author that has shaped the issue** — applies the born-ready checklist
  above and may file it `ralph:ready` (with the evidence section) when every
  item holds.
- **Grilled-PRD origin** — a **strong fast-path** but **not** unconditional.
  Each slice must still pass the concrete checklist and HITL carve-outs;
  grilling produced the specificity, but it is the specificity (not the
  provenance) that earns `ralph:ready`.

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
label:ralph:ready -label:ralph:failed (label:work:slice OR label:work:standalone) is:open no:assignee
```

The explicit `-label:ralph:failed` is fail-closed defense-in-depth: an issue that
ends up with both `ralph:ready` and `ralph:failed` (a state conflict) is excluded
from discovery until repaired, so it can never be silently re-queued. The label
state machine (`ralph_apply_label_transition`) makes that conflict structurally
impossible by clearing every other `ralph:` state label on each transition, but
the search guard keeps discovery safe even if a stale label slips through.

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
gh label create ralph:fast-lane     --color BFD4F2 --description "AUTO-eligible candidate; awaiting one-tap promotion to ralph:ready"
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
