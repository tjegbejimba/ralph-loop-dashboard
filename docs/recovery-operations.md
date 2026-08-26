# Recovery Operations and Migration

This document describes Ralph's recovery and reset behavior for operators and maintainers. It covers:

1. **Backwards compatibility** — how Ralph handles old-format state files
2. **Stale worker reconciliation** — what happens when workers die unexpectedly
3. **Terminal failure exclusion** — why exhausted failures don't auto-retry
4. **Reset budget operation** — how operators can manually retry terminal failures
5. **PRD ownership recovery** — how published branches transfer between runs
6. **Legacy integrated-slice reconciliation** — how operators repair missing canonical evidence

---

## Backwards Compatibility

Ralph's recovery ledger was introduced in PRD #172 (Slices #173-#178). Before that, Ralph tracked state through:
- `.ralph/state.json` (worker claims)
- `.ralph/runs/<RUN_ID>/status.json` (per-run item status)
- GitHub labels (`ralph:running`, `ralph:failed`, etc.)

### Migration Behavior

**Old-format `state.json` and `status.json` files load without crashing.** Missing recovery ledger fields are interpreted conservatively:

- Issues with `status: "claimed"` or `status: "running"` but no recovery ledger entry are treated as **non-recoverable** (no PR/branch evidence).
- Issues with `status: "failed"` but no ledger entry are **terminal** (no auto-retry).
- The recovery ledger file (`.ralph/recovery-ledger.json`) is created on-demand when first needed.

**Implications for operators:**
- After upgrading to the recovery-ledger feature, existing runs continue normally.
- Old failed items will NOT auto-retry unless you explicitly reset them (see "Reset Budget Operation" below).
- Stale `ralph:running` labels from pre-recovery versions are reconciled (see next section).

---

## Zero-Registration PRD Recovery

A launcher can crash after creating PRD branch ownership but before a worker
registers. Ralph treats this differently from a terminal run. Queue contents
record intent, not progress, so they do not make a run active by themselves.

Current launchers publish the owned integration branch before worker startup. A
replacement same-PRD launch transfers that published ownership only when all of
the following are positively proven:

- `status.json` exists, is valid, and has an empty `items` object.
- `state.json` exists, is valid, and has an empty `claims` object.
- The run has no Copilot session ledger.
- The current launcher owns both setup locks, including matching launch tokens
  when controller-owned.
- Any launcher pidfile resolves to the current Bash PID (or its native Windows
  PID), and strict process inspection succeeds with no Ralph worker process.
- `git worktree list` succeeds and contains no other linked worktree. Ralph
  cannot safely distinguish an unregistered worker worktree from an unrelated
  one, so either blocks this exceptional recovery path.
- The integration branch has no worktree or pull request.
- The local branch, when present, either equals the remote tip or is a verified
  ancestor that can be compare-and-swap fast-forwarded after transfer.
- The remote tip still equals the run's owned tip and descends from the
  immutable initial base. Zero-registration recovery never adopts later remote
  movement; terminal recovery accepts a later tip only when it exactly matches
  a recorded `slice-integrated` commit and every recorded integrated commit is
  in that tip's history.

Missing or malformed evidence fails closed. Terminal runs retain their existing
transfer path, which may preserve delivered commits beyond the tip owned at
startup when the complete run is terminal and the remote history remains
linear. Transfer writes `transfer_pending` before creating the new run's
ownership record, then clears the prior active-run marker and retires the prior
record. The intended replacement run can finish this sequence idempotently
after an interrupted write. If orchestration has already minted a later run ID,
that run first completes the recorded handoff, then performs a separately
guarded zero-registration transfer from the abandoned intermediate owner. This
preserves the complete ownership audit chain without retargeting or deleting
staged evidence.

`launch.sh --cleanup` never deletes a remote PRD branch. For backwards
compatibility, a replacement launch or cleanup may retire a branch created by
an older installer that has no remote ref. That legacy local-only path still
requires the branch to equal its frozen base and stages `retirement_pending`
before deleting the local ref with an expected-old-object update. If a later
state or ownership write fails, the next cleanup can finish that specific
staged deletion without treating an arbitrary missing branch as safe.

## Published PRD Ownership Transfer

Every new ownership record freezes both `initial_base_sha` and `owned_tip_sha`.
The first run records the fetched delivery head for both values and publishes
that exact commit with an expected-empty remote lease. A replacement run
preserves `initial_base_sha`, records the stable remote handoff commit as its
new `owned_tip_sha`, and links back with `resumed_from_run_id`.

Transfer fails closed when ownership is ambiguous, PRD or repository settings
change, a live worker or claim remains, the branch is checked out, GitHub PR
evidence exists or cannot be queried, local and remote tips disagree, history
does not descend from the owned commits, terminal slice-delivery evidence does
not account for the exact remote tip, or the remote tip changes during the
handoff. Ralph never force-updates or deletes the published branch during this
path; it only compare-and-swap fast-forwards a stale local ref after durable
transfer evidence exists.

