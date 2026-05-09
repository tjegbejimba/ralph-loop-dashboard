// Unit tests for issue query logic.
// Run via `node --test test/issue-query.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { queryIssues } from "../extension/lib/issue-query.mjs";

// RED: Tracer bullet — successful query returns issue metadata
test("queryIssues — successful query returns issue metadata", () => {
  // Mock gh CLI output for a simple issue list
  const mockOutput = JSON.stringify([
    {
      number: 42,
      title: "Add user authentication",
      body: "Implement JWT-based auth",
      labels: [{ name: "feature" }, { name: "backend" }, { name: "ready-for-agent" }],
      milestone: { title: "v1.0" },
      url: "https://github.com/owner/repo/issues/42",
      closingPullRequestsReferences: [],
    },
    {
      number: 43,
      title: "Fix memory leak",
      body: "Memory usage grows over time",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/43",
      closingPullRequestsReferences: [],
    },
  ]);

  const mockExec = () => mockOutput;

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
  });

  assert.equal(result.error, null);
  assert.equal(result.issues.length, 2);
  
  // First issue
  assert.equal(result.issues[0].number, 42);
  assert.equal(result.issues[0].title, "Add user authentication");
  assert.deepEqual(result.issues[0].labels, ["feature", "backend", "ready-for-agent"]);
  assert.equal(result.issues[0].milestone, "v1.0");
  assert.equal(result.issues[0].url, "https://github.com/owner/repo/issues/42");
  
  // Second issue (no labels, no milestone)
  assert.equal(result.issues[1].number, 43);
  assert.equal(result.issues[1].title, "Fix memory leak");
  assert.deepEqual(result.issues[1].labels, ["ready-for-agent"]);
  assert.equal(result.issues[1].milestone, null);
  
  // No warnings for valid issues
  assert.equal(result.warnings.length, 0);
});

// RED: Empty issue body generates nonblocking warning
test("queryIssues — empty issue body generates warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 50,
      title: "Underspecified task",
      body: "",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/50",
      closingPullRequestsReferences: [],
    },
    {
      number: 51,
      title: "Task with body",
      body: "This has content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/51",
      closingPullRequestsReferences: [],
    },
  ]);

  const mockExec = () => mockOutput;

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
  });

  assert.equal(result.error, null);
  assert.equal(result.issues.length, 2);
  
  // One warning for empty body
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].issueNumber, 50);
  assert.equal(result.warnings[0].type, "empty_body");
  assert.match(result.warnings[0].message, /empty issue body/i);
});

// RED: Issue with linked open PR generates warning
test("queryIssues — linked open PR generates warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 60,
      title: "Task with open PR",
      body: "This task already has a PR",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/60",
      closingPullRequestsReferences: [
        {
          url: "https://github.com/owner/repo/pull/100",
          state: "OPEN",
        },
      ],
    },
    {
      number: 61,
      title: "Task with closed PR",
      body: "This PR was merged",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/61",
      closingPullRequestsReferences: [
        {
          url: "https://github.com/owner/repo/pull/101",
          state: "MERGED",
        },
      ],
    },
    {
      number: 62,
      title: "Task with no PR",
      body: "No PR yet",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/62",
      closingPullRequestsReferences: [],
    },
  ]);

  const mockExec = () => mockOutput;

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
  });

  assert.equal(result.error, null);
  assert.equal(result.issues.length, 3);
  
  // One warning for open PR
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].issueNumber, 60);
  assert.equal(result.warnings[0].type, "linked_pr");
  assert.match(result.warnings[0].message, /open PR/i);
  assert.equal(result.warnings[0].prUrl, "https://github.com/owner/repo/pull/100");
});

// RED: GitHub auth failure surfaces clear error
test("queryIssues — GitHub auth failure surfaces error", () => {
  const mockExec = () => {
    throw new Error("gh: authentication required. Run 'gh auth login' to authenticate");
  };

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
  });

  assert.equal(result.issues, null);
  assert.equal(result.warnings.length, 0);
  assert.notEqual(result.error, null);
  assert.equal(result.error.type, "query_failed");
  assert.match(result.error.message, /authentication required/i);
});

// RED: Malformed GitHub CLI output surfaces error
test("queryIssues — malformed output surfaces error", () => {
  const mockExec = () => "not valid JSON";

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
  });

  assert.equal(result.issues, null);
  assert.equal(result.warnings.length, 0);
  assert.notEqual(result.error, null);
  assert.equal(result.error.type, "query_failed");
});

