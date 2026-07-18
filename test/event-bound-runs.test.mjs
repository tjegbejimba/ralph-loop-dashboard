// Event-bound run specification freezing — verified at run creation seam

import { describe, test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, rmSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { createRun, getActiveRuns } from "../extension/lib/run-store.mjs";

describe("Event-bound run specifications", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = join(
      process.cwd(),
      "test-results",
      `event-bound-${randomBytes(8).toString("hex")}`,
    );
    mkdirSync(tmpDir, { recursive: true });
  });

  // RED: Test that a new event-bound run persists a versioned specification
  test("creates event-bound run with frozen specification", () => {
    const queue = [
      { number: 10, title: "First issue" },
      { number: 20, title: "Second issue" },
    ];

    const runOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 2,
      eventBound: true, // Opt into event protocol
      targetBranch: "main",
      queueProvenance: "dashboard-explicit",
    };

    const result = createRun({ repoRoot: tmpDir, queue, runOptions });

    // Verify specification file exists
    const specPath = join(result.runDir, "run-specification.json");
    assert.ok(existsSync(specPath), "run-specification.json must exist");

    const spec = JSON.parse(readFileSync(specPath, "utf-8"));

    // Verify specification structure
    assert.strictEqual(spec.version, "v1", "Specification must be versioned");
    assert.strictEqual(spec.eventProtocol, "ralph.run.queue-succeeded/v1");
    assert.strictEqual(spec.targetBranch, "main");
    assert.strictEqual(spec.queueProvenance, "dashboard-explicit");
    
    // Verify frozen canonical queue membership (issue numbers only)
    assert.deepStrictEqual(spec.frozenMembership, [10, 20]);
    
    // Verify queue digest for tamper detection
    assert.ok(spec.queueDigest && typeof spec.queueDigest === "string");
    assert.ok(spec.queueDigest.length > 0);
  });

  // RED: Test that duplicate issue numbers are canonicalized
  test("canonicalizes duplicate issue numbers before freezing", () => {
    const queueWithDuplicates = [
      { number: 10, title: "First" },
      { number: 20, title: "Second" },
      { number: 10, title: "First duplicate" }, // duplicate
      { number: 30, title: "Third" },
    ];

    const runOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      eventBound: true,
      targetBranch: "main",
      queueProvenance: "dashboard-explicit",
    };

    const result = createRun({ repoRoot: tmpDir, queue: queueWithDuplicates, runOptions });

    const specPath = join(result.runDir, "run-specification.json");
    const spec = JSON.parse(readFileSync(specPath, "utf-8"));

    // Frozen membership should be deduplicated and sorted
    assert.deepStrictEqual(spec.frozenMembership, [10, 20, 30]);
    
    // Persisted queue should also be deduplicated
    const persistedQueue = JSON.parse(readFileSync(result.queuePath, "utf-8"));
    assert.strictEqual(persistedQueue.length, 3);
    assert.deepStrictEqual(
      persistedQueue.map(i => i.number),
      [10, 20, 30]
    );
  });

  // RED: Test that legacy runs (eventBound: false) remain event-ineligible
  test("legacy runs do not create specification file", () => {
    const queue = [{ number: 10, title: "Issue" }];

    const legacyRunOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      // eventBound omitted or false
    };

    const result = createRun({ repoRoot: tmpDir, queue, runOptions: legacyRunOptions });

    const specPath = join(result.runDir, "run-specification.json");
    assert.ok(!existsSync(specPath), "Legacy runs must not have specification");
  });

  // RED: Test that getActiveRuns exposes event-bound status
  test("getActiveRuns distinguishes event-bound from legacy runs", () => {
    // Create one event-bound run
    const eventQueue = [{ number: 10, title: "Event issue" }];
    const eventOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      eventBound: true,
      targetBranch: "main",
      queueProvenance: "dashboard-explicit",
    };
    createRun({ repoRoot: tmpDir, queue: eventQueue, runOptions: eventOptions });

    // Create one legacy run
    const legacyQueue = [{ number: 20, title: "Legacy issue" }];
    const legacyOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
    };
    createRun({ repoRoot: tmpDir, queue: legacyQueue, runOptions: legacyOptions });

    const runs = getActiveRuns(tmpDir);
    assert.strictEqual(runs.length, 2);

    const eventRun = runs.find(r => r.metadata.eventBound === true);
    const legacyRun = runs.find(r => !r.metadata.eventBound);

    assert.ok(eventRun, "Event-bound run must be discoverable");
    assert.ok(legacyRun, "Legacy run must be discoverable");
    
    assert.ok(eventRun.specification, "Event-bound run must include specification");
    assert.ok(!legacyRun.specification, "Legacy run must not include specification");
  });

  // RED: Test specification includes optional hook generation
  test("event-bound run captures hook configuration when enabled", () => {
    const queue = [{ number: 10, title: "Issue" }];

    const runOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      eventBound: true,
      targetBranch: "main",
      queueProvenance: "dashboard-explicit",
      hookGeneration: 2, // Optional: which hook config generation is enabled
    };

    const result = createRun({ repoRoot: tmpDir, queue, runOptions });

    const specPath = join(result.runDir, "run-specification.json");
    const spec = JSON.parse(readFileSync(specPath, "utf-8"));

    assert.strictEqual(spec.hookGeneration, 2);
  });

  // RED: Test specification omits hookGeneration when not provided
  test("event-bound run omits hookGeneration when not enabled", () => {
    const queue = [{ number: 10, title: "Issue" }];

    const runOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      eventBound: true,
      targetBranch: "main",
      queueProvenance: "dashboard-explicit",
      // hookGeneration omitted
    };

    const result = createRun({ repoRoot: tmpDir, queue, runOptions });

    const specPath = join(result.runDir, "run-specification.json");
    const spec = JSON.parse(readFileSync(specPath, "utf-8"));

    assert.strictEqual(spec.hookGeneration, undefined);
  });

  // Test that frozen membership is preserved across retries
  test("retry operations preserve frozen membership", () => {
    const queue = [
      { number: 10, title: "First" },
      { number: 20, title: "Second" },
    ];

    const runOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      eventBound: true,
      targetBranch: "main",
      queueProvenance: "dashboard-explicit",
    };

    const result = createRun({ repoRoot: tmpDir, queue, runOptions });

    // Load specification before retry
    const specPath = join(result.runDir, "run-specification.json");
    const specBefore = JSON.parse(readFileSync(specPath, "utf-8"));

    // Simulate a status update (retry doesn't touch specification)
    const statusPath = join(result.runDir, "status.json");
    const status = { items: { "10": { status: "failed" } } };
    writeFileSync(statusPath, JSON.stringify(status, null, 2));

    // Load specification after simulated operations
    const specAfter = JSON.parse(readFileSync(specPath, "utf-8"));

    // Specification must be unchanged
    assert.deepStrictEqual(specAfter, specBefore);
    assert.deepStrictEqual(specAfter.frozenMembership, [10, 20]);
  });

  // Test that queue digest is deterministic
  test("queue digest is deterministic for same membership", () => {
    const queue1 = [
      { number: 10, title: "First" },
      { number: 20, title: "Second" },
    ];

    const queue2 = [
      { number: 10, title: "First (different title)" },
      { number: 20, title: "Second (different title)" },
    ];

    const runOptions = {
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      eventBound: true,
      targetBranch: "main",
      queueProvenance: "dashboard-explicit",
    };

    const result1 = createRun({ repoRoot: tmpDir, queue: queue1, runOptions });
    const spec1 = JSON.parse(readFileSync(join(result1.runDir, "run-specification.json"), "utf-8"));

    // Create second run in separate directory
    const tmpDir2 = join(
      process.cwd(),
      "test-results",
      `event-bound-${randomBytes(8).toString("hex")}`,
    );
    mkdirSync(tmpDir2, { recursive: true });
    
    const result2 = createRun({ repoRoot: tmpDir2, queue: queue2, runOptions });
    const spec2 = JSON.parse(readFileSync(join(result2.runDir, "run-specification.json"), "utf-8"));

    // Same membership should produce same digest
    assert.strictEqual(spec1.queueDigest, spec2.queueDigest);
  });
});
