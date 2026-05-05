// Queue timeline presenter tests — validates run state transformation into timeline rows

import { test } from "node:test";
import assert from "node:assert/strict";
import { buildQueueTimeline } from "../extension/lib/queue-timeline.mjs";

test("buildQueueTimeline transforms queued issue without status", () => {
  const queue = [{ number: 1, title: "Test issue" }];
  const status = { items: {} };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 1, "Should have one timeline row");
  assert.equal(timeline[0].issueNumber, 1);
  assert.equal(timeline[0].title, "Test issue");
  assert.equal(timeline[0].state, "queued");
  assert.equal(timeline[0].issueUrl, "https://github.com/test/repo/issues/1");
  assert.equal(timeline[0].prUrl, null);
  assert.equal(timeline[0].logFile, null);
});

test("buildQueueTimeline transforms claimed issue with worker ID", () => {
  const queue = [{ number: 2, title: "Claimed issue" }];
  const status = {
    items: {
      "2": {
        status: "claimed",
        workerId: 1,
        pid: null,
        logFile: null,
        startedAt: null,
        error: null
      }
    }
  };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 1);
  assert.equal(timeline[0].state, "claimed");
  assert.equal(timeline[0].workerId, 1);
});

test("buildQueueTimeline transforms running issue with log file", () => {
  const queue = [{ number: 3, title: "Running issue" }];
  const status = {
    items: {
      "3": {
        status: "running",
        workerId: 2,
        pid: 12345,
        logFile: "worker-2-issue-3.log",
        startedAt: "2026-05-04T10:00:00Z",
        error: null
      }
    }
  };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 1);
  assert.equal(timeline[0].state, "running");
  assert.equal(timeline[0].workerId, 2);
  assert.equal(timeline[0].logFile, "worker-2-issue-3.log");
  assert.equal(timeline[0].startedAt, "2026-05-04T10:00:00Z");
});

test("buildQueueTimeline transforms issue with PR opened", () => {
  const queue = [{ number: 4, title: "Issue with PR" }];
  const status = {
    items: {
      "4": {
        status: "pr-opened",
        workerId: 1,
        pid: null,
        logFile: "worker-1-issue-4.log",
        startedAt: "2026-05-04T09:00:00Z",
        error: null,
        prNumber: 42
      }
    }
  };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 1);
  assert.equal(timeline[0].state, "pr-opened");
  assert.equal(timeline[0].prUrl, "https://github.com/test/repo/pull/42");
  assert.equal(timeline[0].prNumber, 42);
});

test("buildQueueTimeline transforms merged issue", () => {
  const queue = [{ number: 5, title: "Merged issue" }];
  const status = {
    items: {
      "5": {
        status: "merged",
        workerId: 3,
        pid: null,
        logFile: "worker-3-issue-5.log",
        startedAt: "2026-05-04T08:00:00Z",
        error: null,
        prNumber: 43
      }
    }
  };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 1);
  assert.equal(timeline[0].state, "merged");
  assert.equal(timeline[0].prUrl, "https://github.com/test/repo/pull/43");
});

test("buildQueueTimeline transforms failed issue with error", () => {
  const queue = [{ number: 6, title: "Failed issue" }];
  const status = {
    items: {
      "6": {
        status: "failed",
        workerId: 2,
        pid: null,
        logFile: "worker-2-issue-6.log",
        startedAt: "2026-05-04T07:00:00Z",
        error: "Validation failed"
      }
    }
  };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 1);
  assert.equal(timeline[0].state, "failed");
  assert.equal(timeline[0].error, "Validation failed");
  assert.equal(timeline[0].logFile, "worker-2-issue-6.log");
});

test("buildQueueTimeline transforms skipped issue", () => {
  const queue = [{ number: 7, title: "Skipped issue" }];
  const status = {
    items: {
      "7": {
        status: "skipped",
        workerId: null,
        pid: null,
        logFile: null,
        startedAt: null,
        error: "Manually skipped by operator"
      }
    }
  };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 1);
  assert.equal(timeline[0].state, "skipped");
  assert.equal(timeline[0].error, "Manually skipped by operator");
});

test("buildQueueTimeline preserves queue order", () => {
  const queue = [
    { number: 10, title: "Third" },
    { number: 5, title: "First" },
    { number: 8, title: "Second" }
  ];
  const status = { items: {} };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 3);
  assert.equal(timeline[0].issueNumber, 10);
  assert.equal(timeline[1].issueNumber, 5);
  assert.equal(timeline[2].issueNumber, 8);
});

test("buildQueueTimeline handles mixed states", () => {
  const queue = [
    { number: 1, title: "Queued" },
    { number: 2, title: "Running" },
    { number: 3, title: "Merged" }
  ];
  const status = {
    items: {
      "2": { status: "running", workerId: 1, pid: 999, logFile: "w1.log", startedAt: "2026-05-04T10:00:00Z", error: null },
      "3": { status: "merged", workerId: 2, pid: null, logFile: "w2.log", startedAt: "2026-05-04T09:00:00Z", error: null, prNumber: 10 }
    }
  };
  const repoOwner = "test";
  const repoName = "repo";
  
  const timeline = buildQueueTimeline({ queue, status, repoOwner, repoName });
  
  assert.equal(timeline.length, 3);
  assert.equal(timeline[0].state, "queued");
  assert.equal(timeline[1].state, "running");
  assert.equal(timeline[2].state, "merged");
});
