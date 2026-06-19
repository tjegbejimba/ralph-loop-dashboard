# Ralph Dashboard Canvas Extension

This is the repo-native Ralph dashboard canvas extension. It provides a read-only view of the Ralph Loop inside a Copilot canvas (side panel).

## Structure

- `extension.mjs` — Main extension entry point, handles canvas lifecycle, HTTP server, and status endpoint
- `renderer.mjs` — HTML page generator for the dashboard UI
- `package.json` — Extension metadata

## Installation

Install as a **project/repo** extension:

```bash
# From the Ralph Loop repo root
gh copilot extension install --project extension-canvas
```

## Usage

Open the canvas from any Copilot session:

```
@ralph-dashboard-canvas
```

By default, it shows the Ralph Loop status for this repository. To view a different repo:

```
@ralph-dashboard-canvas --repoRoot /path/to/other/repo
```

## Features

- **Read-only dashboard**: View loop status, active workers, queue, recent PRs
- **Live updates**: Polls status every 5 seconds
- **Repo-native data layer**: Reuses `extension/lib/status-data.mjs` from this repo
- **Loopback HTTP server**: Self-contained, no external dependencies
- **No mutation paths**: Cannot start/stop workers or modify issues (read-only by design)

## Canvas Actions

### `get_status`

Returns structured status data for programmatic access:

```javascript
{
  repoRoot: string,
  loopRunning: boolean,
  headerText: string | null,
  workers: Array<{ issue: number, stage: string | null }>,
  openSlices: Array<{ number: number, title: string, labels: string[] }>,
  recentPrs: Array<{ number: number, title: string, state: string }>,
  cumulative: { mergedToday: number, additions: number, deletions: number, changedFiles: number } | null
}
```

## Differences from Native Dashboard

The native dashboard (`extension/extension.mjs`) opens a desktop window and supports interactive controls (launch, stop, queue management). This canvas is read-only and lives in the Copilot side panel for lightweight monitoring.

Both share the same data layer (`status-data.mjs`), so numbers match exactly.

## Development

Tests are in `test/canvas-extension.test.mjs`. Run with:

```bash
npm test
```

The canvas extension does not require the Copilot SDK at build time; it's loaded at runtime by the Copilot CLI.
