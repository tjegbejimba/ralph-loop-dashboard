import { test } from "node:test";
import assert from "node:assert/strict";

import {
  fetchPromotionIssue,
  handlePromoteReadyRequest,
  promoteReadyFromPipeline,
} from "../extension-pipeline/lib/promote-ready.mjs";
import { renderHtml } from "../extension-pipeline/renderer.mjs";

test("pipeline promotion moves an eligible fast-lane issue to ready", async () => {
  const edits = [];
  const result = await promoteReadyFromPipeline({
    repoSlug: "tj/repo",
    issueNumber: 42,
    fetchIssue: async () => ({
      number: 42,
      title: "Fix empty queue",
      body: "Acceptance criteria:\n- Empty queue renders",
      labels: ["ralph:fast-lane", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    }),
    editIssue: async (mutation) => edits.push(mutation),
  });

  assert.deepEqual(result, {
    promoted: true,
    issueNumber: 42,
    labelsAdded: ["ralph:ready"],
    labelsRemoved: ["ralph:fast-lane"],
    skipReason: null,
  });
  assert.deepEqual(edits, [{
    repoSlug: "tj/repo",
    issueNumber: 42,
    labelsAdded: ["ralph:ready"],
    labelsRemoved: ["ralph:fast-lane"],
  }]);
});

test("POST /promote-ready returns the guarded promotion result for a known repo", async () => {
  const calls = [];
  const response = await handlePromoteReadyRequest({
    method: "POST",
    url: new URL("http://127.0.0.1/promote-ready?repo=tj%2Frepo&issue=42"),
    repos: [{ slug: "tj/repo" }],
    expectedToken: "session-secret",
    requestToken: "session-secret",
    promote: async (input) => {
      calls.push(input);
      return {
        promoted: true,
        issueNumber: 42,
        labelsAdded: ["ralph:ready"],
        labelsRemoved: ["ralph:fast-lane"],
        skipReason: null,
      };
    },
  });

  assert.equal(response.status, 200);
  assert.equal(response.body.promoted, true);
  assert.deepEqual(calls, [{ repoSlug: "tj/repo", issueNumber: 42 }]);
});

test("POST /promote-ready rejects requests without the canvas session token", async () => {
  let promoted = false;
  const response = await handlePromoteReadyRequest({
    method: "POST",
    url: new URL("http://127.0.0.1/promote-ready?repo=tj%2Frepo&issue=42"),
    repos: [{ slug: "tj/repo" }],
    expectedToken: "session-secret",
    requestToken: "",
    promote: async () => {
      promoted = true;
    },
  });

  assert.deepEqual(response, { status: 403, body: { error: "Invalid promotion token" } });
  assert.equal(promoted, false);
});

test("pipeline promotion leaves a guarded issue unchanged", async () => {
  let edited = false;
  const result = await promoteReadyFromPipeline({
    repoSlug: "tj/repo",
    issueNumber: 43,
    fetchIssue: async () => ({
      number: 43,
      title: "Assigned work",
      body: "Acceptance criteria:\n- Done",
      labels: ["ralph:fast-lane", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [{ login: "tj" }],
      closedByPullRequestsReferences: [],
    }),
    editIssue: async () => {
      edited = true;
    },
  });

  assert.equal(result.promoted, false);
  assert.match(result.skipReason, /has assignee/i);
  assert.equal(edited, false);
});

test("promotion fetch enriches linked PRs with their current states", async () => {
  const issue = await fetchPromotionIssue({
    repoSlug: "tj/repo",
    issueNumber: 44,
    ghJson: async (args) => {
      if (args[0] === "issue") {
        return {
          number: 44,
          closedByPullRequestsReferences: [{ number: 101, url: "https://github.com/acme/shared/pull/101" }],
        };
      }
      assert.deepEqual(args, ["pr", "view", "101", "--repo", "acme/shared", "--json", "number,state,url"]);
      return { number: 101, state: "MERGED", url: "https://github.com/acme/shared/pull/101" };
    },
  });

  assert.deepEqual(issue.closedByPullRequestsReferences, [{
    number: 101,
    state: "MERGED",
    url: "https://github.com/acme/shared/pull/101",
  }]);
});

test("pipeline renders a one-tap control that promotes without following the issue link", () => {
  const html = renderHtml("session-secret");

  assert.match(html, /class="chip promote"/);
  assert.match(html, />one-tap<\/button>/);
  assert.match(html, /stopPropagation\(\)/);
  assert.match(html, /fetch\("\/promote-ready\?repo="/);
  assert.match(html, /"X-Ralph-Promotion-Token":PROMOTION_TOKEN/);
});
