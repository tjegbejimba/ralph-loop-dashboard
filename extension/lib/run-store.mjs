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
