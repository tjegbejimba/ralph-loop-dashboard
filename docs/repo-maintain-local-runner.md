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
7. Builds a bounded queue: at most `--max-issues` (default **3**), lowest issue
   number first.
8. **Launches only through the gated `orchestrateRun()` path** — the exact same
   launch the dashboard and the orchestrator skill use. It never calls
   `launch.sh --start`/`--foreground` and never invents its own launch.
9. Writes a compact ledger to `.ralph/orchestrator/ledger.json`.

Discovery and `--dry-run` are strictly **read-only**: no `gh` writes, no enqueue,
no launch.

## The `allowAgentLaunch` gate

A launch happens **only** when both are true (both enforced inside
`orchestrateRun()`):

- `allowAgentLaunch: true` in `~/.ralph-dashboard/config.json` (default
  `false`), and
- preflight passes (clean worktree, `.ralph/` present, `gh` authenticated,
  canonical labels).

If the gate is off, the runner still discovers work but **hard-stops** and prints
an owner brief telling you to enable the gate — it does not launch.

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
error); `2` = bad CLI arguments.

## Enabling the scheduled job (when you're ready)

A sample launchd agent lives at
[`docs/examples/com.tj.ralph-orchestrate-repo.alisterr.plist`](examples/com.tj.ralph-orchestrate-repo.alisterr.plist).
It is **not** loaded automatically. To enable it:

1. Confirm a few dry-runs look right.
2. Set `allowAgentLaunch: true` in `~/.ralph-dashboard/config.json`.
3. Edit the absolute paths in the plist (`node`, `cli.mjs`, `--repo-root`).
4. Copy it into `~/Library/LaunchAgents/` and `launchctl load` it (commands are
   in the plist comments). Unload with `launchctl unload`.

The job is safe to run hourly: discovery is read-only, an active run causes a
deferral, and launches are bounded and gated.
