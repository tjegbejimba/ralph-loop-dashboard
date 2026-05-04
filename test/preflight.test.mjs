// Tests for preflight module — validates launch conditions

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { runPreflight } from "../extension/lib/preflight.mjs";

// Helper to create temp test repo structure
function createTestRepo(tmpDir, { hasRalphMd = true, hasConfig = true, validConfig = true } = {}) {
  mkdirSync(tmpDir, { recursive: true });
  mkdirSync(join(tmpDir, ".ralph"), { recursive: true });
  
  if (hasRalphMd) {
    writeFileSync(join(tmpDir, ".ralph", "RALPH.md"), "# Ralph\nTest prompt");
  }
  
  if (hasConfig) {
    const config = validConfig
      ? { profile: "generic", repo: "owner/repo", prdReference: "#7" }
      : { invalid: "config" };
    writeFileSync(join(tmpDir, ".ralph", "config.json"), JSON.stringify(config));
  }
}

test("runPreflight passes when all conditions met", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-1");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      // Mock successful external commands
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
    });
    
    assert.equal(result.passed, true);
    assert.equal(result.checks.length, 5); // queue, ralph.md, config.json, gh auth, gh repo
    assert.ok(result.checks.every(c => c.status === "pass"));
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when queue is empty", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-2");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [], // Empty queue
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
    });
    
    assert.equal(result.passed, false);
    const queueCheck = result.checks.find(c => c.id === "queue-not-empty");
    assert.equal(queueCheck.status, "fail");
    assert.equal(queueCheck.blocking, true);
    assert.match(queueCheck.message, /queue is empty/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when RALPH.md missing", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-3");
  createTestRepo(tmpDir, { hasRalphMd: false });
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
    });
    
    assert.equal(result.passed, false);
    const ralphCheck = result.checks.find(c => c.id === "ralph-md-exists");
    assert.equal(ralphCheck.status, "fail");
    assert.equal(ralphCheck.blocking, true);
    assert.match(ralphCheck.message, /RALPH\.md.*not found/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when config.json missing", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-4");
  createTestRepo(tmpDir, { hasConfig: false });
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
    });
    
    assert.equal(result.passed, false);
    const configCheck = result.checks.find(c => c.id === "config-json-exists");
    assert.equal(configCheck.status, "fail");
    assert.equal(configCheck.blocking, true);
    assert.match(configCheck.message, /config\.json.*not found/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when GitHub auth fails", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-5");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      // Mock failed gh auth
      execGhAuth: async () => ({ exitCode: 1, stdout: "", stderr: "Not authenticated" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
    });
    
    assert.equal(result.passed, false);
    const authCheck = result.checks.find(c => c.id === "github-auth");
    assert.equal(authCheck.status, "fail");
    assert.equal(authCheck.blocking, true);
    assert.match(authCheck.message, /not authenticated/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when repo identity cannot be verified", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-6");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      // Mock failed gh repo view
      execGhRepo: async () => ({ exitCode: 1, stdout: "", stderr: "Repository not found" }),
    });
    
    assert.equal(result.passed, false);
    const repoCheck = result.checks.find(c => c.id === "repo-identity");
    assert.equal(repoCheck.status, "fail");
    assert.equal(repoCheck.blocking, true);
    assert.match(repoCheck.message, /cannot verify.*identity/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight returns all checks even when some fail", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-7");
  createTestRepo(tmpDir, { hasRalphMd: false, hasConfig: false });
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGhAuth: async () => ({ exitCode: 1, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 1, stdout: "", stderr: "" }),
    });
    
    // Should run all checks, not short-circuit
    assert.equal(result.checks.length, 5);
    
    // Queue should pass (has items)
    const queueCheck = result.checks.find(c => c.id === "queue-not-empty");
    assert.equal(queueCheck.status, "pass");
    
    // Files and auth should fail
    const ralphCheck = result.checks.find(c => c.id === "ralph-md-exists");
    const configCheck = result.checks.find(c => c.id === "config-json-exists");
    const authCheck = result.checks.find(c => c.id === "github-auth");
    const repoCheck = result.checks.find(c => c.id === "repo-identity");
    
    assert.equal(ralphCheck.status, "fail");
    assert.equal(configCheck.status, "fail");
    assert.equal(authCheck.status, "fail");
    assert.equal(repoCheck.status, "fail");
    assert.equal(result.passed, false);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});
