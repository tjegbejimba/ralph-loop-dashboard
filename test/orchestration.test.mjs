// Agent orchestration tests — validates gated launch and verification behavior.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { orchestrateRun, resolveOrchestrateRepoRoot } from "../extension/lib/loop-launch-controller.mjs";

const queue = [{ number: 42, title: "Slice 42: Test" }];
const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };

function makeRalphRepo(prefix = "ralph-orchestrate-target-") {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  mkdirSync(join(dir, ".ralph"), { recursive: true });
  return dir;
}

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
    defaultRepoRoot: "/repo",
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
      defaultRepoRoot: tmpRepo,
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
      defaultRepoRoot: tmpRepo,
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

test("resolveOrchestrateRepoRoot defaults to defaultRepoRoot when no override given", () => {
  const result = resolveOrchestrateRepoRoot({
    requested: undefined,
    defaultRepoRoot: "/repo",
    userConfig: {},
  });

  assert.equal(result.ok, true);
  assert.equal(result.repoRoot, "/repo");
  assert.equal(result.overridden, false);
});

test("resolveOrchestrateRepoRoot treats an override that resolves to the default as the default", () => {
  const result = resolveOrchestrateRepoRoot({
    requested: "/repo/sub/..",
    defaultRepoRoot: "/repo",
    userConfig: { orchestrateAllowedRepoRoots: [] },
  });

  assert.equal(result.ok, true);
  assert.equal(result.repoRoot, "/repo");
  assert.equal(result.overridden, false);
});

