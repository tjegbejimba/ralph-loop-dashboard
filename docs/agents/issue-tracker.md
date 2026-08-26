# Issue tracker: GitHub

Issues and specs for this repository live in GitHub Issues at
`tjegbejimba/ralph-loop-dashboard`. Use the `gh` CLI for all operations and infer
the repository from the `origin` remote when running inside this clone.

## Repository conventions

- Human-filed work uses
  [Structured Issue Intake](../../.github/ISSUE_TEMPLATE/structured-intake.yml),
  which starts at `ralph:needs-triage`.
- Agent-authored work must follow the filing-time safety rules and canonical
  `ralph:`, `priority:`, and `work:` dimensions in
  [Ralph Label Vocabulary](../labels.md). In particular, do not promote an
  existing issue to `ralph:ready` autonomously.
- PRD parents use `work:prd` with `ralph:evaluated`. Runnable work uses either
  `work:slice` with an exact `Parent #N` marker or `work:standalone`.
- PRD bodies conventionally use sections such as `Problem Statement`,
  `Solution`, `User Stories`, `Implementation Decisions`, `Testing Decisions`,
  and `Out of Scope`.
- Slice bodies conventionally use `Parent`, `What to build`,
  `Acceptance criteria`, and `Blocked by`. Standalone issues should state the
  problem, bounded scope, verifiable outcome, and blockers just as explicitly.

## Common operations

- **Create an issue**:
  `gh issue create --title "..." --body-file <path> --label "..."`
- **Read an issue**:
  `gh issue view <number> --comments --json number,title,body,labels,comments`
- **List issues**:
  `gh issue list --state open --json number,title,body,labels,comments`
  with appropriate `--label` filters
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply or remove labels**:
  `gh issue edit <number> --add-label "..."` or
  `gh issue edit <number> --remove-label "..."`
- **Close an issue**: `gh issue close <number> --comment "..."`

Prefer `--body-file` for multiline bodies so quoting is reliable across shells.

## Pull requests as a triage surface

**PRs as a request surface: no.** Pull requests are delivery artifacts, not
feature-request or issue-triage inputs.

GitHub shares one number space across issues and pull requests. If a bare
`#42` is ambiguous, run `gh pr view 42` and fall back to `gh issue view 42`.

## Skill translations

- When a skill says **publish to the issue tracker**, create a GitHub issue that
  follows the repository conventions above.
- When a skill says **fetch the relevant ticket**, run
  `gh issue view <number> --comments`.
- `to-spec` publishes a PRD parent with `work:prd`, `ralph:evaluated`, and one
  `priority:*` label.
- `to-tickets` publishes child slices with `work:slice`, one `priority:*`, a
  filing-time state from the born-ready rule, and the exact `Parent #N` marker.
