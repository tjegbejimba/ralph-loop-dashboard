// Preflight module — validates launch conditions and blocks unsafe starts

import { existsSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";

/**
 * Execute a command and return result
 * @param {string} command - Command to execute
 * @param {string[]} args - Command arguments
 * @returns {Promise<Object>} Result with exitCode, stdout, stderr
 */
async function execCommand(command, args = []) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10000, // 10 second timeout
    });
    
    let stdout = "";
    let stderr = "";
    
    proc.stdout?.on("data", (data) => { stdout += data; });
    proc.stderr?.on("data", (data) => { stderr += data; });
    
    proc.on("close", (code) => {
      resolve({
        exitCode: code ?? 1,
        stdout: stdout.trim(),
        stderr: stderr.trim(),
      });
    });
    
    proc.on("error", (err) => {
      resolve({
        exitCode: 1,
        stdout: "",
        stderr: err.message,
      });
    });
  });
}

/**
 * Default GitHub auth checker
 */
async function defaultGhAuthCheck() {
  return execCommand("gh", ["auth", "status"]);
}

/**
 * Default GitHub repo checker
 */
async function defaultGhRepoCheck(repo) {
  return execCommand("gh", ["repo", "view", repo, "--json", "name"]);
}

/**
 * Run preflight checks before launching the Ralph loop
 * 
 * @param {Object} options
 * @param {string} options.repoRoot - Repository root path
 * @param {Array<Object>} options.queue - Selected issue queue
 * @param {Object} options.runOptions - Run configuration (runMode, parallelism, model)
 * @param {Function} [options.execGhAuth] - GitHub auth checker (for testing)
 * @param {Function} [options.execGhRepo] - GitHub repo checker (for testing)
 * @returns {Promise<Object>} Preflight result
 * @returns {boolean} .passed - Whether all blocking checks passed
 * @returns {Array<Object>} .checks - Individual check results
 */
export async function runPreflight({
  repoRoot,
  queue,
  runOptions,
  execGhAuth = defaultGhAuthCheck,
  execGhRepo = defaultGhRepoCheck,
}) {
  const checks = [];
  
  // Check 1: Queue not empty
  const queueEmpty = !Array.isArray(queue) || queue.length === 0;
  checks.push({
    id: "queue-not-empty",
    label: "Queue has issues",
    status: queueEmpty ? "fail" : "pass",
    message: queueEmpty 
      ? "Queue is empty. Select at least one issue to work on."
      : `Queue contains ${queue.length} issue${queue.length === 1 ? "" : "s"}`,
    blocking: true,
  });
  
  // Check 2: RALPH.md exists
  const ralphMdPath = join(repoRoot, ".ralph", "RALPH.md");
  const hasRalphMd = existsSync(ralphMdPath);
  checks.push({
    id: "ralph-md-exists",
    label: "Prompt file exists",
    status: hasRalphMd ? "pass" : "fail",
    message: hasRalphMd
      ? ".ralph/RALPH.md found"
      : ".ralph/RALPH.md not found. Initialize Ralph first.",
    blocking: true,
  });
  
  // Check 3: config.json exists
  const configPath = join(repoRoot, ".ralph", "config.json");
  const hasConfig = existsSync(configPath);
  checks.push({
    id: "config-json-exists",
    label: "Config file exists",
    status: hasConfig ? "pass" : "fail",
    message: hasConfig
      ? ".ralph/config.json found"
      : ".ralph/config.json not found. Initialize Ralph first.",
    blocking: true,
  });
  
  // Check 4: GitHub auth works
  try {
    const authResult = await execGhAuth();
    const authPassed = authResult.exitCode === 0;
    checks.push({
      id: "github-auth",
      label: "GitHub authenticated",
      status: authPassed ? "pass" : "fail",
      message: authPassed
        ? "GitHub CLI authenticated"
        : `GitHub not authenticated: ${authResult.stderr || "gh auth status failed"}. Run 'gh auth login'.`,
      blocking: true,
    });
  } catch (err) {
    checks.push({
      id: "github-auth",
      label: "GitHub authenticated",
      status: "fail",
      message: `GitHub auth check failed: ${err.message}`,
      blocking: true,
    });
  }
  
  // Check 5: Repo identity can be verified
  // Read repo from config.json if it exists
  let repoIdentity = null;
  if (hasConfig) {
    try {
      const { readFileSync } = await import("node:fs");
      const configContent = readFileSync(configPath, "utf-8");
      const config = JSON.parse(configContent);
      repoIdentity = config.repo;
    } catch {
      // Config parse failed, will be caught below
    }
  }
  
  if (repoIdentity && typeof repoIdentity === "string" && repoIdentity.includes("/")) {
    try {
      const repoResult = await execGhRepo(repoIdentity);
      const repoPassed = repoResult.exitCode === 0;
      checks.push({
        id: "repo-identity",
        label: "Repository identity verified",
        status: repoPassed ? "pass" : "fail",
        message: repoPassed
          ? `Repository ${repoIdentity} verified`
          : `Cannot verify repository identity '${repoIdentity}': ${repoResult.stderr || "gh repo view failed"}`,
        blocking: true,
      });
    } catch (err) {
      checks.push({
        id: "repo-identity",
        label: "Repository identity verified",
        status: "fail",
        message: `Repo verification failed: ${err.message}`,
        blocking: true,
      });
    }
  } else {
    checks.push({
      id: "repo-identity",
      label: "Repository identity verified",
      status: "fail",
      message: "Cannot verify repository identity: config.json missing or invalid 'repo' field",
      blocking: true,
    });
  }
  
  // Determine if preflight passed (all blocking checks must pass)
  const passed = checks.filter(c => c.blocking).every(c => c.status === "pass");
  
  return {
    passed,
    checks,
  };
}
