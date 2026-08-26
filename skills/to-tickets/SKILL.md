---
name: to-tickets
description: "Break a Ralph PRD/spec into independently grabbable tracer-bullet slice issues with explicit blocking edges and canonical Ralph labels. Use when the user asks to split a PRD or plan into tickets/issues/slices, or when ralph-orchestrator invokes PRD slice authoring. Do not enqueue or launch workers."
---

# To Tickets

Turn a shaped PRD into child issues that Ralph can reason about independently.
The skill owns slice authoring; `ralph-orchestrator` owns validation, enqueue,
launch, monitoring, and drain.

The filing-time born-ready rule below is authoritative for live publishing. It is
kept self-contained so native Windows managed-copy installations behave the same
as symlink installations.

## Process

### 1. Anchor the source

Read the full PRD issue body and comments with `gh issue view`. For a Ralph PRD,
require an open issue with exactly `work:prd` and exactly `ralph:evaluated`. Use its
single `priority:*` label as the slice default; when it has none, default slices to
`priority:P2` and report that choice without relabeling the parent. Conflicting
priority labels or a work/state mismatch are hard stops, not invitations to relabel
the parent.

Before drafting, discover existing child issues carrying the exact `Parent #N`
marker in their actual body (not a fenced or inline code example). Reuse a complete
matching set. If the existing set is partial, duplicated, or conflicts with the
PRD, stop with the concrete conflict so a retry cannot create duplicate slices.

### 2. Ground the slices

Read the target repository's `CONTEXT.md` when present, relevant ADRs, current code,
and test prior art. Use domain vocabulary from those sources. Look for small
prefactors that make later slices independently landable.

### 3. Draft tracer bullets

Each slice must:

- deliver a narrow but complete path through every affected layer;
- be demoable or verifiable on its own;
- fit one pull request and one fresh agent context;
- have acceptance criteria tied to observable behavior or a regression test;
- declare every blocking edge and no speculative dependency.

A wide mechanical refactor is the exception. Use expand-contract: add the new form
beside the old, migrate callers in independently green batches, then remove the old
form after every migration completes.

Give slices `Slice 1: ...`, `Slice 2: ...` titles in dependency order.
Validate the blocking graph is acyclic before publishing; a cycle is a planning
error, not a runnable frontier.

### 4. Decide whether confirmation is needed

- **Direct user invocation:** present the proposed titles, delivered behavior,
  dependencies, priority, and intended state; publish after approval.
- **`ralph-orchestrator` invocation:** the approved PRD is the authorization to
  author. Continue without another confirmation when the PRD settles every needed
  decision. If it does not, return a product hard stop instead of guessing.
- **Dry-run / plan:** render the complete slice plan with zero GitHub mutations.

### 5. Classify each new slice at filing time

Every slice receives `work:slice`, exactly one `priority:*`, and exactly one state:

- `ralph:ready` only when every born-ready check below passes;
- `ralph:needs-triage` when scope, proof, value, or dependencies are uncertain;
- `ralph:hitl` when the work needs a human/product/security/destructive decision.

The born-ready checks are:

1. clear scope (and a cited root cause for a bug);
2. verifiable acceptance criteria tied to behavior or a failing test;
3. PR-sized runnable work;
4. no unresolved question or `TBD`;
5. no HITL carve-out;
6. an explicit `## Blocked by` section whose open blockers are other slices in the
   same acyclic authored frontier (so Ralph can sequence them), whose external
   blockers are already satisfied, or which says `None`;
7. not duplicate, superseded, or out of scope.

HITL includes destructive changes, migrations/deletions, auth or permissions,
credentials, production services, billing, user data/privacy, broad architecture
or product decisions, and any owner judgment. If the repository lacks
`ralph:hitl`, use `ralph:needs-triage` and add `HITL: <reason>` to the body.

This authority applies only while creating a new issue. Never promote an existing
live issue to `ralph:ready`.

### 6. Publish in dependency order

Create blocker slices first so dependents can cite real issue numbers. Use
`gh issue create --body-file <path>` with the labels chosen above. Every body must
retain Ralph's exact `Parent #N` marker even if the tracker also supports native
sub-issues.

```markdown
## Parent

Parent #<parent-number>

## What to build

The end-to-end behavior this slice makes work.

## Acceptance criteria

- [ ] Observable or test-verifiable criterion.

## Blocked by

None
```

For dependencies, replace `None` with one `- #N` bullet per blocking issue. Ralph
intentionally ignores prose such as `Blocked by #N`; only bullets under the
`## Blocked by` heading create dependency edges.

Every `ralph:ready` body must also include:

```markdown
## Born-ready checklist

- Scope/root cause: <evidence>
- Regression test or validation target: <evidence>
- Acceptance criteria: <observable proof>
- Blocked by: None or the loop-handled issue references above
- Parent #<parent-number>
- Not duplicate/superseded; worth automating
```

### 7. Return the authored frontier

Report every created or reused issue as `#N URL - state - priority - blockers`.
Return the ordered issue numbers to the caller. Do not enqueue, launch, relabel
existing issues, close the parent, or implement a slice.

## Completion criteria

The step is complete only when every planned slice is accounted for exactly once,
each body has the canonical parent marker and a `None` or bulleted blocker section,
each issue has one label in all three Ralph dimensions, and the caller receives the
issue frontier. A dry run must show the same plan and labels with zero mutations.
