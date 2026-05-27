import { spawn } from "node:child_process";
import { existsSync, openSync } from "node:fs";
import { join } from "node:path";
import { joinSession } from "@github/copilot-sdk/extension";
import { CopilotWebview } from "./lib/copilot-webview.js";
import { resolveRepoState } from "./lib/repo-resolver.mjs";
import { initializeRalph } from "./lib/ralph-init.mjs";
import { loadUserConfig } from "./lib/user-config.mjs";
import {
  retryFailedIssue,
  skipFailedIssue,
  removeQueuedIssue,
  reorderQueuedIssue,
} from "./lib/run-store.mjs";
import {
  readPidFile,
  writePidFile,
  removePidFile,
  resolveBashExe,
  toBashPath,
  validateWindowsParallelism,
} from "./lib/platform-shim.mjs";
import { createStatusReader } from "./lib/status-data.mjs";

const IS_WINDOWS = process.platform === "win32";

// Resolve repo state at extension load time
const REPO_STATE = resolveRepoState({
  env: process.env,
  cwd: process.cwd(),
  searchStart: import.meta.dirname,
});

// For backward compatibility, export REPO_ROOT (or fallback to cwd if unresolved)
const REPO_ROOT = REPO_STATE.repoRoot || process.cwd();
const LOOP_LOG = join(REPO_ROOT, ".ralph", "loop.out");
const LAUNCHER_PID_FILE = join(REPO_ROOT, ".ralph", "launcher.pid");

// Shared data layer used by both this dashboard and the terminal CLI
// (extension/cli.mjs). All data-extraction/regex/log-parsing lives there.
const statusReader = createStatusReader({
  repoRoot: REPO_ROOT,
  env: process.env,
});
const { getLoopProcess, ghJson } = statusReader;

// Single-PR and single-issue lookups used by dashboard side panels. These
// take a number argument so they don't belong in the status reader (which
// produces snapshot payloads).
async function getPrDetail(number) {
  if (!Number.isInteger(number) || number <= 0) {
    return { error: "invalid PR number" };
  }
  return await ghJson([
    "pr",
    "view",
    String(number),
    "--json",
    "number,title,body,state,url,mergedAt,createdAt,closedAt,headRefName,baseRefName,additions,deletions,changedFiles,author,labels,isDraft",
  ]);
}

async function getIssueDetail(number) {
  return await ghJson([
    "issue",
    "view",
    String(number),
    "--json",
    "number,title,body,labels,state,createdAt,updatedAt,comments,url,milestone",
  ]);
}

async function getStatus() {
  // Delegate to the shared data layer; pass REPO_STATE so the config summary
  // can report repoRoot resolution status to the webview.
  return statusReader.buildStatusPayload({
    withPrs: true,
    repoState: {
      state: REPO_STATE.state,
      repoRoot: REPO_STATE.repoRoot,
      hasRalph: REPO_STATE.hasRalph,
      source: REPO_STATE.source,
    },
  });
}

// Spawn .ralph/launch.sh detached so the loop survives this extension/session.
async function startLoop({ runOptions } = {}) {
  const procs = await getLoopProcess();
  // On Windows getLoopProcess returns the launcher pidfile entry directly;
  // POSIX returns ralph.sh / copilot -p entries.
  const alreadyRunning = IS_WINDOWS
    ? procs.length > 0
    : procs.some((p) => p.cmd.includes("ralph.sh"));
  if (alreadyRunning) {
    return { ok: false, error: "Loop is already running.", processes: procs };
  }
  const launcher = join(REPO_ROOT, ".ralph", "launch.sh");
  if (!existsSync(launcher)) {
    return { ok: false, error: `launcher not found: ${launcher}` };
  }

  if (IS_WINDOWS) {
    return startLoopWindows({ runOptions });
  }

  try {
    // Append stdout/stderr to loop.out and fully detach so the process
    // survives the extension lifecycle.
    const out = openSync(LOOP_LOG, "a");
    
    // Build environment with run options
    const env = {
      ...process.env,
      PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || ""}`,
    };
    if (runOptions?.parallelism) {
      env.RALPH_PARALLELISM = String(runOptions.parallelism);
    }
    if (runOptions?.model) {
      env.RALPH_MODEL = runOptions.model;
    }
    
    // Build args - add --once flag for one-pass mode
    const args = [launcher];
    if (runOptions?.runMode === "one-pass") {
      args.push("--once");
    }
    
    const child = spawn("bash", args, {
      cwd: REPO_ROOT,
      detached: true,
      stdio: ["ignore", out, out],
      env,
    });
    child.unref();
    return { ok: true, pid: child.pid };
  } catch (err) {
    return { ok: false, error: String(err.message || err) };
  }
}

// Windows-only: spawn launch.sh via Git for Windows bash with --foreground
// to sidestep the Cygwin fork crash that bites `nohup ... &` (the default
// background path inside launch.sh). Foreground mode runs everything inside
// a single hidden bash.exe console — no fork, no DLL-load race.
//
// We write the bash.exe PID to .ralph\launcher.pid so getLoopProcess() and
// stopLoop() can find the loop later. This matches the contract used by
// Glasswork's scripts/launch-ralph.ps1, so external launches and dashboard
// launches are interchangeable from the dashboard's point of view.
async function startLoopWindows({ runOptions }) {
  const validation = validateWindowsParallelism(runOptions?.parallelism);
  if (!validation.ok) return validation;
  const parallelism = validation.parallelism;

  let bashExe;
  try {
    bashExe = resolveBashExe(process.env);
  } catch (err) {
    return { ok: false, error: String(err.message || err) };
  }
  if (!bashExe) {
    return {
      ok: false,
      error:
        `Could not locate Git Bash. Install Git for Windows (https://git-scm.com/download/win), ` +
        `or set RALPH_BASH_EXE to your bash.exe path. See docs/adr/0002.`,
    };
  }

  const env = { ...process.env };
  // PATH stays as-is on Windows: gh and git live on the system PATH.
  env.RALPH_PARALLELISM = String(parallelism);
  if (runOptions?.model) {
    env.RALPH_MODEL = runOptions.model;
  }

  const repoRootBash = toBashPath(REPO_ROOT);
  const logPathBash = toBashPath(LOOP_LOG);
  const launcherArgs = ["--foreground"];
  if (runOptions?.runMode === "one-pass") launcherArgs.push("--once");
  const launcherCmd = launcherArgs.join(" ");
  // -lc gives us a login shell with PATH/profile loaded; exec replaces bash
  // with launch.sh so the recorded PID is the launcher itself.
  const bashCommand = `cd '${repoRootBash}' && exec ./.ralph/launch.sh ${launcherCmd} >> '${logPathBash}' 2>&1`;

  try {
    const child = spawn(bashExe, ["-lc", bashCommand], {
      cwd: REPO_ROOT,
      detached: true,
      windowsHide: true,
      stdio: "ignore",
      env,
    });
    child.unref();
    if (typeof child.pid !== "number") {
      return { ok: false, error: "spawn returned no pid" };
    }
    writePidFile(LAUNCHER_PID_FILE, child.pid);
    return { ok: true, pid: child.pid };
  } catch (err) {
    return { ok: false, error: String(err.message || err) };
  }
}

