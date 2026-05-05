// Run store module — creates and manages durable run directories

import { mkdirSync, writeFileSync, existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

/**
 * Generate a unique run ID with timestamp and random suffix
 * Format: YYYYMMDD-HHMMSS-randomhex
 */
function generateRunId() {
  const now = new Date();
  const datePart = now.toISOString().slice(0, 10).replace(/-/g, "");
  const timePart = now.toISOString().slice(11, 19).replace(/:/g, "");
  const randomPart = randomBytes(4).toString("hex");
  return `${datePart}-${timePart}-${randomPart}`;
}

/**
 * Create a new run with unique ID and persistent state
 * 
 * @param {Object} options
 * @param {string} options.repoRoot - Repository root path
 * @param {Array} options.queue - Selected issue queue
 * @param {Object} options.runOptions - Run configuration (runMode, parallelism, model)
 * @returns {Object} Run details
 * @returns {string} .runId - Unique run identifier
 * @returns {string} .runDir - Run directory path
 * @returns {string} .queuePath - Queue file path
 * @returns {string} .metadataPath - Metadata file path
 */
export function createRun({ repoRoot, queue, runOptions }) {
  // Validate required parameters
  if (!repoRoot || typeof repoRoot !== "string") {
    throw new TypeError("repoRoot is required and must be a string");
  }
  if (!Array.isArray(queue)) {
    throw new TypeError("queue is required and must be an array");
  }
  if (!runOptions || typeof runOptions !== "object") {
    throw new TypeError("runOptions is required and must be an object");
  }
  if (!runOptions.runMode || typeof runOptions.runMode !== "string") {
    throw new TypeError("runOptions.runMode is required and must be a string");
  }
  if (!runOptions.model || typeof runOptions.model !== "string") {
    throw new TypeError("runOptions.model is required and must be a string");
  }
  if (!Number.isFinite(runOptions.parallelism) || 
      !Number.isInteger(runOptions.parallelism) || 
      runOptions.parallelism < 1) {
    throw new TypeError("runOptions.parallelism must be a positive integer");
  }
  
  const runId = generateRunId();
  const runsDir = join(repoRoot, ".ralph", "runs");
  const runDir = join(runsDir, runId);
  
  // Create run directory structure
  mkdirSync(runDir, { recursive: true });
  
  // Write immutable queue file
  const queuePath = join(runDir, "queue.json");
  writeFileSync(queuePath, JSON.stringify(queue, null, 2), "utf-8");
  
  // Write initial metadata
  const metadataPath = join(runDir, "metadata.json");
  const metadata = {
    repoRoot,
    runMode: runOptions.runMode,
    model: runOptions.model,
    parallelism: runOptions.parallelism,
    createdAt: new Date().toISOString(),
  };
  writeFileSync(metadataPath, JSON.stringify(metadata, null, 2), "utf-8");
  
  // Write initial empty status
  const statusPath = join(runDir, "status.json");
  const initialStatus = { items: {} };
  writeFileSync(statusPath, JSON.stringify(initialStatus, null, 2), "utf-8");
  
  return {
    runId,
    runDir,
    queuePath,
    metadataPath,
  };
}

/**
 * Discover active runs from filesystem
 * 
 * @param {string} repoRoot - Repository root path
 * @returns {Array<Object>} Active runs
 * @returns {string} [].runId - Run identifier
 * @returns {string} [].runDir - Run directory path
 * @returns {Object} [].metadata - Run metadata
 * @returns {string} [].queuePath - Queue file path
 */
export function getActiveRuns(repoRoot) {
  // Validate required parameters
  if (!repoRoot || typeof repoRoot !== "string") {
    throw new TypeError("repoRoot is required and must be a string");
  }
  
  const runsDir = join(repoRoot, ".ralph", "runs");
  
  if (!existsSync(runsDir)) {
    return [];
  }
  
  const entries = readdirSync(runsDir, { withFileTypes: true });
  const runs = [];
  
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }
    
    const runId = entry.name;
    const runDir = join(runsDir, runId);
    const metadataPath = join(runDir, "metadata.json");
    const queuePath = join(runDir, "queue.json");
    
    // Skip runs missing required files
    if (!existsSync(metadataPath) || !existsSync(queuePath)) {
      continue;
    }
    
    try {
      const metadata = JSON.parse(readFileSync(metadataPath, "utf-8"));
      
      // Validate metadata has all required fields with correct types
      if (!metadata.repoRoot || 
          !metadata.runMode || 
          !metadata.createdAt ||
          !metadata.model ||
          !Number.isFinite(metadata.parallelism) ||
          !Number.isInteger(metadata.parallelism)) {
        continue;
      }
      
      runs.push({
        runId,
        runDir,
        metadata,
        queuePath,
      });
    } catch {
      // Skip runs with invalid JSON or other read errors
      continue;
    }
  }
  
  return runs;
}