// RED: Claimed issue generates warning
test("queryIssues — claimed issue generates warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 70,
      title: "Already claimed task",
      body: "This is claimed",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/70",
      closingPullRequestsReferences: [],
    },
    {
      number: 71,
      title: "Available task",
      body: "Not claimed",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/71",
      closingPullRequestsReferences: [],
    },
  ]);

  const mockExec = () => mockOutput;

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
    claimedIssues: [70], // Issue 70 is claimed
  });

  assert.equal(result.error, null);
  assert.equal(result.issues.length, 2);
  
  // One warning for claimed issue
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].issueNumber, 70);
  assert.equal(result.warnings[0].type, "already_claimed");
  assert.match(result.warnings[0].message, /already claimed/i);
});

// Test type validation
test("queryIssues — validates claimedIssues is an array", () => {
  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => "[]",
    claimedIssues: "not-an-array", // Invalid type
  });

  assert.equal(result.issues, null);
  assert.notEqual(result.error, null);
  assert.equal(result.error.type, "invalid_input");
});

test("queryIssues — handles malformed labels array gracefully", () => {
  const mockOutput = JSON.stringify([
    {
      number: 80,
      title: "Task with malformed labels",
      body: "Content",
      labels: "not-an-array",
      milestone: null,
      url: "https://github.com/owner/repo/issues/80",
      closingPullRequestsReferences: [],
    },
  ]);

  const mockExec = () => mockOutput;

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
  });

  assert.equal(result.error, null);
  assert.equal(result.issues.length, 1);
  assert.deepEqual(result.issues[0].labels, []); // Falls back to empty array
});

test("queryIssues — handles malformed PR references gracefully", () => {
  const mockOutput = JSON.stringify([
    {
      number: 81,
      title: "Task with malformed PR refs",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/81",
      closingPullRequestsReferences: "not-an-array",
    },
  ]);

  const mockExec = () => mockOutput;

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: mockExec,
  });

  assert.equal(result.error, null);
  assert.equal(result.issues.length, 1);
  assert.equal(result.warnings.length, 0); // No warnings for malformed data
});

// ─── Preflight label warnings ────────────────────────────────────────────────

test("queryIssues — needs-triage label generates needs_triage warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 90,
      title: "Half-baked task",
      body: "Content here",
      labels: [{ name: "needs-triage" }, { name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/90",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
  });

  assert.equal(result.error, null);
  const w = result.warnings.find(w => w.type === "needs_triage");
  assert.ok(w, "expected needs_triage warning");
  assert.equal(w.issueNumber, 90);
  assert.match(w.message, /needs-triage/i);
  assert.equal(w.blocking, false);
});

test("queryIssues — no needs-triage label means no needs_triage warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 91,
      title: "Clean task",
      body: "Content here",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/91",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
  });

  assert.equal(result.error, null);
  assert.ok(!result.warnings.some(w => w.type === "needs_triage"));
});

test("queryIssues — missing ready-for-agent label generates not_ready_for_agent warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 92,
      title: "Not AFK-safe task",
      body: "Content here",
      labels: [{ name: "bug" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/92",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
  });

  assert.equal(result.error, null);
  const w = result.warnings.find(w => w.type === "not_ready_for_agent");
  assert.ok(w, "expected not_ready_for_agent warning");
  assert.equal(w.issueNumber, 92);
  assert.match(w.message, /ready-for-agent/i);
  assert.equal(w.blocking, false);
});

test("queryIssues — ready-for-agent present means no not_ready_for_agent warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 93,
      title: "AFK-safe task",
      body: "Content here",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/93",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
  });

  assert.equal(result.error, null);
  assert.ok(!result.warnings.some(w => w.type === "not_ready_for_agent"));
});

