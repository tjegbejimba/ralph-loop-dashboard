// Queue edit test — reorder and remove operations for not-yet-claimed issues

import { describe, test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { removeQueuedIssue, reorderQueuedIssue } from "../extension/lib/run-store.mjs";

describe("Queue edit operations", () => {
  let tmpDir;
  let runDir;
  let runId;

  beforeEach(() => {
    // Create temporary test directory
    tmpDir = join(
      process.cwd(),
      "test-results",
      `queue-edit-${randomBytes(8).toString("hex")}`,
    );
    mkdirSync(tmpDir, { recursive: true });

    // Create run structure
    runId = "20260504-130000-test5678";
    const runsDir = join(tmpDir, ".ralph", "runs");
    runDir = join(runsDir, runId);
    mkdirSync(runDir, { recursive: true });

    // Create initial queue with 5 issues
    const queue = [
      { number: 10, title: "First issue" },
      { number: 20, title: "Second issue" },
      { number: 30, title: "Third issue" },
      { number: 40, title: "Fourth issue" },
      { number: 50, title: "Fifth issue" },
    ];
    writeFileSync(join(runDir, "queue.json"), JSON.stringify(queue, null, 2));

    // Create initial metadata
    const metadata = {
      repoRoot: tmpDir,
      runMode: "run-aware",
      model: "claude-sonnet-4.5",
      parallelism: 2,
      createdAt: new Date().toISOString(),
    };
    writeFileSync(join(runDir, "metadata.json"), JSON.stringify(metadata, null, 2));

    // Create status where some issues are claimed/running
    const status = {
      items: {
        "10": {
          status: "running",
          workerId: 1,
          pid: 11111,
          logFile: "iter-20260504-130000-w1-issue-10.log",
          startedAt: "2026-05-04T13:00:00Z",
          error: null,
        },
        "20": {
          status: "claimed",
          workerId: 2,
          pid: 22222,
          logFile: "iter-20260504-130100-w2-issue-20.log",
          startedAt: "2026-05-04T13:01:00Z",
          error: null,
        },
        // 30, 40, 50 are not claimed yet
      },
    };
    writeFileSync(join(runDir, "status.json"), JSON.stringify(status, null, 2));
  });

  test("removeQueuedIssue removes an unclaimed issue from queue", () => {
    const result = removeQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 30,
    });

    assert.strictEqual(result.success, true);

    // Read queue.json and verify issue removed
    const queuePath = join(runDir, "queue.json");
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));

    assert.strictEqual(queue.length, 4);
    assert.strictEqual(queue.some((i) => i.number === 30), false);
    assert.deepStrictEqual(
      queue.map((i) => i.number),
      [10, 20, 40, 50],
    );
  });

  test("removeQueuedIssue rejects claimed issues", () => {
    const result = removeQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 10, // running
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /already claimed or completed/);

    // Verify queue unchanged
    const queuePath = join(runDir, "queue.json");
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));
    assert.strictEqual(queue.length, 5);
  });

  test("removeQueuedIssue rejects issue not in queue", () => {
    const result = removeQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 999,
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /not found in queue/);
  });

  test("reorderQueuedIssue moves an unclaimed issue to new position", () => {
    // Move issue 30 from index 2 to index 4 (last position)
    const result = reorderQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 30,
      newIndex: 4,
    });

    assert.strictEqual(result.success, true);

    // Read queue.json and verify new order
    const queuePath = join(runDir, "queue.json");
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));

    assert.strictEqual(queue.length, 5);
    assert.deepStrictEqual(
      queue.map((i) => i.number),
      [10, 20, 40, 50, 30], // 30 moved to end
    );
  });

  test("reorderQueuedIssue moves unclaimed issue forward", () => {
    // Move issue 50 from index 4 to index 2
    const result = reorderQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 50,
      newIndex: 2,
    });

    assert.strictEqual(result.success, true);

    const queuePath = join(runDir, "queue.json");
    const queue = JSON.parse(readFileSync(queuePath, "utf-8"));

    assert.deepStrictEqual(
      queue.map((i) => i.number),
      [10, 20, 50, 30, 40], // 50 moved forward
    );
  });

  test("reorderQueuedIssue rejects claimed issues", () => {
    const result = reorderQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 20, // claimed
      newIndex: 3,
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /already claimed or completed/);
  });

  test("reorderQueuedIssue rejects invalid index", () => {
    const result = reorderQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 30,
      newIndex: 999,
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /invalid/i);
  });

  test("reorderQueuedIssue rejects issue not in queue", () => {
    const result = reorderQueuedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 999,
      newIndex: 0,
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /not found in queue/);
  });
});
