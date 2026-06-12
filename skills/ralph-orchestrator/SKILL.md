---
name: ralph-orchestrator
description: "Autonomous control-plane orchestrator that drives a PRD or a scheduled repo sweep through the Ralph headless TDD loop end to end. Use when to-prd hands off a PRD issue number to run it through Ralph (validate -> slice via to-issues -> enqueue -> gated launch -> monitor -> drain), when the user says orchestrate/run/drive a PRD through Ralph, or on an hourly scheduled tick for TJ's Ready agent automation (repo-maintain sweep). Launches are gated by allowAgentLaunch + preflight via orchestrateRun(); it never claims, implements, or merges work itself. Do not use for one-off enqueue/preflight (use to-ralph), advisory-only issue triage (use ralph-issue-triage-agent), PRD authoring (to-prd), or slice authoring (to-issues)."
---

# Ralph Orchestrator

Thin control plane that takes shaped work all the way through the Ralph loop. It
consumes structured CLI signals, applies authorization gates, builds a bounded
queue, launches headless workers **behind the gate**, monitors run state, raises
owner-decision briefs on hard stops, and keeps a compact ledger. It does **not**
claim, implement, review, or merge — that is the worker's job.

```
grill-me → to-prd → ralph-orchestrator (prd-run) → Ralph workers
                    └ uses to-issues to author slices, then enqueues + launches
repo-maintain (hourly schedule) → ralph-orchestrator → Ralph workers
```

## Mode detection

Pick exactly one mode and **load only that mode file** — never both in context at
once.

- **`prd-run`** — entry is a single PRD issue number (a `to-prd` handoff, or the
  operator says "run/orchestrate this PRD through Ralph"). → load
  [`modes/prd-run.md`](modes/prd-run.md).
- **`repo-maintain`** — entry is an hourly Copilot scheduled-workflow tick with no
  PRD (TJ's "Ready agent automation" sweep). → load
  [`modes/repo-maintain.md`](modes/repo-maintain.md).

If the trigger is genuinely ambiguous (e.g. a bare "run Ralph" with no PRD and no
tick), ask which mode is intended before loading either file.

## Autonomy

The only human hand is at PRD creation. Once `to-prd` hands off a PRD number (or a
schedule tick fires), the orchestrator creates/labels/enqueues/launches without
further confirmation — gated only by the authorization gates below. It pauses only
on a hard stop.

## Authorization gates (summary)

A launch proceeds only when **all** hold; otherwise pause and emit an owner brief:

1. `allowAgentLaunch: true` in `~/.ralph-dashboard/config.json` (default `false`),
   enforced inside `orchestrateRun()`.
2. Preflight passes (hard blocker inside `orchestrateRun()`).
3. Autopilot context for the auto-permitted `ralph_dashboard_orchestrate` tool;
   otherwise explicit operator approval.

Launch only via the `ralph_dashboard_orchestrate` tool / `orchestrateRun()`. Never
call `.ralph/launch.sh --start`/`--foreground` or any worker-start path directly.
Full gate, launch-contract, and availability details in
[`references/policy.md`](references/policy.md).

## Hard stops (summary)

Pause + owner brief, never auto-resolve: (1) unresolved preflight blockers;
(2) `allowAgentLaunch` off; (3) a product decision the PRD/issue doesn't answer;
(4) a worker failing/stalling repeatedly on one slice; (5) destructive/irreversible
actions (force-push `main`, delete issue, close without merge, label migration);
(6) missing credentials/access. Everything else is autonomous. Details and the
auto-resolvable-vs-hard-stop split: [`references/policy.md`](references/policy.md).

## Triage & ownership (summary)

Triage is **CLI-first hybrid** (ADR 0003): the orchestrator consumes
`node extension/cli.mjs triage --dry-run --json` as the deterministic source of
truth and escalates to the advisory `ralph-issue-triage-agent` (frozen snapshot,
zero mutations) only by exception. `to-issues` owns slice authoring; the
orchestrator owns gating/queueing/launch/monitor/ledger; workers own
claim→implement→review→merge. Interface in
[`references/triage-contract.md`](references/triage-contract.md); full ownership
table in [`references/policy.md`](references/policy.md).

## Concurrency

**One active run per repo.** If a run is already active, report state and **defer** —
record it in the ledger and do not modify that repo.

## Reporting

- **Owner-decision brief** on every hard stop: one actionable decision with full
  context (canonical URL + title, what/why, why-now, completed proof state,
  tradeoffs/risks, recommendation, exact choices). Delivered as a cross-session
  message to TJ's active session **and** recorded in the ledger. Format and delivery
  in [`references/policy.md`](references/policy.md).
- **Ledger:** compact, repo-scoped at `.ralph/orchestrator/ledger.json` (no raw
  triage dumps or full issue bodies). Schema in
  [`references/policy.md`](references/policy.md).
- **Drain closeout (prd-run):** post a summary, write the ledger closeout, and
  **stop cleanly** — do not auto-jump into `repo-maintain`.

## Non-negotiables

- **Dry-run / plan = zero mutations.** No `gh` issue/PR writes, no
  `--enqueue`/`--enqueue-prd`, no `orchestrateRun`/launch, no `triage --live`. Only
  read-only CLI (`triage --dry-run --json`, `launch.sh --status`, `gh ... view/list`).
- Never relabel issues, create canonical labels, or rewrite `.ralph/config.json`
  `issue.issueSearch` autonomously.
- Never run worker work yourself, and spawn at most one sub-agent for
  shaping/owner-brief reasoning — never one agent per slice.

## References

- [`modes/prd-run.md`](modes/prd-run.md) — PRD pipeline steps + dry-run plan output.
- [`modes/repo-maintain.md`](modes/repo-maintain.md) — scheduled sweep steps + V1 params.
- [`references/policy.md`](references/policy.md) — gates, hard stops, worker contract, owner-brief, ledger schema, ownership table.
- [`references/triage-contract.md`](references/triage-contract.md) — `triage --json` interface + escalation rule.
