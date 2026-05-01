# Ralph Loop + Dashboard

A self-driving TDD loop for [Copilot CLI](https://github.com/github/copilot-cli) that:

1. **Runs Copilot headless** through GitHub issues one at a time, enforcing red-green-refactor TDD with mandatory dual-model code review (`gpt-5.5` + `claude-opus-4.7`).
2. **Ships a desktop dashboard** (Copilot CLI extension) showing live loop status — current iteration, stage, PR/CI status, queue, history, and start/stop controls.

> Inspired by [Geoff Huntley's "Ralph Wiggum as a software engineer"](https://ghuntley.com/ralph/) — a single agent looping on `cat PROMPT.md | claude --dangerously-skip-permissions` until the work is done.

## What's in the box

```
ralph-loop-dashboard/
├── ralph/                      # The loop itself
│   ├── ralph.sh                # Main loop: pick lowest-numbered open issue, run, wait for merge
│   ├── launch.sh               # Idempotent worktree setup + background launcher
│   └── RALPH.md.template       # Per-iteration prompt (workflow law for the agent)
├── extension/                  # The Copilot CLI dashboard extension
│   ├── extension.mjs           # Bootstrapper
│   ├── main.mjs                # Status reader + tools (getStatus, startLoop, stopLoop)
│   └── content/                # Webview UI (HTML/CSS/JS)
└── install.sh                  # One-shot bootstrap into a target repo
```

## Install

```bash
git clone https://github.com/tjegbejimba/ralph-loop-dashboard.git
cd ralph-loop-dashboard
./install.sh /path/to/your/project
# or choose a repo profile explicitly
./install.sh /path/to/your/project --profile python
```

This:
- Copies `ralph/*` → `<your-project>/.ralph/`, with `RALPH.md` rendered from the template using your repo slug
- Creates `<your-project>/.ralph/config.json` from a profile (`generic`, `bun`, or `python`)
- Symlinks `extension/` → `~/.copilot/extensions/ralph-dashboard/` (user-level, available in all Copilot CLI sessions)

Restart Copilot CLI afterwards (or `/restart`) so the extension is picked up.

## File the work as issues

The loop picks issues whose title matches a regex (default: `^Slice [0-9]+:`). Number them sequentially — lowest number runs first. A good shape:

```
Slice 1: Project bootstrap (lint + test + build commands)
Slice 2: User can sign up
Slice 3: Email confirmation flow
...
```

Each issue body should describe the slice's intent + acceptance criteria. The loop drops the body into `RALPH.md` under `--- ISSUE #N ---` so the agent has full context.

## Run the loop

```bash
.ralph/launch.sh                     # background, logs to .ralph/loop.out
.ralph/launch.sh --foreground        # attached (single-worker only)
.ralph/launch.sh --status            # active workers + claims
.ralph/launch.sh --stop              # SIGTERM all workers
```

### Parallel workers

Run multiple slices concurrently. Each worker gets its own git worktree
(`<MAIN>-ralph-1`, `-2`, …) on its own branch (`ralph-loop-1`, …) and they
coordinate via `.ralph/state.json` (file-locked).

```bash
RALPH_PARALLELISM=2 .ralph/launch.sh
```

A worker only claims an issue whose **Blocked by** issues are all CLOSED, so
the dependency graph from your sliced issues is honored automatically. Stale
claims (worker crashed) are auto-reaped on the next selection round.

Or use the dashboard's "Start" button (after restarting Copilot CLI):

```
/extensions
# Run "ralph" command, or invoke ralph_dashboard_show
```

The loop iterates until no open matching issues remain, then exits cleanly.

## Configuration

Project-specific config lives at `.ralph/config.json`. Built-in profiles live in
`ralph/profiles/` and can be selected during install:

```bash
./install.sh /path/to/project --profile generic
./install.sh /path/to/project --profile bun
./install.sh /path/to/project --profile python
```

The installer never overwrites an existing `.ralph/config.json` unless
`--force-config` is passed.

Config is intentionally small:

```json
{
  "profile": "python",
  "issue": {
    "titleRegex": "^Slice [0-9]+:",
    "titleNumRegex": "^Slice (?<x>[0-9]+):",
    "issueSearch": "Slice in:title"
  },
  "validation": {
    "commands": [
      { "name": "Compile", "command": "python3 -m py_compile <changed python files>" },
      { "name": "Unit tests", "command": "python3 -m unittest discover" }
    ]
  },
  "stages": [
    {
      "id": "testing",
      "label": "running tests",
      "icon": "🧪",
      "patterns": ["\\bpytest\\b", "python3? -m unittest"]
    }
  ]
}
```

The config informs the prompt and dashboard. The worker agent still runs validation commands; the dashboard does not execute them.

Environment variables still override config:

| Variable | Default | What it does |
| --- | --- | --- |
| `RALPH_REPO` | auto-detected from `git remote origin` | `owner/repo` for `gh` calls |
| `RALPH_TITLE_REGEX` | config or `^Slice [0-9]+:` | Matches issues to work on (extension + script) |
| `RALPH_TITLE_NUM_REGEX` | config or `^Slice (?<x>[0-9]+):` | jq-compatible capture for the number |
| `RALPH_ISSUE_SEARCH` | config or `Slice in:title` | `gh issue list --search` query (extension) |
| `RALPH_MODEL` | `claude-sonnet-4.5` | Model passed to `copilot -p` |
| `RALPH_TIMEOUT_SEC` | `7200` | Per-iteration timeout |
| `RALPH_MAIN_REPO` | parent of `.ralph/` | Path to your main checkout |
| `RALPH_LOOP_REPO` | `<MAIN>-ralph` | Base path for loop worktree(s); worker N gets `-N` suffix when parallelism>1 |
| `RALPH_LOOP_BRANCH` | `ralph-loop` | Base branch name; worker N gets `-N` suffix when parallelism>1 |
| `RALPH_PARALLELISM` | `1` | Number of concurrent workers |
| `RALPH_WORKER_ID` | `1` | Set automatically by `launch.sh`; identifies a worker in `state.json` and log filenames |
| `RALPH_POLL_SEC` | `30` | How long a worker sleeps when no eligible issue is available |
| `RALPH_REPO_ROOT` | walks up from cwd | Override for the dashboard's project detection |

To customize the title pattern (e.g., for "Task N:" instead of "Slice N:"):

```bash
export RALPH_TITLE_REGEX='^Task [0-9]+:'
export RALPH_TITLE_NUM_REGEX='^Task (?<x>[0-9]+):'
export RALPH_ISSUE_SEARCH='Task in:title'
```

## Workflow guarantees

The agent (in `RALPH.md`) is locked into:

- **Red → Green → Refactor**, no skipping the red phase
- All local checks pass before push (`lint`, `typecheck`, `test`, `e2e`, `build` — adapt to your repo)
- PR body must include `Closes #<N>` for auto-close on merge
- Dual-model code review (parallel `gpt-5.5` + `claude-opus-4.7`) before merge
- Pre-merge rebase, force-push with lease, watch CI, squash-merge

If anything fails, the iteration halts loudly. No "I'll get to it later" half-ships.

## Dashboard tools

When the extension is loaded, these tools are available to any Copilot agent in the workspace:

- `ralph_dashboard_show` — open the live dashboard window
- `ralph_dashboard_eval` — run JS in the dashboard webview (debug)
- `ralph_dashboard_close` — close the window

And via the agent's tool surface: `getStatus`, `startLoop`, `stopLoop`, `getPrDetail`, `getIssueDetail`.

## Caveats

- **macOS-tested.** The launcher and process detection use `ps -axww`. Linux should work but is not exercised; PRs welcome.
- **Bun-native repos** are the original target — `RALPH.md` references `bun test` etc. Edit the template (or the rendered `.ralph/RALPH.md`) for npm/pnpm/cargo/etc.
- The loop assumes you have `gh` authenticated and Copilot CLI installed.

## License

MIT — see [LICENSE](LICENSE).
