# Mode: repo-maintain

The scheduled repo sweep — TJ's "Ready agent automation". Load this file only when
the orchestrator is acting on a schedule tick, not a single PRD. Shared rules
(gates, hard stops, worker contract, owner-brief, ledger) live in
`../references/policy.md`; the triage interface in `../references/triage-contract.md`.

```
hourly Copilot scheduled-workflow tick
  ──▶ ralph-orchestrator: repo-maintain
      pick repo → discover ready work → bound queue → launch(gated) → monitor
  ──▶ Ralph headless workers claim/implement
```

Entry: an hourly scheduled-workflow tick (no PRD). Fully autonomous, gated by the
authorization gates in policy.

## V1 parameters (reuse exactly)

- **Allowlist:** `alisterr`, `kindleflow`. No other repos in V1.
- **Per tick:** at most **1** new repo run.
- **Per new run:** at most **3** issues, **1** worker.
- **Selection order:** round-robin by *last successful automated start* (oldest
  first), tracked in the ledger.
- **Skip** issues with an open linked PR, or with a local Ralph duplicate already in
  flight.
- **Read** each repo's `issue.issueSearch` from its `.ralph/config.json`; **never
  rewrite it.**

## Steps

1. **Concurrency check first.** For each candidate repo, check for a live run
   (`.ralph/launch.sh --status`, or a non-terminal `.ralph/runs/<runId>/status.json`).
   If a run is active, **report and defer** — record it in the ledger and do not
   modify that repo. One active run per repo (policy "Concurrency").

2. **Pick one repo** from the allowlist by round-robin (oldest last-successful-start
   first), skipping repos with an active run.

3. **Label precondition.** If the chosen repo lacks the canonical `ralph:*` labels,
   **skip it** and emit a **one-time** owner brief containing the exact label-creation
   commands (see `docs/labels.md`). Do **not** autonomously create labels or migrate
   a legacy taxonomy. Mark the brief as sent in the ledger so it is not repeated.

4. **Discover ready work via the CLI.** Read the repo's `issue.issueSearch` from
   `.ralph/config.json` and run it read-only
   (`gh issue list --search "<issueSearch>" --json number,title,labels,url`). Only
   `ralph:ready` + `work:slice|standalone`, open, unassigned, no unresolved blocker
   issues qualify. Optionally run `triage --dry-run --json` for classification
   confidence; escalate to the advisory agent only by exception
   (`../references/triage-contract.md`).

5. **Build a bounded queue.** Take up to 3 qualifying issues (lowest-number first
   within the ready set), dropping any with an open linked PR or a local Ralph
   duplicate. If nothing qualifies, record "no ready work" in the ledger and stop
   for this tick.

6. **Launch behind the gate.** With policy's authorization gates satisfied, launch
   through the `ralph_dashboard_orchestrate` tool (wraps `orchestrateRun()`) with the
   bounded queue and `parallelism: 1`. If `allowAgentLaunch` is not enabled (or
   `orchestrateRun` is unavailable), do not launch — emit the gate hard stop and
   stop. Never call `launch.sh --start`/`--foreground`.

7. **Record + monitor.** Write `runId` / `runDir` / worker id and the queued issues
   to the ledger; update `last successful automated start` for the repo on a clean
   launch. Poll `.ralph/runs/<runId>/status.json` on state change or every ~2–5 min.
   Let workers run; intervene only on hard-stop evidence (worker-stall brief on
   repeated same-slice failure).

8. **Next tick.** Each tick is independent: re-check concurrency, advance the
   round-robin, and respect the ≤1-new-run-per-tick cap. Do not batch multiple repos
   in one tick.

## Dry-run / plan mode (zero mutations)

When mutations are not authorized, produce the plan without executing steps 6 — no
`orchestrateRun`/launch, no `gh` writes, no `triage --live`, no ledger write. Use
only read-only calls (`gh issue list --search …`, `launch.sh --status`,
`triage --dry-run --json`). Emit:

1. **Mode detection** — `repo-maintain`, the tick source.
2. **Concurrency report** — per allowlist repo: active run? defer?
3. **Repo pick** — chosen repo + why (round-robin position); label-precondition
   status (and the one-time brief if labels are missing).
4. **Ready-work discovery** — the `issue.issueSearch` used and the qualifying issues
   (compact, one line each).
5. **Bounded queue** — the ≤3 issues that would be queued, with skips explained.
6. **Gated launch decision** — each authorization gate + status; LAUNCH or HARD STOP.
7. **Ledger JSON** — the object that *would* be written. Shown, not written.

If a hard stop or label precondition is reached, also render the owner-decision
brief (policy format).
