// Unit tests for the orchestrate-repo headless repo-maintain runner.
// The runner reuses the gated orchestrateRun launch path; these tests inject
// stubs for orchestrateRun / gh discovery / active-run detection so nothing
// hits the network or launches real workers.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  runOrchestrateRepo,
  buildBoundedQueue,
  findMissingCanonicalLabels,
  resolveRepoSlug,
} from "../extension/lib/orchestrate-repo.mjs";
import { RALPH_STATES, PRIORITIES, WORK_TYPES } from "../extension/lib/label-taxonomy.mjs";

const FIXED_NOW = () => new Date("2026-06-12T12:00:00.000Z");

// All canonical labels present so the label precondition passes by default.
function allCanonicalLabels() {
  return [...RALPH_STATES, ...PRIORITIES, ...WORK_TYPES];
}

function makeRepo({ config, withRalphMd = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "ralph-orch-repo-"));
  mkdirSync(join(root, ".ralph"), { recursive: true });
  const cfg = config ?? {
    repo: "octo/alisterr",
    issue: { issueSearch: "label:ralph:ready is:open no:assignee" },
  };
  writeFileSync(join(root, ".ralph", "config.json"), JSON.stringify(cfg));
  if (withRalphMd) writeFileSync(join(root, ".ralph", "RALPH.md"), "# RALPH\n");
  return root;
}

function readyIssue(number, extra = {}) {
  return {
    number,
    title: `Standalone fix ${number}`,
    body: "",
    labels: [{ name: "ralph:ready" }, { name: "work:standalone" }, { name: "priority:P2" }],
    milestone: null,
    url: `https://github.com/octo/alisterr/issues/${number}`,
    closedByPullRequestsReferences: [],
    ...extra,
  };
}

// queryIssues calls its execCommand and expects a JSON string of issues.
function ghIssueList(issues) {
  return () => JSON.stringify(issues);
}

function ledgerPath(root) {
  return join(root, ".ralph", "orchestrator", "ledger.json");
}

function seedFailedRun(root, runId, issueNumber, error, extra = {}) {
  const runDir = join(root, ".ralph", "runs", runId);
  const logFile = extra.logFile ?? `iter-${runId}-issue-${issueNumber}.log`;
  mkdirSync(runDir, { recursive: true });
  if (extra.logBody) {
    mkdirSync(join(root, ".ralph", "logs"), { recursive: true });
    writeFileSync(join(root, ".ralph", "logs", logFile), extra.logBody);
  }
  writeFileSync(
    join(runDir, "status.json"),
    JSON.stringify({
      items: {
        [String(issueNumber)]: {
          status: "failed",
          workerId: extra.workerId ?? 1,
          pid: extra.pid ?? 99999,
          logFile,
          startedAt: extra.startedAt ?? "2026-06-12T11:00:00.000Z",
          error,
        },
      },
    }, null, 2),
  );
}

function baseDeps(overrides = {}) {
  return {
    now: FIXED_NOW,
    userConfig: { allowAgentLaunch: true },
    listLabels: async () => allCanonicalLabels(),
    resolveActiveRunFn: () => null,
    execIssueList: ghIssueList([]),
    orchestrateRunFn: async () => {
      throw new Error("orchestrateRun should not be called in this test");
    },
    getLoopProcessForRepo: () => async () => [],
    ...overrides,
  };
}

