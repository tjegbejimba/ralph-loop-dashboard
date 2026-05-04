// Shell launcher module — starts shell engine detached from dashboard process

import { spawn } from "node:child_process";
import { join } from "node:path";
import { chmodSync, accessSync, constants } from "node:fs";

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
  
  // Make script executable if needed
  try {
    chmodSync(scriptPath, 0o755);
  } catch (err) {
    // Only warn on non-ENOENT errors; ENOENT means already caught above
    if (err.code !== "ENOENT") {
      console.warn(`chmod failed on ${scriptPath}: ${err.message}`);
    }
  }
  
  // Spawn detached process with error handling
  return new Promise((resolve) => {
    const child = spawn(scriptPath, [], {
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        RALPH_RUN_ID: runId,
        RALPH_RUN_DIR: runDir,
        RALPH_MAIN_REPO: repoRoot,
        RALPH_MODEL: runOptions.model,
        RALPH_PARALLELISM: String(runOptions.parallelism),
        RALPH_RUN_MODE: runOptions.runMode,
      },
    });
    
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