// Stop the loop by SIGTERMing every detected ralph.sh + copilot -p PID.
async function stopLoop() {
  const procs = await getLoopProcess();
  if (procs.length === 0) {
    return { ok: false, error: "No loop process running." };
  }
  const killed = [];
  const failed = [];
  for (const p of procs) {
    try {
      process.kill(p.pid, "SIGTERM");
      killed.push(p.pid);
    } catch (err) {
      failed.push({ pid: p.pid, error: String(err.message || err) });
    }
  }
  // Windows: clean up the launcher pidfile so the next status query reflects
  // reality immediately. POSIX has no pidfile to clean.
  if (IS_WINDOWS) {
    removePidFile(LAUNCHER_PID_FILE);
  }
  return { ok: killed.length > 0, killed, failed };
}

// Initialize Ralph in the resolved repository root.
async function initRalph() {
  if (REPO_STATE.state === "unresolved") {
    return { ok: false, error: "No repository root resolved. Cannot initialize." };
  }
  if (!REPO_STATE.repoRoot) {
    return { ok: false, error: "Repository root is null. Cannot initialize." };
  }
  if (REPO_STATE.hasRalph) {
    return { ok: false, error: ".ralph/ already exists. Initialization not needed." };
  }
  
  const result = initializeRalph(REPO_STATE.repoRoot);
  
  if (result.success) {
    return {
      ok: true,
      message: "Ralph initialized successfully.",
      created: result.created,
      skipped: result.skipped,
      repoRoot: REPO_STATE.repoRoot,
    };
  } else {
    return {
      ok: false,
      error: result.error || "Initialization failed.",
      created: result.created,
      skipped: result.skipped,
    };
  }
}

// Run preflight checks
async function runPreflight({ queue, runOptions }) {
  // Import the preflight module
  const { runPreflight: runPreflightChecks } = await import("./lib/preflight.mjs");
  
  const result = await runPreflightChecks({
    repoRoot: REPO_ROOT,
    queue,
    runOptions,
  });
  
  return result;
}

// Get user config with defaults
async function getUserConfig() {
  const { config } = loadUserConfig();
  return config;
}

// Retry a failed issue
async function retryIssue({ runId, issueNumber }) {
  return retryFailedIssue({ repoRoot: REPO_ROOT, runId, issueNumber });
}

// Skip a failed issue
async function skipIssue({ runId, issueNumber }) {
  return skipFailedIssue({ repoRoot: REPO_ROOT, runId, issueNumber });
}

// Remove a queued issue
async function removeIssue({ runId, issueNumber }) {
  return removeQueuedIssue({ repoRoot: REPO_ROOT, runId, issueNumber });
}

// Reorder a queued issue
async function reorderIssue({ runId, issueNumber, newIndex }) {
  return reorderQueuedIssue({ repoRoot: REPO_ROOT, runId, issueNumber, newIndex });
}

const webview = new CopilotWebview({
  extensionName: "ralph_dashboard",
  contentDir: join(import.meta.dirname, "content"),
  title: "Ralph Loop Dashboard",
  width: 1200,
  height: 900,
  callbacks: {
    getStatus,
    getPrDetail,
    getIssueDetail,
    startLoop,
    stopLoop,
    initRalph,
    runPreflight,
    getUserConfig,
    retryIssue,
    skipIssue,
    removeIssue,
    reorderIssue,
    log: (msg, opts) => session.log(msg, opts),
  },
});

const session = await joinSession({
  tools: webview.tools,
  commands: [
    {
      name: "ralph",
      description: "Open the Ralph loop dashboard window.",
      handler: () => webview.show(),
    },
  ],
  hooks: { onSessionEnd: webview.close },
});
