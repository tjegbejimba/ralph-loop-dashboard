import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { computePipelineState, discoverFailedRunItems } from "../extension-pipeline/lib/pipeline-state.mjs";
import { renderHtml } from "../extension-pipeline/renderer.mjs";

function issue(number, labels = []) {
  return {
    number,
    title: `Issue ${number}`,
    url: `https://github.com/tj/repo/issues/${number}`,
    labels: labels.map((name) => ({ name })),
    assignees: [],
    body: "",
    createdAt: "2026-06-20T10:00:00Z",
    updatedAt: "2026-06-28T17:00:00Z",
  };
}

test("discovers failed run items from recent durable Ralph run state", () => {
  const repoRoot = mkdtempSync(join(tmpdir(), "ralph-pipeline-"));
  try {
    const runDir = join(repoRoot, ".ralph", "runs", "20260628-165239-1a6a4003");
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      join(runDir, "metadata.json"),
      JSON.stringify({
        repoRoot,
        runMode: "until-empty",
        model: "claude-sonnet-4.5",
        parallelism: 1,
        createdAt: "2026-06-28T16:52:39.453Z",
      }),
    );
    writeFileSync(
      join(runDir, "queue.json"),
      JSON.stringify([
        {
          number: 139,
          title: "Add install.sh --check content-diff drift gate in CI",
          url: "https://github.com/tj/repo/issues/139",
          labels: ["ralph:ready", "priority:P2", "work:standalone"],
        },
      ]),
    );
    writeFileSync(
      join(runDir, "status.json"),
      JSON.stringify({
        items: {
          139: {
            status: "failed",
            workerId: 1,
            pid: 5642,
            logFile: "iter-20260628-095241-w1-issue-139.log",
            startedAt: "2026-06-28T16:52:41Z",
            error: "No merged PR found after copilot completed",
          },
          147: { status: "queued" },
        },
      }),
    );

    const failures = discoverFailedRunItems(repoRoot);

    assert.equal(failures.length, 1);
    assert.equal(failures[0].number, 139);
    assert.equal(failures[0].runId, "20260628-165239-1a6a4003");
    assert.equal(failures[0].runDir, runDir);
    assert.equal(failures[0].reason, "No merged PR found after copilot completed");
    assert.equal(failures[0].logFile, "iter-20260628-095241-w1-issue-139.log");
    assert.equal(failures[0].logFilePath, join(repoRoot, ".ralph", "logs", "iter-20260628-095241-w1-issue-139.log"));
    assert.equal(failures[0].title, "Add install.sh --check content-diff drift gate in CI");
  } finally {
    rmSync(repoRoot, { recursive: true, force: true });
  }
});

test("failed run details are visible once and enriched with issue and PR context", () => {
  const failedRunItems = [
    {
      number: 139,
      title: "Queue title should not replace live issue title",
      url: "https://github.com/tj/repo/issues/139",
      labels: ["ralph:ready", "priority:P2", "work:standalone"],
      runId: "20260628-165239-1a6a4003",
      runDir: "/repo/.ralph/runs/20260628-165239-1a6a4003",
      reason: "No merged PR found after copilot completed",
      logFile: "iter-20260628-095241-w1-issue-139.log",
      logFilePath: "/repo/.ralph/logs/iter-20260628-095241-w1-issue-139.log",
      startedAt: "2026-06-28T16:52:41Z",
      runCreatedAt: "2026-06-28T16:52:39.453Z",
    },
  ];

  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [
      issue(139, ["ralph:failed", "ralph:ready", "priority:P2", "work:standalone"]),
      issue(147, ["ralph:ready", "priority:P2", "work:standalone"]),
    ],
    closedIssues: [],
    openPrs: [
      {
        number: 169,
        title: "Fix #139",
        url: "https://github.com/tj/repo/pull/169",
        headRefName: "slice-139-install-check",
        closingIssuesReferences: [{ number: 139 }],
      },
    ],
    claims: {},
    failedRunItems,
  });

  assert.equal(state.failed.length, 1);
  assert.equal(state.failed[0].number, 139);
  assert.equal(state.failed[0].title, "Issue 139");
  assert.equal(state.failed[0].repoSlug, "tj/repo");
  assert.equal(state.failed[0].state, "ralph:failed");
  assert.equal(state.failed[0].reason, "No merged PR found after copilot completed");
  assert.equal(state.failed[0].runId, "20260628-165239-1a6a4003");
  assert.equal(state.failed[0].runDir, "/repo/.ralph/runs/20260628-165239-1a6a4003");
  assert.equal(state.failed[0].logFilePath, "/repo/.ralph/logs/iter-20260628-095241-w1-issue-139.log");
  assert.equal(state.failed[0].linkedPR.number, 169);
  assert.deepEqual(state.nextQueue, [147]);
  assert.equal(state.counts.failed, 1);
});

test("current non-failed Ralph issue state suppresses stale failed run noise", () => {
  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [issue(139, ["ralph:ready", "priority:P2", "work:standalone"])],
    closedIssues: [],
    openPrs: [],
    claims: {},
    failedRunItems: [
      {
        number: 139,
        title: "Old failed run",
        url: "https://github.com/tj/repo/issues/139",
        labels: ["ralph:ready", "priority:P2", "work:standalone"],
        runId: "old-failed-run",
        reason: "Worker process died",
        failedAt: "2026-06-20T10:00:00Z",
      },
    ],
  });

  assert.equal(state.failed.length, 0);
  assert.deepEqual(state.nextQueue, [139]);
});

test("durable failed run overrides stale ralph:running issue label without duplication", () => {
  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [
      {
        ...issue(139, ["ralph:running", "priority:P2", "work:standalone"]),
        updatedAt: "2026-06-28T16:52:40Z",
      },
    ],
    closedIssues: [],
    openPrs: [],
    claims: {
      139: {
        pid: 99999,
        startedAt: "2026-06-28T16:52:41Z",
        logFile: "iter-20260628-095241-w1-issue-139.log",
        workerId: 1,
      },
    },
    failedRunItems: [
      {
        number: 139,
        title: "Running label but failed run status",
        url: "https://github.com/tj/repo/issues/139",
        labels: ["ralph:running", "priority:P2", "work:standalone"],
        runId: "20260628-165239-1a6a4003",
        reason: "Worker process died",
        failedAt: "2026-06-28T16:52:41Z",
      },
    ],
  });

  assert.equal(state.failed.length, 1);
  assert.equal(state.failed[0].number, 139);
  assert.equal(state.failed[0].reason, "Worker process died");
  assert.equal(state.running.length, 0);
});

test("pipeline renderer includes a prominent failed needs-attention lane", () => {
  const html = renderHtml();

  assert.match(html, /Failed · needs attention/);
  assert.match(html, /d\.failed/);
  assert.match(html, /Needs attention/);
  assert.match(html, /runId/);
  assert.match(html, /logFilePath/);
  assert.match(html, /function href/);
  assert.match(html, /u\.protocol==="http:"\|\|u\.protocol==="https:"/);
});
