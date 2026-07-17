import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, utimesSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { computePipelineErrorState, computePipelineState, discoverFailedRunItems, discoverRecoverableRunItems } from "../extension-pipeline/lib/pipeline-state.mjs";
import { fetchMissingFailedIssueStates } from "../extension-pipeline/lib/failed-issue-state.mjs";
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

test("uses status.json mtime as failedAt when a failed item has only startedAt", () => {
  const repoRoot = mkdtempSync(join(tmpdir(), "ralph-pipeline-"));
  try {
    const runDir = join(repoRoot, ".ralph", "runs", "20260628-165239-1a6a4003");
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      join(runDir, "metadata.json"),
      JSON.stringify({ repoRoot, runMode: "until-empty", model: "claude-sonnet-4.5", parallelism: 1, createdAt: "2026-06-28T16:52:39.453Z" }),
    );
    writeFileSync(
      join(runDir, "queue.json"),
      JSON.stringify([{ number: 139, title: "Failure timestamp", url: "https://github.com/tj/repo/issues/139" }]),
    );
    const statusPath = join(runDir, "status.json");
    writeFileSync(
      statusPath,
      JSON.stringify({
        items: {
          139: {
            status: "failed",
            startedAt: "2026-06-28T16:52:41Z",
            error: "Worker failed after issue metadata changed",
          },
        },
      }),
    );
    const persistedFailureTime = new Date("2026-06-28T17:02:41Z");
    assert.equal(utimesSync(statusPath, persistedFailureTime, persistedFailureTime), undefined);

    const [failure] = discoverFailedRunItems(repoRoot);
    const state = computePipelineState({
      repo: { slug: "tj/repo", label: "repo", mainCheckout: repoRoot },
      openIssues: [
        {
          ...issue(139, ["ralph:ready", "priority:P2", "work:standalone"]),
          updatedAt: "2026-06-28T16:57:41Z",
        },
      ],
      failedRunItems: [failure],
    });

    assert.equal(failure.startedAt, "2026-06-28T16:52:41Z");
    assert.match(failure.failedAt, /^2026-06-28T17:02:41/);
    assert.equal(state.failed.length, 1);
    assert.equal(state.failed[0].number, 139);
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

test("closed failed issues remain historical instead of needing attention", () => {
  const closed = {
    ...issue(139, ["ralph:failed", "priority:P2", "work:standalone"]),
    state: "CLOSED",
    closedAt: "2026-06-29T10:00:00Z",
  };
  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [],
    closedIssues: [closed],
    openPrs: [],
    claims: {},
    failedRunItems: [
      {
        number: 139,
        title: "Old failed run",
        runId: "old-failed-run",
        reason: "Worker process died",
        failedAt: "2026-06-20T10:00:00Z",
      },
    ],
  });

  assert.equal(state.failed.length, 0);
  assert.deepEqual(state.recent, [{
    number: 139,
    title: "Issue 139",
    url: "https://github.com/tj/repo/issues/139",
    closedAt: "2026-06-29T10:00:00Z",
    outcome: "failed",
  }]);
});

test("fetches current GitHub state for failed runs outside the recent issue window", async () => {
  const calls = [];
  const result = await fetchMissingFailedIssueStates({
    repoSlug: "tj/repo",
    failedRunItems: [{ number: 188 }, { number: 188 }, { number: 189 }],
    knownIssues: [{ number: 189 }],
    fetchIssue: async ({ repoSlug, issueNumber }) => {
      calls.push({ repoSlug, issueNumber });
      return {
        number: issueNumber,
        state: "CLOSED",
        closedAt: "2026-05-09T06:13:33Z",
      };
    },
  });

  assert.deepEqual(calls, [{ repoSlug: "tj/repo", issueNumber: 188 }]);
  assert.deepEqual(result.issues, [{
    number: 188,
    state: "CLOSED",
    closedAt: "2026-05-09T06:13:33Z",
  }]);
  assert.deepEqual(result.errors, []);
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

test("pipeline error state fails closed when PR data cannot be fetched", () => {
  const state = computePipelineErrorState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    error: { kind: "pr-fetch-failed", message: "Could not fetch PRs: rate limit" },
  });

  assert.equal(state.error.kind, "pr-fetch-failed");
  assert.deepEqual(state.nextQueue, []);
  assert.deepEqual(state.ready, []);
  assert.equal(state.counts.ready, 0);
});

