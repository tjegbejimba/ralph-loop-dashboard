# Dependency-aware run queues

Ralph already supports issue dependencies in the shell worker through issue body
metadata. The next dashboard tranche (#35 and #36) extends that model to selected
run queues so operators can see dependency risk before starting workers.

## Canonical issue syntax

Use `## Blocked by` as the canonical dependency section:

```markdown
## Blocked by
- #123
- #124
```

The dashboard dependency parser should also accept `## Depends on` as an alias,
plus explicit inline phrases such as `Blocked by #123` or `Depends on #123`.
Ordinary issue references, such as `Related to #123`, must not be treated as
dependencies.

`None` and `No blockers` under a dependency heading mean the issue has no
blockers.

## Satisfaction rule

A blocker is satisfied only when the blocker issue is closed by a merged PR. A
manually closed issue does not satisfy downstream dependencies, because the code
may not have landed on the default branch.

Dashboard preflight and shell worker enforcement should use the same predicate.

## Parsing and data flow

The selected queue should stay lightweight. Do not persist full issue bodies in
browser localStorage or add them to every status payload.

Preflight should fetch detail for the selected issue numbers, parse dependencies
inside the extension process, and return structured dependency metadata to the
browser. A useful shape is a small graph of edges:

```json
{
  "from": 50,
  "to": 49,
  "source": "Blocked by",
  "inSelectedQueue": true,
  "satisfied": false
}
```

The graph gives preflight enough information to render precise messages now and
lets future dashboard visualization reuse the same contract.

## Preflight behavior

Sequential runs and parallel runs have different safety rules:

- `parallelism = 1`: dependencies inside the selected queue are allowed and
  should be explained as sequential work.
- `parallelism > 1`: dependencies inside the selected queue block Start. The
  blocking message should name the relationship and tell the operator to reduce
  parallelism to 1.
- Every `parallelism > 1` run should also show a nonblocking warning that no
  parser can prove issues are semantically independent.

Dependencies outside the selected queue require satisfaction checks. If the
external blocker is already satisfied, preflight can pass with an annotation. If
the external blocker is unsatisfied, preflight should block Start for both
sequential and parallel runs because the selected queue cannot make progress on
its own.

Dependency cycles among selected issues should block all starts, including
sequential starts, and the message should name the cycle.

## Shell enforcement

Dashboard preflight is not the only safety layer. Run-aware shell workers should
also enforce dependencies before claiming issues from `.ralph/runs/<run>/queue.json`.

This preserves safety for manual CLI starts, stale dashboards, and queue edits
that happen after preflight. The shell can skip blocked downstream items and
claim later items only when their blockers are satisfied.

## Queue order

Ralph should not automatically reorder the selected queue in the first
implementation. Preflight explains the graph, and the worker enforces safe
claims. The operator's saved queue order remains intact.
