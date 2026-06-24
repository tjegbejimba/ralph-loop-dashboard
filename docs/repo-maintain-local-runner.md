# Local repo-maintain runner (`orchestrate-repo`)

`orchestrate-repo` is the **headless** equivalent of the `ralph-orchestrator`
skill's `repo-maintain` mode. It performs the same bounded "discover canonical
ready work and launch a small run behind the gate" sweep, but from the command
line so a local scheduler (launchd or cron) can run it on a timer.

## Why it has to run from the MAIN checkout (not a Copilot worktree)

`repo-maintain` needs the repo's `.ralph/` directory — `config.json` (for the
exact `issue.issueSearch`), `RALPH.md` (the worker prompt), and `runs/` (to
detect an already-active run). **`.ralph/` is gitignored and local-only.** It
exists *only* in the repo's main working checkout where `install.sh` created it.

Copilot scheduled workflows run in **throwaway git worktrees** created fresh for
each run. Those worktrees never contain the gitignored `.ralph/`, so the
agent-session `repo-maintain` mode can never discover work or launch from there —
there's nothing to read. Running `orchestrate-repo` from the main checkout (which
*does* have `.ralph/`) via launchd/cron is the fix.

```
Copilot scheduled workflow  ──>  throwaway worktree     ──>  no .ralph/  ✗
launchd / cron              ──>  repo MAIN checkout      ──>  has .ralph/ ✓
```

## What stays in the Copilot scheduled workflow

Only repo-maintain needs this local-runner shape. Slug-addressed GitHub-only
verbs can run from the app scheduler because they do not read `.ralph/` or launch
workers. The hourly `Triage Needs-Triage Issues` workflow should run the
needs-triage front half in one tick:

```bash
node extension/cli.mjs triage --live --canonical-labels \
  --repo tjegbejimba/alisterr \
  --repo tjegbejimba/kindleflow \
  --repo tjegbejimba/Glasswork \
  --json

node extension/cli.mjs promote-lanes --live \
  --repo tjegbejimba/alisterr \
  --repo tjegbejimba/kindleflow \
  --repo tjegbejimba/Glasswork \
  --json
```

`triage --live` only creates or updates the bot-owned advisory triage comment.
`promote-lanes --live` then applies the deterministic guarded lane labels, such
as `ralph:needs-triage` -> `ralph:fast-lane` for AUTO-eligible issues. It never
promotes to `ralph:ready`; that remains the human one-tap gate.

## What it does

Operating on `--repo-root` (default: the current directory), it:

1. Requires a real `.ralph/` install (`config.json` + `RALPH.md`). If missing it
   **hard-stops** with an owner brief — it never installs or repairs Ralph.
2. Reads `issue.issueSearch` from `.ralph/config.json` **verbatim**.
3. Resolves the repo `owner/name` from `config.repo` or the `origin` remote.
4. **Defers** (exit 0) if a run is already active for the repo (a non-terminal
   `.ralph/runs/<id>/status.json` or a live claim).
5. **Skips** with a one-time owner brief if the repo is missing the canonical
   `ralph:*` state labels. It never migrates labels for you.
6. Discovers ready work **read-only** via `gh issue list --search "<issueSearch>"`,
   dropping issues with an open linked PR, an in-flight Ralph claim, or an
   unresolved blocker.
7. Builds a bounded queue: at most `--max-issues` (default **3**), highest
   priority first, then lowest issue number within a priority band.
8. Checks prior run history for the bounded queue. Repeated deterministic
   issue/code-shape worker failures still **hard-stop** as `worker-stall`, but
   transient runtime/network/Copilot API failures and agent no-delivery exits
   are recorded in the ledger without poisoning the ready issue.
9. **Launches only through the gated `orchestrateRun()` path** — the exact same
   launch the dashboard and the orchestrator skill use. It never calls
   `launch.sh --start`/`--foreground` and never invents its own launch.
