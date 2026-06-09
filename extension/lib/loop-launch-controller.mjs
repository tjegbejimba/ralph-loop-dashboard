// Safe Ralph loop startup orchestration shared by the dashboard UI and agent tool.

import { createRun as createRunImpl } from "./run-store.mjs";
import { runPreflight as runPreflightImpl } from "./preflight.mjs";
import { getRunOptions, validateModel, validateParallelism, validateRunMode } from "./run-options.mjs";
import { launchLoop as launchLoopImpl } from "./loop-launcher.mjs";

const IS_WINDOWS = process.platform === "win32";

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
  };
}