Normal PRD launch writes the `setup-locks-acquired` startup phase before remote
PRD initialization. This prevents a healthy but slow pre-registration launch
from being killed solely because ownership setup has not yet produced a worker
status item.

---

## Legacy Integrated-Slice Reconciliation

Use `.ralph/reconcile-slice.sh` only when a prior terminal PRD run delivered a
slice to its owned integration branch but retained legacy `merged` status
instead of canonical `slice-integrated` evidence. Never call
`record_slice_integrated` directly and never hand-edit `status.json`.

The command has a mandatory two-step contract. Dry-run independently proves the
local, GitHub, process, worktree, ownership, and branch evidence and emits one
JSON proof. Apply requires that reviewed proof, acquires both launcher setup
locks and the shared state lock, then repeats every proof while locked before
atomically replacing `status.json`.

```bash
# Run from the target repository in Bash (including Git Bash on Windows).
proof_file="$(mktemp "${TMPDIR:-/tmp}/ralph-reconcile-507.XXXXXX.json")"

.ralph/reconcile-slice.sh \
  --run 20260825-184631-43b25623 \
  --prd 505 \
  --issue 507 \
  --pr 533 \
  --dry-run >"$proof_file"

# Review the complete proof before applying it.
jq . "$proof_file"

.ralph/reconcile-slice.sh \
  --run 20260825-184631-43b25623 \
  --prd 505 \
  --issue 507 \
  --pr 533 \
  --apply \
  --proof "$proof_file"
```

The dry-run succeeds only when all of these facts are unambiguous:

- The run ID, PRD, queue, status, run metadata, Ralph config, and one active
  ownership record agree. The metadata resolves to the current repository
  (including native Windows paths), the run is terminal, and ownership is
  neither transferring nor retiring. Configured repository, remote, delivery
  branch, and issue-branch prefix must match the ownership evidence.
- `state.json` is valid, has no claims, and does not name another active run.
- Strict process inspection finds no scoped launcher or worker; no launcher
  pidfile, launcher/worker lock, or linked worktree exists.
- The issue is closed with a closure timestamp. The exact PR exists, is merged,
  targets the owned integration branch, comes from the same repository, and
  uses the configured `<prefix><issue>-...` head. Its GitHub closing references
  or body closing keyword must name the issue.
- Issue closure must independently point to that PR, either through GitHub's
  closing-PR references or one exact OWNER/MEMBER/COLLABORATOR closure comment
  written between PR merge and issue closure. This supports non-default-base
  integration PRs such as `Closes #507`, which GitHub does not auto-close.
- Exhaustive paginated inspection finds no live PR from the integration branch
  and no other open PR whose body or canonical issue head claims the slice.
- The configured Git remote is a network URL for the same GitHub `owner/repo`
  returned by the API. Local and path-like remotes are rejected.
- The remote branch exists at one exact tip, descends from both frozen ownership
  commits, and does not conflict with a local branch tip. The target merge must
  be a strict descendant of the run's frozen owned tip, so a historical merge
  cannot be attributed to a later run.
- Git replacement refs and legacy grafts must be absent. Ancestry checks also
  disable replacement objects explicitly.
- The PR merge commit equals the current remote integration-branch tip exactly.
  Descendant commits are rejected even if they have other canonical status
  evidence; an operator must reconcile against an unambiguous exact tip.
- Existing evidence is either the expected legacy `merged` item, or identical
  canonical evidence. Conflicting PR, commit, or provenance fails closed.

The proof records the authenticated GitHub operator, repository, run/PRD/issue/
PR identities, issue closure source and time, exact PR body linkage, head and
head repository, URLs, merge time and commit, config and run-metadata binding,
ownership branch and remote, exact remote tip, prior status evidence, and proof
timestamp. Apply stores that reviewed proof under
`items["<issue>"].reconciliation`, adds its own apply timestamp and source
`operator-guarded-reconciliation`, then invokes the normal slice-integration
lifecycle helper to atomically replace the item with canonical fields:

```json
{
  "status": "slice-integrated",
  "pr_number": "533",
  "integrated_commit": "<verified merge commit>",
  "integrated_at": "<reconciliation apply time>"
}
```

If any API call, JSON parse, process inspection, fetch, lock, atomic rename, or
revalidation fails, no canonical evidence is written. If evidence changes after
dry-run, discard the proof and start again. Reapplying the same proof, or
applying a fresh proof to identical canonical evidence, returns `unchanged`
without rewriting status.

## Stale Worker Reconciliation

Ralph workers can die unexpectedly (process killed, machine crash, network loss). When this happens:

### Detection

