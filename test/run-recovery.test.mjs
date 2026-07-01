// Run recovery test — retry and skip operations for failed issues

import { describe, test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { retryFailedIssue, skipFailedIssue, retryNow, pauseRecovery, resetBudget } from "../extension/lib/run-store.mjs";

describe("Run recovery operations", () => {
  let tmpDir;
  let runDir;
  let runId;

  beforeEach(() => {
    // Create temporary test directory
    tmpDir = join(
      process.cwd(),
      "test-results",
      `run-recovery-${randomBytes(8).toString("hex")}`,
    );
    mkdirSync(tmpDir, { recursive: true });

    // Create run structure
    runId = "20260504-120000-test1234";
    const runsDir = join(tmpDir, ".ralph", "runs");
    runDir = join(runsDir, runId);
    mkdirSync(runDir, { recursive: true });

    // Create initial queue
    const queue = [
      { number: 10, title: "First issue" },
      { number: 20, title: "Second issue" },
      { number: 30, title: "Third issue" },
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

    // Create initial status with a failed issue
    const status = {
      items: {
        "10": {
          status: "failed",
          workerId: 1,
          pid: 99999,
          logFile: "iter-20260504-120000-w1-issue-10.log",
          startedAt: "2026-05-04T12:00:00Z",
          error: "Copilot exited with code 1",
        },
        "20": {
          status: "running",
          workerId: 2,
          pid: 88888,
          logFile: "iter-20260504-120100-w2-issue-20.log",
          startedAt: "2026-05-04T12:01:00Z",
          error: null,
        },
      },
    };
    writeFileSync(join(runDir, "status.json"), JSON.stringify(status, null, 2));
  });

  test("retryFailedIssue resets a failed issue to queued state", () => {
    const result = retryFailedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 10,
    });

    assert.strictEqual(result.success, true);

    // Read status.json and verify issue is back to queued
    const statusPath = join(runDir, "status.json");
    const status = JSON.parse(readFileSync(statusPath, "utf-8"));

    assert.strictEqual(status.items["10"].status, "queued");
    assert.strictEqual(status.items["10"].workerId, null);
    assert.strictEqual(status.items["10"].pid, null);
    assert.strictEqual(status.items["10"].logFile, null);
    assert.strictEqual(status.items["10"].error, null);
    assert.strictEqual(status.items["10"].startedAt, null);
  });

  test("retryFailedIssue rejects non-failed issues", () => {
    const result = retryFailedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 20, // running, not failed
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /not in failed state/);

    // Verify status unchanged
    const statusPath = join(runDir, "status.json");
    const status = JSON.parse(readFileSync(statusPath, "utf-8"));
    assert.strictEqual(status.items["20"].status, "running");
  });

  test("retryFailedIssue rejects issue not in queue", () => {
    const result = retryFailedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 999, // not in queue
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /not found in queue/);
  });

  test("skipFailedIssue marks a failed issue as skipped", () => {
    const result = skipFailedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 10,
    });

    assert.strictEqual(result.success, true);

    // Read status.json and verify issue is skipped
    const statusPath = join(runDir, "status.json");
    const status = JSON.parse(readFileSync(statusPath, "utf-8"));

    assert.strictEqual(status.items["10"].status, "skipped");
    assert.strictEqual(status.items["10"].workerId, null);
    assert.strictEqual(status.items["10"].pid, null);
    assert.strictEqual(status.items["10"].logFile, null);
    assert.strictEqual(status.items["10"].error, null);
    assert.strictEqual(status.items["10"].startedAt, null);
  });

  test("skipFailedIssue rejects non-failed issues", () => {
    const result = skipFailedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 20, // running, not failed
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /not in failed state/);
  });

  test("skipFailedIssue rejects issue not in queue", () => {
    const result = skipFailedIssue({
      repoRoot: tmpDir,
      runId,
      issueNumber: 999,
    });

    assert.strictEqual(result.success, false);
    assert.match(result.error, /not found in queue/);
  });

  test("retryNow moves nextRetryAt to now for a recoverable issue", () => {
    // Reset status.json with recoverable item
    const statusPath = join(runDir, "status.json");
    const status = {
      items: {
        "10": {
          status: "recoverable",
          workerId: 1,
          pid: 99999,
          logFile: "iter-20260504-120000-w1-issue-10.log",
          startedAt: "2026-05-04T12:00:00Z",
          nextRetryAt: "2026-05-04T13:00:00Z",
          attemptCount: 1,
          error: "Copilot exited with code 1",
        },
      },
    };
    writeFileSync(statusPath, JSON.stringify(status, null, 2));

    const result = retryNow({
      repoRoot: tmpDir,
      runId,
      issueNumber: 10,
    });

    assert.strictEqual(result.success, true);

    // Read status.json and verify nextRetryAt is updated to now or earlier
    const updatedStatus = JSON.parse(readFileSync(statusPath, "utf-8"));
    const now = new Date().toISOString();
    assert.strictEqual(updatedStatus.items["10"].status, "recoverable");
    assert.ok(updatedStatus.items["10"].nextRetryAt <= now);
  });

  test("pauseRecovery transitions issue to ralph:hitl state", () => {
    // Reset status.json with recoverable item
    const statusPath = join(runDir, "status.json");
    const status = {
      items: {
        "10": {
          status: "recoverable",
          workerId: 1,
          pid: 99999,
          logFile: "iter-20260504-120000-w1-issue-10.log",
          startedAt: "2026-05-04T12:00:00Z",
          nextRetryAt: "2026-05-04T13:00:00Z",
          attemptCount: 1,
          error: "Copilot exited with code 1",
        },
      },
    };
    writeFileSync(statusPath, JSON.stringify(status, null, 2));

    const result = pauseRecovery({
      repoRoot: tmpDir,
      runId,
      issueNumber: 10,
    });

    assert.strictEqual(result.success, true);

    // Read status.json and verify issue is paused
    const updatedStatus = JSON.parse(readFileSync(statusPath, "utf-8"));
    assert.strictEqual(updatedStatus.items["10"].status, "paused");
    assert.strictEqual(updatedStatus.items["10"].pausedAt !== null, true);
  });

  test("resetBudget clears attempt counters and re-queues issue", () => {
    // Create recovery ledger
    const ledgerDir = join(tmpDir, ".ralph", "recovery");
    mkdirSync(ledgerDir, { recursive: true});
    writeFileSync(
      join(ledgerDir, "10.json"),
      JSON.stringify({
        issueNumber: 10,
        attemptCount: 2,
        maxAttempts: 2,
        lastAttemptAt: "2026-05-04T12:00:00Z",
        nextRetryAt: "2026-05-04T13:00:00Z",
        reason: "Budget exhausted",
        prNumber: 42,
        branch: "slice-10-test",
      }),
    );

    // Reset status.json with recoverable item
    const statusPath = join(runDir, "status.json");
    const status = {
      items: {
        "10": {
          status: "recoverable",
          workerId: 1,
          pid: 99999,
          logFile: "iter-20260504-120000-w1-issue-10.log",
          startedAt: "2026-05-04T12:00:00Z",
          nextRetryAt: null,
          attemptCount: 2,
          error: "Budget exhausted",
        },
      },
    };
    writeFileSync(statusPath, JSON.stringify(status, null, 2));

    const result = resetBudget({
      repoRoot: tmpDir,
      runId,
      issueNumber: 10,
    });

    assert.strictEqual(result.success, true);

    // Read ledger and verify counters are cleared
    const ledgerPath = join(ledgerDir, "10.json");
    const updatedLedger = JSON.parse(readFileSync(ledgerPath, "utf-8"));
    assert.strictEqual(updatedLedger.attemptCount, 0);
    assert.strictEqual(updatedLedger.resetAt !== null, true);

    // Read status.json and verify issue is back to queued
    const updatedStatus = JSON.parse(readFileSync(statusPath, "utf-8"));
    assert.strictEqual(updatedStatus.items["10"].status, "queued");
    assert.strictEqual(updatedStatus.items["10"].attemptCount, 0);
  });
});
