---
name: to-spec
description: "Turn shaped conversation context into a Ralph PRD/spec issue and optionally hand it to ralph-orchestrator. Use when the user asks to create, write, publish, or file a PRD/spec for Ralph. Do not use for child slice authoring (use to-tickets) or for running an existing PRD (use ralph-orchestrator)."
---

# To Spec

Synthesize the decisions already present in the conversation and codebase into a
Ralph PRD parent. Ralph's domain still calls this artifact a PRD (`work:prd` and
`--enqueue-prd`); this skill uses the current spec/tickets skill vocabulary.

Do not restart discovery as an interview. If a material product or architecture
decision is genuinely unresolved, identify the decision and stop before publishing
rather than inventing it.

## Process

1. **Ground the spec.**
   - Read the target repository's `CONTEXT.md` when present and the relevant ADRs.
   - Read `docs/agents/issue-tracker.md` when present for tracker conventions.
   - Explore enough current code and tests to identify existing seams and prior art.
   - Use repository domain vocabulary throughout.

2. **Choose test seams.** Prefer the highest existing seam that can prove external
   behavior. Add a new seam only when the existing design cannot support the work.
   Record the chosen seams and test targets in the spec.

3. **Draft the PRD.** Use the template below. Keep implementation decisions durable:
   describe modules, interfaces, contracts, and constraints, not volatile file paths
   or full code listings.

4. **Validate the artifact.** Before publishing, require:
   - a user-facing problem and solution;
   - complete user stories;
   - settled implementation and testing decisions;
   - explicit out-of-scope boundaries;
   - no unresolved `TBD` or open product decision;
   - exactly one priority (`priority:P0` through `priority:P3`, default `P2` when
     the conversation establishes no stronger priority).

5. **Publish the PRD parent.**
   - A dry-run or plan request renders the title, body, and intended labels only.
   - Otherwise, create a GitHub issue with `gh issue create --body-file <path>` and
     labels `work:prd`, `ralph:evaluated`, and the chosen `priority:*`.
   - Resolve and report the canonical issue URL and number.
   - If the target repository lacks the canonical labels, stop with the missing
     labels instead of publishing an incorrectly shaped parent.

6. **Handoff deliberately.** If the user's request includes running, orchestrating,
   or sending the PRD through Ralph, invoke `ralph-orchestrator` with the new issue
   number. If the request was only to author the PRD, stop after reporting the issue
   and name `ralph-orchestrator` as the next stage.

## PRD template

```markdown
## Problem Statement

The problem from the user's perspective.

## Solution

The intended outcome from the user's perspective.

## User Stories

1. As an <actor>, I want <capability>, so that <benefit>.

## Implementation Decisions

- Settled modules, interfaces, contracts, schema/API decisions, interactions, and
  architectural constraints.

## Testing Decisions

- The externally observable behavior that proves the feature.
- The seams/modules to test.
- Relevant testing prior art in the repository.

## Out of Scope

- Explicitly excluded work.

## Further Notes

- Supporting context that does not belong in the decisions above.
```

## Completion criteria

The step is complete only when the PRD issue exists with `work:prd`,
`ralph:evaluated`, and exactly one `priority:*` label, its canonical URL is
reported, and any requested Ralph handoff has occurred. A dry run is complete when
the equivalent title, body, labels, and handoff decision are shown with zero
mutations.

