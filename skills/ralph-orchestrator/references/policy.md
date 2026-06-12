# ralph-orchestrator — shared policy

Authoritative, mode-agnostic policy for the orchestrator. Both `modes/prd-run.md`
and `modes/repo-maintain.md` reference this file; do not duplicate it.

The orchestrator is a **control plane**. It consumes structured signals, applies
gates, builds a bounded queue, launches behind those gates, monitors, and writes
a ledger. It never claims, implements, reviews, or merges work itself — that is
the headless Ralph worker's job (see "Worker contract").

## Ownership boundary

| Actor | Owns |
| --- | --- |
| **Ralph CLI** (`extension/cli.mjs`, `.ralph/launch.sh`) | Query/snapshot, taxonomy + preflight, baseline triage JSON, fingerprinted advisory comment create/update, enqueue, launch (`orchestrateRun`), verify. |
| **`to-issues` skill** | PRD → slice authoring (a reasoning task — never build a CLI slicer). |
| **`ralph-issue-triage-agent` skill** | Optional advisory reasoning over a **frozen** triage snapshot only. No writes/discovery/enqueue/launch. |
| **orchestrator** (this skill) | Consume structured output, apply gates, build the queue, launch behind gates, poll/monitor, owner briefs, ledger. Spawns a sub-agent ONLY for shaping/owner-brief reasoning — never one agent per slice. |
| **Ralph headless workers** | Claim + implement + test + dual-review + open/merge PR per `.ralph/RALPH.md`. |

The orchestrator never claims or merges. It never edits a worker's branch, PR, or
issue state. It observes worker progress through run state and triage/preflight CLI
output only.

## Authorization gates

A launch may proceed only when **all** of these hold. Otherwise pause and emit an
owner-decision brief.

1. **`allowAgentLaunch` is `true`** in the user-level Ralph dashboard config
   (`~/.ralph-dashboard/config.json`, default `false`). This is enforced inside
   `orchestrateRun()` — do not invent a second gate or bypass it.
2. **Preflight passes** for the normalized queue. `orchestrateRun()` treats a
   failed preflight as a hard blocker and refuses to launch.
3. **Autopilot context.** The agent-facing tool `ralph_dashboard_orchestrate`
   (which wraps `orchestrateRun`) is auto-permitted only in autopilot mode; in
   other modes the launch needs explicit operator approval.

### Launch contract (do not improvise)

Reuse the existing controller. Do **not** call `launch.sh --start`/`--foreground`
or any worker-start path directly.

```
orchestrateRun({ repoRoot, issueNumbers | queue, runOptions, userConfig, verify })
  → gate on userConfig.allowAgentLaunch === true
  → normalizeQueue → normalizeRunOptions
  → runPreflight (hard blocker)
  → createRun → launchRun (detached)
  → verifyRunStatus (optional; polls status.json until terminal)
```

In a Copilot CLI session, invoke this through the `ralph_dashboard_orchestrate`
tool. Agent launches default to `runMode: "until-empty"`.

> Availability: `orchestrateRun()` and `allowAgentLaunch` live in
> `extension/lib/loop-launch-controller.mjs` and are on `main`. If a checkout
> lacks them (older `main`, or the controller file is missing), do not improvise a
> launch — declare the absence in the ledger/brief and stop at the launch gate.

## Hard stops

Pause and emit an owner-decision brief (never auto-resolve) on any of:

1. **Preflight blockers** the orchestrator cannot auto-resolve.
2. **`allowAgentLaunch` not enabled.**
3. **A product decision** the PRD/issue does not answer.
4. **A worker that fails or stalls repeatedly** on the same slice (e.g. repeated
   `ralph:failed`, or a dead worker / non-terminal slice across poll cycles).
5. **Destructive or irreversible actions**: force-push to `main`, delete an issue,
   close an issue without a merged PR, rewrite history, label migration.
6. **Missing credentials or access** (`gh` auth, repo permissions, run dir
   unwritable).

Everything else is autonomous. The only human hand is at PRD creation; after
`to-prd` hands off a PRD number, the orchestrator creates/labels/enqueues/launches
without further confirmation, gated only by the authorization gates above.

## Auto-resolvable vs hard-stop preflight

