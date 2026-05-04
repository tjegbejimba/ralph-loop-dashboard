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
      labels: [{ name: "feature" }, { name: "backend" }],
      milestone: { title: "v1.0" },
      url: "https://github.com/owner/repo/issues/42",
    },
    {
      number: 43,
      title: "Fix memory leak",
      body: "Memory usage grows over time",
      labels: [],
      milestone: null,
      url: "https://github.com/owner/repo/issues/43",
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
  assert.deepEqual(result.issues[0].labels, ["feature", "backend"]);
  assert.equal(result.issues[0].milestone, "v1.0");
  assert.equal(result.issues[0].url, "https://github.com/owner/repo/issues/42");
  
  // Second issue (no labels, no milestone)
  assert.equal(result.issues[1].number, 43);
  assert.equal(result.issues[1].title, "Fix memory leak");
  assert.deepEqual(result.issues[1].labels, []);
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
      labels: [],
      milestone: null,
      url: "https://github.com/owner/repo/issues/50",
    },
    {
      number: 51,
      title: "Task with body",
      body: "This has content",
      labels: [],
      milestone: null,
      url: "https://github.com/owner/repo/issues/51",
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
      labels: [],
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
      labels: [],
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
      labels: [],
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
      labels: [],
      milestone: null,
      url: "https://github.com/owner/repo/issues/70",
      closingPullRequestsReferences: [],
    },
    {
      number: 71,
      title: "Available task",
      body: "Not claimed",
      labels: [],
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
