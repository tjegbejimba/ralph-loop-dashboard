// Unit tests for pipeline-data.mjs — pure pipeline bucketing / next-run logic
// Tests the core pipeline computation without gh/fs/network dependencies

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { computePipelineState } from "../extension-canvas/lib/pipeline-data.mjs";

// Test: bucket running issues correctly with worker metadata
test("bucket running issues with worker metadata", () => {
  const issues = [
    {
      number: 1,
      title: "Implement auth",
      url: "https://github.com/test/repo/issues/1",
      labels: [{ name: "ralph:running" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-20T10:00:00Z",
      assignees: [],
      body: "",
    },
  ];
  
  const claims = {
    "1": {
      pid: 12345,
      startedAt: "2026-06-27T12:00:00Z",
      logFile: "/path/to/worker-1.log",
      workerId: "worker-1",
      resumeAttempt: 0,
    },
  };
  
  const openPrs = [];
  
  const result = computePipelineState({ issues, claims, openPrs });
  
  assert.equal(result.running.length, 1);
  assert.equal(result.running[0].number, 1);
  assert.equal(result.running[0].title, "Implement auth");
  assert.equal(result.running[0].worker.pid, 12345);
  assert.equal(result.running[0].worker.workerId, "worker-1");
});

// Test: compute next-run queue with cap at 3, priority-first
test("compute next-run queue capped at 3, priority-first", () => {
  const issues = [
    {
      number: 5,
      title: "P2 task",
      url: "https://github.com/test/repo/issues/5",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P2" }],
      createdAt: "2026-06-25T10:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 1,
      title: "P0 critical",
      url: "https://github.com/test/repo/issues/1",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P0" }],
      createdAt: "2026-06-26T10:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 3,
      title: "P1 important",
      url: "https://github.com/test/repo/issues/3",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-25T12:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 4,
      title: "Another P1",
      url: "https://github.com/test/repo/issues/4",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-25T11:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 6,
      title: "P2 lower priority",
      url: "https://github.com/test/repo/issues/6",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P2" }],
      createdAt: "2026-06-24T10:00:00Z",
      assignees: [],
      body: "",
    },
  ];
  
  const result = computePipelineState({ issues, claims: {}, openPrs: [] });
  
  // Should be capped at 3 and sorted by priority then number
  assert.equal(result.nextQueue.length, 3);
  assert.deepEqual(result.nextQueue, [1, 3, 4]); // P0:#1, P1:#3, P1:#4 (lowest numbers first)
  assert.equal(result.ready.length, 5);
  // First 3 should be marked as queued
  assert.equal(result.ready[0].queued, true);
  assert.equal(result.ready[1].queued, true);
  assert.equal(result.ready[2].queued, true);
  assert.equal(result.ready[3].queued, false);
  assert.equal(result.ready[4].queued, false);
});

// Test: exclude assigned issues from next-run queue
test("exclude assigned issues from next-run queue", () => {
  const issues = [
    {
      number: 1,
      title: "Assigned task",
      url: "https://github.com/test/repo/issues/1",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-26T10:00:00Z",
      assignees: [{ login: "alice" }],
      body: "",
    },
    {
      number: 2,
      title: "Unassigned task",
      url: "https://github.com/test/repo/issues/2",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-26T09:00:00Z",
      assignees: [],
      body: "",
    },
  ];
  
  const result = computePipelineState({ issues, claims: {}, openPrs: [] });
  
  // Only unassigned should be in next-run
  assert.equal(result.nextQueue.length, 1);
  assert.deepEqual(result.nextQueue, [2]);
  // Assigned should be in deferred
  assert.equal(result.deferred.length, 1);
  assert.equal(result.deferred[0].number, 1);
  assert.equal(result.deferred[0].reason, "assigned");
});

// Test: exclude issues with open linked PRs from next-run queue
test("exclude issues with open linked PRs from next-run", () => {
  const issues = [
    {
      number: 1,
      title: "Has open PR",
      url: "https://github.com/test/repo/issues/1",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-26T10:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 2,
      title: "No PR",
      url: "https://github.com/test/repo/issues/2",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-26T09:00:00Z",
      assignees: [],
      body: "",
    },
  ];
  
  const openPrs = [
    {
      number: 100,
      title: "Fix for issue 1",
      url: "https://github.com/test/repo/pull/100",
      headRefName: "slice-1-auth",
      closingIssuesReferences: [{ number: 1 }],
    },
  ];
  
  const result = computePipelineState({ issues, claims: {}, openPrs });
  
  // Only issue without PR should be in next-run
  assert.equal(result.nextQueue.length, 1);
  assert.deepEqual(result.nextQueue, [2]);
  // Issue with PR should be in deferred
  assert.equal(result.deferred.length, 1);
  assert.equal(result.deferred[0].number, 1);
  assert.match(result.deferred[0].reason, /open PR #100/);
  assert.equal(result.deferred[0].linkedPR.number, 100);
});

// Test: categorize held issues (ralph:blocked, ralph:hitl)
test("categorize held issues correctly", () => {
  const issues = [
    {
      number: 1,
      title: "Blocked issue",
      url: "https://github.com/test/repo/issues/1",
      labels: [{ name: "ralph:blocked" }, { name: "work:slice" }],
      createdAt: "2026-06-26T10:00:00Z",
      assignees: [],
      body: "## Blocked by\n- #2\n- #3",
    },
    {
      number: 2,
      title: "Blocker 1",
      url: "https://github.com/test/repo/issues/2",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }],
      createdAt: "2026-06-25T10:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 3,
      title: "Blocker 2",
      url: "https://github.com/test/repo/issues/3",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }],
      createdAt: "2026-06-25T09:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 4,
      title: "Human review needed",
      url: "https://github.com/test/repo/issues/4",
      labels: [{ name: "ralph:hitl" }, { name: "work:slice" }],
      createdAt: "2026-06-26T09:00:00Z",
      assignees: [],
      body: "",
    },
  ];
  
  const result = computePipelineState({ issues, claims: {}, openPrs: [] });
  
  assert.equal(result.held.length, 2);
  // Find blocked issue
  const blocked = result.held.find((h) => h.number === 1);
  assert.ok(blocked);
  assert.equal(blocked.kind, "blocked");
  assert.match(blocked.reason, /blocked by #2, #3/);
  // Find hitl issue
  const hitl = result.held.find((h) => h.number === 4);
  assert.ok(hitl);
  assert.equal(hitl.kind, "hitl");
});

