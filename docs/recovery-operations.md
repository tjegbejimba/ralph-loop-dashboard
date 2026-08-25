# Recovery Operations and Migration

This document describes Ralph's recovery and reset behavior for operators and maintainers. It covers:

1. **Backwards compatibility** — how Ralph handles old-format state files
2. **Stale worker reconciliation** — what happens when workers die unexpectedly
3. **Terminal failure exclusion** — why exhausted failures don't auto-retry
4. **Reset budget operation** — how operators can manually retry terminal failures
5. **Zero-registration PRD recovery** — how pre-worker crashes retire ownership

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

`launch.sh --cleanup` and a replacement launch may retire that ownership only
when all of the following are positively proven:

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
- The integration branch has no worktree, pull request, or remote ref.
- The local branch still equals the ownership record's frozen base.

Missing or malformed evidence fails closed. Terminal runs retain their existing
recovery path. A successful zero-registration retirement records
`retirement_reason` as
`abandoned before worker registration (zero-item guarded recovery)`, rechecks
the ownership document under the state lock, and deletes the local ref with its
expected old SHA before committing the retirement record. Before deleting the
ref, Ralph durably writes `retirement_pending` with the reason and expected tip.
If a later state or ownership write fails, the next cleanup can finish that
specific staged deletion without treating an arbitrary missing branch as safe.

Normal PRD launch writes the `setup-locks-acquired` startup phase before remote
PRD initialization. This prevents a healthy but slow pre-registration launch
from being killed solely because ownership setup has not yet produced a worker
status item.

---

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
