# Mode: repo-maintain

The scheduled repo sweep — TJ's "Ready agent automation". Load this file only when
the orchestrator is acting on a schedule tick, not a single PRD. Shared rules
(gates, hard stops, worker contract, owner-brief, ledger) live in
`../references/policy.md`; the triage interface in `../references/triage-contract.md`.

```
hourly Copilot scheduled tick (one per allowlist repo session)
  ──▶ ralph-orchestrator: repo-maintain (runs inside THIS repo's session)
      discover ready work → bound queue → launch(gated) → monitor
  ──▶ Ralph headless workers claim/implement
```

Entry: an hourly scheduled-workflow tick (no PRD). **A tick runs inside one allowlist
repo's own session** — `REPO_ROOT` is that repo, and the orchestrator acts on that
repo only. It does **not** pick among repos or launch a different repo remotely: the
current `ralph_dashboard_orchestrate` tool can only launch its own session's
`REPO_ROOT` (see "Tooling prerequisites"). The allowlist, round-robin, and
≤1-new-run-per-tick cap are enforced by the **fan-out automation** that decides which
repo sessions tick — not by one session reaching across repos. Fully autonomous,
gated by the authorization gates in policy.

> **Read-only / launch-only sweep.** A repo-maintain tick discovers ready work
> read-only and, behind the gate, launches workers. It **closes nothing** — not
> slices, not PRDs. Closing a fully-delivered `work:prd` parent is a **separate,
> opt-in reconcile** (policy "PRD parent close"), exposed only via
> `node extension/cli.mjs orchestrate-repo --close-completed-prds [--dry-run]`. It
> is OFF by default and never runs as part of this sweep.

## V1 parameters (reuse exactly)

The **allowlist** and **round-robin / per-tick cap** are properties of the **fan-out
automation** (the scheduler that ticks repo sessions), not of a single session:

- **Allowlist:** `alisterr`, `kindleflow`. No other repos in V1 — only these repos'
  sessions are ticked.
- **Per tick (global):** at most **1** new repo run across the allowlist.
- **Selection order:** round-robin by *last successful automated start* (oldest
  first), tracked in the ledger.

Within a single repo session's tick:

- **Per new run:** at most **3** issues, **1** worker.
- **Skip** issues with an open linked PR, or with a local Ralph duplicate already in
  flight.
- **Read** this repo's `issue.issueSearch` from its `.ralph/config.json`; **never
  rewrite it.**

## Tooling prerequisites

Cross-repo orchestration from a *single* session is not yet supported, which is why
repo-maintain runs as a **per-repo session**:

- `ralph_dashboard_orchestrate` exposes only `issueNumbers` / `queue` / `runOptions` /
  `verify` / `timeoutMinutes` — it has **no repo parameter** and always launches the
  extension's resolved `REPO_ROOT`. A single session cannot launch a different
  allowlist repo. (Tracked: #94.)
- `triage` is hardcoded to the default repo (`tjegbejimba/ralph-loop-dashboard`) with
  **no `--repo` flag**, so the triage primitive can only classify that repo. (Tracked:
  #95.)

Until #94 and #95 land, each allowlist repo must be swept by its own session, and
launch targets that session's `REPO_ROOT`. Do not attempt to launch or triage another
repo from this session.

## Steps

Every step operates on **this session's repo** (`REPO_ROOT`) — the allowlist repo the
tick fired for. The orchestrator does not reach into other repos.

1. **Confirm the target.** This tick runs inside one allowlist repo's session;
   `REPO_ROOT` is that repo. Confirm it is on the allowlist (`alisterr`,
   `kindleflow`); if not, stop — repo-maintain only runs for allowlist repos. The
   fan-out automation already applied round-robin and the ≤1-new-run-per-tick cap when
   it chose to tick this session.

2. **Concurrency check.** Check this repo for a live run (`.ralph/launch.sh --status`,
   or a non-terminal `.ralph/runs/<runId>/status.json`). If a run is active, **report
   and defer** — record it in the ledger and do not modify the repo. One active run
   per repo (policy "Concurrency").

3. **Label precondition.** If this repo lacks the canonical `ralph:*` labels, **skip
   it** and emit a **one-time** owner brief containing the exact label-creation
   commands (see `docs/labels.md`). Do **not** autonomously create labels or migrate
   a legacy taxonomy. Mark the brief as sent in the ledger so it is not repeated.

4. **Discover ready work via the CLI.** Read this repo's `issue.issueSearch` from
   `.ralph/config.json` and run it read-only (`gh issue list --search "<issueSearch>"
   --json number,title,labels,url` — `gh` defaults to the session's repo). Only
   `ralph:ready` + `work:slice|standalone`, open, unassigned, no unresolved blocker
   issues qualify. Triage classification is available only for the default repo
   (`triage` has no `--repo` flag — see "Tooling prerequisites" and
   `../references/triage-contract.md`); escalate to the advisory agent only by
   exception.

5. **Build a bounded queue.** Take up to 3 qualifying issues (lowest-number first
   within the ready set), dropping any with an open linked PR or a local Ralph
   duplicate. If nothing qualifies, record "no ready work" in the ledger and stop
   for this tick.

6. **Launch behind the gate.** With policy's authorization gates satisfied, launch
   through the `ralph_dashboard_orchestrate` tool (wraps `orchestrateRun()`) with the
   bounded queue and `parallelism: 1`. The launch targets this session's `REPO_ROOT`
   (the tool has no repo parameter — see "Tooling prerequisites"). If
   `allowAgentLaunch` is not enabled (or `orchestrateRun` is unavailable), do not
   launch — emit the gate hard stop and stop. Never call
   `launch.sh --start`/`--foreground`.

7. **Record + monitor.** Write `runId` / `runDir` / worker id and the queued issues
   to the ledger; update `last successful automated start` for the repo on a clean
   launch. Poll `.ralph/runs/<runId>/status.json` on state change or every ~2–5 min.
   Let workers run; intervene only on hard-stop evidence (worker-stall brief on
   repeated same-slice failure).

8. **Next tick.** Each tick is independent and scoped to its own repo session:
   re-check concurrency for this repo. The fan-out automation advances the
   round-robin and enforces the ≤1-new-run-per-tick cap across the allowlist; a single
   session does not batch or reach into other repos.

## Dry-run / plan mode (zero mutations)

When mutations are not authorized, produce the plan without executing steps 6 — no
`orchestrateRun`/launch, no `gh` writes, no `triage --live`, no ledger write. Use
only read-only calls (`gh issue list --search …`, `launch.sh --status`,
`triage --dry-run --json`). Emit:

1. **Mode detection** — `repo-maintain`, the tick source, and this session's repo
   (`REPO_ROOT`).
2. **Target + concurrency** — confirm this repo's allowlist membership and whether a
   run is already active (defer?). (Allowlist / round-robin / ≤1-run-per-tick are the
   fan-out automation's concern — note them as context, not a cross-repo action.)
3. **Label precondition** — canonical `ralph:*` labels present for this repo? If
   missing, render the skip + one-time owner brief.
4. **Ready-work discovery** — the `issue.issueSearch` used (this repo) and the
   qualifying issues (compact, one line each).
5. **Bounded queue** — the ≤3 issues that would be queued, with skips explained.
6. **Gated launch decision** — each authorization gate + status; LAUNCH or HARD STOP.
   The launch would target this session's `REPO_ROOT` (no cross-repo target — see
   "Tooling prerequisites").
7. **Ledger JSON** — the object that *would* be written. Shown, not written.

If a hard stop or label precondition is reached, also render the owner-decision
brief (policy format).
