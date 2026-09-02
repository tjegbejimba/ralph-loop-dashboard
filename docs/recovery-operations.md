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
  movement; terminal recovery accepts a later tip only when every first-parent
  advancement is uniquely attributed to canonical `slice-integrated` evidence
  or separately recorded, operator-guarded HITL integration evidence.

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

This recovery command is distributed with Ralph's repository scripts. Refresh a
target checkout with `./install.sh <target-repository> --scripts-only`; no
dashboard extension refresh is required.

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
- The issue is closed with an exact closure timestamp and closing actor. The
  exact PR exists, is merged with a merge commit, targets the exact owned
  integration branch, comes from the same repository, and uses the configured
  `<prefix><issue>-...` head. Its merge timestamp cannot postdate issue closure.
- An exact same-repository `closingIssuesReferences` entry for the issue remains
  sufficient linkage. If GitHub returns no closing references, as it does for
  non-default-base integration PRs, every part of the independent fallback
  bundle below is mandatory, and the owned base must differ from the
  repository's current GitHub default branch.
- The PR body contains exactly one isolated, unindented closing directive for
  the exact issue, such as `Closes #507`. Directives embedded in prose,
  blockquotes, lists, fenced or indented code, raw HTML, or HTML comments are
  not accepted. GitHub-compatible keyword casing and an optional colon are
  recognized. Another directive, another issue, unsafe markup, or ambiguous
  parsing fails closed.
- The issue has exactly one Ralph-shaped integration comment with byte-exact
  text ``Merged via PR #<pr> into `<owned-branch>`.`` The comment must have been
  created exactly at issue closure, never edited, and authored by the issue's
  closing actor. Its GitHub author association must be `OWNER`, `MEMBER`, or
  `COLLABORATOR`, and a separate current repository-permission lookup must
  return `admin`, `maintain`, or `write`. Missing, edited, duplicate,
  conflicting, mismatched, or unauthorized comments fail closed.
  Normal PRD integration emits this same branch-bound comment and records
  canonical local status only after explicit issue closure succeeds.
- An all-state PR query for the owned branch must identify the supplied PR as
  the only candidate linked to the issue. The body is streamed and
  content-addressed from both PR lookups; the byte-exact body OIDs must agree,
  including trailing newlines. Competing bare, same-repository qualified, and
  canonical issue-URL directives are all treated as linkage conflicts.
- Exhaustive paginated inspection finds no live PR from the integration branch
  and no other open PR whose body or canonical issue head claims the slice.
- The configured Git remote is a network URL for the same GitHub `owner/repo`
  returned by the API. Local and path-like remotes are rejected.
- GitHub's repository API identifies the default branch, and its Git-ref API
  supplies the owned branch's exact tip. This prevents local Git URL rewrite
  configuration from substituting a mirror as branch-tip authority. The
  verified commit is then fetched and must descend from both frozen ownership
  commits. The target merge must be a strict descendant of the run's frozen
  owned tip, so a historical merge cannot be attributed to a later run.
- Git replacement refs and legacy grafts must be absent. Ancestry checks also
  disable replacement objects explicitly.
- A current local integration ref must equal the remote tip. The only exception
  is a stable local ref that is a verified ancestor of the stable remote tip.
  Diverged, missing-object, deleted, or concurrently moving local refs fail
  closed.
- For that stale-local exception, every commit in the complete local-to-remote
  range must have exactly one attribution. A commit is attributable only when
  it is the supplied PR's merge commit, appears in the exhaustive GitHub commit
  list for that exact PR, or equals one other canonical `slice-integrated`
  commit in the same run. Missing, malformed, duplicate, ambiguous, or
  unattributed commit evidence rejects the proof. When the local ref already
  equals the remote ref, the original exact-tip policy remains in force and a
  historical target PR is rejected, unless canonical reconciliation provenance
  already binds that exact PR merge, remote tip, branch, and pending or
  completed compare-and-swap. That narrow exception lets a post-CAS restart
  finalize without reopening historical attribution.
- Existing evidence is either the expected legacy `merged` item, or identical
  canonical evidence. Conflicting PR, commit, or provenance fails closed.

