# Triage contract (CLI-first hybrid)

How the orchestrator consumes triage. Per ADR 0003, the deterministic CLI is the
**source of truth**; the LLM triage agent is **advisory only** over a frozen
snapshot. The orchestrator never lets probabilistic output drive labels, queue
state, enqueue, or launch.

## The primitive

```
node extension/cli.mjs triage --dry-run --json [--canonical-labels] [--query "<search>"]
```

- **Read-only as used here.** `--dry-run` (the default) prints planned comments
  without posting; `--json` emits the structured run. The orchestrator only ever
  calls the dry-run JSON form. `--live` (which posts the bot-owned comment) is not
  the orchestrator's to call — the deterministic writer/scheduled path owns that.
- **Default scope:** repo `tjegbejimba/ralph-loop-dashboard`, query
  `label:needs-triage`. `--canonical-labels` switches the query to
  `label:ralph:needs-triage`; `--query` overrides it entirely. The CLI also accepts a
  repeatable **`--repo OWNER/NAME`** flag (#95, landed) to classify one or more
  explicit repos in a single run — the scheduled triage workflow uses it directly
  (`--repo tjegbejimba/alisterr --repo tjegbejimba/kindleflow --repo
  tjegbejimba/Glasswork`). `--repo` selects repos **by name** and is independent of
  the `orchestrateAllowedRepoRoots` launch allowlist (which gates local checkout
  paths for launch, not triage). In `repo-maintain` a per-repo session still
  classifies its own repo by default, but cross-repo triage classification is
  available whenever a caller passes `--repo`.
- Deterministic, idempotent, auditable. Same input → same output.

### Output shape (consume only these fields)

```jsonc
{
  "mode": "dry-run",
  "repos": [
    {
      "repo": "owner/repo",
      "query": "label:ralph:needs-triage",
      "processed": [
        {
          "issueNumber": 85,
          "action": "create | update | skip",
          "recommendation": "Pursue | Refine | Needs info | Defer | Close | Uncertain",
          "commentBody": "…full opinion (Recommendation/Confidence/Priority/Automation safety/Why/Next action)…"
        }
      ],
      "skipped": [{ "issueNumber": 0, "reason": "" }],
      "errors": [{ "issueNumber": 0, "type": "", "message": "" }]
    }
  ]
}
```

The richer per-issue opinion (Confidence, Priority, Automation safety, Why, Next
action) is embedded in `commentBody`. Parse what you need from there; do not
re-derive a score.

## Compact consumption rule

Reduce each issue to a single line for the ledger / summary. **Never** store raw
`gh` dumps, full issue bodies, or full `commentBody` text in the ledger.

```
#<number> <url> — <recommendation>/<priority>/<automation-safety> — <one-clause why>
```

Keep the triage summary to the issues in scope for the current run. Carry only:
`issueNumber`, `url`, `recommendation`, `priority`, `automationSafety`, and at most
one short cited span.

## Ready-work vs needs-triage

`triage --json` classifies the **needs-triage backlog** (advisory). It does **not**
discover runnable work. For `repo-maintain` (a per-repo session), *ready-work
discovery* uses the session repo's configured canonical search, read from
`.ralph/config.json` `issue.issueSearch`
(default: `is:open no:assignee label:ralph:ready (label:work:slice OR label:work:standalone)`),
run read-only (`gh issue list --search "<issueSearch>" --json number,title,labels,url`,
which defaults to the session's repo). The orchestrator **never rewrites**
`issue.issueSearch`. Triage classification (the session's own repo by default, or
explicit repos when `--repo` is passed — see the `--repo` note above) then informs
confidence/escalation, but only `ralph:ready` + passing preflight issues enter the
queue.

## When to escalate to the advisory agent

Spawn the `ralph-issue-triage-agent` (single sub-agent, frozen snapshot) only when
the deterministic result needs a maintainer-grade second look:

- `confidence: low`;
- conflicting taxonomy or preflight signals;
- a suspicious `Close` or `Defer` recommendation;
- `needs-owner` / a product or risk call the CLI cannot represent.

The agent reads the **frozen** triage JSON snapshot, adds nuance/citations/owner
interpretation, and returns advice. It performs **zero** mutations, no live
discovery, no enqueue, no launch. Its output can enrich or challenge the CLI
result but is never the source of truth for labels, queue construction, enqueue, or
launch. Default path is the CLI alone — escalate by exception, not by habit.

## Forward reference: #106 lane router (not yet built)

The advisory `ralph-issue-triage-agent` emits maintainer **review** lanes
(`Immediate / worth shaping`, `Needs TJ or owner judgment`, `Defer/close/supersede`).
The planned deterministic lane router (#106) introduces a different lane vocabulary —
AUTO / REFINE / PRD / HOLD — that drives routing and promotion. These are
intentionally separate today: the agent's lanes are advisory review buckets, not
execution states. When #106 lands, add an explicit mapping so advisory output feeds
the router cleanly (roughly: `Immediate / worth shaping` → AUTO or REFINE by
confidence + automation safety; `Needs TJ or owner judgment` → PRD or HOLD;
`Defer/close/supersede` → HOLD). This is a forward reference only — no behavior
change until #106 is implemented.