Preflight warnings the orchestrator may reconcile autonomously by re-running the
canonical CLI path (not by mutating GitHub directly): `missing_priority` defaulting
to `priority:P2`, `RALPH.md` placeholder fixed by re-running `--enqueue-prd`, and
queue-mode confirmation. Anything requiring a label/state/product judgment
(`missing_state`, `missing_work_type`, `state_conflict`, `not_runnable_state`,
`unresolved_blocker`, `assigned`, `closed`, dirty tree) is a hard stop with an
owner brief — the orchestrator does not relabel or force a tree clean.

## Concurrency

**One active run per repo.** Before launching, check for an existing live run
(`.ralph/launch.sh --status`, or a non-terminal `.ralph/runs/<runId>/status.json`).
If a run is active, **report state and defer** — record the active repo in the
ledger and do not modify it. Active repos are reported, never mutated.

## Worker contract

Headless Ralph workers operate under `.ralph/RALPH.md` (operational law). They:
claim one ready issue, run strict TDD (red-green-refactor via the `tdd` skill),
run the repo's validation commands, dual-model code review (`gpt-5.5` quality +
`claude-opus-4.8` security), open a PR with a literal `Closes #<N>`, rebase, and
merge via the normal protected path (never `--admin`). Closure happens only via a
merged PR. The orchestrator must not pre-empt, resume, or finish a worker's slice;
on repeated worker failure it emits a hard-stop brief and leaves the evidence in
place.

## Monitoring

The orchestrator runs as a long-lived session. Poll `.ralph/runs/<runId>/status.json`
on run-state change or every ~2–5 minutes. Let active workers run; intervene only
on hard-stop evidence (gate 4 above). Do not poll faster than needed or restart
healthy workers.

## Owner-decision brief

When a hard stop fires, deliver a brief that is **one actionable decision with full
context**:

- **Canonical URL + title** of the issue/PRD/run.
- **What / why** in plain language.
- **Why now** (what is blocked while this waits).
- **Completed proof state** (what already passed: preflight, merges, triage).
- **Tradeoffs / risks** of each option.
- **The orchestrator's recommendation.**
- **The exact choices available** (decision options, not raw commands).

Keep it compact and decision-shaped. Do not dump raw `gh` output or full issue
bodies — cite URLs and short spans.

### Delivery

1. Send a cross-session message to TJ's active session (the creator session that
   handed off the PRD, or the session that owns the schedule tick).
2. Record the same brief in the ledger under `lastOwnerDecision` / `blockers`.

Then stop cleanly for that target until the owner responds. Do not loop or retry a
hard-stopped action.

## Ledger schema

Compact, repo-scoped state at `.ralph/orchestrator/ledger.json`. No raw triage
dumps, no full issue bodies — issue numbers, URLs, and short spans only. One ledger
object per repo (the file holds the most recent state for the active target).

```json
{
  "schemaVersion": "ralph-orchestrator/v1",
  "mode": "prd-run | repo-maintain",
  "target": {
    "repo": "owner/repo",
    "prd": 0,
    "prdUrl": "https://github.com/owner/repo/issues/N"
  },
  "phase": "validating | slicing | enqueueing | preflight | launching | monitoring | draining | done | paused",
  "queuedIssues": [{ "number": 0, "url": "", "priority": "P2" }],
  "run": { "runId": null, "workerIds": [], "runDir": null },
  "blockers": [
    { "kind": "allowAgentLaunch | preflight | product | worker-stall | destructive | access", "ref": "https://github.com/owner/repo/issues/N", "detail": "short span" }
  ],
  "lastOwnerDecision": { "at": "ISO-8601", "question": "", "choice": "", "by": "" },
  "concurrency": { "activeRunDetected": false, "deferred": false },
  "updatedAt": "ISO-8601"
}
```

`prd` is null/0 for `repo-maintain`. `run` stays null until a gated launch
succeeds. On clean drain, set `phase: "done"` and write a closeout (summary + final
queue outcomes); do **not** auto-start another mode.

## Non-negotiables

- **Dry-run / plan requests perform zero mutations**: no `gh` issue/PR writes, no
  `--enqueue`/`--enqueue-prd`, no `orchestrateRun`/launch, no `triage --live`. Only
  read-only CLI (`triage --dry-run --json`, `launch.sh --status`, `gh ... view/list`).
- The orchestrator never creates the canonical labels itself (see
  `modes/repo-maintain.md` precondition) and never rewrites `.ralph/config.json`
  `issue.issueSearch`.
- It spawns at most one sub-agent for shaping/owner-brief reasoning — never one
  agent per slice, and never to do worker implementation.