10. Writes a compact ledger to `.ralph/orchestrator/ledger.json`.

Discovery and `--dry-run` are strictly **read-only**: no `gh` writes, no enqueue,
no launch.

## The launch gate (`allowAgentLaunch` + `orchestrateAllowedRepoRoots`)

A launch happens **only** when all of these hold (each enforced inside
`orchestrateRun()`):

- `allowAgentLaunch: true` in `~/.ralph-dashboard/config.json` (default
  `false`),
- the target `--repo-root` is **allowlisted** — its absolute path is listed in
  `orchestrateAllowedRepoRoots` in `~/.ralph-dashboard/config.json`, and
- preflight passes (clean worktree, `.ralph/` present, `gh` authenticated,
  canonical labels).

### Why the allowlist matters here

`--repo-root` is operator-supplied and this is the most dangerous unattended
entry point (a scheduler launching auto-merging workers). To prevent an
arbitrary path from launching, the runner treats `--repo-root` as an
**override** and validates it against `orchestrateAllowedRepoRoots` — the trusted
default is the extension's own repo, never the path you pass in. Any repo other
than the extension itself (e.g. `/Users/tjegbejimba/Code/alisterr`) **must** be
added to the allowlist or the runner hard-stops with an owner brief:

```jsonc
// ~/.ralph-dashboard/config.json
{
  "allowAgentLaunch": true,
  "orchestrateAllowedRepoRoots": [
    "/Users/tjegbejimba/Code/alisterr"
  ]
}
```

If the gate is off, the path is not allowlisted, or preflight fails, the runner
still discovers work but **hard-stops** and prints an owner brief telling you
exactly what to fix — it does not launch.

## Run it manually (always dry-run first)

From the target repo's main checkout, or with an explicit `--repo-root`:

```bash
# 1) See the plan with zero mutations (no gh writes, no launch, no ledger):
node /path/to/ralph-loop-dashboard/extension/cli.mjs \
  orchestrate-repo --repo-root /Users/tjegbejimba/Code/alisterr --dry-run

# 2) Machine-readable plan:
node /path/to/ralph-loop-dashboard/extension/cli.mjs \
  orchestrate-repo --repo-root /Users/tjegbejimba/Code/alisterr --dry-run --json

# 3) For real (only launches if allowAgentLaunch is enabled + preflight passes):
node /path/to/ralph-loop-dashboard/extension/cli.mjs \
  orchestrate-repo --repo-root /Users/tjegbejimba/Code/alisterr
```

Options: `--repo-root <path>` (default cwd), `--dry-run`, `--json`,
`--max-issues <n>` (default 3), `--parallelism <n>` (default 1),
`--run-mode <one-pass|until-empty>` (default `until-empty`).

Exit codes: `0` = launched / deferred / skipped-labels / no-ready-work /
dry-run; `1` = hard stop (missing `.ralph/`, gate off, preflight failed, access
error, repeated deterministic worker failure); `2` = bad CLI arguments.

## Enabling the scheduled job (when you're ready)

A sample launchd agent lives at
[`docs/examples/com.tj.ralph-orchestrate-repo.alisterr.plist`](examples/com.tj.ralph-orchestrate-repo.alisterr.plist).
It is **not** loaded automatically. To enable it:

1. Confirm a few dry-runs look right.
2. Set `allowAgentLaunch: true` in `~/.ralph-dashboard/config.json`.
3. Add the target repo's absolute path to `orchestrateAllowedRepoRoots` in
   `~/.ralph-dashboard/config.json` (see the gate section above). Without this
   the runner hard-stops instead of launching.
4. Edit the absolute paths in the plist (`node`, `cli.mjs`, `--repo-root`).
5. Copy it into `~/Library/LaunchAgents/` and `launchctl load` it (commands are
   in the plist comments). Unload with `launchctl unload`.

The job is safe to run hourly: discovery is read-only, an active run causes a
deferral, and launches are bounded and gated.
