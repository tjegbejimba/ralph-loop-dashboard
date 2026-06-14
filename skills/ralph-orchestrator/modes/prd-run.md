# Mode: prd-run

The PRD pipeline. Load this file only when the orchestrator is acting on a single
PRD. Shared rules (gates, hard stops, worker contract, owner-brief, ledger) live in
`../references/policy.md`; the triage interface in `../references/triage-contract.md`.

```
to-prd ──(PRD #N)──▶ ralph-orchestrator: prd-run ──▶ Ralph headless workers
                     validate → slice → enqueue → launch(gated) → monitor → drain
```

Entry: a PRD issue number, handed off automatically by `to-prd` or supplied by the
operator. After entry this mode is autonomous — no further confirmation — gated only
by the authorization gates in policy. The single human hand was PRD creation.

## Steps

1. **Anchor the PRD.** Resolve `#N` to its canonical URL and read it read-only
   (`gh issue view N --repo OWNER/REPO --json number,title,body,state,labels,url`).
   Initialize/refresh the ledger (`phase: "validating"`).

2. **Validate the PRD.** Require: open, exactly `work:prd`, exactly `ralph:evaluated`
   (PRD parents are evaluated, never a runnable state). If the labels/state are
   wrong or ambiguous, this is a **product/labeling hard stop** — emit an owner brief
   (the PRD is not shaped for autonomous slicing) and stop. Do not **relabel** a
   mislabeled PRD yourself. (Closing a *fully-delivered* PRD is different and is the
   orchestrator's to own — see step 8 and policy "PRD parent close".)

3. **Author slices via `to-issues`.** Invoke the existing `to-issues` skill to turn
   the PRD into independently-grabbable child slices. Slice authoring is a reasoning
   task — **never** build or call a CLI slicer. `to-issues` creates each child with
   an exact `Parent #N` marker and canonical labels (`work:slice`, a `priority:*`,
   and the state it assigns). Because the PRD grilling that produced these slices is
   itself the triage step, `to-issues` labels AFK slices as **born-runnable**
   (`ralph:ready` on canonical repos, `ready-for-agent` on legacy repos) and reserves
   a triage state only for HITL slices that still need a human decision — so AFK
   slices normally reach enqueue already runnable. The orchestrator consumes the
   resulting issue numbers; it does not hand-edit slice bodies.

4. **Enqueue via the Ralph CLI.** Run `./.ralph/launch.sh --enqueue-prd <N>` when the
   child slices are canonically labelled and carry the exact `Parent #N` marker, or
   `./.ralph/launch.sh --enqueue <N> [<N>...]` for an explicit set. `--enqueue-prd`
   also refreshes the `{{PRD_REFERENCE}}` marker in `.ralph/RALPH.md`. `launch.sh`
   runs preflight automatically and prints a structured report — read that; do not
   re-run `--status`.

5. **Resolve preflight.** Read the verdict and per-issue findings. Reconcile only the
   auto-resolvable ones via the canonical CLI path (see policy "Auto-resolvable vs
   hard-stop preflight"); re-run `--enqueue-prd` if you fixed a placeholder/priority
   default. Any label/state/blocker/dirty-tree finding is a **hard stop** → owner
   brief, then stop. A slice found in a non-runnable state (e.g.
   `not_runnable_state(ralph:needs-triage)`) is today one of these hard stops —
   though, because `to-issues` now births AFK slices runnable (step 3), it should be
   rare. (A future deterministic promotion path — the lane router / `ralph:evaluated`
   promotion in #106/#109 — may auto-recover this once implemented; until that code
   lands it is **not** an available recovery route and the hard stop stands.) Record
   queued issues + blockers in the ledger.

6. **Launch behind the gate.** Only when preflight verdict is ✅ and policy's
   authorization gates all hold, launch through the `ralph_dashboard_orchestrate`
   tool (which wraps `orchestrateRun()`), passing the queued issue numbers and
   letting run options default to `until-empty`. If `allowAgentLaunch` is not
   enabled (or `orchestrateRun` is unavailable in this checkout), do **not** launch —
   emit the gate hard stop and stop. Never call `launch.sh --start`/`--foreground`.

7. **Monitor.** Record `runId` / `runDir` / worker ids in the ledger
   (`phase: "monitoring"`). Poll `.ralph/runs/<runId>/status.json` on state change or
   every ~2–5 min. Let workers run. Intervene only on hard-stop evidence — a worker
   that fails or stalls repeatedly on the same slice gets a worker-stall owner brief;
   do not resume or finish the slice yourself.

8. **Drain, close the PRD, and stop cleanly.** When the queue is empty and every
   slice is terminal:
   - Post a summary (merged / failed / skipped per slice, with PR URLs).
   - **Close the PRD parent if it is fully delivered.** Evaluate policy's "PRD
     parent close" rule against the PRD and its child slices: the parent is OPEN
     and `work:prd`, it has ≥1 child (exact `Parent #N` marker), and **every**
     child is CLOSED via a **merged** PR. If all hold, close it as completed —
     `gh issue close <N> --reason completed` with a comment cross-linking the
     completed child slices and their merge PRs. If **any** slice is still open,
     was closed without a merged PR, or there are zero children, do **not** close
     the parent (leave it open; a failed/abandoned slice is a worker-stall or
     product decision, not a close). This is the only issue the orchestrator may
     close, and it never closes a slice/standalone or uses `--admin`.
   - Write a ledger closeout (`phase: "done"`, final per-issue outcomes, and the
     parent-close result).
   - **Stop.** Do **not** auto-jump into `repo-maintain` or pick up unrelated work.
     The run is finished when the PRD's slices are terminal and the parent is
     closed (or recorded as not-yet-closable).

## Dry-run / plan mode (zero mutations)

When the request is a dry run / plan (or any time mutations are not authorized),
produce the plan **without** executing steps 3, 4, 6 — no `to-issues` issue
creation, no `--enqueue*`, no `orchestrateRun`/launch, no `gh` writes, no
`triage --live`. Use only read-only calls: `triage --dry-run --json`,
`launch.sh --status`, `gh ... view/list`.

Emit exactly these sections:

1. **Mode detection** — `prd-run`, PRD `#N` + URL, and why this mode was chosen.
2. **PRD validation** — open? `work:prd`? `ralph:evaluated`? PASS, or the specific
   gap (and that a real run would hard-stop here).
3. **Triage summary (compact)** — from `triage --dry-run --json`, one line per issue
   per `../references/triage-contract.md` (`#N url — rec/priority/safety — why`). No
   raw dumps.
4. **Slice plan** — the slices `to-issues` would author (title, one-line scope,
   `Parent #N`, intended `work:slice` + `priority:*`, dependencies). Numbered, not
   created.
5. **Enqueue plan** — the exact command that *would* run
   (`./.ralph/launch.sh --enqueue-prd <N>`), the queue it would write, and the
   preflight findings to expect. Not executed.
6. **Gated launch decision** — state each authorization gate and its status:
   `allowAgentLaunch` (read `~/.ralph-dashboard/config.json`; absent ⇒ false),
   preflight verdict, autopilot context, and whether `orchestrateRun`/
   `ralph_dashboard_orchestrate` are available in this checkout. Conclude
   LAUNCH or HARD STOP with the reason.
7. **Ledger JSON** — the `.ralph/orchestrator/ledger.json` object that *would* be
   written (schema in policy), reflecting the plan and any blockers. Shown, not
   written.

If a hard stop is reached, also render the owner-decision brief (policy format) so
the operator can act.
