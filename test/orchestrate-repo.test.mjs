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
    closingPullRequestsReferences: [],
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

test("buildBoundedQueue — sorts by issue number ascending and caps at maxIssues", () => {
  const issues = [{ number: 30 }, { number: 5 }, { number: 12 }, { number: 99 }];
  const queue = buildBoundedQueue(issues, { maxIssues: 3 });
  assert.deepEqual(queue.map((i) => i.number), [5, 12, 30]);
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

test("discovery returns N → bounded to maxIssues (lowest numbers first)", async () => {
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
            closingPullRequestsReferences: [
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
    // Gated launch args.
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

test("allowAgentLaunch=false → gate hard stop surfaced (orchestrateRun gate)", async () => {
  const root = makeRepo();
  let receivedArgs = null;
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
      ...baseDeps({
        userConfig: { allowAgentLaunch: false },
        execIssueList: ghIssueList([readyIssue(7)]),
        orchestrateRunFn: async (args) => {
          receivedArgs = args;
          return {
            ok: false,
            error:
              "Agent Ralph launch requires allowAgentLaunch: true in the Ralph dashboard user config.",
          };
        },
      }),
    });
    // orchestrateRun was invoked with the right queue, and its gate failure
    // is surfaced as a hard stop (not bypassed).
    assert.deepEqual(receivedArgs.issueNumbers, [7]);
    assert.equal(result.ok, false);
    assert.equal(result.outcome, "hard-stop");
    assert.equal(result.exitCode, 1);
    assert.match(result.ownerBrief, /allowAgentLaunch/);
    const ledger = JSON.parse(readFileSync(ledgerPath(root), "utf8"));
    assert.equal(ledger.blockers[0].kind, "allowAgentLaunch");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("preflight failure from orchestrateRun → hard stop with preflight blocker", async () => {
  const root = makeRepo();
  try {
    const result = await runOrchestrateRepo({
      repoRoot: root,
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
