// Tests for preflight module — validates launch conditions

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { runPreflight } from "../extension/lib/preflight.mjs";

// Helper to create temp test repo structure
function createTestRepo(tmpDir, { hasRalphMd = true, hasConfig = true, validConfig = true } = {}) {
  mkdirSync(tmpDir, { recursive: true });
  mkdirSync(join(tmpDir, ".ralph"), { recursive: true });
  
  if (hasRalphMd) {
    writeFileSync(join(tmpDir, ".ralph", "RALPH.md"), "# Ralph\nTest prompt");
  }
  
  if (hasConfig) {
    const config = validConfig
      ? { profile: "generic", repo: "owner/repo", prdReference: "#7" }
      : { invalid: "config" };
    writeFileSync(join(tmpDir, ".ralph", "config.json"), JSON.stringify(config));
  }
}

const BASE_COMMIT = "0123456789abcdef0123456789abcdef01234567";
function execGitAtBase({
  branch = "main",
  headCommit = BASE_COMMIT,
  baseCommit = BASE_COMMIT,
  status = "",
  fetchResult = { exitCode: 0, stdout: "", stderr: "" },
} = {}) {
  return async (_repoRoot, args) => {
    if (args[0] === "fetch") return fetchResult;
    if (args[0] === "status") return { exitCode: 0, stdout: status, stderr: "" };
    if (args[0] === "rev-parse" && args[1] === "HEAD") {
      return { exitCode: 0, stdout: headCommit, stderr: "" };
    }
    if (args[0] === "rev-parse" && args[1] === `refs/remotes/origin/${branch}`) {
      return { exitCode: 0, stdout: baseCommit, stderr: "" };
    }
    throw new Error(`Unexpected git args: ${args.join(" ")}`);
  };
}
const execGhIssueReady = async () => ({
  exitCode: 0,
  stdout: JSON.stringify({
    number: 1,
    title: "Standalone task",
    body: "Ready to run",
    state: "OPEN",
    labels: [{ name: "ralph:ready" }, { name: "priority:P2" }, { name: "work:standalone" }],
    assignees: [],
  }),
  stderr: "",
});

function passingPreflightOptions(repoRoot, execGit, overrides = {}) {
  return {
    repoRoot,
    queue: [{ number: 1, title: "Test" }],
    runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
    execGit,
    execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
    execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
    execGhIssue: execGhIssueReady,
    ...overrides,
  };
}

test("runPreflight passes when all conditions met", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-1");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      // Mock successful external commands
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });
    
    assert.equal(result.passed, true);
    assert.equal(result.checks.length, 8);
    assert.ok(result.checks.every(c => c.status === "pass"));
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight accepts a clean coordinator at the fetched remote base", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-base-match");
  createTestRepo(tmpDir);
  const gitCalls = [];

  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      baseBranch: "main",
      execGit: async (_repoRoot, args) => {
        gitCalls.push(args);
        if (args[0] === "fetch") {
          return { exitCode: 0, stdout: "", stderr: "" };
        }
        if (args[0] === "status") {
          return { exitCode: 0, stdout: "", stderr: "" };
        }
        if (args[0] === "rev-parse" && args[1] === "HEAD") {
          return { exitCode: 0, stdout: "0123456789abcdef", stderr: "" };
        }
        if (args[0] === "rev-parse" && args[1] === "refs/remotes/origin/main") {
          return { exitCode: 0, stdout: "0123456789abcdef", stderr: "" };
        }
        throw new Error(`Unexpected git args: ${args.join(" ")}`);
      },
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });

    assert.equal(result.passed, true);
    assert.deepEqual(gitCalls[0], ["fetch", "--quiet", "origin", "main"]);
    const baseCheck = result.checks.find(c => c.id === "coordinator-base-revision");
    assert.equal(baseCheck.status, "pass");
    assert.match(baseCheck.message, /origin\/main/);
    assert.match(baseCheck.message, /0123456789abcdef/);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