test("queryIssues — both labels missing produces both label warnings", () => {
  const mockOutput = JSON.stringify([
    {
      number: 94,
      title: "Unprocessed task",
      body: "Content here",
      labels: [],
      milestone: null,
      url: "https://github.com/owner/repo/issues/94",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
  });

  assert.equal(result.error, null);
  assert.ok(result.warnings.some(w => w.type === "not_ready_for_agent" && w.issueNumber === 94));
  // needs-triage absent means no needs_triage warning
  assert.ok(!result.warnings.some(w => w.type === "needs_triage"));
});

test("queryIssues — both labels present produces no label warnings", () => {
  const mockOutput = JSON.stringify([
    {
      number: 95,
      title: "Fully tagged task",
      body: "Content here",
      labels: [{ name: "ready-for-agent" }, { name: "feature" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/95",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
  });

  assert.equal(result.error, null);
  assert.equal(result.warnings.length, 0);
});

// ─── Configurable blocking ────────────────────────────────────────────────────

test("queryIssues — requireReadyForAgent:true makes not_ready_for_agent blocking", () => {
  const mockOutput = JSON.stringify([
    {
      number: 96,
      title: "Not ready",
      body: "Content",
      labels: [],
      milestone: null,
      url: "https://github.com/owner/repo/issues/96",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    config: { preflight: { requireReadyForAgent: true } },
  });

  assert.equal(result.error, null);
  const w = result.warnings.find(w => w.type === "not_ready_for_agent");
  assert.ok(w);
  assert.equal(w.blocking, true);
});

test("queryIssues — requireNotNeedsTriage:true makes needs_triage blocking", () => {
  const mockOutput = JSON.stringify([
    {
      number: 97,
      title: "Needs triage",
      body: "Content",
      labels: [{ name: "needs-triage" }, { name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/97",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    config: { preflight: { requireNotNeedsTriage: true } },
  });

  assert.equal(result.error, null);
  const w = result.warnings.find(w => w.type === "needs_triage");
  assert.ok(w);
  assert.equal(w.blocking, true);
});

// ─── Unresolved blocker warnings ─────────────────────────────────────────────

test("queryIssues — parsedDependencies with open blocker emits unresolved_blocker warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 100,
      title: "Blocked task",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/100",
      closingPullRequestsReferences: [],
    },
  ]);

  const parsedDependencies = {
    100: [{ number: 50, isOpen: true }],
  };

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    parsedDependencies,
  });

  assert.equal(result.error, null);
  const w = result.warnings.find(w => w.type === "unresolved_blocker");
  assert.ok(w, "expected unresolved_blocker warning");
  assert.equal(w.issueNumber, 100);
  assert.equal(w.blockerNumber, 50);
  assert.match(w.message, /#50/);
  assert.equal(w.blocking, false);
});

test("queryIssues — closed blocker does not generate unresolved_blocker warning", () => {
  const mockOutput = JSON.stringify([
    {
      number: 101,
      title: "Task with resolved blocker",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/101",
      closingPullRequestsReferences: [],
    },
  ]);

  const parsedDependencies = {
    101: [{ number: 55, isOpen: false }],
  };

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    parsedDependencies,
  });

  assert.equal(result.error, null);
  assert.ok(!result.warnings.some(w => w.type === "unresolved_blocker"));
});

test("queryIssues — open blocker within the same result set (in-queue) still warns", () => {
  // Both issue 102 and its blocker 103 appear in the same result set
  const mockOutput = JSON.stringify([
    {
      number: 102,
      title: "Blocked task",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/102",
      closingPullRequestsReferences: [],
    },
    {
      number: 103,
      title: "Blocker task",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/103",
      closingPullRequestsReferences: [],
    },
  ]);

  const parsedDependencies = {
    102: [{ number: 103, isOpen: true }],
  };

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    parsedDependencies,
  });

  assert.equal(result.error, null);
  const w = result.warnings.find(w => w.type === "unresolved_blocker" && w.issueNumber === 102);
  assert.ok(w, "should warn even when blocker is in same result set");
  assert.equal(w.blockerNumber, 103);
});

test("queryIssues — open blocker outside result set (outside queue) still warns", () => {
  // Only the blocked issue is in the query; blocker #200 is not
  const mockOutput = JSON.stringify([
    {
      number: 104,
      title: "Blocked task",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/104",
      closingPullRequestsReferences: [],
    },
  ]);

  const parsedDependencies = {
    104: [{ number: 200, isOpen: true }],
  };

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    parsedDependencies,
  });

  assert.equal(result.error, null);
  const w = result.warnings.find(w => w.type === "unresolved_blocker" && w.issueNumber === 104);
  assert.ok(w, "should warn even when blocker is outside the result set");
  assert.equal(w.blockerNumber, 200);
});

test("queryIssues — null parsedDependencies skips blocker checks (graceful degradation)", () => {
  const mockOutput = JSON.stringify([
    {
      number: 105,
      title: "Task without dep parser",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/105",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    // parsedDependencies not provided — defaults to null
  });

  assert.equal(result.error, null);
  assert.ok(!result.warnings.some(w => w.type === "unresolved_blocker"));
});

test("queryIssues — malformed parsedDependencies entry does not crash", () => {
  const mockOutput = JSON.stringify([
    {
      number: 106,
      title: "Task",
      body: "Content",
      labels: [{ name: "ready-for-agent" }],
      milestone: null,
      url: "https://github.com/owner/repo/issues/106",
      closingPullRequestsReferences: [],
    },
  ]);

  const result = queryIssues({
    repoOwner: "owner",
    repoName: "repo",
    searchQuery: "is:open",
    execCommand: () => mockOutput,
    parsedDependencies: { 106: "bad-value" }, // not an array
  });

  assert.equal(result.error, null);
  assert.ok(!result.warnings.some(w => w.type === "unresolved_blocker"));
});