/**
 * Retry a failed issue by resetting it to queued state
 * 
 * @param {Object} options
 * @param {string} options.repoRoot - Repository root path
 * @param {string} options.runId - Run identifier
 * @param {number} options.issueNumber - Issue number to retry
 * @returns {Object} Result
 * @returns {boolean} .success - Whether operation succeeded
 * @returns {string} [.error] - Error message (only if success is false)
 */
export function retryFailedIssue({ repoRoot, runId, issueNumber }) {
  // Validate required parameters
  if (!repoRoot || typeof repoRoot !== "string") {
    return { success: false, error: "repoRoot is required and must be a string" };
  }
  if (!runId || typeof runId !== "string") {
    return { success: false, error: "runId is required and must be a string" };
  }
  if (!Number.isFinite(issueNumber) || !Number.isInteger(issueNumber)) {
    return { success: false, error: "issueNumber must be a finite integer" };
  }

  const runDir = join(repoRoot, ".ralph", "runs", runId);
  const queuePath = join(runDir, "queue.json");
  const statusPath = join(runDir, "status.json");

  // Verify run exists
  if (!existsSync(runDir) || !existsSync(queuePath) || !existsSync(statusPath)) {
    return { success: false, error: `Run ${runId} not found` };
  }

  try {
    // Load queue and status
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));
    const status = JSON.parse(readFileSync(statusPath, "utf-8"));

    // Verify issue is in queue
    const issueInQueue = queue.some((i) => i.number === issueNumber);
    if (!issueInQueue) {
      return { success: false, error: `Issue ${issueNumber} not found in queue` };
    }

    // Verify issue is in failed state
    const itemStatus = status.items[String(issueNumber)];
    if (!itemStatus || itemStatus.status !== "failed") {
      return {
        success: false,
        error: `Issue ${issueNumber} not in failed state (current: ${itemStatus?.status || "unknown"})`,
      };
    }

    // Reset issue to queued state
    status.items[String(issueNumber)] = {
      status: "queued",
      workerId: null,
      pid: null,
      logFile: null,
      startedAt: null,
      error: null,
    };

    // Write updated status
    writeFileSync(statusPath, JSON.stringify(status, null, 2), "utf-8");

    return { success: true };
  } catch (err) {
    return { success: false, error: `Failed to retry issue: ${err.message}` };
  }
}

/**
 * Skip a failed issue by marking it as skipped
 * 
 * @param {Object} options
 * @param {string} options.repoRoot - Repository root path
 * @param {string} options.runId - Run identifier
 * @param {number} options.issueNumber - Issue number to skip
 * @returns {Object} Result
 * @returns {boolean} .success - Whether operation succeeded
 * @returns {string} [.error] - Error message (only if success is false)
 */
export function skipFailedIssue({ repoRoot, runId, issueNumber }) {
  // Validate required parameters
  if (!repoRoot || typeof repoRoot !== "string") {
    return { success: false, error: "repoRoot is required and must be a string" };
  }
  if (!runId || typeof runId !== "string") {
    return { success: false, error: "runId is required and must be a string" };
  }
  if (!Number.isFinite(issueNumber) || !Number.isInteger(issueNumber)) {
    return { success: false, error: "issueNumber must be a finite integer" };
  }

  const runDir = join(repoRoot, ".ralph", "runs", runId);
  const queuePath = join(runDir, "queue.json");
  const statusPath = join(runDir, "status.json");

  // Verify run exists
  if (!existsSync(runDir) || !existsSync(queuePath) || !existsSync(statusPath)) {
    return { success: false, error: `Run ${runId} not found` };
  }

  try {
    // Load queue and status
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));
    const status = JSON.parse(readFileSync(statusPath, "utf-8"));

    // Verify issue is in queue
    const issueInQueue = queue.some((i) => i.number === issueNumber);
    if (!issueInQueue) {
      return { success: false, error: `Issue ${issueNumber} not found in queue` };
    }

    // Verify issue is in failed state
    const itemStatus = status.items[String(issueNumber)];
    if (!itemStatus || itemStatus.status !== "failed") {
      return {
        success: false,
        error: `Issue ${issueNumber} not in failed state (current: ${itemStatus?.status || "unknown"})`,
      };
    }

    // Mark issue as skipped
    status.items[String(issueNumber)] = {
      status: "skipped",
      workerId: null,
      pid: null,
      logFile: null,
      startedAt: null,
      error: null,
    };

    // Write updated status
    writeFileSync(statusPath, JSON.stringify(status, null, 2), "utf-8");

    return { success: true };
  } catch (err) {
    return { success: false, error: `Failed to skip issue: ${err.message}` };
  }
}

/**
 * Remove an unclaimed issue from the queue
 * 
 * @param {Object} options
 * @param {string} options.repoRoot - Repository root path
 * @param {string} options.runId - Run identifier
 * @param {number} options.issueNumber - Issue number to remove
 * @returns {Object} Result
 * @returns {boolean} .success - Whether operation succeeded
 * @returns {string} [.error] - Error message (only if success is false)
 */