test("resolveOrchestrateRepoRoot rejects a non-default override that is not allowlisted", () => {
  const result = resolveOrchestrateRepoRoot({
    requested: "/home/user/secret",
    defaultRepoRoot: "/repo",
    userConfig: { orchestrateAllowedRepoRoots: ["/home/user/allowed"] },
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /orchestrateAllowedRepoRoots/);
});

test("orchestrateRun rejects a non-default repoRoot that is not allowlisted, even with allowAgentLaunch", async () => {
  let launched = false;
  let preflightRan = false;

  const result = await orchestrateRun({
    repoRoot: "/home/user/not-allowed",
    defaultRepoRoot: "/repo",
    queue,
    runOptions,
    userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: ["/home/user/allowed"] },
    verify: false,
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
  assert.match(result.error, /orchestrateAllowedRepoRoots/);
  assert.equal(preflightRan, false);
  assert.equal(launched, false);
});

test("orchestrateRun rejects an allowlisted target that lacks a .ralph/ directory", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-no-ralph-"));
  try {
    let launched = false;

    const result = await orchestrateRun({
      repoRoot: tmpRepo,
      defaultRepoRoot: "/repo",
      queue,
      runOptions,
      userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: [tmpRepo] },
      verify: false,
      getLoopProcess: async () => [],
      runPreflight: async () => ({ passed: true, checks: [] }),
      createRun: () => ({ runId: "run-1", runDir: join(tmpRepo, ".ralph", "runs", "run-1") }),
      launchLoop: async () => {
        launched = true;
        return { success: true, pid: 1234 };
      },
    });

    assert.equal(result.ok, false);
    assert.match(result.error, /\.ralph/);
    assert.equal(launched, false);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("orchestrateRun launches an allowlisted, valid target and threads the resolved repoRoot", async () => {
  const tmpRepo = makeRalphRepo();
  try {
    let preflightRepoRoot;
    let createdRepoRoot;
    let launchedRepoRoot;

    const result = await orchestrateRun({
      repoRoot: tmpRepo,
      defaultRepoRoot: "/repo",
      queue,
      runOptions,
      userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: [tmpRepo] },
      verify: false,
      getLoopProcess: async () => [],
      runPreflight: async ({ repoRoot }) => {
        preflightRepoRoot = repoRoot;
        return { passed: true, checks: [] };
      },
      createRun: ({ repoRoot }) => {
        createdRepoRoot = repoRoot;
        return { runId: "run-1", runDir: join(tmpRepo, ".ralph", "runs", "run-1") };
      },
      launchLoop: async ({ repoRoot }) => {
        launchedRepoRoot = repoRoot;
        return { success: true, pid: 1234 };
      },
    });

    assert.equal(result.ok, true);
    assert.equal(preflightRepoRoot, tmpRepo);
    assert.equal(createdRepoRoot, tmpRepo);
    assert.equal(launchedRepoRoot, tmpRepo);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("orchestrateRun is backward compatible when no repoRoot override is provided", async () => {
  let createdRepoRoot;

  const result = await orchestrateRun({
    defaultRepoRoot: "/repo",
    queue,
    runOptions,
    userConfig: { allowAgentLaunch: true },
    verify: false,
    getLoopProcess: async () => [],
    runPreflight: async () => ({ passed: true, checks: [] }),
    createRun: ({ repoRoot }) => {
      createdRepoRoot = repoRoot;
      return { runId: "run-1", runDir: "/repo/.ralph/runs/run-1" };
    },
    launchLoop: async () => ({ success: true, pid: 1234 }),
  });

  assert.equal(result.ok, true);
  assert.equal(createdRepoRoot, "/repo");
});

test("orchestrateRun does not authorize an arbitrary repoRoot when defaultRepoRoot is omitted", async () => {
  let launched = false;

  const result = await orchestrateRun({
    repoRoot: "/home/user/anything",
    queue,
    runOptions,
    userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: [] },
    verify: false,
    getLoopProcess: async () => [],
    runPreflight: async () => ({ passed: true, checks: [] }),
    createRun: () => ({ runId: "run-1", runDir: "/x/.ralph/runs/run-1" }),
    launchLoop: async () => {
      launched = true;
      return { success: true, pid: 1234 };
    },
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /defaultRepoRoot is required/);
  assert.equal(launched, false);
});

test("orchestrateRun scopes the running-guard to the target repo (default-repo loop does not block an override launch)", async () => {
  const tmpRepo = makeRalphRepo();
  try {
    const scopeCalls = [];
    let launched = false;

    const result = await orchestrateRun({
      repoRoot: tmpRepo,
      defaultRepoRoot: "/repo",
      queue,
      runOptions,
      userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: [tmpRepo] },
      verify: false,
      // Factory returns a running loop for the DEFAULT repo but an idle target.
      getLoopProcessForRepo: (repoRoot) => {
        scopeCalls.push(repoRoot);
        if (repoRoot === "/repo") {
          return async () => [{ pid: 99, cmd: "bash /repo/.ralph/ralph.sh" }];
        }
        return async () => [];
      },
      runPreflight: async () => ({ passed: true, checks: [] }),
      createRun: () => ({ runId: "run-1", runDir: join(tmpRepo, ".ralph", "runs", "run-1") }),
      launchLoop: async () => {
        launched = true;
        return { success: true, pid: 1234 };
      },
    });

    assert.equal(result.ok, true);
    assert.equal(launched, true);
    // The factory was consulted with the resolved target repo, not the default.
    assert.ok(scopeCalls.includes(tmpRepo));
    assert.ok(!scopeCalls.includes("/repo"));
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("orchestrateRun detects an existing run in the override target repo and refuses to launch", async () => {
  const tmpRepo = makeRalphRepo();
  try {
    let launched = false;

    const result = await orchestrateRun({
      repoRoot: tmpRepo,
      defaultRepoRoot: "/repo",
      queue,
      runOptions,
      userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: [tmpRepo] },
      verify: false,
      // The target repo already has a running loop.
      getLoopProcessForRepo: (repoRoot) =>
        repoRoot === tmpRepo
          ? async () => [{ pid: 4321, cmd: `bash ${join(tmpRepo, ".ralph", "ralph.sh")}` }]
          : async () => [],
      runPreflight: async () => ({ passed: true, checks: [] }),
      createRun: () => ({ runId: "run-1", runDir: join(tmpRepo, ".ralph", "runs", "run-1") }),
      launchLoop: async () => {
        launched = true;
        return { success: true, pid: 1234 };
      },
    });

    assert.equal(result.ok, false);
    assert.match(result.error, /already running/i);
    assert.equal(launched, false);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});
