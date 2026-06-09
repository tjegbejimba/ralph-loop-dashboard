// Platform launcher for Ralph loops. Keeps process/log/pidfile behavior aligned
// with the dashboard's historical start path.

import { spawn } from "node:child_process";
import { existsSync, openSync } from "node:fs";
import { join } from "node:path";
import {
  resolveBashExe,
  toBashPath,
  validateWindowsParallelism,
  writePidFile,
} from "./platform-shim.mjs";

const IS_WINDOWS = process.platform === "win32";

function buildLaunchEnv({ repoRoot, runId, runDir, runOptions, isWindows = IS_WINDOWS }) {
  const env = {
    ...process.env,
    RALPH_MAIN_REPO: repoRoot,
    RALPH_RUN_ID: runId,
    RALPH_RUN_DIR: runDir,
    RALPH_RUN_MODE: runOptions.runMode,
    RALPH_PARALLELISM: String(runOptions.parallelism),
  };
  if (!isWindows) {
    env.PATH = `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || ""}`;
  }
  if (runOptions.model) {
    env.RALPH_MODEL = runOptions.model;
  }
  return env;
}

export async function launchLoop({
  repoRoot,
  runId,
  runDir,
  runOptions,
  isWindows = IS_WINDOWS,
}) {
  const launcher = join(repoRoot, ".ralph", "launch.sh");
  if (!existsSync(launcher)) {
    return { success: false, error: `launcher not found: ${launcher}` };
  }

  if (isWindows) {
    return launchLoopWindows({ repoRoot, runId, runDir, runOptions, launcher });
  }

  try {
    const out = openSync(join(repoRoot, ".ralph", "loop.out"), "a");
    const args = [launcher];
    if (runOptions.runMode === "one-pass") {
      args.push("--once");
    }

    const child = spawn("bash", args, {
      cwd: repoRoot,
      detached: true,
      stdio: ["ignore", out, out],
      env: buildLaunchEnv({ repoRoot, runId, runDir, runOptions, isWindows: false }),
    });
    child.unref();
    return { success: true, pid: child.pid };
  } catch (err) {
    return { success: false, error: String(err.message || err) };
  }
}

async function launchLoopWindows({ repoRoot, runId, runDir, runOptions }) {
  const validation = validateWindowsParallelism(runOptions.parallelism);
  if (!validation.ok) {
    return { success: false, error: validation.error };
  }
  const normalizedRunOptions = {
    ...runOptions,
    parallelism: validation.parallelism,
  };

  let bashExe;
  try {
    bashExe = resolveBashExe(process.env);
  } catch (err) {
    return { success: false, error: String(err.message || err) };
  }
  if (!bashExe) {
    return {
      success: false,
      error:
        `Could not locate Git Bash. Install Git for Windows (https://git-scm.com/download/win), ` +
        `or set RALPH_BASH_EXE to your bash.exe path. See docs/adr/0002.`,
    };
  }

  const repoRootBash = toBashPath(repoRoot);
  const logPathBash = toBashPath(join(repoRoot, ".ralph", "loop.out"));
  const launcherArgs = ["--foreground"];
  if (runOptions.runMode === "one-pass") launcherArgs.push("--once");
  const launcherCmd = launcherArgs.join(" ");
  const bashCommand = `cd '${repoRootBash}' && exec ./.ralph/launch.sh ${launcherCmd} >> '${logPathBash}' 2>&1`;

  try {
    const child = spawn(bashExe, ["-lc", bashCommand], {
      cwd: repoRoot,
      detached: true,
      windowsHide: true,
      stdio: "ignore",
      env: buildLaunchEnv({
        repoRoot,
        runId,
        runDir,
        runOptions: normalizedRunOptions,
        isWindows: true,
      }),
    });
    child.unref();
    if (typeof child.pid !== "number") {
      return { success: false, error: "spawn returned no pid" };
    }
    writePidFile(join(repoRoot, ".ralph", "launcher.pid"), child.pid);
    return { success: true, pid: child.pid };
  } catch (err) {
    return { success: false, error: String(err.message || err) };
  }
}