The proof records the authenticated GitHub operator, repository, run/PRD/issue/
PR identities, issue closure source, time, and actor, the exact integration
comment and actor authorization, closing-reference evidence, the parsed body
directive, byte-exact body OIDs and all-state candidate set, head and head
repository, URLs, merge time and commit, config and run-metadata binding,
ownership branch and remote, repository default branch, GitHub ref and exact
tip, local ref and expected old object, remote-only commit attributions, prior
status evidence, and proof timestamp. Apply stores that reviewed proof under
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

For an equal local ref, this status replacement completes the transaction. For
a stale local ref, the same atomic replacement also stages
`reconciliation.local_ref_update` with `pending`, the exact ref name, expected
old SHA, and target SHA. Only after that durable intent exists does apply
recheck the GitHub remote ref and run `git update-ref <ref> <target>
<expected-old>`. A successful compare-and-swap is followed by a second atomic
status replacement that marks the intent `completed`.

Failures before the canonical status write leave no new evidence. Failures
after that write retain a valid pending intent and never roll the local ref
back. Reapplying the same reviewed proof resumes the exact pending operation:
if the local ref still equals the expected old SHA, apply retries the
compare-and-swap; if it already equals the target SHA, apply finalizes the
intent without moving it again. Any third value, remote movement, malformed
pending evidence, or changed external proof fails closed. A retry after
completion returns `unchanged` without rewriting status. While the intent is
pending, a new dry-run also fails closed and directs the operator to reapply the
original reviewed proof stored in canonical reconciliation evidence; it cannot
produce a no-op proof that leaves the pending intent unresolved.

## Approved HITL Slice Integration

Use the same command with `--hitl` when an approved `ralph:hitl` slice was
merged interactively into a terminal run's owned PRD integration branch. This
mode is only for an issue that was never in that run's queue and has no
canonical worker status. It does not add the issue to `queue.json` or
`status.json`, and it does not claim that Ralph delivered the slice.

```bash
proof_file="$(mktemp "${TMPDIR:-/tmp}/ralph-hitl-513.XXXXXX.json")"

.ralph/reconcile-slice.sh \
  --hitl \
  --run 20260830-210025-e9b13095 \
  --prd 505 \
  --issue 513 \
  --pr 553 \
  --dry-run >"$proof_file"

# Review every identity, SHA, timestamp, actor, comment, and attribution.
jq . "$proof_file"

.ralph/reconcile-slice.sh \
  --hitl \
  --run 20260830-210025-e9b13095 \
  --prd 505 \
  --issue 513 \
  --pr 553 \
  --apply \
  --proof "$proof_file"
```

In addition to the legacy reconciliation checks above, HITL mode requires both
`work:slice` and `ralph:hitl`, zero queue ownership for the issue, and no status
item for it. Apply revalidates the exact reviewed proof under the setup and
state locks, then atomically appends a content-addressed record to
`.ralph/runs/<run-id>/hitl-integrations.json`. Existing records must have unique
issue, PR, and merge-commit identities and valid proof hashes.
Unlike normal reconciliation, the approved HITL PR may use a same-repository
interactive branch instead of the configured `slice-<issue>-*` worker branch.
The proof binds the exact head ref and head SHA from independent GraphQL and
REST PR evidence and resolves the SHA through the repository commit API. The
head must not be the owned PRD integration branch, repository default branch,
or configured delivery branch. A deleted source ref is acceptable only while
the merged PR still supplies consistent head metadata and the exact commit
remains resolvable; missing, changed, cross-repository, or unresolvable evidence
fails closed.
Each HITL proof requires its PR merge commit to equal the exact current remote
tip. Record sequential HITL integrations in merge order; do not use a later
remote tip to retroactively prove an earlier merge.

Terminal ownership transfer reads this file as separate provenance. It accepts
the current remote tip only when every first-parent advancement after
`owned_tip_sha` has exactly one canonical Ralph or guarded HITL attribution.
This permits multiple sequential, fully accounted integrations while rejecting
unknown or multiply attributed descendants. Transfer snapshots both status and
HITL provenance and rejects either changing under its lock. Local replacement
refs, legacy grafts, and shallow history are also rejected so local Git graph
rewrites cannot hide an unaccounted advancement.

Do not use `--hitl` for queued work, generic descendants, open or conflicting
delivery PRs, or to repair missing approval evidence. A rejected dry-run or
failed apply does not mutate queue, status, ownership, or HITL provenance.

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