export function removeQueuedIssue({ repoRoot, runId, issueNumber }) {
  // Validate required parameters
  if (!repoRoot || typeof repoRoot !== "string") {
    return { success: false, error: "repoRoot is required and must be a string" };
  }
  if (!runId || typeof runId !== "string") {
    return { success: false, error: "runId is required and must be a string" };
  }
  if (!Number.isFinite(issueNumber) || !Number.isInteger(issueNumber)) {
    return { success: false, error: "issueNumber must be a finite integer" };
  }

  const runDir = join(repoRoot, ".ralph", "runs", runId);
  const queuePath = join(runDir, "queue.json");
  const statusPath = join(runDir, "status.json");

  // Verify run exists
  if (!existsSync(runDir) || !existsSync(queuePath)) {
    return { success: false, error: `Run ${runId} not found` };
  }

  try {
    // Load queue
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));

    // Find issue index
    const issueIndex = queue.findIndex((i) => i.number === issueNumber);
    if (issueIndex === -1) {
      return { success: false, error: `Issue ${issueNumber} not found in queue` };
    }

    // Load status (if exists) to check if issue is claimed/completed
    if (existsSync(statusPath)) {
      const status = JSON.parse(readFileSync(statusPath, "utf-8"));
      const itemStatus = status.items[String(issueNumber)];

      // Reject if issue is already claimed or in terminal state
      if (itemStatus && ["claimed", "running", "merged", "pr-opened"].includes(itemStatus.status)) {
        return {
          success: false,
          error: `Issue ${issueNumber} is already claimed or completed (state: ${itemStatus.status})`,
        };
      }
    }

    // Remove issue from queue
    queue.splice(issueIndex, 1);

    // Write updated queue
    writeFileSync(queuePath, JSON.stringify(queue, null, 2), "utf-8");

    return { success: true };
  } catch (err) {
    return { success: false, error: `Failed to remove issue: ${err.message}` };
  }
}

/**
 * Reorder an unclaimed issue in the queue
 * 
 * @param {Object} options
 * @param {string} options.repoRoot - Repository root path
 * @param {string} options.runId - Run identifier
 * @param {number} options.issueNumber - Issue number to reorder
 * @param {number} options.newIndex - New zero-based index position
 * @returns {Object} Result
 * @returns {boolean} .success - Whether operation succeeded
 * @returns {string} [.error] - Error message (only if success is false)
 */
export function reorderQueuedIssue({ repoRoot, runId, issueNumber, newIndex }) {
  // Validate required parameters
  if (!repoRoot || typeof repoRoot !== "string") {
    return { success: false, error: "repoRoot is required and must be a string" };
  }
  if (!runId || typeof runId !== "string") {
    return { success: false, error: "runId is required and must be a string" };
  }
  if (!Number.isFinite(issueNumber) || !Number.isInteger(issueNumber)) {
    return { success: false, error: "issueNumber must be a finite integer" };
  }
  if (!Number.isFinite(newIndex) || !Number.isInteger(newIndex) || newIndex < 0) {
    return { success: false, error: "newIndex must be a non-negative integer" };
  }

  const runDir = join(repoRoot, ".ralph", "runs", runId);
  const queuePath = join(runDir, "queue.json");
  const statusPath = join(runDir, "status.json");

  // Verify run exists
  if (!existsSync(runDir) || !existsSync(queuePath)) {
    return { success: false, error: `Run ${runId} not found` };
  }

  try {
    // Load queue
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));

    // Find issue index
    const issueIndex = queue.findIndex((i) => i.number === issueNumber);
    if (issueIndex === -1) {
      return { success: false, error: `Issue ${issueNumber} not found in queue` };
    }

    // Validate newIndex
    if (newIndex >= queue.length) {
      return { success: false, error: `New index ${newIndex} is invalid (queue length: ${queue.length})` };
    }

    // Load status (if exists) to check if issue is claimed/completed
    if (existsSync(statusPath)) {
      const status = JSON.parse(readFileSync(statusPath, "utf-8"));
      const itemStatus = status.items[String(issueNumber)];

      // Reject if issue is already claimed or in terminal state
      if (itemStatus && ["claimed", "running", "merged", "pr-opened"].includes(itemStatus.status)) {
        return {
          success: false,
          error: `Issue ${issueNumber} is already claimed or completed (state: ${itemStatus.status})`,
        };
      }
    }

    // Reorder: remove from current position and insert at new position
    const [issue] = queue.splice(issueIndex, 1);
    queue.splice(newIndex, 0, issue);

    // Write updated queue
    writeFileSync(queuePath, JSON.stringify(queue, null, 2), "utf-8");

    return { success: true };
  } catch (err) {
    return { success: false, error: `Failed to reorder issue: ${err.message}` };
  }
}
