# Release-branch Ralph loops

By default Ralph assumes every PR lands on the repo default branch (usually
`main`). For long-lived feature work — multi-user redesigns, parallel
migrations, feature-flagged rewrites — it's common to stack many issues onto
a release branch (e.g. `multi-user`, `next`, `v2`) and only merge into `main`
when the whole release is ready.

GitHub's automatic issue-closure behaviour does **not** work on non-default
base branches:

- `closingIssuesReferences` / `closedByPullRequests` are empty for PRs whose
  base ≠ default branch — even with `Closes #N` in the body.
- Merging a PR into a non-default base does **not** close the referenced
  issue.

The default Ralph verifier therefore halts on every iteration of a release
branch loop, even when the agent merged the PR cleanly. To unblock these
flows, set `RALPH_RELEASE_BRANCH` and (optionally) `RALPH_BRANCH_PREFIX`.

## Env vars

### `RALPH_RELEASE_BRANCH`

Name of the release branch (e.g. `multi-user`). When set, the post-iteration
verifier:

1. Tries to merge an open PR into the release branch whose body contains
   `Closes #N` and whose checks are green, then explicitly closes the issue.
2. If that fails, falls through to a final acceptance pass: if the issue is
   already `CLOSED` *and* a PR was merged into the release branch in this
   iteration window referencing `#N`, accept it as success.

When unset, behaviour is identical to before — no release-branch logic runs.

### `RALPH_BRANCH_PREFIX`

Per-issue branch prefix (e.g. `mu-`, `release-`). When set together with
`RALPH_RELEASE_BRANCH`, an additional fallback runs: if no PR exists but a
remote branch `${prefix}${issue}-…` is found (i.e. copilot pushed but didn't
run `gh pr create`), the verifier opens a PR for that branch using the
latest commit message as title and `Closes #N` as body, then re-runs the
merge fallback above.

This handles the case where copilot's iteration runs out of token budget
between `git push` and `gh pr create`.

## Example

```bash
RALPH_RELEASE_BRANCH=multi-user \
RALPH_BRANCH_PREFIX=mu- \
RALPH_RUN_ID=20260509-… \
./.ralph/launch.sh
```

The agent's RALPH.md prompt should still document the expected branch
naming, PR base, and the explicit `gh issue close` step. The verifier's
fallback exists for resilience, not as the primary closure path.

## Ground rule update

The "never call `gh issue close`" rule (see `docs/labels.md` and the
canonical RALPH.md prompts) still applies to the **default-branch** flow.
For release-branch flows, `gh issue close --reason completed` is invoked by
the verifier — but only as the second half of `gh pr merge && gh issue
close`, never standalone. RALPH.md prompts targeting a release branch should
include an explicit closure step so the agent does it directly when
possible; the verifier picks up the slack when copilot stops mid-flow.

## Related

- Issue [#55](https://github.com/tjegbejimba/ralph-loop-dashboard/issues/55) — original feature request and design discussion.
