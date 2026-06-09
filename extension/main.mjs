import { join } from "node:path";
import { joinSession } from "@github/copilot-sdk/extension";
import { CopilotWebview } from "./lib/copilot-webview.js";
import { resolveRepoState } from "./lib/repo-resolver.mjs";
import { initializeRalph } from "./lib/ralph-init.mjs";
import { loadUserConfig } from "./lib/user-config.mjs";
import { orchestrateRun as orchestrateRalphRun, startRalphLoop } from "./lib/loop-launch-controller.mjs";
import {
  createAutopilotOrchestrationPermissionHook,
  createRalphOrchestrationTool,
  inferSessionMode,
} from "./lib/ralph-tools.mjs";
import {
  retryFailedIssue,
  skipFailedIssue,
  removeQueuedIssue,
  reorderQueuedIssue,
} from "./lib/run-store.mjs";
import { removePidFile } from "./lib/platform-shim.mjs";
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

// Start .ralph/launch.sh through the shared controller so UI and agent starts
// run the same preflight, run creation, and platform launch behavior.
async function startLoop({ queue, issueNumbers, runOptions } = {}) {
  const { config: userConfig } = loadUserConfig();
  return startRalphLoop({
    repoRoot: REPO_ROOT,
    queue,
    issueNumbers,
    runOptions,
    userConfig,
    getLoopProcess,
  });
}

async function orchestrateRun({ queue, issueNumbers, runOptions, verify, timeoutMinutes } = {}) {
  const { config: userConfig } = loadUserConfig();
  return orchestrateRalphRun({
    repoRoot: REPO_ROOT,
    queue,
    issueNumbers,
    runOptions,
    verify,
    timeoutMinutes,
    userConfig,
    getLoopProcess,
  });
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
    orchestrateRun,
    getUserConfig,
    retryIssue,
    skipIssue,
    removeIssue,
    reorderIssue,
    log: (msg, opts) => session.log(msg, opts),
  },
});
const agentSafeWebviewTools = webview.tools.filter((tool) => tool.name !== "ralph_dashboard_eval");

let currentSessionMode = null;
const updateCurrentSessionMode = (event) => {
  currentSessionMode = inferSessionMode([event], currentSessionMode);
};
const allowAutopilotRalphOrchestration = createAutopilotOrchestrationPermissionHook({
  getMode: () => currentSessionMode,
});

const session = await joinSession({
  tools: [
    ...agentSafeWebviewTools,
    createRalphOrchestrationTool({ orchestrateRun }),
  ],
  commands: [
    {
      name: "ralph",
      description: "Open the Ralph loop dashboard window.",
      handler: () => webview.show(),
    },
  ],
  hooks: {
    onSessionEnd: webview.close,
    onPreToolUse: allowAutopilotRalphOrchestration,
  },
});

try {
  currentSessionMode = inferSessionMode(await session.getEvents(), currentSessionMode);
} catch (err) {
  session.log(`Failed to infer initial session mode: ${String(err.message || err)}`, {
    level: "warn",
  });
  currentSessionMode = null;
}
session.on("session.mode_changed", updateCurrentSessionMode);
session.on("user.message", updateCurrentSessionMode);