test("buildBoundedQueue — orders by priority rank, then issue number, and caps at maxIssues", () => {
  // Core regression: a high-numbered P1 must beat a low-numbered P2 (no priority inversion).
  assert.deepEqual(
    buildBoundedQueue(
      [{ number: 5, priority: "P2" }, { number: 99, priority: "P1" }],
      { maxIssues: 1 },
    ).map((i) => i.number),
    [99],
  );

  // Within the same priority band, lowest number first.
  assert.deepEqual(
    buildBoundedQueue([{ number: 30, priority: "P1" }, { number: 5, priority: "P1" }]).map((i) => i.number),
    [5, 30],
  );

  // Full ordering across all priority bands (P0 < P1 < P2 < P3), number as tiebreaker.
  assert.deepEqual(
    buildBoundedQueue([
      { number: 7, priority: "P3" },
      { number: 8, priority: "P1" },
      { number: 3, priority: "P2" },
      { number: 1, priority: "P0" },
      { number: 2, priority: "P1" },
    ], { maxIssues: 5 }).map((i) => i.number),
    [1, 2, 8, 3, 7],
  );

  // Cap is applied after the new ordering.
  assert.deepEqual(
    buildBoundedQueue([
      { number: 7, priority: "P3" },
      { number: 8, priority: "P1" },
      { number: 1, priority: "P0" },
    ], { maxIssues: 2 }).map((i) => i.number),
    [1, 8],
  );

  // Missing priority defaults to the P2 band, so an unprioritised set stays number-ascending.
  assert.deepEqual(
    buildBoundedQueue([{ number: 30 }, { number: 5 }, { number: 12 }, { number: 99 }], { maxIssues: 3 }).map((i) => i.number),
    [5, 12, 30],
  );
});

test("buildBoundedQueue — does not mutate the input array", () => {
  const issues = [{ number: 5, priority: "P2" }, { number: 99, priority: "P1" }];
  buildBoundedQueue(issues, { maxIssues: 2 });
  assert.deepEqual(issues.map((i) => i.number), [5, 99]);
});

test("findMissingCanonicalLabels — reports missing ralph:* state labels", () => {
  assert.deepEqual(findMissingCanonicalLabels([]), [...RALPH_STATES]);
  assert.deepEqual(findMissingCanonicalLabels(allCanonicalLabels()), []);
  const partial = allCanonicalLabels().filter((l) => l !== "ralph:ready");
  assert.deepEqual(findMissingCanonicalLabels(partial), ["ralph:ready"]);
});

test("resolveRepoSlug — prefers config.repo over origin remote", () => {
  const slug = resolveRepoSlug({
    repoRoot: "/tmp/x",
    config: { repo: "octo/alisterr" },
    execGit: () => "git@github.com:other/repo.git\n",
  });
  assert.deepEqual(slug, { owner: "octo", name: "alisterr", slug: "octo/alisterr" });
});

test("resolveRepoSlug — falls back to origin remote (ssh + https)", () => {
  const ssh = resolveRepoSlug({
    repoRoot: "/tmp/x",
    config: {},
    execGit: () => "git@github.com:octo/alisterr.git\n",
  });
  assert.equal(ssh.slug, "octo/alisterr");
  const https = resolveRepoSlug({
    repoRoot: "/tmp/x",
    config: {},
    execGit: () => "https://github.com/octo/alisterr\n",
  });
  assert.equal(https.slug, "octo/alisterr");
});

