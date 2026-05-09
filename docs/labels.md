# Ralph Label Vocabulary

Ralph uses three GitHub labels to control which issues AFK workers may pick up.

## Labels

### `needs-triage`

**Color**: `#E4E669` (yellow)

Issues that have not yet been reviewed or scoped for an agent. Ralph skips
these entirely — they are not included in the default `issueSearch` query.

### `ready-for-agent`

**Color**: `#0075CA` (blue)

Issues that have been reviewed, scoped, and are safe for Ralph to pick up
autonomously. Ralph's default `issueSearch` filters to `label:ready-for-agent`,
so only issues carrying this label will be picked up by workers.

### `hitl`

**Color**: `#B60205` (red)

**"Human-in-the-loop"** — issues that require human interaction or judgment
before work can proceed (e.g., ambiguous requirements, security-sensitive
changes, design decisions). Ralph's default `issueSearch` includes
`-label:hitl`, so `hitl` issues are **naturally skipped** even if they also
carry `ready-for-agent`.

`ready-for-agent` and `hitl` are **mutually exclusive** in practice:
- An issue labelled only `ready-for-agent` → picked up by Ralph workers.
- An issue labelled `hitl` (with or without `ready-for-agent`) → skipped by Ralph workers.
- An issue labelled neither → skipped because `label:ready-for-agent` is required.

## How they interact with Ralph's `issueSearch`

The default `issueSearch` in every profile config combines both guards:

```
label:ready-for-agent -label:hitl
```

This means **only issues that are explicitly opt-ed in (`ready-for-agent`) AND
have not been flagged for human review (`-label:hitl`) will be processed by
Ralph**.

## Creating labels in your target repo

When you run `install.sh` against a new repo, create matching labels with the
GitHub CLI:

```bash
gh label create needs-triage   --color E4E669 --description "Needs human triage before agent work"
gh label create ready-for-agent --color 0075CA --description "Safe for AFK Ralph workers to pick up"
gh label create hitl            --color B60205 --description "Requires human interaction; not safe for AFK Ralph workers"
```

The `install.sh` script prints a reminder with these commands after a
successful install.