Every run uses `status_reconcile_stale_workers` to detect dead workers:
- Checks every item with `status: "running"` or `status: "claimed"`
- Uses `is_pid_alive_and_ralph` to verify the worker PID is still running
- If PID is dead (or process isn't ralph-related), marks the item `status: "failed"` with error `"Worker died"`

### Recovery Ledger Preservation

**Key invariant:** Worker death does NOT clear recovery ledger entries.

If a worker opened a PR (`slice-<N>-*` branch) and recorded recovery evidence before dying, that evidence is preserved:
- `status.json` shows `status: "failed"` (worker died)
- `recovery-ledger.json` still shows `status: "recoverable"` with PR/branch
- After the cooldown period (5 minutes), another worker can pick up the recoverable work

**Without recovery evidence:**
- Worker died before opening a PR → `status: "failed"`, no ledger entry → **terminal** (no auto-retry)

### Stale `ralph:running` Labels

GitHub labels are coarse workflow signals, not the source of truth. After reconciliation:
- Dead worker → status becomes `failed`
- If recoverable, label should be `ralph:queued` (not `ralph:running`)
- If terminal, label should be `ralph:failed`

Operators can manually fix stale labels or rely on the next run to reconcile them. **The recovery ledger is authoritative**, not the label.

---

## Terminal Failure Exclusion

Ralph uses a **bounded retry budget** (default: 2 automatic attempts per issue). After exhausting the budget:

### Terminal State

An issue becomes **terminal** when:
- Attempt counter reaches `RALPH_RETRY_BUDGET + 1` (e.g., 3 attempts with default budget of 2)
- Recovery ledger shows `status: "failed"` and `state: "terminal"`
- Terminal reason recorded: `"Retry budget exhausted (3 > 2)"`

### What Terminal Means

**Terminal items are NOT auto-picked:**
- `ledger_is_recoverable` returns false for terminal items
- Workers skip terminal entries when claiming work
- `repo-maintain` queue discovery excludes terminal items
- Dashboard shows terminal items separately from recoverable work

**Why this is safe:**
- Prevents infinite retry loops on broken requirements or flaky tests
- Forces human review of repeated failures
- Preserves PR/branch evidence for debugging

### Labels for Terminal Items

Terminal items should have:
- GitHub label: `ralph:failed` (not `ralph:queued`)
- Recovery ledger: `status: "failed"`, `state: "terminal"`

---

## Reset Budget Operation

Operators can **reset the retry budget** to manually retry terminal failures after fixing the root cause.

### When to Reset

Use `ledger_reset_budget` after:
- Fixing a bug that caused repeated failures
- Updating a flaky test
- Resolving a transient infrastructure issue
- Clarifying ambiguous requirements

### How to Reset

```bash
# In a repo with Ralph installed:
cd /path/to/repo
. .ralph/lib/state.sh
. .ralph/lib/recovery-ledger.sh

# Reset issue 42 with PR 123 and branch slice-42-fix:
ledger_reset_budget "42" "123" "slice-42-fix"
```

### What Reset Does

**Clears terminal state:**
- `attempt: 0` (retry counter reset)
- `status: "recoverable"` (no longer failed)
- `terminal_reason: null` (cleared)
- `state: null` (no longer terminal)

**Preserves evidence:**
- PR number (updates if you provide a new one)
- Branch name (updates if you provide a new one)
- Sets 5-minute cooldown (`nextRetryAt`)

**Does NOT:**
- Delete the PR or branch
- Force-push or rewrite history
- Close the GitHub issue
- Modify label state (you may need to manually change `ralph:failed` → `ralph:queued`)

### After Reset

The issue becomes **recoverable** again:
- `ledger_is_recoverable` returns true
- Workers can claim it after the cooldown
- `repo-maintain` can re-queue it
- Retry budget is restored (2 more attempts)

---

## Summary for Operators

| Scenario | State File | Recovery Ledger | Auto-Retry? | Action |
|----------|------------|-----------------|-------------|--------|
| Old-format status.json | `status: "failed"` | (missing) | No | Reset budget if retry desired |
| Worker died, no PR | `status: "failed"` | (missing) | No | Investigate + reset if needed |
| Worker died, has PR | `status: "failed"` | `status: "recoverable"` | Yes (after cooldown) | Wait for auto-retry |
| Budget exhausted | `status: "failed"` | `status: "failed", state: "terminal"` | No | Fix root cause + reset budget |
| After reset | (unchanged) | `status: "recoverable"` | Yes (after cooldown) | Issue is re-queued |

---

## See Also

- [Recovery Ledger Tests](../test/recovery-ledger.test.sh) — unit tests for ledger operations
- [Stale Worker Reconciliation Tests](../test/stale-worker-reconciliation.test.sh) — worker death scenarios
- [Terminal Failed Exclusion Tests](../test/terminal-failed-exclusion.test.sh) — terminal state behavior
- [Reset Budget Tests](../test/reset-budget-requeue.test.sh) — reset operation coverage
- [Labels Documentation](./labels.md) — label lifecycle and taxonomy