// Test: parse blockers from "## Blocked by" section
test("parse blockers from issue body", () => {
  const issues = [
    {
      number: 1,
      title: "Task",
      url: "https://github.com/test/repo/issues/1",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }, { name: "priority:P1" }],
      createdAt: "2026-06-26T10:00:00Z",
      assignees: [],
      body: "## Blocked by\n- #5\n- #10\n\n## Other section\nSome text",
    },
    {
      number: 5,
      title: "Blocker 1",
      url: "https://github.com/test/repo/issues/5",
      labels: [{ name: "ralph:ready" }, { name: "work:slice" }],
      createdAt: "2026-06-25T10:00:00Z",
      assignees: [],
      body: "",
    },
  ];
  
  const result = computePipelineState({ issues, claims: {}, openPrs: [] });
  
  // Issue 1 is blocked by #5 (which is open) and #10 (which doesn't exist)
  // So it should be deferred with blockers
  assert.equal(result.deferred.length, 1);
  assert.equal(result.deferred[0].number, 1);
  assert.match(result.deferred[0].reason, /blocked by #5/);
  assert.ok(result.deferred[0].blockers);
  assert.equal(result.deferred[0].blockers.length, 1);
  assert.equal(result.deferred[0].blockers[0], 5);
});

// Test: blocked/hitl overrides ready (label conflict handling)
test("blocked and hitl labels override ready state", () => {
  const issues = [
    {
      number: 1,
      title: "Blocked but also labeled ready",
      url: "https://github.com/test/repo/issues/1",
      labels: [{ name: "ralph:ready" }, { name: "ralph:blocked" }, { name: "work:slice" }],
      createdAt: "2026-06-26T10:00:00Z",
      assignees: [],
      body: "",
    },
    {
      number: 2,
      title: "HITL but also labeled ready",
      url: "https://github.com/test/repo/issues/2",
      labels: [{ name: "ralph:ready" }, { name: "ralph:hitl" }, { name: "work:slice" }],
      createdAt: "2026-06-26T09:00:00Z",
      assignees: [],
      body: "",
    },
  ];
  
  const result = computePipelineState({ issues, claims: {}, openPrs: [] });
  
  // Both should be in held, NOT in ready or nextQueue
  assert.equal(result.held.length, 2);
  assert.equal(result.ready.length, 0);
  assert.equal(result.nextQueue.length, 0);
  
  const blocked = result.held.find((h) => h.number === 1);
  const hitl = result.held.find((h) => h.number === 2);
  assert.ok(blocked);
  assert.ok(hitl);
  assert.equal(blocked.kind, "blocked");
  assert.equal(hitl.kind, "hitl");
});
