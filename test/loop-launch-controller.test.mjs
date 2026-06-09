// Loop launch controller tests — validates the safe agent/UI launch path.

import { test } from "node:test";
import assert from "node:assert/strict";
import { startRalphLoop } from "../extension/lib/loop-launch-controller.mjs";

const queue = [{ number: 42, title: "Slice 42: Test" }];
const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };

function passingPreflight() {
  return { passed: true, checks: [{ id: "ok", status: "pass", blocking: true }] };
}

test("startRalphLoop runs preflight, creates a run, and launches it", async () => {
  const calls = [];

  const result = await startRalphLoop({
    repoRoot: "/repo",
    queue,
    runOptions,
    getLoopProcess: async () => [],
    runPreflight: async (args) => {
      calls.push(["preflight", args]);
      return passingPreflight();
    },
    createRun: (args) => {
      calls.push(["createRun", args]);
      return { runId: "run-1", runDir: "/repo/.ralph/runs/run-1" };
    },
    launchLoop: async (args) => {
      calls.push(["launchLoop", args]);
      return { success: true, pid: 1234 };
    },
  });

  assert.equal(result.ok, true);
  assert.equal(result.runId, "run-1");
  assert.equal(result.pid, 1234);
  assert.equal(calls[0][0], "preflight");
  assert.deepEqual(calls[0][1], { repoRoot: "/repo", queue, runOptions });
  assert.equal(calls[1][0], "createRun");
  assert.deepEqual(calls[1][1], { repoRoot: "/repo", queue, runOptions });
  assert.equal(calls[2][0], "launchLoop");
  assert.deepEqual(calls[2][1], {
    repoRoot: "/repo",
    runId: "run-1",
    runDir: "/repo/.ralph/runs/run-1",
    runOptions,
  });
});

test("startRalphLoop blocks on failed preflight before creating or launching", async () => {
  let created = false;
  let launched = false;
  const preflight = {
    passed: false,
    checks: [{ id: "github-auth", status: "fail", blocking: true, message: "not authenticated" }],
  };

  const result = await startRalphLoop({
    repoRoot: "/repo",
    queue,
    runOptions,
    getLoopProcess: async () => [],
    runPreflight: async () => preflight,
    createRun: () => {
      created = true;
    },
    launchLoop: async () => {
      launched = true;
    },
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /preflight/i);
  assert.equal(result.preflight, preflight);
  assert.equal(created, false);
  assert.equal(launched, false);
});

test("startRalphLoop refuses to launch when a loop is already running", async () => {
  let preflightRan = false;

  const result = await startRalphLoop({
    repoRoot: "/repo",
    queue,
    runOptions,
    getLoopProcess: async () => [{ pid: 99, cmd: "bash /repo/.ralph/ralph.sh" }],
    runPreflight: async () => {
      preflightRan = true;
      return passingPreflight();
    },
    createRun: () => ({ runId: "run-1", runDir: "/repo/.ralph/runs/run-1" }),
    launchLoop: async () => ({ success: true, pid: 1234 }),
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /already running/i);
  assert.equal(preflightRan, false);
});

test("startRalphLoop accepts issueNumbers for agent-initiated launches", async () => {
  let preflightQueue;
  let createdQueue;

  const result = await startRalphLoop({
    repoRoot: "/repo",
    issueNumbers: [42, "43"],
    runOptions,
    getLoopProcess: async () => [],
    runPreflight: async ({ queue }) => {
      preflightQueue = queue;
      return passingPreflight();
    },
    createRun: ({ queue }) => {
      createdQueue = queue;
      return { runId: "run-1", runDir: "/repo/.ralph/runs/run-1" };
    },
    launchLoop: async () => ({ success: true, pid: 1234 }),
  });

  assert.equal(result.ok, true);
  assert.deepEqual(preflightQueue, [
    { number: 42, title: "Issue #42" },
    { number: 43, title: "Issue #43" },
  ]);
  assert.deepEqual(createdQueue, preflightQueue);
});

test("startRalphLoop returns a structured error for invalid run options", async () => {
  let preflightRan = false;

  const result = await startRalphLoop({
    repoRoot: "/repo",
    queue,
    runOptions: { runMode: "forever", parallelism: 1, model: "claude-sonnet-4.5" },
    getLoopProcess: async () => [],
    runPreflight: async () => {
      preflightRan = true;
      return passingPreflight();
    },
    createRun: () => ({ runId: "run-1", runDir: "/repo/.ralph/runs/run-1" }),
    launchLoop: async () => ({ success: true, pid: 1234 }),
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /run mode/i);
  assert.equal(preflightRan, false);
});
