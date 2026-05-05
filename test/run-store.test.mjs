// Run store module tests — validates durable run directory creation and rediscovery

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createRun, getActiveRuns } from "../extension/lib/run-store.mjs";

test("createRun generates unique timestamp-based run ID", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const queue = [{ number: 1, title: "Test issue" }];
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    const run1 = createRun({ repoRoot: tmpRepo, queue, runOptions });
    const run2 = createRun({ repoRoot: tmpRepo, queue, runOptions });
    
    assert.ok(run1.runId, "First run should have an ID");
    assert.ok(run2.runId, "Second run should have an ID");
    assert.notEqual(run1.runId, run2.runId, "Run IDs should be unique");
    assert.match(run1.runId, /^\d{8}-\d{6}-[a-z0-9]+$/, "Run ID should be timestamp-based");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("createRun creates run directory structure", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const queue = [{ number: 1, title: "Test issue" }];
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    const result = createRun({ repoRoot: tmpRepo, queue, runOptions });
    
    assert.ok(existsSync(result.runDir), "Run directory should exist");
    assert.equal(result.runDir, join(tmpRepo, ".ralph", "runs", result.runId), "Run directory path should be correct");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("createRun writes immutable queue file", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const queue = [
      { number: 1, title: "First issue" },
      { number: 2, title: "Second issue" }
    ];
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    const result = createRun({ repoRoot: tmpRepo, queue, runOptions });
    
    assert.ok(existsSync(result.queuePath), "Queue file should exist");
    const queueContent = JSON.parse(readFileSync(result.queuePath, "utf-8"));
    assert.deepEqual(queueContent, queue, "Queue file should contain the selected queue");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("createRun writes metadata with all required fields", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const queue = [{ number: 1, title: "Test issue" }];
    const runOptions = { runMode: "one-pass", parallelism: 2, model: "claude-opus-4.7" };
    
    const result = createRun({ repoRoot: tmpRepo, queue, runOptions });
    
    assert.ok(existsSync(result.metadataPath), "Metadata file should exist");
    const metadata = JSON.parse(readFileSync(result.metadataPath, "utf-8"));
    
    assert.equal(metadata.repoRoot, tmpRepo, "Metadata should record repo root");
    assert.equal(metadata.runMode, "one-pass", "Metadata should record run mode");
    assert.equal(metadata.model, "claude-opus-4.7", "Metadata should record model");
    assert.equal(metadata.parallelism, 2, "Metadata should record parallelism");
    assert.ok(metadata.createdAt, "Metadata should have creation timestamp");
    assert.match(metadata.createdAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "Creation timestamp should be ISO 8601");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("getActiveRuns rediscovers runs from filesystem", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const queue1 = [{ number: 1, title: "First issue" }];
    const queue2 = [{ number: 2, title: "Second issue" }];
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    const run1 = createRun({ repoRoot: tmpRepo, queue: queue1, runOptions });
    const run2 = createRun({ repoRoot: tmpRepo, queue: queue2, runOptions });
    
    const activeRuns = getActiveRuns(tmpRepo);
    
    assert.equal(activeRuns.length, 2, "Should discover both runs");
    assert.ok(activeRuns.some(r => r.runId === run1.runId), "Should find first run");
    assert.ok(activeRuns.some(r => r.runId === run2.runId), "Should find second run");
    
    const discoveredRun1 = activeRuns.find(r => r.runId === run1.runId);
    assert.equal(discoveredRun1.metadata.runMode, "one-pass", "Should load metadata");
    assert.equal(discoveredRun1.queuePath, run1.queuePath, "Should include queue path");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("getActiveRuns handles missing runs directory gracefully", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    // Don't create any runs, just call getActiveRuns
    const activeRuns = getActiveRuns(tmpRepo);
    
    assert.ok(Array.isArray(activeRuns), "Should return an array");
    assert.equal(activeRuns.length, 0, "Should return empty array when no runs exist");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("createRun validates required parameters", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    assert.throws(() => createRun({ repoRoot: null, queue: [], runOptions: {} }), TypeError, "Should reject null repoRoot");
    assert.throws(() => createRun({ repoRoot: tmpRepo, queue: null, runOptions: {} }), TypeError, "Should reject null queue");
    assert.throws(() => createRun({ repoRoot: tmpRepo, queue: [], runOptions: null }), TypeError, "Should reject null runOptions");
    assert.throws(() => createRun({ repoRoot: tmpRepo, queue: [], runOptions: {} }), TypeError, "Should reject runOptions missing required fields");
    assert.throws(() => createRun({ repoRoot: tmpRepo, queue: [], runOptions: { runMode: "one-pass", model: "claude-sonnet-4.5" } }), TypeError, "Should reject runOptions missing parallelism");
    assert.throws(() => createRun({ repoRoot: tmpRepo, queue: [], runOptions: { runMode: "one-pass", model: "claude-sonnet-4.5", parallelism: NaN } }), TypeError, "Should reject NaN parallelism");
    assert.throws(() => createRun({ repoRoot: tmpRepo, queue: [], runOptions: { runMode: "one-pass", model: "claude-sonnet-4.5", parallelism: Infinity } }), TypeError, "Should reject Infinity parallelism");
    assert.throws(() => createRun({ repoRoot: tmpRepo, queue: [], runOptions: { runMode: "one-pass", model: "claude-sonnet-4.5", parallelism: 1.5 } }), TypeError, "Should reject float parallelism");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("createRun writes initial empty status.json", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const queue = [{ number: 1, title: "Test issue" }];
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    const result = createRun({ repoRoot: tmpRepo, queue, runOptions });
    
    const statusPath = join(result.runDir, "status.json");
    assert.ok(existsSync(statusPath), "status.json should exist");
    
    const status = JSON.parse(readFileSync(statusPath, "utf-8"));
    assert.deepEqual(status, { items: {} }, "status.json should have empty items map");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("getActiveRuns validates metadata schema", () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runsDir = join(tmpRepo, ".ralph", "runs");
    
    // Create run with valid metadata
    const validRunId = "valid-run";
    const validRunDir = join(runsDir, validRunId);
    mkdirSync(validRunDir, { recursive: true });
    writeFileSync(join(validRunDir, "queue.json"), "[]", "utf-8");
    writeFileSync(join(validRunDir, "metadata.json"), JSON.stringify({
      repoRoot: tmpRepo,
      runMode: "one-pass",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      createdAt: new Date().toISOString(),
    }), "utf-8");
    
    // Create run with incomplete metadata (missing required fields)
    const incompleteRunId = "incomplete-run";
    const incompleteRunDir = join(runsDir, incompleteRunId);
    mkdirSync(incompleteRunDir, { recursive: true });
    writeFileSync(join(incompleteRunDir, "queue.json"), "[]", "utf-8");
    writeFileSync(join(incompleteRunDir, "metadata.json"), JSON.stringify({
      model: "claude-sonnet-4.5", // missing repoRoot, runMode, createdAt, parallelism
    }), "utf-8");
    
    // Create run with corrupted parallelism (null from NaN serialization)
    const corruptedRunId = "corrupted-run";
    const corruptedRunDir = join(runsDir, corruptedRunId);
    mkdirSync(corruptedRunDir, { recursive: true });
    writeFileSync(join(corruptedRunDir, "queue.json"), "[]", "utf-8");
    writeFileSync(join(corruptedRunDir, "metadata.json"), JSON.stringify({
      repoRoot: tmpRepo,
      runMode: "one-pass",
      model: "claude-sonnet-4.5",
      parallelism: null, // corrupted
      createdAt: new Date().toISOString(),
    }), "utf-8");
    
    // Create run missing queue.json
    const noQueueRunId = "no-queue-run";
    const noQueueRunDir = join(runsDir, noQueueRunId);
    mkdirSync(noQueueRunDir, { recursive: true });
    writeFileSync(join(noQueueRunDir, "metadata.json"), JSON.stringify({
      repoRoot: tmpRepo,
      runMode: "one-pass",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      createdAt: new Date().toISOString(),
    }), "utf-8");
    
    const activeRuns = getActiveRuns(tmpRepo);
    
    assert.equal(activeRuns.length, 1, "Should only discover valid run");
    assert.equal(activeRuns[0].runId, validRunId, "Should find the valid run");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("getActiveRuns validates repoRoot parameter", () => {
  assert.throws(() => getActiveRuns(null), TypeError, "Should reject null repoRoot");
  assert.throws(() => getActiveRuns(undefined), TypeError, "Should reject undefined repoRoot");
  assert.throws(() => getActiveRuns(123), TypeError, "Should reject numeric repoRoot");
});
