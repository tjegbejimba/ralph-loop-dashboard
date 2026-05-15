# Manually-closed blockers

By default Ralph treats an issue as "satisfied" — and therefore unblocking
its downstream slices — only when GitHub reports that the issue was closed
by a merged pull request whose body contained a closing keyword
(`Closes #N`, `Fixes #N`, `Resolves #N`). This is the same predicate the
worker uses to verify its own iteration succeeded, so the "blocker is
satisfied" invariant is the same as "code for the blocker actually landed
on the default branch."

That invariant breaks down whenever an issue is **closed manually** without
that PR linkage. Common scenarios:

- The work was merged inside a larger PR that didn't list the keyword for
  this specific issue.
- The issue was determined to be obsolete (or already done elsewhere) and a
  maintainer closed it directly with `gh issue close --reason completed`.
- A scripted cleanup process closed a batch of duplicates.

In every case `gh issue view <N> --json closedByPullRequestsReferences`
returns `[]`. The default verifier therefore decides the blocker is not
satisfied, the downstream slice is silently skipped on every poll, and the
worker eventually exits as idle without ever picking up the issue it
should have worked on.

This is the structural sibling of the
[release-branch case](release-branch.md) — both are situations where the
"merged PR closed the issue" linkage on GitHub is missing even though the
work (or the maintainer's intent that the issue be done) is in fact
finished.

## Opting in

Set `acceptManuallyClosed: true` under `.worker` in `.ralph/config.json`,
or export `RALPH_ACCEPT_MANUALLY_CLOSED=1`. When enabled, the verifier
also accepts a blocker as satisfied when **all** of the following hold:

- `state` is `CLOSED`
- `stateReason` is `COMPLETED` (the default "Close as completed" choice in
  the GitHub UI; equivalent to `gh issue close --reason completed`)
- The standard merged-PR check has already failed

Issues closed with `stateReason=NOT_PLANNED` (the "Close as not planned"
choice — used for wontfix, duplicates, and obsolete reports) remain
**unsatisfied** even with the knob on. The same is true for legacy issues
whose `stateReason` is missing or null. This keeps the "the work happened"
invariant intact for the most common ambiguous case.

### Example

```jsonc
// .ralph/config.json
{
  "worker": {
    "acceptManuallyClosed": true
  }
}
```

Or as a per-launch override:

```bash
RALPH_ACCEPT_MANUALLY_CLOSED=1 ./.ralph/launch.sh
```

Boolean values are normalised: `1`, `true`, `yes`, `on` enable the flag
(case-insensitive). `0`, `false`, `no`, `off`, and the empty string
disable it. Any other value is rejected at startup with a clear error so
a typo in `config.json` cannot silently flip the wrong way.

## Trade-off

The strict default exists for a reason: it is the only guarantee that a
slice's prerequisite code is actually on `main` before the downstream
slice tries to build on top of it. Opting in weakens that guarantee — a
maintainer who closes an issue with `stateReason=COMPLETED` because they
*intend* the work to be merged-via-related-PR is taking on the
responsibility of making sure the corresponding code really did land.

Use this knob when the repo's workflow regularly produces manual closures
(e.g. when many issues are closed by larger umbrella PRs whose body
doesn't list every child issue) and the cost of a missed downstream pick
exceeds the cost of an occasional "blocker said done but code never
landed" surprise.

## Diagnostic mode

When a worker is idling and you're not sure *why* it keeps rejecting an
otherwise-eligible candidate, turn on verbose mode:

```bash
RALPH_VERBOSE=1 ./.ralph/launch.sh
```

or

```jsonc
// .ralph/config.json
{
  "worker": {
    "verbose": true
  }
}
```

The candidate-selection loop will emit one line per rejected candidate:

```
  ↳ skipping #126: blocker #125 not satisfied (state=CLOSED reason=NOT_PLANNED prs=)
  ↳ skipping #127: claimed by another worker
```

The `state`/`reason`/`prs` fields come straight from the cached
`is_issue_satisfied` lookup, so the diagnostic doesn't make any extra
`gh` calls. The first idle poll of every worker session also prints a
one-time pointer to `RALPH_VERBOSE=1` so future stalls are debuggable
without having to remember to set the flag ahead of time.

## Minimum tooling

The fallback reads the `stateReason` field from `gh issue view`. GitHub
CLI has supported that field on the `--json` flag since v2.13 (April
2022). If the first `gh issue view` call fails for any reason — older
`gh` rejecting the field, transient network errors, rate-limiting — the
verifier retries the same call once without `stateReason`. The strict
merged-PR satisfaction path keeps working on the retry, but the
manual-close fallback can't fire because the `stateReason` value isn't
reachable. Bumping `gh` is the only way to enable the fallback on
installations older than v2.13; transient failures resolve themselves on
the next polling cycle.

## Related

- [`docs/release-branch.md`](release-branch.md) — sibling escape hatch for
  PRs whose base branch is not the repo default.
- Issue
  [#65](https://github.com/tjegbejimba/ralph-loop-dashboard/issues/65) —
  original feature request and design discussion.