for (const checkoutKind of ["detached worktree", "temporary local branch"]) {
  test(`runPreflight accepts a clean ${checkoutKind} at the fetched remote base`, async () => {
    const tmpDir = join(
      import.meta.dirname,
      `tmp-preflight-${checkoutKind.replaceAll(" ", "-")}`,
    );
    createTestRepo(tmpDir);

    try {
      const result = await runPreflight(
        passingPreflightOptions(tmpDir, execGitAtBase()),
      );

      assert.equal(result.passed, true);
      assert.equal(
        result.checks.find(c => c.id === "coordinator-base-revision").status,
        "pass",
      );
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
}

for (const mismatch of [
  {
    name: "stale coordinator behind the fetched base",
    headCommit: "1111111111111111111111111111111111111111",
    baseCommit: "2222222222222222222222222222222222222222",
  },
  {
    name: "coordinator with a local commit ahead of the fetched base",
    headCommit: "3333333333333333333333333333333333333333",
    baseCommit: "2222222222222222222222222222222222222222",
  },
]) {
  test(`runPreflight rejects a ${mismatch.name}`, async () => {
    const tmpDir = join(import.meta.dirname, `tmp-preflight-mismatch-${mismatch.headCommit[0]}`);
    createTestRepo(tmpDir);

    try {
      const result = await runPreflight(
        passingPreflightOptions(
          tmpDir,
          execGitAtBase({
            headCommit: mismatch.headCommit,
            baseCommit: mismatch.baseCommit,
          }),
        ),
      );

      assert.equal(result.passed, false);
      const baseCheck = result.checks.find(c => c.id === "coordinator-base-revision");
      assert.equal(baseCheck.status, "fail");
      assert.match(baseCheck.message, new RegExp(mismatch.headCommit));
      assert.match(baseCheck.message, new RegExp(mismatch.baseCommit));
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
}

test("runPreflight compares an explicitly configured release branch", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-release-base");
  createTestRepo(tmpDir);
  const gitCalls = [];
  const execGit = execGitAtBase({ branch: "release/v2" });

  try {
    const result = await runPreflight(
      passingPreflightOptions(
        tmpDir,
        async (repoRoot, args) => {
          gitCalls.push(args);
          return execGit(repoRoot, args);
        },
        { baseBranch: "release/v2" },
      ),
    );

    assert.equal(result.passed, true);
    assert.deepEqual(gitCalls[0], ["fetch", "--quiet", "origin", "release/v2"]);
    const baseCheck = result.checks.find(c => c.id === "coordinator-base-revision");
    assert.match(baseCheck.message, /origin\/release\/v2/);
    assert.match(baseCheck.message, new RegExp(BASE_COMMIT));
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight fails closed when the configured base cannot be fetched", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-fetch-failure");
  createTestRepo(tmpDir);

  try {
    const result = await runPreflight(
      passingPreflightOptions(
        tmpDir,
        execGitAtBase({
          fetchResult: {
            exitCode: 1,
            stdout: "",
            stderr: "fatal: couldn't find remote ref missing",
          },
        }),
        { baseBranch: "missing" },
      ),
    );

    assert.equal(result.passed, false);
    const baseCheck = result.checks.find(c => c.id === "coordinator-base-revision");
    assert.equal(baseCheck.status, "fail");
    assert.match(baseCheck.message, /origin\/missing/);
    assert.match(baseCheck.message, /couldn't find remote ref/);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight passes for already queued canonical issues", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-queued");
  createTestRepo(tmpDir);

  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 2, title: "Queued standalone" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: async () => ({
        exitCode: 0,
        stdout: JSON.stringify({
          number: 2,
          title: "Queued standalone",
          body: "Ready to run from direct queue",
          state: "OPEN",
          labels: [{ name: "ralph:queued" }, { name: "priority:P2" }, { name: "work:standalone" }],
          assignees: [],
        }),
        stderr: "",
      }),
    });

    assert.equal(result.passed, true);
    const queueCheck = result.checks.find(c => c.id === "queue-canonical-ready");
    assert.equal(queueCheck.status, "pass");
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when queue is empty", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-2");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [], // Empty queue
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });
    
    assert.equal(result.passed, false);
    const queueCheck = result.checks.find(c => c.id === "queue-not-empty");
    assert.equal(queueCheck.status, "fail");
    assert.equal(queueCheck.blocking, true);
    assert.match(queueCheck.message, /queue is empty/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when RALPH.md missing", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-3");
  createTestRepo(tmpDir, { hasRalphMd: false });
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });
    
    assert.equal(result.passed, false);
    const ralphCheck = result.checks.find(c => c.id === "ralph-md-exists");
    assert.equal(ralphCheck.status, "fail");
    assert.equal(ralphCheck.blocking, true);
    assert.match(ralphCheck.message, /RALPH\.md.*not found/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when config.json missing", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-4");
  createTestRepo(tmpDir, { hasConfig: false });
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });
    
    assert.equal(result.passed, false);
    const configCheck = result.checks.find(c => c.id === "config-json-exists");
    assert.equal(configCheck.status, "fail");
    assert.equal(configCheck.blocking, true);
    assert.match(configCheck.message, /config\.json.*not found/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when GitHub auth fails", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-5");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      // Mock failed gh auth
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 1, stdout: "", stderr: "Not authenticated" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });
    
    assert.equal(result.passed, false);
    const authCheck = result.checks.find(c => c.id === "github-auth");
    assert.equal(authCheck.status, "fail");
    assert.equal(authCheck.blocking, true);
    assert.match(authCheck.message, /not authenticated/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when repo identity cannot be verified", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-6");
  createTestRepo(tmpDir);
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      // Mock failed gh repo view
      execGhRepo: async () => ({ exitCode: 1, stdout: "", stderr: "Repository not found" }),
      execGhIssue: execGhIssueReady,
    });
    
    assert.equal(result.passed, false);
    const repoCheck = result.checks.find(c => c.id === "repo-identity");
    assert.equal(repoCheck.status, "fail");
    assert.equal(repoCheck.blocking, true);
    assert.match(repoCheck.message, /cannot verify.*identity/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight returns all checks even when some fail", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-7");
  createTestRepo(tmpDir, { hasRalphMd: false, hasConfig: false });
  
  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 1, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 1, stdout: "", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });
    
    // Should run all checks, not short-circuit
    assert.equal(result.checks.length, 8);
    
    // Queue should pass (has items)
    const queueCheck = result.checks.find(c => c.id === "queue-not-empty");
    assert.equal(queueCheck.status, "pass");
    
    // Files and auth should fail
    const ralphCheck = result.checks.find(c => c.id === "ralph-md-exists");
    const configCheck = result.checks.find(c => c.id === "config-json-exists");
    const authCheck = result.checks.find(c => c.id === "github-auth");
    const repoCheck = result.checks.find(c => c.id === "repo-identity");
    const gitCheck = result.checks.find(c => c.id === "worktree-clean");
    
    assert.equal(ralphCheck.status, "fail");
    assert.equal(configCheck.status, "fail");
    assert.equal(gitCheck.status, "pass");
    assert.equal(authCheck.status, "fail");
    assert.equal(repoCheck.status, "fail");
    assert.equal(result.passed, false);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks when worktree has uncommitted changes", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-8");
  createTestRepo(tmpDir);

  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [{ number: 1, title: "Test" }],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase({ status: " M src/app.js\n?? tmp.txt" }),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: execGhIssueReady,
    });

    assert.equal(result.passed, false);
    const gitCheck = result.checks.find(c => c.id === "worktree-clean");
    assert.equal(gitCheck.status, "fail");
    assert.equal(gitCheck.blocking, true);
    assert.match(gitCheck.message, /uncommitted changes/i);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runPreflight blocks queued issues that are not canonical Ralph-runnable work", async () => {
  const tmpDir = join(import.meta.dirname, "tmp-preflight-9");
  createTestRepo(tmpDir);

  try {
    const result = await runPreflight({
      repoRoot: tmpDir,
      queue: [
        { number: 1, title: "Ready" },
        { number: 2, title: "HITL" },
        { number: 3, title: "Triage" },
      ],
      runOptions: { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" },
      execGit: execGitAtBase(),
      execGhAuth: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      execGhRepo: async () => ({ exitCode: 0, stdout: "{}", stderr: "" }),
      execGhIssue: async (_repo, number) => {
        const fixtures = {
          1: {
            number: 1,
            title: "Ready",
            body: "Ready",
            state: "OPEN",
            labels: [{ name: "ralph:ready" }, { name: "priority:P2" }, { name: "work:standalone" }],
            assignees: [],
          },
          2: {
            number: 2,
            title: "HITL",
            body: "Needs a human",
            state: "OPEN",
            labels: [{ name: "ralph:hitl" }, { name: "priority:P2" }, { name: "work:standalone" }],
            assignees: [],
          },
          3: {
            number: 3,
            title: "Triage",
            body: "Needs triage",
            state: "OPEN",
            labels: [{ name: "ralph:needs-triage" }, { name: "work:standalone" }],
            assignees: [],
          },
        };
        return { exitCode: 0, stdout: JSON.stringify(fixtures[number]), stderr: "" };
      },
    });
    assert.equal(result.passed, false);
    assert.equal(result.passed, false);
    const canonicalCheck = result.checks.find(c => c.id === "queue-canonical-ready");
    assert.equal(canonicalCheck.status, "fail");
    assert.equal(canonicalCheck.blocking, true);
    assert.match(canonicalCheck.message, /#2 must be ralph:ready, ralph:blocked, ralph:queued/);
    assert.match(canonicalCheck.message, /#3 must be ralph:ready, ralph:blocked, ralph:queued/);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
});
