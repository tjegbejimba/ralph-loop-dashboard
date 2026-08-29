// Shell launcher module — starts shell engine detached from dashboard process

import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  accessSync,
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { homedir } from "node:os";
import {
  isAlive,
  readPidFile,
  removePidFile,
  resolveBashExe,
  toBashPath,
  validateWindowsParallelism,
  writePidFile,
} from "./platform-shim.mjs";

const IS_WINDOWS = process.platform === "win32";
const DEFAULT_SPAWN_CHECK_MS = 100;
const DEFAULT_CONFIRM_START_MS = 30000;
const DEFAULT_STARTUP_POLL_MS = 50;
const DEFAULT_STARTUP_MAX_MS = 300000;
const DIAGNOSTIC_TAIL_BYTES = 16 * 1024;
const LAUNCH_PROTOCOL_MARKER = "# RALPH_LAUNCH_PROTOCOL: 1";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function formatExit({ code, signal }) {
  if (code !== null && code !== undefined) return `exited with code ${code}`;
  return `exited from signal ${signal || "unknown"}`;
}

function readStartupProgress(runDir) {
  const startupPath = join(runDir, "startup.json");
  try {
    return readFileSync(startupPath, "utf-8").trim() || null;
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function readFileSize(path) {
  let fd;
  try {
    fd = openSync(path, "r");
    return fstatSync(fd).size;
  } catch (error) {
    if (error.code === "ENOENT") return 0;
    throw error;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function resolveSetupLockPaths(repoRoot) {
  const lockPaths = [join(repoRoot, ".ralph", "launch.lock")];
  try {
    const rawCommonDir = execFileSync(
      "git",
      ["-C", repoRoot, "rev-parse", "--git-common-dir"],
      { encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] },
    ).trim();
    if (rawCommonDir) {
      const commonDir = isAbsolute(rawCommonDir)
        ? rawCommonDir
        : resolve(repoRoot, rawCommonDir);
      lockPaths.push(join(commonDir, "ralph-launch.lock"));
    }
  } catch {
    // Non-git launcher fixtures have only the per-repo setup lock.
  }
  return [...new Set(lockPaths)];
}

function recoveryText(execFile, command, args, options = {}) {
  const output = execFile(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...options,
  });
  return String(output ?? "").trim();
}

function recoveryJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function recoveryPathKey(path, isWindows) {
  const normalized = path.replaceAll("\\", "/").replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);
  return isWindows ? normalized.toLowerCase() : normalized;
}

function assertExactRecovery({ repoRoot, runId, runDir, recovery, execFile, isWindows }) {
  const fail = (message) => { throw new Error(`Recovery proof failed: ${message}`); };
  const pathKey = (path) => recoveryPathKey(path, isWindows);
  const ralphDir = join(repoRoot, ".ralph");
  const expectedRunDir = join(ralphDir, "runs", recovery.runId);
  if (runId !== recovery.runId || resolve(runDir) !== resolve(expectedRunDir)) fail("run directory mismatch");

  let worktree;
  try { worktree = realpathSync.native(recovery.worktreePath); } catch { fail("worktree does not exist"); }
  if (pathKey(worktree) !== pathKey(recovery.worktreePath)) fail("worktree path is not canonical");
  const git = (args) => recoveryText(execFile, "git", ["-C", worktree, ...args]);
  if (pathKey(git(["rev-parse", "--show-toplevel"])) !== pathKey(worktree)) fail("worktree root mismatch");
  if (git(["branch", "--show-current"]) !== recovery.branch) fail("worktree branch mismatch");
  if (!git(["status", "--porcelain"])) fail("worktree is not dirty");
  const registered = recoveryText(execFile, "git", ["-C", repoRoot, "worktree", "list", "--porcelain"])
    .split(/\r?\n/).filter((line) => line.startsWith("worktree ")).map((line) => pathKey(line.slice(9)));
  if (!registered.includes(pathKey(worktree))) fail("worktree is not registered");
  try { recoveryText(execFile, "git", ["-C", worktree, "merge-base", "--is-ancestor", recovery.baseCommit, "HEAD"]); }
  catch { fail("base commit is not an ancestor of the worker branch"); }

  let queue, status, ownership, state, events;
  try {
    queue = recoveryJson(join(runDir, "queue.json"));
    status = recoveryJson(join(runDir, "status.json"));
    ownership = recoveryJson(join(runDir, "ownership.json"));
    state = recoveryJson(join(ralphDir, "state.json"));
    events = readFileSync(join(runDir, "copilot-sessions.jsonl"), "utf8").trim().split(/\r?\n/).map(JSON.parse);
  } catch { fail("run evidence is missing or malformed"); }
  if (queue.length !== 1 || Number(queue[0]?.number) !== recovery.issueNumber) fail("queue identity mismatch");
  const item = status.items?.[recovery.issueNumber];
  if (item?.status !== "failed" || item?.error !== "Worker process died" || Number(item.workerId) !== recovery.workerId) {
    fail("status is not the exact dead-worker failure");
  }
  if (ownership.run_id !== recovery.runId || Number(ownership.prd_number) !== recovery.prdNumber
      || ownership.initial_base_sha !== recovery.baseCommit) fail("immutable ownership mismatch");
  if (state.active_run_id !== recovery.runId || Number(state.active_prd) !== recovery.prdNumber
      || !state.claims || Object.keys(state.claims).length !== 0) fail("state has conflicting ownership or claims");
  const workerEvents = events.filter((event) =>
    event.runId === recovery.runId && Number(event.issue) === recovery.issueNumber && Number(event.workerId) === recovery.workerId);
  if (workerEvents.length !== 1 || workerEvents[0].event !== "start"
      || workerEvents[0].sessionId !== recovery.sessionId
      || pathKey(workerEvents[0].cwd) !== pathKey(worktree)) fail("session ledger identity or lifecycle mismatch");

  for (const pidFile of [join(ralphDir, "launcher.pid"), join(ralphDir, "lock", `worker-${recovery.workerId}`, "owner")]) {
    if (!existsSync(pidFile)) continue;
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    if (!Number.isInteger(pid) || pid <= 0) fail("process ownership evidence is malformed");
    if (isAlive(pid)) fail("launcher or worker is still live");
  }
  const sessionRoot = process.env.RALPH_COPILOT_SESSION_STATE_DIR || join(homedir(), ".copilot", "session-state");
  const sessionDir = join(sessionRoot, recovery.sessionId);
  const workspace = readFileSync(join(sessionDir, "workspace.yaml"), "utf8");
  if (!workspace.includes(`id: ${recovery.sessionId}`) || !workspace.split(/\r?\n/)
    .some((line) => line.startsWith("cwd: ") && pathKey(line.slice(5).replace(/^["']|["']$/g, "")) === pathKey(worktree))) {
    fail("Copilot session workspace identity mismatch");
  }
  for (const name of readdirSync(sessionDir).filter((entry) => entry.startsWith("inuse."))) {
    const match = /^inuse\.([1-9][0-9]*)\.lock$/.exec(name);
    if (!match) fail("session lock evidence is malformed");
    if (isAlive(Number(match[1]))) fail("Copilot session is still live");
  }
  const gh = process.env.RALPH_GH_BIN || "gh";
  const ghOptions = { cwd: repoRoot };
  const targetRepo = recoveryText(execFile, gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], ghOptions);
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(targetRepo)) fail("target repository identity is malformed");
  const issue = JSON.parse(recoveryText(execFile, gh, ["issue", "view", String(recovery.issueNumber), "--repo", targetRepo, "--json", "number,state,labels"], ghOptions));
  const labels = new Set((issue.labels || []).map((label) => label.name));
  if (Number(issue.number) !== recovery.issueNumber || issue.state !== "OPEN"
      || !labels.has("ralph:running") || !labels.has("work:slice")) fail("issue is not OPEN and Ralph-owned");
  const prs = JSON.parse(recoveryText(execFile, gh, ["pr", "list", "--repo", targetRepo, "--state", "open", "--head", recovery.branch, "--json", "number"], ghOptions));
  if (!Array.isArray(prs) || prs.length !== 0) fail("worker branch already has an open pull request");
  const script = join(worktree, ".ralph", "ralph.sh");
  accessSync(script, constants.R_OK);
  return { worktree, script, targetRepo };
}

function cleanupTokenOwnedSetupLocks(lockPaths, launchToken) {
  const retained = [];
  const errors = [];

  for (const lockPath of lockPaths) {
    if (!existsSync(lockPath)) continue;

    let observedToken;
    try {
      observedToken = readFileSync(join(lockPath, "token"), "utf-8").trim();
    } catch (error) {
      retained.push(`${lockPath} (missing or unreadable launch token: ${error.code ?? error.message})`);
      continue;
    }

    if (observedToken !== launchToken) {
      retained.push(`${lockPath} (owned by a different launch)`);
      continue;
    }

    try {
      rmSync(lockPath, { recursive: true, force: false });
    } catch (error) {
      errors.push(`${lockPath}: ${error.message}`);
    }
  }

  return { retained, errors };
}

function terminateWindowsProcessTree(pid) {
  if (!isAlive(pid)) return;
  try {
    execFileSync("taskkill.exe", ["/PID", String(pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
    });
  } catch (error) {
    if (isAlive(pid)) {
      throw new Error(`Failed to terminate Windows launcher process tree ${pid}: ${error.message}`);
    }
  }
}

function terminateLauncher(pid, { isWindows, killProcess }) {
  if (typeof killProcess === "function") {
    killProcess(pid, "SIGTERM");
    return;
  }
  if (isWindows) {
    terminateWindowsProcessTree(pid);
    return;
  }
  process.kill(pid, "SIGTERM");
}

async function waitForExit(getExit, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const exit = getExit();
    if (exit) return exit;
    await sleep(Math.min(25, Math.max(0, deadline - Date.now())));
  }
  return getExit();
}

function readDiagnosticTail(logPath, maxBytes = DIAGNOSTIC_TAIL_BYTES) {
  let fd;
  try {
    fd = openSync(logPath, "r");
    const size = fstatSync(fd).size;
    if (size === 0) return "";
    const bytesToRead = Math.min(size, maxBytes);
    const buffer = Buffer.alloc(bytesToRead);
    readSync(fd, buffer, 0, bytesToRead, size - bytesToRead);
    return buffer.toString("utf-8").trim();
  } catch (error) {
    if (error.code === "ENOENT") return "";
    return `[launcher log unreadable: ${error.message}]`;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function withFailureDetails(message, launcherLog, cleanup = null) {
  const details = [message];
  const diagnostics = readDiagnosticTail(launcherLog);
  details.push(
    diagnostics
      ? `Launcher diagnostics (${launcherLog}):\n${diagnostics}`
      : `Launcher diagnostics: ${launcherLog} (empty)`,
  );
  if (cleanup?.retained?.length) {
    details.push(`Setup locks retained fail-closed:\n${cleanup.retained.join("\n")}`);
  }
  if (cleanup?.errors?.length) {
    details.push(`Setup lock cleanup errors:\n${cleanup.errors.join("\n")}`);
  }
  return details.join("\n");
}

async function waitForStartup({
  child,
  getExit,
  scriptPath,
  confirmStarted,
  getStartupProgress,
  getLauncherLogSize,
  initialLauncherLogSize,
  startupTimeoutMs,
  startupMaxTimeoutMs,
  startupPollMs,
}) {
  const timeoutMs = startupTimeoutMs ?? (confirmStarted ? DEFAULT_CONFIRM_START_MS : DEFAULT_SPAWN_CHECK_MS);
  const maxTimeoutMs = Math.max(
    startupMaxTimeoutMs ?? DEFAULT_STARTUP_MAX_MS,
    timeoutMs,
  );
  const pollMs = startupPollMs ?? DEFAULT_STARTUP_POLL_MS;
  const startedAt = Date.now();
  let inactivityDeadline = startedAt + timeoutMs;
  const absoluteDeadline = startedAt + maxTimeoutMs;
  let lastProgress = null;
  let lastLauncherLogSize = initialLauncherLogSize ?? 0;

  if (typeof confirmStarted === "function") {
    while (Date.now() < inactivityDeadline && Date.now() < absoluteDeadline) {
      const exit = getExit();
      if (exit && exit.code !== 0) {
        return { success: false, error: `${scriptPath} ${formatExit(exit)} during startup` };
      }
      let confirmed = false;
      try {
        confirmed = await confirmStarted();
      } catch (err) {
        return {
          success: false,
          error: `Startup confirmation failed for ${scriptPath}: ${String(err.message || err)}`,
        };
      }
      if (confirmed) {
        return { success: true, pid: child.pid };
      }
      if (typeof getStartupProgress === "function") {
        let progress;
        try {
          progress = await getStartupProgress();
        } catch (err) {
          return {
            success: false,
            error: `Startup progress read failed for ${scriptPath}: ${String(err.message || err)}`,
          };
        }
        if (progress !== null && progress !== undefined && progress !== lastProgress) {
          lastProgress = progress;
          inactivityDeadline = Math.min(Date.now() + timeoutMs, absoluteDeadline);
        }
      }
      if (typeof getLauncherLogSize === "function") {
        let launcherLogSize;
        try {
          launcherLogSize = await getLauncherLogSize();
        } catch (err) {
          return {
            success: false,
            error: `Launcher log progress read failed for ${scriptPath}: ${String(err.message || err)}`,
          };
        }
        if (launcherLogSize > lastLauncherLogSize) {
          lastLauncherLogSize = launcherLogSize;
          inactivityDeadline = Math.min(Date.now() + timeoutMs, absoluteDeadline);
        }
      }
      const deadline = Math.min(inactivityDeadline, absoluteDeadline);
      await sleep(Math.min(pollMs, Math.max(0, deadline - Date.now())));
    }
    const exit = getExit();
    if (exit && exit.code !== 0) {
      return { success: false, error: `${scriptPath} ${formatExit(exit)} during startup` };
    }
    return {
      success: false,
      error: Date.now() >= absoluteDeadline
        ? `Reached hard startup limit waiting for Ralph workers after launching ${scriptPath}`
        : `Timed out waiting for startup progress after launching ${scriptPath}`,
      timedOut: true,
    };
  }

  while (Date.now() < inactivityDeadline) {
    const exit = getExit();
    if (exit) {
      if (exit.code === 0) return { success: true, pid: child.pid };
      return { success: false, error: `${scriptPath} ${formatExit(exit)} during startup` };
    }
    await sleep(pollMs);
  }
  return { success: true, pid: child.pid };
}

/**
 * Launch shell engine detached with run ID
 * 
 * @param {Object} options
 * @param {string} options.runId - Unique run identifier
 * @param {string} options.runDir - Run directory path
 * @param {string} options.repoRoot - Repository root path
 * @param {Object} options.runOptions - Run configuration (runMode, parallelism, model)
 * @param {Object} [options.base] - Preflight-approved remote, branch, and commit
 * @param {string} [options.shellScript] - Override shell script path (for testing)
 * @param {Function} [options.confirmStarted] - Optional startup verifier
 * @param {Function} [options.getStartupProgress] - Optional setup progress probe
 * @param {number} [options.startupTimeoutMs] - Startup confirmation timeout
 * @param {number} [options.startupMaxTimeoutMs] - Hard cap across progress renewals
 * @param {number} [options.startupPollMs] - Startup confirmation poll interval
 * @param {boolean} [options.isWindows] - Platform override for tests
 * @param {Function} [options.resolveBash] - Bash resolver override for tests
 * @param {Function} [options.toBash] - Path converter override for tests
 * @param {Function} [options.killProcess] - Process killer override for tests
 * @returns {Promise<Object>} Launch result
 * @returns {boolean} .success - Whether launch succeeded
 * @returns {number} [.pid] - Process ID (only if success is true)
 * @returns {string} [.error] - Error message (only if success is false)
 */
export async function launchRun({
  runId,
  runDir,
  repoRoot,
  runOptions,
  base,
  shellScript,
  confirmStarted,
  getStartupProgress,
  startupTimeoutMs,
  startupMaxTimeoutMs,
  startupPollMs,
  isWindows = IS_WINDOWS,
  resolveBash = resolveBashExe,
  toBash = toBashPath,
  killProcess = null,
  recoveryExecFile = execFileSync,
  recovery,
}) {
  // Validate required parameters
  if (!runId || typeof runId !== "string") {
    throw new TypeError("runId is required and must be a string");
  }
  if (!runDir || typeof runDir !== "string") {
    throw new TypeError("runDir is required and must be a string");
  }
  if (!repoRoot || typeof repoRoot !== "string") {
    throw new TypeError("repoRoot is required and must be a string");
  }
  if (!runOptions || typeof runOptions !== "object") {
    throw new TypeError("runOptions is required and must be an object");
  }
  if (!runOptions.model || typeof runOptions.model !== "string") {
    throw new TypeError("runOptions.model is required and must be a string");
  }
  if (!Number.isFinite(runOptions.parallelism) || 
      !Number.isInteger(runOptions.parallelism)) {
    throw new TypeError("runOptions.parallelism must be a finite integer");
  }
  if (!runOptions.runMode || typeof runOptions.runMode !== "string") {
    throw new TypeError("runOptions.runMode is required and must be a string");
  }
  
  let recoveryLaunch;
  if (recovery) {
    try {
      recoveryLaunch = assertExactRecovery({
        repoRoot, runId, runDir, recovery, execFile: recoveryExecFile, isWindows,
      });
    } catch (error) {
      return { success: false, error: String(error.message || error) };
    }
  }
  const scriptPath = recoveryLaunch?.script || shellScript || join(repoRoot, ".ralph", "launch.sh");
  const launcherPidFile = join(repoRoot, ".ralph", "launcher.pid");
  
  // Verify script exists and is executable
  try {
    accessSync(scriptPath, constants.F_OK);
  } catch {
    return {
      success: false,
      error: `Shell script not found: ${scriptPath}`,
    };
  }
  if (!recovery && !shellScript && typeof confirmStarted === "function") {
    const installedScript = readFileSync(scriptPath, "utf-8");
    if (!installedScript.includes(LAUNCH_PROTOCOL_MARKER)) {
      return {
        success: false,
        error:
          `Installed launcher does not support the controller startup protocol: ${scriptPath}. ` +
          `Refresh this repository's Ralph scripts from canonical main before launching.`,
      };
    }
  }
  if (isWindows) {
    const existingPid = readPidFile(launcherPidFile);
    if (existingPid && isAlive(existingPid)) {
      return {
        success: false,
        error: `Ralph launcher is already running with PID ${existingPid}.`,
      };
    }
    if (existingPid) removePidFile(launcherPidFile, existingPid);
  }
  
  // Make script executable if needed. Skip on Windows: NTFS doesn't carry
  // POSIX exec bits, and chmodSync on Windows is a no-op that can still
  // emit warnings on some filesystems. Bash interprets the shebang itself.
  if (!isWindows) {
    try {
      chmodSync(scriptPath, 0o755);
    } catch (err) {
      // Only warn on non-ENOENT errors; ENOENT means already caught above
      if (err.code !== "ENOENT") {
        console.warn(`chmod failed on ${scriptPath}: ${err.message}`);
      }
    }
  }

  mkdirSync(runDir, { recursive: true });
  const launcherLog = join(runDir, "launcher.log");
  try {
    closeSync(openSync(launcherLog, "a"));
  } catch (error) {
    return {
      success: false,
      error: `Cannot open launcher diagnostics at ${launcherLog}: ${error.message}`,
    };
  }
  const initialLauncherLogSize = readFileSize(launcherLog);
  const launchToken = randomUUID();

  const childResult = await new Promise((resolve) => {
    const env = {
      ...process.env,
      RALPH_RUN_ID: runId,
      RALPH_RUN_DIR: runDir,
      RALPH_MAIN_REPO: repoRoot,
      RALPH_MODEL: runOptions.model,
      RALPH_PARALLELISM: String(runOptions.parallelism),
      RALPH_RUN_MODE: runOptions.runMode,
      RALPH_LAUNCH_TOKEN: launchToken,
      RALPH_LAUNCH_LOG: isWindows ? toBash(launcherLog) : launcherLog,
    };
    if (base) {
      env.RALPH_BASE_REMOTE = base.remote;
      env.RALPH_BASE_BRANCH = base.branch;
      env.RALPH_BASE_COMMIT = base.commit;
    }
    if (recovery) {
      Object.assign(env, {
        RALPH_RECOVERY_RUN_ID: recovery.runId,
        RALPH_RECOVERY_ISSUE_NUMBER: String(recovery.issueNumber),
        RALPH_RECOVERY_WORKER_ID: String(recovery.workerId),
        RALPH_RECOVERY_SESSION_ID: recovery.sessionId,
        RALPH_RECOVERY_WORKTREE_PATH: isWindows ? toBash(recoveryLaunch.worktree) : recoveryLaunch.worktree,
        RALPH_RECOVERY_BRANCH: recovery.branch,
        RALPH_RECOVERY_PRD_NUMBER: String(recovery.prdNumber),
        RALPH_RECOVERY_BASE_COMMIT: recovery.baseCommit,
        RALPH_LOG_DIR: isWindows ? toBash(join(repoRoot, ".ralph", "logs")) : join(repoRoot, ".ralph", "logs"),
        RALPH_REPO: recoveryLaunch.targetRepo,
      });
    }
    const launchArgs = runOptions.runMode === "one-pass" ? ["--once"] : [];
    const revalidate = () => {
      const current = assertExactRecovery({ repoRoot, runId, runDir, recovery, execFile: recoveryExecFile, isWindows });
      if (current.targetRepo !== recoveryLaunch.targetRepo) throw new Error("target repository identity changed");
    };

    let child;
    let exit = null;
    if (isWindows) {
      const validation = validateWindowsParallelism(runOptions.parallelism);
      if (!validation.ok) {
        resolve({ success: false, error: validation.error });
        return;
      }
      // Windows: invoke launch.sh through Git for Windows bash. Direct
      // spawn(scriptPath, ...) fails because Node on Windows cannot honour
      // a shebang. Pass the script as bash's file argument instead of using
      // a login shell: Git Bash startup scripts can fork before launch.sh,
      // which is unreliable in native Windows detached mode.
      let bashExe;
      try {
        bashExe = resolveBash(process.env);
      } catch (err) {
        resolve({ success: false, error: String(err.message || err) });
        return;
      }
      if (!bashExe) {
        resolve({
          success: false,
          error:
            `Could not locate Git Bash. Install Git for Windows (https://git-scm.com/download/win), ` +
            `or set RALPH_BASH_EXE to your bash.exe path.`,
        });
        return;
      }
      const scriptBash = toBash(scriptPath);
      try { if (recovery) revalidate(); } catch (error) {
        resolve({ success: false, error: `Recovery proof changed before spawn: ${String(error.message || error)}` });
        return;
      }
      const windowsLaunchArgs = recovery ? ["--once"] : ["--foreground", ...launchArgs];
      child = spawn(bashExe, [scriptBash, ...windowsLaunchArgs], {
        cwd: recoveryLaunch?.worktree || repoRoot,
        detached: true,
        windowsHide: true,
        stdio: "ignore",
        env,
      });
    } else {
      try { if (recovery) revalidate(); } catch (error) {
        resolve({ success: false, error: `Recovery proof changed before spawn: ${String(error.message || error)}` });
        return;
      }
      child = spawn(scriptPath, recovery ? ["--once"] : launchArgs, {
        cwd: recoveryLaunch?.worktree || repoRoot,
        detached: true,
        stdio: "ignore",
        env,
      });
    }

    child.once("exit", (code, signal) => {
      exit = { code, signal };
    });
    
    // Handle spawn errors before unref
    child.on("error", (err) => {
      resolve({
        success: false,
        error: withFailureDetails(`Failed to spawn ${scriptPath}: ${err.message}`, launcherLog),
      });
    });
    
    // On successful spawn, unref and confirm startup
    child.on("spawn", () => {
      let pidfileOwned = false;
      if (isWindows) {
        try {
          writePidFile(launcherPidFile, child.pid, { exclusive: true });
          pidfileOwned = true;
        } catch (err) {
          resolve({
            child,
            getExit: () => exit,
            pidfileOwned,
            startupError: `Failed to claim launcher pidfile: ${String(err.message || err)}`,
          });
          return;
        }
      }
      child.unref();
      resolve({ child, getExit: () => exit, pidfileOwned });
    });
  });

  if (childResult.success === false) {
    return childResult;
  }

  const result = childResult.startupError
    ? { success: false, error: childResult.startupError }
    : await waitForStartup({
      child: childResult.child,
      getExit: childResult.getExit,
      scriptPath,
      confirmStarted,
      getStartupProgress: getStartupProgress ?? (() => readStartupProgress(runDir)),
      getLauncherLogSize: () => readFileSize(launcherLog),
      initialLauncherLogSize,
      startupTimeoutMs,
      startupMaxTimeoutMs,
      startupPollMs,
    });
  if (!result.success) {
    let terminationError = null;
    let cleanup = null;
    try {
      terminateLauncher(childResult.child.pid, { isWindows, killProcess });
    } catch (error) {
      if (isAlive(childResult.child.pid)) terminationError = error;
    }
    const terminated = await waitForExit(childResult.getExit);
    if (terminated) {
      cleanup = cleanupTokenOwnedSetupLocks(resolveSetupLockPaths(repoRoot), launchToken);
    } else {
      terminationError ??= new Error(
        `Launcher process ${childResult.child.pid} did not exit; setup locks were retained fail-closed.`,
      );
    }
    if (isWindows && childResult.pidfileOwned && terminated) {
      removePidFile(launcherPidFile, childResult.child.pid);
    }
    let error = result.error;
    if (terminationError) error += `\n${terminationError.message}`;
    return {
      ...result,
      pid: childResult.child.pid,
      launcherLog,
      error: withFailureDetails(error, launcherLog, cleanup),
    };
  }
  return { ...result, launcherLog };
}
