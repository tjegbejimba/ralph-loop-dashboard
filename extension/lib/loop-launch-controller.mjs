// Safe Ralph loop startup orchestration shared by the dashboard UI and agent tool.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createRun as createRunImpl } from "./run-store.mjs";
import { runPreflight as runPreflightImpl } from "./preflight.mjs";
import { getRunOptions, validateModel, validateParallelism, validateRunMode } from "./run-options.mjs";
import { launchRun as launchLoopImpl } from "./shell-launcher.mjs";
import { isAlive } from "./platform-shim.mjs";

const IS_WINDOWS = process.platform === "win32";
const TERMINAL_STATUSES = new Set(["merged", "failed", "skipped"]);
const DEFAULT_VERIFY_TIMEOUT_MINUTES = 60;
const DEFAULT_VERIFY_POLL_MS = 5000;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeIssueNumber(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

export function normalizeQueue({ queue, issueNumbers } = {}) {
  if (Array.isArray(queue) && queue.length > 0) {
    const normalized = [];
    for (const issue of queue) {
      const number = normalizeIssueNumber(issue?.number);
      if (!number) {
        return { ok: false, error: "Queue issues must include positive integer issue numbers." };
      }
      normalized.push({
        ...issue,
        number,
        title: String(issue.title || `Issue #${number}`),
      });
    }
    return { ok: true, queue: normalized };
  }

  if (Array.isArray(issueNumbers) && issueNumbers.length > 0) {
    const normalized = [];
    const seen = new Set();
    for (const value of issueNumbers) {
      const number = normalizeIssueNumber(value);
      if (!number) {
        return { ok: false, error: "issueNumbers must contain positive integers." };
      }
      if (seen.has(number)) continue;
      seen.add(number);
      normalized.push({ number, title: `Issue #${number}` });
    }
    return { ok: true, queue: normalized };
  }

  return { ok: true, queue: [] };
}

export function normalizeRunOptions(input, { userConfig } = {}) {
  const defaults = getRunOptions({ userConfig });
  const raw = { ...defaults, ...(input || {}) };
  const parallelism =
    typeof raw.parallelism === "string" ? Number(raw.parallelism) : raw.parallelism;
  const runOptions = {
    runMode: raw.runMode,
    parallelism,
    model: raw.model,
  };

  const runModeResult = validateRunMode(runOptions.runMode);
  if (!runModeResult.valid) return { ok: false, error: runModeResult.error };

  const parallelismResult = validateParallelism(runOptions.parallelism);
  if (!parallelismResult.valid) return { ok: false, error: parallelismResult.error };

  const modelResult = validateModel(runOptions.model);
  if (!modelResult.valid) return { ok: false, error: modelResult.error };

  return { ok: true, runOptions };
}

function isLoopAlreadyRunning(procs, isWindows) {
  return isWindows
    ? procs.length > 0
    : procs.some((p) => String(p.cmd || "").includes("ralph.sh"));
}

function readStatusJson(statusPath) {
  if (!existsSync(statusPath)) {
    return { ok: false, error: `Run status file not found: ${statusPath}` };
  }
  try {
    return { ok: true, status: JSON.parse(readFileSync(statusPath, "utf-8")) };
  } catch (err) {
    return { ok: false, error: `Failed to read run status: ${String(err.message || err)}` };
  }
}

function hasRunStatusActivity({ queue, runDir }) {
  const statusResult = readStatusJson(join(runDir, "status.json"));
  if (!statusResult.ok) return false;
  const statusItems = statusResult.status?.items || {};
  return queue.some((issue) => Object.hasOwn(statusItems, String(issue.number)));
}

export function summarizeRunVerification({ queue, runDir, status, timedOut = false, statusError = null }) {
  const statusItems = status?.items && typeof status.items === "object" ? status.items : {};
  const items = queue.map((issue) => {
    const issueStatus = statusItems[String(issue.number)] || {};
    const itemStatus = typeof issueStatus.status === "string" ? issueStatus.status : "pending";
    const pid = Number.isInteger(Number(issueStatus.pid)) ? Number(issueStatus.pid) : null;
    const pidAlive = pid ? isAlive(pid) : null;
    const deadWorker =
      (itemStatus === "running" || itemStatus === "claimed") && pid !== null && pidAlive === false;
    return {
      number: issue.number,
      title: issue.title,
      status: itemStatus,
      terminal: TERMINAL_STATUSES.has(itemStatus),
      workerId: issueStatus.workerId ?? null,
      pid,
      pidAlive,
      deadWorker,
      logFile: issueStatus.logFile ?? null,
      error: issueStatus.error ?? null,
    };
  });
  const counts = {
    total: items.length,
    merged: items.filter((item) => item.status === "merged").length,
    failed: items.filter((item) => item.status === "failed").length,
    skipped: items.filter((item) => item.status === "skipped").length,
    nonterminal: items.filter((item) => !item.terminal).length,
    deadWorker: items.filter((item) => item.deadWorker).length,
  };
  return {
    ok: counts.total > 0 && counts.merged === counts.total,
    complete: counts.total > 0 && counts.nonterminal === 0,
    timedOut,
    statusPath: join(runDir, "status.json"),
    statusError,
    counts,
    items,
  };
}

export async function verifyRunStatus({
  queue,
  runDir,
  timeoutMinutes = DEFAULT_VERIFY_TIMEOUT_MINUTES,
  pollMs = DEFAULT_VERIFY_POLL_MS,
  sleepFn = sleep,
} = {}) {
  const timeoutNumber = Number(timeoutMinutes);
  const timeoutMs =
    Math.max(0, Number.isFinite(timeoutNumber) ? timeoutNumber : DEFAULT_VERIFY_TIMEOUT_MINUTES) *
    60 *
    1000;
  const pollNumber = Number(pollMs);
  const effectivePollMs =
    Number.isFinite(pollNumber) && pollNumber > 0 ? pollNumber : DEFAULT_VERIFY_POLL_MS;
  const deadline = Date.now() + timeoutMs;
  const statusPath = join(runDir, "status.json");
  let lastSummary = null;

  while (true) {
    const statusResult = readStatusJson(statusPath);
    lastSummary = summarizeRunVerification({
      queue,
      runDir,
      status: statusResult.ok ? statusResult.status : null,
      statusError: statusResult.ok ? null : statusResult.error,
    });
    if (lastSummary.complete) {
      return lastSummary;
    }
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) {
      return {
        ...lastSummary,
        timedOut: true,
        ok: false,
      };
    }
    await sleepFn(Math.min(effectivePollMs, remainingMs));
  }
}