test("pipeline extension does not convert PR fetch failures to an empty PR list", () => {
  const extensionSource = readFileSync(new URL("../extension-pipeline/extension.mjs", import.meta.url), "utf8");

  assert.doesNotMatch(extensionSource, /pr[^\n]*list[\s\S]{0,160}\.catch\(\s*\(\)\s*=>\s*\[\]\s*\)/);
  assert.match(extensionSource, /pr-fetch-failed/);
  assert.match(extensionSource, /computePipelineErrorState/);
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

test("pipeline renderer includes recoverable work lane", () => {
  const html = renderHtml();

  assert.match(html, /Recoverable/);
  assert.match(html, /d\.recoverable/);
  assert.match(html, /attemptCount/);
  assert.match(html, /maxAttempts/);
  assert.match(html, /nextRetryAt/);
  assert.match(html, /branch/);
});

test("discovers recoverable run items from recent durable Ralph run state", () => {
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
          number: 140,
          title: "Add recovery budget tracking",
          url: "https://github.com/tj/repo/issues/140",
          labels: ["ralph:queued", "priority:P2", "work:standalone"],
        },
      ]),
    );
    
    // Create recovery ledger with real schema
    const ledgerPath = join(repoRoot, ".ralph", "recovery-ledger.json");
    mkdirSync(join(repoRoot, ".ralph"), { recursive: true });
    writeFileSync(
      ledgerPath,
      JSON.stringify({
        "140": {
          pr: "169",
          branch: "slice-140-recovery-budget",
          attempt: 1,
          nextRetryAt: "2026-06-28T16:57:41Z",
          reason: "Copilot exited with code 1",
          status: "recoverable",
          recordedAt: "2026-06-28T16:52:41Z",
        },
      }),
    );
    
    writeFileSync(
      join(runDir, "status.json"),
      JSON.stringify({
        items: {
          140: {
            status: "recoverable",
            workerId: 1,
            pid: 5642,
            logFile: "iter-20260628-095241-w1-issue-140.log",
            startedAt: "2026-06-28T16:52:41Z",
            error: "Copilot exited with code 1",
          },
        },
      }),
    );

    const recoverables = discoverRecoverableRunItems(repoRoot);

    assert.equal(recoverables.length, 1);
    assert.equal(recoverables[0].number, 140);
    assert.equal(recoverables[0].runId, "20260628-165239-1a6a4003");
    assert.equal(recoverables[0].runDir, runDir);
    assert.equal(recoverables[0].reason, "Copilot exited with code 1");
    assert.equal(recoverables[0].attemptCount, 1);
    assert.equal(recoverables[0].maxAttempts, 2);
    assert.equal(recoverables[0].nextRetryAt, "2026-06-28T16:57:41Z");
    assert.equal(recoverables[0].prNumber, 169);
    assert.equal(recoverables[0].branch, "slice-140-recovery-budget");
  } finally {
    rmSync(repoRoot, { recursive: true, force: true });
  }
});

