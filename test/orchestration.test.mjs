// Agent orchestration tests — validates gated launch and verification behavior.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { orchestrateRun } from "../extension/lib/loop-launch-controller.mjs";

const queue = [{ number: 42, title: "Slice 42: Test" }];
const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };

test("orchestrateRun refuses agent launch unless allowAgentLaunch is enabled", async () => {
  let preflightRan = false;
  let launched = false;

  const result = await orchestrateRun({
    repoRoot: "/repo",
    queue,
    runOptions,
    userConfig: {},
    getLoopProcess: async () => [],
    runPreflight: async () => {
      preflightRan = true;
      return { passed: true, checks: [] };
    },
    createRun: () => ({ runId: "run-1", runDir: "/repo/.ralph/runs/run-1" }),
    launchLoop: async () => {
      launched = true;
      return { success: true, pid: 1234 };
    },
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /allowAgentLaunch/i);
  assert.equal(preflightRan, false);
  assert.equal(launched, false);
});

test("orchestrateRun defaults agent launches to until-empty", async () => {
  let preflightRunOptions;
  let createdRunOptions;
  let launchedRunOptions;

  const result = await orchestrateRun({
    repoRoot: "/repo",
    queue,
    userConfig: { allowAgentLaunch: true },
    verify: false,
    getLoopProcess: async () => [],
    runPreflight: async ({ runOptions }) => {
      preflightRunOptions = runOptions;
      return { passed: true, checks: [] };
    },
    createRun: ({ runOptions }) => {
      createdRunOptions = runOptions;
      return { runId: "run-1", runDir: "/repo/.ralph/runs/run-1" };
    },
    launchLoop: async ({ runOptions }) => {
      launchedRunOptions = runOptions;
      return { success: true, pid: 1234 };
    },
  });

  assert.equal(result.ok, true);
  assert.equal(preflightRunOptions.runMode, "until-empty");
  assert.equal(createdRunOptions.runMode, "until-empty");
  assert.equal(launchedRunOptions.runMode, "until-empty");
});

test("orchestrateRun verification reports merged, failed, and skipped distinctly", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-orchestration-"));
  try {
    const runId = "run-terminal";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const mixedQueue = [
      { number: 1, title: "Merged issue" },
      { number: 2, title: "Failed issue" },
      { number: 3, title: "Skipped issue" },
    ];
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      join(runDir, "status.json"),
      JSON.stringify({
        items: {
          "1": { status: "merged" },
          "2": { status: "failed", error: "Copilot exited with code 1" },
          "3": { status: "skipped" },
        },
      }),
    );

    const result = await orchestrateRun({
      repoRoot: tmpRepo,
      queue: mixedQueue,
      runOptions,
      userConfig: { allowAgentLaunch: true },
      verify: true,
      timeoutMinutes: 0.01,
      getLoopProcess: async () => [],
      runPreflight: async () => ({ passed: true, checks: [] }),
      createRun: () => ({ runId, runDir }),
      launchLoop: async () => ({ success: true, pid: 1234 }),
    });

    assert.equal(result.ok, false);
    assert.equal(result.error, "Ralph run verification did not complete successfully.");
    assert.equal(result.verification.timedOut, false);
    assert.deepEqual(result.verification.counts, {
      total: 3,
      merged: 1,
      failed: 1,
      skipped: 1,
      nonterminal: 0,
      deadWorker: 0,
    });
    assert.deepEqual(
      result.verification.items.map((item) => ({ number: item.number, status: item.status })),
      [
        { number: 1, status: "merged" },
        { number: 2, status: "failed" },
        { number: 3, status: "skipped" },
      ],
    );
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("orchestrateRun verification times out with nonterminal and dead-worker breakdown", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-orchestration-"));
  try {
    const runId = "run-timeout";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const timeoutQueue = [
      { number: 10, title: "Running issue" },
      { number: 20, title: "Never claimed issue" },
    ];
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      join(runDir, "status.json"),
      JSON.stringify({
        items: {
          "10": { status: "running", pid: 99999999, workerId: 1 },
        },
      }),
    );

    const result = await orchestrateRun({
      repoRoot: tmpRepo,
      queue: timeoutQueue,
      runOptions,
      userConfig: { allowAgentLaunch: true },
      verify: true,
      timeoutMinutes: 0,
      getLoopProcess: async () => [],
      runPreflight: async () => ({ passed: true, checks: [] }),
      createRun: () => ({ runId, runDir }),
      launchLoop: async () => ({ success: true, pid: 1234 }),
    });

    assert.equal(result.ok, false);
    assert.equal(result.verification.timedOut, true);
    assert.deepEqual(result.verification.counts, {
      total: 2,
      merged: 0,
      failed: 0,
      skipped: 0,
      nonterminal: 2,
      deadWorker: 1,
    });
    assert.deepEqual(
      result.verification.items.map((item) => ({
        number: item.number,
        status: item.status,
        deadWorker: item.deadWorker,
      })),
      [
        { number: 10, status: "running", deadWorker: true },
        { number: 20, status: "pending", deadWorker: false },
      ],
    );
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});
