// Shell launcher module — starts shell engine detached from dashboard process

import { spawn } from "node:child_process";
import { join } from "node:path";
import { chmodSync, accessSync, constants } from "node:fs";
import { resolveBashExe, toBashPath } from "./platform-shim.mjs";

const IS_WINDOWS = process.platform === "win32";

/**
 * Launch shell engine detached with run ID
 * 
 * NOTE: RALPH_RUN_ID and RALPH_RUN_DIR are passed but not yet consumed by
 * launch.sh/ralph.sh. These will be used in future slices for run-aware execution.
 * 
 * @param {Object} options
 * @param {string} options.runId - Unique run identifier
 * @param {string} options.runDir - Run directory path
 * @param {string} options.repoRoot - Repository root path
 * @param {Object} options.runOptions - Run configuration (runMode, parallelism, model)
 * @param {string} [options.shellScript] - Override shell script path (for testing)
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
  shellScript,
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
  
  // Default to ralph/launch.sh if not overridden
  const scriptPath = shellScript || join(repoRoot, "ralph", "launch.sh");
  
  // Verify script exists and is executable
  try {
    accessSync(scriptPath, constants.F_OK);
  } catch {
    return {
      success: false,
      error: `Shell script not found: ${scriptPath}`,
    };
  }
  
  // Make script executable if needed. Skip on Windows: NTFS doesn't carry
  // POSIX exec bits, and chmodSync on Windows is a no-op that can still
  // emit warnings on some filesystems. Bash interprets the shebang itself.
  if (!IS_WINDOWS) {
    try {
      chmodSync(scriptPath, 0o755);
    } catch (err) {
      // Only warn on non-ENOENT errors; ENOENT means already caught above
      if (err.code !== "ENOENT") {
        console.warn(`chmod failed on ${scriptPath}: ${err.message}`);
      }
    }
  }
  
  // Spawn detached process with error handling
  return new Promise((resolve) => {
    const env = {
      ...process.env,
      RALPH_RUN_ID: runId,
      RALPH_RUN_DIR: runDir,
      RALPH_MAIN_REPO: repoRoot,
      RALPH_MODEL: runOptions.model,
      RALPH_PARALLELISM: String(runOptions.parallelism),
      RALPH_RUN_MODE: runOptions.runMode,
    };

    let child;
    if (IS_WINDOWS) {
      // Windows: invoke launch.sh through Git for Windows bash. Direct
      // spawn(scriptPath, ...) fails because Node on Windows cannot honour
      // a shebang. We use `bash -lc "exec '<posix-path>'"` so the recorded
      // PID is launch.sh, not bash.
      let bashExe;
      try {
        bashExe = resolveBashExe(process.env);
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
      const scriptBash = toBashPath(scriptPath);
      child = spawn(bashExe, ["-lc", `exec '${scriptBash}'`], {
        detached: true,
        windowsHide: true,
        stdio: "ignore",
        env,
      });
    } else {
      child = spawn(scriptPath, [], {
        detached: true,
        stdio: "ignore",
        env,
      });
    }
    
    // Handle spawn errors before unref
    child.on("error", (err) => {
      resolve({
        success: false,
        error: `Failed to spawn ${scriptPath}: ${err.message}`,
      });
    });
    
    // On successful spawn, unref and return
    child.on("spawn", () => {
      child.unref();
      resolve({
        success: true,
        pid: child.pid,
      });
    });
  });
}
