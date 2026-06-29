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
repo's own session** — `REPO_ROOT` is that repo, and by design the orchestrator acts
on that repo only. The allowlist, round-robin, and ≤1-new-run-per-tick cap are
enforced by the **fan-out automation** that decides which repo sessions tick. A tick
launches its own session's `REPO_ROOT`; launching a *different* allowlisted checkout
is supported by the tooling (`ralph_dashboard_orchestrate` accepts an absolute
`repoRoot` gated by `orchestrateAllowedRepoRoots` — see "Tooling prerequisites") but
remains the fan-out automation's job, not something one session does ad hoc. Fully
autonomous, gated by the authorization gates in policy.

> **Read-only / launch-only sweep.** A repo-maintain tick discovers ready work
> read-only and, behind the gate, launches workers. It **closes nothing** — not
> slices, not PRDs. Closing a fully-delivered `work:prd` parent is a **separate,
> opt-in reconcile** (policy "PRD parent close"), exposed only via
> `node extension/cli.mjs orchestrate-repo --close-completed-prds [--dry-run]`. It
> is OFF by default and never runs as part of this sweep. Like the launch path, a
> non-default `--repo-root` is validated against `orchestrateAllowedRepoRoots`
> before any close, so the reconcile can only ever touch an allowlisted checkout.

## V1 parameters (reuse exactly)

The **allowlist** and **round-robin / per-tick cap** are properties of the **fan-out
automation** (the scheduler that ticks repo sessions), not of a single session:

- **Allowlist:** `alisterr`, `kindleflow`, `ralph-loop-dashboard`. No other repos in
  V1 — only these repos' sessions are ticked.
- **Per tick (global):** at most **1** new repo run across the allowlist.
- **Selection order:** round-robin by *last successful automated start* (oldest
  first), tracked in the ledger.

> **Current deployment note (informational, not the spec).** The orchestrator
> workflows actually enabled today are `ralph-loop-dashboard` (daily) and `alisterr`
> (daily); `kindleflow` is on the normative V1 allowlist above but is not yet ticked.
> All three are now on the normative V1 allowlist above.
> This note records what is wired up now — the bullet list above remains the V1
> design spec and is the source of truth for the allowlist.

Within a single repo session's tick:

- **Per new run:** at most **10** issues, **1** worker.
- **Skip** issues with an open linked PR, or with a local Ralph duplicate already in
  flight.
- **Read** this repo's `issue.issueSearch` from its `.ralph/config.json`; **never
  rewrite it.**

## Tooling prerequisites

repo-maintain runs as a **per-repo session** by design — the fan-out automation owns
the allowlist, round-robin, and per-tick cap. The underlying tools now support
targeting other repos (#94 and #95 have landed); a single session simply defers that
fan-out to the scheduler rather than reaching across repos ad hoc:

- `ralph_dashboard_orchestrate` accepts `issueNumbers` / `queue` / `runOptions` /
  `verify` / `timeoutMinutes` **and** an optional absolute `repoRoot`. A non-default
  `repoRoot` is gated by `orchestrateAllowedRepoRoots` and must be a real local
  checkout that contains `.ralph/` (the gitignored, local-only Ralph install). Absent
  `repoRoot`, it launches the extension's resolved `REPO_ROOT`. (#94, landed.)
- `triage` accepts a repeatable **`--repo OWNER/NAME`** flag, so the triage primitive
  can classify one or more explicit repos in a single run (the scheduled triage
  workflow uses it). Without `--repo` it targets the configured default repo. `--repo`
  selects repos **by name** and is independent of the `orchestrateAllowedRepoRoots`
  launch allowlist. (#95, landed.)

A repo-maintain tick still operates on its own session's `REPO_ROOT`: cross-checkout
launch is possible only against an allowlisted local checkout that contains `.ralph/`,
and choosing which repos tick is the fan-out automation's job, not one session's.

## Steps

Every step operates on **this session's repo** (`REPO_ROOT`) — the allowlist repo the
tick fired for. The orchestrator does not reach into other repos.

1. **Confirm the target.** This tick runs inside one allowlist repo's session;
   `REPO_ROOT` is that repo. Confirm it is on the allowlist (`alisterr`,
   `kindleflow`, `ralph-loop-dashboard`); if not, stop — repo-maintain only runs for
   allowlist repos. The
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
   issues qualify. Triage classification covers this session's repo by default and can
   also cover explicit repos via `triage --repo OWNER/NAME` (see "Tooling
   prerequisites" and `../references/triage-contract.md`); escalate to the advisory
   agent only by exception.

5. **Build a bounded queue.** Take up to 10 qualifying issues (highest priority
   first, then lowest-number within a priority band), dropping any with an open
   linked PR or a local Ralph duplicate. If nothing qualifies, record "no ready
   work" in the ledger and stop for this tick.

6. **Launch behind the gate.** With policy's authorization gates satisfied, launch
   through the `ralph_dashboard_orchestrate` tool (wraps `orchestrateRun()`) with the
   bounded queue and `parallelism: 1`. The launch targets this session's `REPO_ROOT`
   (a repo-maintain tick does not pass a non-default `repoRoot`; cross-checkout launch
   via the gated `repoRoot` is the fan-out automation's job — see "Tooling
   prerequisites"). If
   `allowAgentLaunch` is not enabled (or `orchestrateRun` is unavailable), do not
   launch — emit the gate hard stop and stop. Never call
   `launch.sh --start`/`--foreground`.

7. **Record + monitor.** Write `runId` / `runDir` / worker id and the queued issues
   to the ledger; update `last successful automated start` for the repo on a clean
   launch. Poll `.ralph/runs/<runId>/status.json` on state change or every ~2–5 min.
   Let workers run; intervene only on hard-stop evidence. Repeated deterministic
   implementation/code-shape failures on the same slice get a `worker-stall` owner
   brief; transient runtime/network/Copilot API outages and no-delivery worker exits
   are recorded and surfaced, but do not permanently poison a ready issue.

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
5. **Bounded queue** — the ≤10 issues that would be queued, with skips explained.
6. **Gated launch decision** — each authorization gate + status; LAUNCH or HARD STOP.
   The launch would target this session's `REPO_ROOT` (a tick does not pass a
   non-default `repoRoot` — see "Tooling prerequisites").
7. **Ledger JSON** — the object that *would* be written. Shown, not written.

If a hard stop or label precondition is reached, also render the owner-decision
brief (policy format).