test("missing .ralph/config.json → hard stop, non-zero exit, no ledger", async () => {
  const root = mkdtempSync(join(tmpdir(), "ralph-orch-bare-"));
  try {
    const result = await runOrchestrateRepo({ repoRoot: root, ...baseDeps() });
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.equal(result.exitCode, 1);
    assert.match(result.ownerBrief, /\.ralph/);
    assert.equal(existsSync(ledgerPath(root)), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("missing .ralph/RALPH.md → hard stop", async () => {
  const root = makeRepo({ withRalphMd: false });
  try {
    const result = await runOrchestrateRepo({ repoRoot: root, ...baseDeps() });
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.equal(result.exitCode, 1);
    assert.match(result.ownerBrief, /RALPH\.md/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("dry-run → prints plan, makes zero mutations, never calls orchestrateRun", async () => {
  const root = makeRepo();
  let orchestrateCalled = false;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      dryRun: true,
      ...baseDeps({
        execIssueList: ghIssueList([readyIssue(7), readyIssue(3)]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true };
        },
      }),
    });
    assert.equal(orchestrateCalled, false);
    assert.equal(result.dryRun, true);
    assert.equal(result.outcome, "dry-run");
    assert.equal(result.exitCode, 0);
    // Discovery + bounded queue computed read-only.
    assert.deepEqual(result.queue.map((i) => i.number), [3, 7]);
    assert.equal(result.issueSearch, "label:ralph:ready is:open no:assignee");
    // The would-be ledger is returned but NOT written.
    assert.ok(result.ledger);
    assert.equal(result.ledgerWritten, false);
    assert.equal(existsSync(ledgerPath(root)), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("active run → defer (exit 0, no launch), recorded in ledger", async () => {
  const root = makeRepo();
  let orchestrateCalled = false;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      ...baseDeps({
        resolveActiveRunFn: () => ({ runId: "run-live", isActive: true }),
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true };
        },
      }),
    });
    assert.equal(orchestrateCalled, false);
    assert.equal(result.outcome, "deferred");
    assert.equal(result.exitCode, 0);
    assert.equal(result.concurrency.activeRunDetected, true);
    assert.equal(result.concurrency.deferred, true);
    // Ledger written (defer is recorded), concurrency reflects the active run.
    assert.equal(result.ledgerWritten, true);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.concurrency.activeRunDetected, true);
    assert.equal(ledger.concurrency.deferred, true);
    assert.equal(ledger.mode, "repo-maintain");
    assert.equal(ledger.target.repo, "octo/alisterr");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("label precondition missing → skip + one-time owner brief, no launch", async () => {
  const root = makeRepo();
  let orchestrateCalled = false;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      ...baseDeps({
        listLabels: async () => ["bug", "enhancement"],
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true };
        },
      }),
    });
    assert.equal(orchestrateCalled, false);
    assert.equal(result.outcome, "skipped-labels");
    assert.equal(result.exitCode, 0);
    assert.equal(result.labelPrecondition.ok, false);
    assert.ok(result.labelPrecondition.missing.includes("ralph:ready"));
    assert.match(result.ownerBrief, /gh label create/);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.ownerBriefsSent["octo/alisterr:labels"], true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("discovery returns N → bounded to maxIssues (priority then number)", async () => {
  const root = makeRepo();
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      dryRun: true,
      maxIssues: 3,
      ...baseDeps({
        execIssueList: ghIssueList([
          readyIssue(20),
          readyIssue(4),
          readyIssue(15),
          readyIssue(8),
          readyIssue(11),
        ]),
      }),
    });
    assert.equal(result.discovered.length, 5);
    assert.deepEqual(result.queue.map((i) => i.number), [4, 8, 11]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("discovery drops issues with an open linked PR and non-ready issues", async () => {
  const root = makeRepo();
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      dryRun: true,
      ...baseDeps({
        execIssueList: ghIssueList([
          readyIssue(5),
          readyIssue(6, {
            closedByPullRequestsReferences: [
              { state: "OPEN", url: "https://github.com/octo/alisterr/pull/99" },
            ],
          }),
          // needs-triage is not runnable
          readyIssue(7, { labels: [{ name: "ralph:needs-triage" }] }),
        ]),
      }),
    });
    assert.deepEqual(result.queue.map((i) => i.number), [5]);
    const skippedNums = result.skipped.map((s) => s.number);
    assert.ok(skippedNums.includes(6));
    assert.ok(skippedNums.includes(7));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("no ready work → exit 0, ledger phase done, no orchestrateRun call", async () => {
  const root = makeRepo();
  let orchestrateCalled = false;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      ...baseDeps({
        execIssueList: ghIssueList([]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true };
        },
      }),
    });
    assert.equal(orchestrateCalled, false);
    assert.equal(result.outcome, "no-ready-work");
    assert.equal(result.exitCode, 0);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.phase, "done");
    assert.deepEqual(ledger.queuedIssues, []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("launch → orchestrateRun called with gated args; ledger written with run", async () => {
  const root = makeRepo();
  let receivedArgs = null;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      parallelism: 1,
      runMode: "until-empty",
      ...baseDeps({
        execIssueList: ghIssueList([readyIssue(7), readyIssue(3)]),
        orchestrateRunFn: async (args) => {
          receivedArgs = args;
          return {
            ok: true,
            runId: "run-1",
            runDir: join(root, ".ralph", "runs", "run-1"),
            pid: 4321,
            queue: [{ number: 3 }, { number: 7 }],
          };
        },
      }),
    });

    assert.equal(result.outcome, "launched");
    assert.equal(result.exitCode, 0);
    // Gated launch args — defaultRepoRoot is the TRUSTED root, not a blind echo
    // of the operator-supplied repoRoot (that would bypass the allowlist).
    assert.equal(receivedArgs.repoRoot, root);
    assert.equal(receivedArgs.defaultRepoRoot, root);
    assert.deepEqual(receivedArgs.issueNumbers, [3, 7]);
    assert.equal(receivedArgs.verify, false);
    assert.equal(receivedArgs.runOptions.parallelism, 1);
    assert.equal(receivedArgs.runOptions.runMode, "until-empty");
    assert.equal(receivedArgs.userConfig.allowAgentLaunch, true);

    // Ledger shape.
    assert.equal(result.ledgerWritten, true);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.schemaVersion, "ralph-orchestrator/v1");
    assert.equal(ledger.mode, "repo-maintain");
    assert.equal(ledger.target.repo, "octo/alisterr");
    assert.equal(ledger.phase, "monitoring");
    assert.equal(ledger.run.runId, "run-1");
    assert.deepEqual(ledger.queuedIssues.map((q) => q.number), [3, 7]);
    assert.equal(ledger.queuedIssues[0].priority, "P2");
    assert.equal(ledger.updatedAt, "2026-06-12T12:00:00.000Z");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("allowAgentLaunch=false → gate hard stop, orchestrateRun never called", async () => {
  const root = makeRepo();
  let orchestrateCalled = false;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      ...baseDeps({
        userConfig: { allowAgentLaunch: false },
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true };
        },
      }),
    });
    // The gate is evaluated up front; with launch disabled we refuse without
    // ever invoking orchestrateRun, and surface a clear owner brief.
    assert.equal(orchestrateCalled, false);
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.equal(result.exitCode, 1);
    assert.equal(result.gate.allowAgentLaunch, false);
    assert.match(result.ownerBrief, /allowAgentLaunch/);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.blockers[0].kind, "allowAgentLaunch");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("non-allowlisted --repo-root → gate hard stop, no launch (allowlist enforced)", async () => {
  const root = makeRepo();
  const otherTrusted = mkdtempSync(join(tmpdir(), "ralph-orch-trusted-"));
  let orchestrateCalled = false;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      // Trusted default is a DIFFERENT repo, and root is not in the allowlist,
      // so the operator-supplied --repo-root must be rejected by the real
      // resolveOrchestrateRepoRoot (not injected here).
      trustedRepoRoot: otherTrusted,
      ...baseDeps({
        userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: [] },
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true };
        },
      }),
    });
    assert.equal(orchestrateCalled, false);
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.equal(result.exitCode, 1);
    assert.equal(result.gate.repoRootAllowed, false);
    assert.match(result.ownerBrief, /orchestrateAllowedRepoRoots/);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.blockers[0].kind, "allowlist");
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(otherTrusted, { recursive: true, force: true });
  }
});