test("pipeline state includes recoverable lane with attempt counts and PR context", () => {
  const recoverableRunItems = [
    {
      number: 140,
      title: "Add recovery budget tracking",
      url: "https://github.com/tj/repo/issues/140",
      labels: ["ralph:queued", "priority:P2", "work:standalone"],
      runId: "20260628-165239-1a6a4003",
      runDir: "/repo/.ralph/runs/20260628-165239-1a6a4003",
      reason: "Copilot exited with code 1",
      logFile: "iter-20260628-095241-w1-issue-140.log",
      logFilePath: "/repo/.ralph/logs/iter-20260628-095241-w1-issue-140.log",
      startedAt: "2026-06-28T16:52:41Z",
      runCreatedAt: "2026-06-28T16:52:39.453Z",
      attemptCount: 1,
      maxAttempts: 2,
      nextRetryAt: "2026-06-28T16:57:41Z",
      prNumber: 169,
      branch: "slice-140-recovery-budget",
    },
  ];

  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [
      issue(140, ["ralph:queued", "priority:P2", "work:standalone"]),
      issue(147, ["ralph:ready", "priority:P2", "work:standalone"]),
    ],
    closedIssues: [],
    openPrs: [
      {
        number: 169,
        title: "Fix #140",
        url: "https://github.com/tj/repo/pull/169",
        headRefName: "slice-140-recovery-budget",
        closingIssuesReferences: [{ number: 140 }],
      },
    ],
    claims: {},
    failedRunItems: [],
    recoverableRunItems,
  });

  assert.equal(state.recoverable.length, 1);
  assert.equal(state.recoverable[0].number, 140);
  assert.equal(state.recoverable[0].title, "Issue 140");
  assert.equal(state.recoverable[0].repoSlug, "tj/repo");
  assert.equal(state.recoverable[0].state, "ralph:queued");
  assert.equal(state.recoverable[0].reason, "Copilot exited with code 1");
  assert.equal(state.recoverable[0].attemptCount, 1);
  assert.equal(state.recoverable[0].maxAttempts, 2);
  assert.equal(state.recoverable[0].nextRetryAt, "2026-06-28T16:57:41Z");
  assert.equal(state.recoverable[0].linkedPR.number, 169);
  assert.equal(state.recoverable[0].branch, "slice-140-recovery-budget");
  assert.deepEqual(state.nextQueue, [147]);
  assert.equal(state.counts.recoverable, 1);
});

test("pipeline state exposes promotion eligibility and guard reasons", () => {
  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [
      issue(188, ["ralph:fast-lane", "priority:P1"]),
      issue(210, ["ralph:fast-lane", "priority:P2", "work:standalone"]),
    ],
    closedIssues: [],
    openPrs: [],
    claims: {},
    failedRunItems: [],
    recoverableRunItems: [],
  });

  assert.deepEqual(state.awaiting.map((card) => [card.number, card.promotion]), [
    [188, { eligible: false, reason: "Missing work type - add work:standalone or work:slice." }],
    [210, { eligible: true, reason: null }],
  ]);
});

test("awaiting promotion contains fast-lane candidates but not reviewed PRD parents", () => {
  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [
      issue(200, ["ralph:evaluated", "priority:P1", "work:prd"]),
      issue(210, ["ralph:fast-lane", "priority:P2", "work:standalone"]),
    ],
    closedIssues: [],
    openPrs: [],
    claims: {},
  });

  assert.deepEqual(state.awaiting.map((card) => card.number), [210]);
  assert.equal(state.needsTriage.some((card) => card.number === 200), false);
});

test("unexpected evaluated non-PRD issues remain visible in needs triage", () => {
  const state = computePipelineState({
    repo: { slug: "tj/repo", label: "repo", mainCheckout: "/repo" },
    openIssues: [
      issue(211, ["ralph:evaluated", "priority:P2", "work:standalone"]),
    ],
    closedIssues: [],
    openPrs: [],
    claims: {},
  });

  assert.deepEqual(state.awaiting, []);
  assert.equal(state.needsTriage.length, 1);
  assert.equal(state.needsTriage[0].number, 211);
  assert.equal(
    state.needsTriage[0].note,
    "Unexpected ralph:evaluated issue - expected exactly work:prd; review labels.",
  );
});
