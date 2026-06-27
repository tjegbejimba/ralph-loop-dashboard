// Regression test for issue #130: abandoned runs (queue.json exists but
// status.json is empty) should not poison queue idempotency.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { runOrchestrateRepo } from "../extension/lib/orchestrate-repo.mjs";
import { RALPH_STATES, PRIORITIES, WORK_TYPES } from "../extension/lib/label-taxonomy.mjs";

const FIXED_NOW = () => new Date("2026-06-15T12:00:00.000Z");

function allCanonicalLabels() {
  return [...RALPH_STATES, ...PRIORITIES, ...WORK_TYPES];
}

function makeRepo({ config, withRalphMd = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "ralph-abandoned-"));
  mkdirSync(join(root, ".ralph"), { recursive: true });
  const cfg = config ?? {
    repo: "octo/test",
    issue: { issueSearch: "label:ralph:ready is:open no:assignee" },
  };
  writeFileSync(join(root, ".ralph", "config.json"), JSON.stringify(cfg));
  if (withRalphMd) writeFileSync(join(root, ".ralph", "RALPH.md"), "# RALPH\n");
  return root;
}

function readyIssue(number, extra = {}) {
  return {
    number,
    title: `Fix ${number}`,
    body: "Test issue",
    labels: [{ name: "ralph:ready" }, { name: "work:standalone" }, { name: "priority:P2" }],
    milestone: null,
    url: `https://github.com/octo/test/issues/${number}`,
    closedByPullRequestsReferences: [],
    ...extra,
  };
}

function ghIssueList(issues) {
  return () => JSON.stringify(issues);
}

function seedAbandonedRun(root, runId, queuedIssues) {
  const runDir = join(root, ".ralph", "runs", runId);
  mkdirSync(runDir, { recursive: true });
  
  // Write queue.json with the intended issues
  writeFileSync(
    join(runDir, "queue.json"),
    JSON.stringify(queuedIssues.map(n => ({ number: n, title: `Issue ${n}` })), null, 2),
  );
  
  // Write empty status.json (no workers ever started)
  writeFileSync(
    join(runDir, "status.json"),
    JSON.stringify({ items: {} }, null, 2),
  );
  
  // Write metadata
  writeFileSync(
    join(runDir, "metadata.json"),
    JSON.stringify({
      repoRoot: root,
      runMode: "until-empty",
      model: "claude-sonnet-4.5",
      parallelism: 1,
      createdAt: "2026-06-15T11:00:00.000Z",
    }, null, 2),
  );
}

function baseDeps(overrides = {}) {
  return {
    now: FIXED_NOW,
    userConfig: { allowAgentLaunch: true },
    listLabels: async () => allCanonicalLabels(),
    // Don't mock resolveActiveRunFn - use the real implementation
    // resolveActiveRunFn: () => null,
    execIssueList: ghIssueList([]),
    orchestrateRunFn: async () => {
      throw new Error("orchestrateRun should not be called in this test");
    },
    getLoopProcessForRepo: () => async () => [],
    ...overrides,
  };
}

test("abandoned run (queue.json exists, status.json empty) does NOT block issues on next tick", async () => {
  const root = makeRepo();
  try {
    // Seed an abandoned run: queue.json says [119, 122] but status.json is empty
    seedAbandonedRun(root, "20260615-110000-abandoned", [119, 122]);
    
    // Next tick discovers the same issues plus others
    const allIssues = [
      readyIssue(119),  // Was in abandoned run
      readyIssue(122),  // Was in abandoned run
      readyIssue(123),  // New issue
    ];
    
    let launchedQueue = null;
    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      maxIssues: 3,
      ...baseDeps({
        execIssueList: ghIssueList(allIssues),
        orchestrateRunFn: async (args) => {
          launchedQueue = args.issueNumbers;
          return {
            ok: true,
            runId: "20260615-120000-new",
            runDir: join(root, ".ralph", "runs", "20260615-120000-new"),
            pid: 1234,
            queue: args.issueNumbers.map(n => ({ number: n })),
          };
        },
      }),
    });
    
    // The abandoned run should NOT have blocked #119 and #122
    assert.equal(result.outcome, "launched");
    assert.ok(launchedQueue, "orchestrateRun should have been called");
    
    // Issues from abandoned run should be in the new queue
    assert.ok(launchedQueue.includes(119), "Issue 119 from abandoned run should be queued");
    assert.ok(launchedQueue.includes(122), "Issue 122 from abandoned run should be queued");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});


test("run with only queued items (no started/merged/failed) is treated as abandoned", async () => {
  const root = makeRepo();
  try {
    // Seed a run where issues were queued but never started
    const runDir = join(root, ".ralph", "runs", "20260615-110000-queued-only");
    mkdirSync(runDir, { recursive: true });
    
    writeFileSync(
      join(runDir, "queue.json"),
      JSON.stringify([{ number: 119 }, { number: 122 }], null, 2),
    );
    
    // status.json shows items as "queued" (never progressed beyond queued state)
    writeFileSync(
      join(runDir, "status.json"),
      JSON.stringify({
        items: {
          "119": { status: "queued" },
          "122": { status: "queued" },
        },
      }, null, 2),
    );
    
    writeFileSync(
      join(runDir, "metadata.json"),
      JSON.stringify({
        repoRoot: root,
        runMode: "until-empty",
        model: "claude-sonnet-4.5",
        parallelism: 1,
        createdAt: "2026-06-15T11:00:00.000Z",
      }, null, 2),
    );
    
    const allIssues = [readyIssue(119), readyIssue(122)];
    
    let launchedQueue = null;
    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      maxIssues: 3,
      ...baseDeps({
        execIssueList: ghIssueList(allIssues),
        orchestrateRunFn: async (args) => {
          launchedQueue = args.issueNumbers;
          return {
            ok: true,
            runId: "20260615-120000-new",
            runDir: join(root, ".ralph", "runs", "20260615-120000-new"),
            pid: 1234,
            queue: args.issueNumbers.map(n => ({ number: n })),
          };
        },
      }),
    });
    
    // Queued-only items should not block re-queuing
    assert.equal(result.outcome, "launched");
    assert.ok(launchedQueue?.includes(119), "Issue 119 (queued-only) should be re-queued");
    assert.ok(launchedQueue?.includes(122), "Issue 122 (queued-only) should be re-queued");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