export async function startRalphLoop({
  repoRoot,
  queue,
  issueNumbers,
  runOptions,
  userConfig,
  getLoopProcess,
  runPreflight = runPreflightImpl,
  createRun = createRunImpl,
  launchLoop = launchLoopImpl,
  isWindows = IS_WINDOWS,
  startupTimeoutMs,
  startupPollMs,
} = {}) {
  if (!repoRoot || typeof repoRoot !== "string") {
    return { ok: false, error: "repoRoot is required and must be a string." };
  }
  if (typeof getLoopProcess !== "function") {
    return { ok: false, error: "getLoopProcess is required." };
  }

  const normalizedQueue = normalizeQueue({ queue, issueNumbers });
  if (!normalizedQueue.ok) return { ok: false, error: normalizedQueue.error };

  const normalizedRunOptions = normalizeRunOptions(runOptions, { userConfig });
  if (!normalizedRunOptions.ok) return { ok: false, error: normalizedRunOptions.error };

  const procs = await getLoopProcess();
  if (isLoopAlreadyRunning(procs, isWindows)) {
    return { ok: false, error: "Loop is already running.", processes: procs };
  }

  const preflight = await runPreflight({
    repoRoot,
    queue: normalizedQueue.queue,
    runOptions: normalizedRunOptions.runOptions,
  });
  if (!preflight.passed) {
    return { ok: false, error: "Preflight failed.", preflight };
  }

  let run;
  try {
    run = createRun({
      repoRoot,
      queue: normalizedQueue.queue,
      runOptions: normalizedRunOptions.runOptions,
    });
  } catch (err) {
    return { ok: false, error: `Failed to create run: ${String(err.message || err)}` };
  }

  const launch = await launchLoop({
    repoRoot,
    runId: run.runId,
    runDir: run.runDir,
    runOptions: normalizedRunOptions.runOptions,
    startupTimeoutMs,
    startupPollMs,
    confirmStarted: async () => {
      const statusActive = hasRunStatusActivity({ queue: normalizedQueue.queue, runDir: run.runDir });
      if (isWindows) return statusActive;
      const currentProcs = await getLoopProcess();
      return (
        isLoopAlreadyRunning(currentProcs, isWindows) ||
        statusActive
      );
    },
  });
  if (!launch?.success) {
    return {
      ok: false,
      error: launch?.error || "Failed to launch Ralph loop.",
      runId: run.runId,
      runDir: run.runDir,
    };
  }

  return {
    ok: true,
    runId: run.runId,
    runDir: run.runDir,
    pid: launch.pid,
    queue: normalizedQueue.queue,
    runOptions: normalizedRunOptions.runOptions,
  };
}

export async function orchestrateRun(options = {}) {
  if (options.userConfig?.allowAgentLaunch !== true) {
    return {
      ok: false,
      error: "Agent Ralph launch requires allowAgentLaunch: true in the Ralph dashboard user config.",
    };
  }

  const launch = await startRalphLoop({
    ...options,
    runOptions: {
      runMode: "until-empty",
      ...(options.runOptions || {}),
    },
  });
  if (!launch.ok || options.verify === false) {
    return launch;
  }

  const verification = await verifyRunStatus({
    queue: launch.queue,
    runDir: launch.runDir,
    timeoutMinutes: options.timeoutMinutes,
    pollMs: options.verifyPollMs,
    sleepFn: options.verifySleep,
  });
  if (!verification.ok) {
    return {
      ...launch,
      ok: false,
      error: "Ralph run verification did not complete successfully.",
      verification,
    };
  }

  return { ...launch, verification };
}