test("allowlisted --repo-root → launches; orchestrateRun gets the TRUSTED default", async () => {
  const root = makeRepo();
  const otherTrusted = mkdtempSync(join(tmpdir(), "ralph-orch-trusted-"));
  let receivedArgs = null;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: otherTrusted,
      ...baseDeps({
        // root differs from the trusted default, so it must be allowlisted.
        userConfig: { allowAgentLaunch: true, orchestrateAllowedRepoRoots: [root] },
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async (args) => {
          receivedArgs = args;
          return { ok: true, runId: "run-9", runDir: join(root, ".ralph", "runs", "run-9"), queue: [{ number: 7 }] };
        },
      }),
    });
    assert.equal(result.outcome, "launched");
    assert.equal(result.exitCode, 0);
    assert.equal(result.gate.repoRootAllowed, true);
    // The fix: defaultRepoRoot is the trusted constant, repoRoot is the target.
    assert.equal(receivedArgs.repoRoot, root);
    assert.equal(receivedArgs.defaultRepoRoot, otherTrusted);
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(otherTrusted, { recursive: true, force: true });
  }
});

test("preflight failure from orchestrateRun → hard stop with preflight blocker", async () => {
  const root = makeRepo();
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      ...baseDeps({
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async () => ({
          ok: false,
          error: "Preflight failed.",
          preflight: { passed: false, checks: [] },
        }),
      }),
    });
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.equal(result.exitCode, 1);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.blockers[0].kind, "preflight");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("repeated deterministic worker failures for a queued issue → worker-stall hard stop", async () => {
  const root = makeRepo();
  let orchestrateCalled = false;
  try {
    seedFailedRun(root, "20260610-120000-deadbeef", 7, "Project checks failed after implementation");
    seedFailedRun(root, "20260611-120000-feedface", 7, "Copilot exited with code 1");

    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      ...baseDeps({
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true, runId: "run-should-not-start" };
        },
      }),
    });

    assert.equal(orchestrateCalled, false);
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.equal(result.exitCode, 1);
    assert.equal(result.failureHistory.blocking[0].issueNumber, 7);
    assert.equal(result.failureHistory.blocking[0].blockingFailureCount, 2);
    assert.match(result.ownerBrief, /repeated deterministic worker failures/i);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.phase, "paused");
    assert.equal(ledger.blockers[0].kind, "worker-stall");
    assert.equal(ledger.blockers[0].ref, "https://github.com/octo/alisterr/issues/7");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("transient Copilot API and no-delivery failures do not poison a ready issue", async () => {
  const root = makeRepo();
  let receivedArgs = null;
  try {
    seedFailedRun(
      root,
      "20260615-145640-696108fc",
      125,
      "No merged PR found after copilot completed (issue state=OPEN, stateReason=, merged_prs=0)",
    );
    seedFailedRun(
      root,
      "20260620-140159-695afe09",
      125,
      "Copilot exited with code 1: getaddrinfo ENOTFOUND api.enterprise.githubcopilot.com",
    );

    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      ...baseDeps({
        execIssueList: ghIssueList([readyIssue(125)]),
        orchestrateRunFn: async (args) => {
          receivedArgs = args;
          return {
            ok: true,
            runId: "run-retry-125",
            runDir: join(root, ".ralph", "runs", "run-retry-125"),
            queue: [{ number: 125 }],
          };
        },
      }),
    });

    assert.equal(result.ok, true);
    assert.equal(result.outcome, "launched");
    assert.deepEqual(receivedArgs.issueNumbers, [125]);
    assert.deepEqual(result.failureHistory.blocking, []);
    assert.equal(result.failureHistory.nonBlocking[0].issueNumber, 125);
    assert.deepEqual(
      result.failureHistory.nonBlocking[0].failures.map((failure) => failure.class),
      ["agent-no-delivery", "transient-runtime"],
    );
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.phase, "monitoring");
    assert.deepEqual(ledger.blockers, []);
    assert.deepEqual(
      ledger.failureHistory.nonBlocking[0].failures.map((failure) => failure.class),
      ["agent-no-delivery", "transient-runtime"],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("generic Copilot exits use worker log evidence for transient runtime classification", async () => {
  const root = makeRepo();
  let receivedArgs = null;
  try {
    seedFailedRun(root, "20260620-140159-695afe09", 125, "Copilot exited with code 1", {
      logBody: "Error: getaddrinfo ENOTFOUND api.enterprise.githubcopilot.com\n",
    });
    seedFailedRun(
      root,
      "20260621-140159-695afe09",
      125,
      "Copilot exited with code 1",
      { logBody: "FetchError: request to api.enterprise.githubcopilot.com failed, reason: EAI_AGAIN\n" },
    );

    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      ...baseDeps({
        execIssueList: ghIssueList([readyIssue(125)]),
        orchestrateRunFn: async (args) => {
          receivedArgs = args;
          return {
            ok: true,
            runId: "run-retry-log-evidence",
            runDir: join(root, ".ralph", "runs", "run-retry-log-evidence"),
            queue: [{ number: 125 }],
          };
        },
      }),
    });

    assert.equal(result.ok, true);
    assert.equal(result.outcome, "launched");
    assert.deepEqual(receivedArgs.issueNumbers, [125]);
    assert.deepEqual(result.failureHistory.blocking, []);
    assert.deepEqual(
      result.failureHistory.nonBlocking[0].failures.map((failure) => failure.class),
      ["transient-runtime", "transient-runtime"],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("deterministic failures that mention network or dns in logs still hard-stop", async () => {
  const root = makeRepo();
  let orchestrateCalled = false;
  try {
    seedFailedRun(root, "20260622-140159-11111111", 125, "Copilot exited with code 1", {
      logBody: "Project checks failed: DNS parser unit test expected a network label fixture\n",
    });
    seedFailedRun(root, "20260623-140159-22222222", 125, "Copilot exited with code 1", {
      logBody: "Project checks failed: network retry classifier assertion failed\n",
    });

    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      ...baseDeps({
        execIssueList: ghIssueList([readyIssue(125)]),
        orchestrateRunFn: async () => {
          orchestrateCalled = true;
          return { ok: true, runId: "run-should-not-start" };
        },
      }),
    });

    assert.equal(orchestrateCalled, false);
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.deepEqual(
      result.failureHistory.blocking[0].failures.map((failure) => failure.class),
      ["deterministic-implementation", "deterministic-implementation"],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("local in-flight claims feed active-run detection and discovery (no duplicate queueing)", async () => {
  const root = makeRepo();
  let activeRunArgs = null;
  let queryArgs = null;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      trustedRepoRoot: root,
      ...baseDeps({
        readLocalClaimsFn: () => [7],
        // No active run found, but the local claim must still reach both calls.
        resolveActiveRunFn: (_root, opts) => {
          activeRunArgs = opts;
          return null;
        },
        queryIssuesFn: (args) => {
          queryArgs = args;
          // Issue 7 is locally claimed → already_claimed warning → skipped.
          return {
            issues: [
              { number: 7, title: "claimed", url: "u7", taxonomy: { state: "ralph:ready", runnable: true, priority: "priority:P2" } },
              { number: 9, title: "free", url: "u9", taxonomy: { state: "ralph:ready", runnable: true, priority: "priority:P2" } },
            ],
            warnings: [{ type: "already_claimed", issueNumber: 7 }],
          };
        },
        orchestrateRunFn: async () => ({ ok: true, runId: "run-2", runDir: join(root, ".ralph", "runs", "run-2"), queue: [{ number: 9 }] }),
      }),
    });
    // Live claims threaded into active-run detection...
    assert.deepEqual(activeRunArgs.liveIssues, [7]);
    // ...and into discovery as claimedIssues.
    assert.deepEqual(queryArgs.claimedIssues, [7]);
    // The claimed issue is skipped, only the free one is queued.
    assert.deepEqual(result.queue.map((i) => i.number), [9]);
    assert.ok(result.skipped.some((s) => s.number === 7));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("orchestrator discovery path only queues ralph:ready issues (unchanged by lane promotion)", async () => {
  const root = makeRepo();
  const deps = baseDeps({
    execIssueList: ghIssueList([
      readyIssue(100),
      {
        number: 101,
        title: "Fast-lane candidate",
        body: "Test issue",
        labels: [{ name: "ralph:fast-lane" }, { name: "work:standalone" }, { name: "priority:P2" }],
        milestone: null,
        url: "https://github.com/octo/alisterr/issues/101",
        closedByPullRequestsReferences: [],
      },
    ]),
  });

  const result = await runOrchestrateRepo({ repoRoot: root, ...deps });

  // Only ralph:ready issues should be queued
  assert.equal(result.queue.length, 1);
  assert.equal(result.queue[0].number, 100);
  
  // ralph:fast-lane candidate should be skipped
  assert.ok(result.skipped.some((s) => s.number === 101 && /not canonical ralph:ready/.test(s.reason)));

  rmSync(root, { recursive: true, force: true });
});
