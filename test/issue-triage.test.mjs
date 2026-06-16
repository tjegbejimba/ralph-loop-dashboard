import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_TRIAGE_CONFIG,
  buildAuthorAssociationQuery,
  buildTriageQuery,
  evaluateIssueForTriage,
  planTriageComment,
  renderTriageComment,
  runIssueTriage,
} from "../extension/lib/issue-triage.mjs";

describe("issue triage advisory automation", () => {
  it("builds legacy and canonical needs-triage queries from repo configuration", () => {
    assert.equal(buildTriageQuery({}), "label:needs-triage");
    assert.equal(buildTriageQuery({ taxonomyMode: "canonical" }), "label:ralph:needs-triage");
    assert.equal(buildTriageQuery({ query: "label:custom-triage" }), "label:custom-triage");
  });

  it("builds an authorAssociation query that declares no unused GraphQL variables", () => {
    const query = buildAuthorAssociationQuery([12, 34, 56]);
    const declared = [...query.matchAll(/\$([A-Za-z_][A-Za-z0-9_]*)\s*:/g)].map((m) => m[1]);
    assert.deepEqual([...new Set(declared)].sort(), ["name", "owner"]);
    for (const variable of declared) {
      const references = query.split(`$${variable}`).length - 1;
      assert.ok(references >= 2, `variable $${variable} must be referenced, not just declared`);
    }
    assert.ok(!query.includes("$numbers"), "must not declare the unused $numbers variable");
    assert.ok(query.includes("issue(number: 12)"));
    assert.ok(query.includes("issue2: issue(number: 56)"));
  });

  it("defaults the configured repo to the canonical needs-triage query", () => {
    for (const repoConfig of DEFAULT_TRIAGE_CONFIG.repos) {
      assert.equal(repoConfig.taxonomyMode, "canonical");
      assert.equal(buildTriageQuery(repoConfig), "label:ralph:needs-triage");
    }
  });

  it("recommends pursuing clear Ralph safety work and renders a complete triage opinion", () => {
    const opinion = evaluateIssueForTriage({
      issue: {
        number: 201,
        title: "Prevent unsafe launches when generated files are dirty",
        body: [
          "Ralph can waste quota or corrupt work if workers start from a dirty repo with generated artifacts.",
          "",
          "Acceptance criteria:",
          "- preflight blocks unsafe launches with a user-visible reason",
          "- tests cover dirty generated files and clean repos",
        ].join("\n"),
        labels: ["needs-triage"],
        state: "OPEN",
      },
      repoContext: {
        valueSignals: ["safer AFK agent execution", "prevents quota waste", "prevents corrupt work"],
      },
    });

    assert.equal(opinion.recommendation, "Pursue");
    assert.equal(opinion.priority, "P1");
    assert.equal(opinion.automationSafety, "safe after prep");
    assert.equal(opinion.confidence, "high");
    assert.ok(opinion.why.length >= 2);
    assert.ok(opinion.why.length <= 4);
    assert.ok(opinion.preflight.some((item) => /missing priority/i.test(item)));
    assert.equal(opinion.nextAction, "Shape this as work:standalone with explicit acceptance criteria before marking it ready for Ralph.");

    const comment = renderTriageComment(opinion);

    assert.match(comment, /^## Triage opinion\n\n\*\*Recommendation:\*\* I recommend Pursue\./);
    assert.match(comment, /\*\*Confidence:\*\* high — /);
    assert.match(comment, /\*\*Priority:\*\* P1/);
    assert.match(comment, /\*\*Automation safety:\*\* safe after prep/);
    assert.match(comment, /\*\*Preflight:\*\*/);
    assert.match(comment, /\*\*Why:\*\*/);
    assert.match(comment, /\*\*Next action:\*\* Shape this as work:standalone/);
    assert.match(comment, /No labels, closure, Ralph enqueue, PRD creation, or slice creation happened automatically\./);
  });

  it("maps issue evidence into advisory recommendation categories", () => {
    const cases = [
      {
        name: "high-value but underspecified Ralph work",
        issue: {
          number: 202,
          title: "Make Ralph queue recovery safer",
          body: "Ralph recovery can be unsafe.",
          labels: ["needs-triage"],
        },
        expected: "Refine",
      },
      {
        name: "unscoreable placeholder",
        issue: {
          number: 203,
          title: "TODO",
          body: "",
          labels: ["needs-triage"],
        },
        expected: "Needs info",
      },
      {
        name: "low-leverage nice-to-have",
        issue: {
          number: 204,
          title: "Add success confetti to the dashboard",
          body: "Nice-to-have UI polish someday; no known TJ pain or operator urgency yet.",
          labels: ["needs-triage"],
        },
        expected: "Defer",
      },
      {
        name: "clear duplicate",
        issue: {
          number: 205,
          title: "Duplicate dashboard status idea",
          body: "Duplicate of #55, which already covers this exact status panel request.",
          labels: ["needs-triage"],
        },
        expected: "Close",
      },
    ];

    for (const { name, issue, expected } of cases) {
      assert.equal(evaluateIssueForTriage({ issue }).recommendation, expected, name);
    }
  });

  it("keeps Close recommendations human-action oriented", () => {
    const opinion = evaluateIssueForTriage({
      issue: {
        number: 205,
        title: "Duplicate dashboard status idea",
        body: "Duplicate of #55, which already covers this exact status panel request.",
        labels: ["needs-triage"],
      },
    });

    assert.equal(opinion.recommendation, "Close");
    assert.equal(opinion.automationSafety, "hitl-required");
    assert.match(opinion.confidenceReason, /duplicate, obsolete, or out-of-scope evidence is explicit/);
  });

  it("reports advisory taxonomy preflight conflicts without mutating labels", () => {
    const opinion = evaluateIssueForTriage({
      issue: {
        number: 206,
        title: "Slice task with conflicting metadata",
        body: "Implement the final step.\n\n## Blocked by\n- #17",
        labels: ["ralph:ready", "priority:P1", "priority:P3", "work:slice"],
        closedByPullRequestsReferences: [
          { state: "OPEN", url: "https://github.com/tjegbejimba/ralph-loop-dashboard/pull/88" },
        ],
      },
    });

    assert.ok(opinion.preflight.some((item) => /priority has conflicting Ralph labels/i.test(item)));
    assert.ok(opinion.preflight.some((item) => /work:slice.*Parent #N/i.test(item)));
    assert.ok(opinion.preflight.some((item) => /visible blocker #17/i.test(item)));
    assert.ok(opinion.preflight.some((item) => /open PR.*pull\/88/i.test(item)));
    assert.deepEqual(opinion.plannedMutations, []);
  });

  it("plans one bot-owned triage comment and skips unchanged opinions", () => {
    const issue = {
      number: 207,
      title: "Make failed worker recovery diagnosable",
      body: "Ralph failures are hard to diagnose.\n\nAcceptance criteria:\n- surface the failed stage\n- include a regression test",
      labels: ["needs-triage"],
    };

    const createPlan = planTriageComment({
      issue,
      comments: [],
      botLogin: "ralph-triage[bot]",
    });
    assert.equal(createPlan.action, "create");
    assert.match(createPlan.commentBody, /<!-- ralph-triage-opinion:v1 fingerprint=[a-f0-9]{64} -->/);
    assert.deepEqual(createPlan.plannedMutations, []);

    const botComment = {
      id: 10,
      author: { login: "ralph-triage[bot]" },
      body: createPlan.commentBody,
      createdAt: "2026-06-11T10:00:00Z",
    };
    const skipPlan = planTriageComment({
      issue,
      comments: [botComment],
      botLogin: "ralph-triage[bot]",
    });
    assert.equal(skipPlan.action, "skip");
    assert.equal(skipPlan.reason, "unchanged");

    const changedPlan = planTriageComment({
      issue: { ...issue, body: `${issue.body}\n- include queue quota impact` },
      comments: [botComment],
      botLogin: "ralph-triage[bot]",
    });
    assert.equal(changedPlan.action, "update");
    assert.equal(changedPlan.commentId, 10);
    assert.equal(changedPlan.reason, "input_changed");

    const humanReplyPlan = planTriageComment({
      issue,
      comments: [
        botComment,
        {
          id: 11,
          author: { login: "tjegbejimba" },
          body: "This mainly matters when quota gets wasted on doomed retries.",
          createdAt: "2026-06-11T10:05:00Z",
        },
      ],
      botLogin: "ralph-triage[bot]",
    });
    assert.equal(humanReplyPlan.action, "update");
    assert.equal(humanReplyPlan.commentId, 10);
    assert.equal(humanReplyPlan.reason, "human_reply_after_bot");
  });

  it("uses the bot comment update timestamp as the human-reply cutoff", () => {
    const issue = {
      number: 208,
      title: "Make queued worker retries safer",
      body: "Ralph should avoid wasting quota on doomed retries.\n\nAcceptance criteria:\n- explain retry safety\n- include a regression test",
      labels: ["needs-triage"],
    };
    const botLogin = "ralph-triage[bot]";
    const createPlan = planTriageComment({
      issue,
      comments: [],
      botLogin,
    });
    const originalBotComment = {
      id: 20,
      author: { login: botLogin },
      body: createPlan.commentBody,
      createdAt: "2026-06-11T10:00:00Z",
      updatedAt: "2026-06-11T10:00:00Z",
    };
    const humanReplyBeforeRefresh = {
      id: 21,
      author: { login: "tjegbejimba" },
      body: "This mostly matters when quota gets wasted on retries.",
      createdAt: "2026-06-11T10:05:00Z",
    };

    const refreshPlan = planTriageComment({
      issue,
      comments: [originalBotComment, humanReplyBeforeRefresh],
      botLogin,
    });
    assert.equal(refreshPlan.action, "update");
    assert.equal(refreshPlan.reason, "human_reply_after_bot");

    const refreshedBotComment = {
      ...originalBotComment,
      body: refreshPlan.commentBody,
      updatedAt: "2026-06-11T10:10:00Z",
    };
    const unchangedAfterRefreshPlan = planTriageComment({
      issue,
      comments: [refreshedBotComment, humanReplyBeforeRefresh],
      botLogin,
    });
    assert.equal(unchangedAfterRefreshPlan.action, "skip");
    assert.equal(unchangedAfterRefreshPlan.reason, "unchanged");

    const humanReplyAfterRefresh = {
      id: 22,
      author: { login: "tjegbejimba" },
      body: "Also include the retry count in the explanation.",
      createdAt: "2026-06-11T10:15:00Z",
    };
    const newReplyPlan = planTriageComment({
      issue,
      comments: [refreshedBotComment, humanReplyBeforeRefresh, humanReplyAfterRefresh],
      botLogin,
    });
    assert.equal(newReplyPlan.action, "update");
    assert.equal(newReplyPlan.reason, "human_reply_after_bot");
  });

  it("runs dry-run calibration against configured repos without posting comments", async () => {
    const posted = [];
    const issues = Array.from({ length: 25 }, (_, index) => {
      const number = 25 - index;
      return {
        number,
        title: `Make Ralph safety check ${number} diagnosable`,
        body: "Ralph should make AFK agent failures easier to diagnose.\n\nAcceptance criteria:\n- render a clear preflight reason\n- cover with a regression test",
        labels: ["needs-triage"],
        createdAt: `2026-06-${String(number).padStart(2, "0")}T10:00:00Z`,
      };
    });

    const result = await runIssueTriage({
      mode: "dry-run",
      config: {
        repos: [{ owner: "tjegbejimba", name: "ralph-loop-dashboard" }],
      },
      fetchIssues: async ({ repo, query }) => {
        assert.equal(repo, "tjegbejimba/ralph-loop-dashboard");
        assert.equal(query, "label:needs-triage");
        return issues;
      },
      fetchComments: async () => [],
      createComment: async (input) => posted.push(input),
      updateComment: async (input) => posted.push(input),
    });

    assert.equal(result.dryRun, true);
    assert.deepEqual(result.repos[0].processed.map((item) => item.issueNumber), [
      1, 2, 3, 4, 5,
      6, 7, 8, 9, 10,
      11, 12, 13, 14, 15,
      16, 17, 18, 19, 20,
    ]);
    assert.equal(result.repos[0].processed[0].action, "create");
    assert.match(result.repos[0].processed[0].commentBody, /^## Triage opinion/);
    assert.deepEqual(posted, []);
  });

  it("caps live runs at ten changed issues and only writes comments", async () => {
    const issues = Array.from({ length: 12 }, (_, index) => ({
      number: index + 1,
      title: `Make Ralph live triage ${index + 1} safer`,
      body: "Ralph should keep advisory triage comments concise.\n\nAcceptance criteria:\n- generate one opinion\n- avoid label mutation",
      labels: ["needs-triage"],
      createdAt: `2026-06-${String(index + 1).padStart(2, "0")}T10:00:00Z`,
    }));
    const commentWrites = [];

    const result = await runIssueTriage({
      mode: "live",
      config: {
        repos: [{ repo: "tjegbejimba/ralph-loop-dashboard" }],
      },
      fetchIssues: async () => issues,
      fetchComments: async () => [],
      createComment: async (input) => commentWrites.push({ type: "create", ...input }),
      updateComment: async (input) => commentWrites.push({ type: "update", ...input }),
    });

    assert.equal(result.dryRun, false);
    assert.equal(result.repos[0].processed.length, 10);
    assert.deepEqual(result.repos[0].processed.map((item) => item.issueNumber), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    assert.equal(commentWrites.length, 10);
    assert.ok(commentWrites.every((write) => write.type === "create"));
    assert.ok(result.repos[0].processed.every((item) => item.posted === true));
    assert.deepEqual(result.repos[0].processed.flatMap((item) => item.plannedMutations), []);
  });

  it("skips active work and reports evidence-gathering failures without posting opinions", async () => {
    const fetchedCommentsFor = [];
    const result = await runIssueTriage({
      mode: "dry-run",
      config: {
        repos: [{ repo: "tjegbejimba/ralph-loop-dashboard" }],
      },
      fetchIssues: async () => [
        {
          number: 301,
          title: "Assigned work",
          body: "Someone owns this already.",
          labels: ["needs-triage"],
          assignees: [{ login: "human" }],
          createdAt: "2026-06-01T10:00:00Z",
        },
        {
          number: 302,
          title: "Open PR work",
          body: "Covered by a pull request.",
          labels: ["needs-triage"],
          closedByPullRequestsReferences: [{ state: "OPEN", url: "https://github.com/o/r/pull/1" }],
          createdAt: "2026-06-02T10:00:00Z",
        },
        {
          number: 303,
          title: "Queued work",
          body: "Already queued.",
          labels: ["ralph:queued", "priority:P2", "work:standalone"],
          createdAt: "2026-06-03T10:00:00Z",
        },
        {
          number: 304,
          title: "Evidence failure work",
          body: "Ralph should diagnose this.\n\nAcceptance criteria:\n- collect evidence",
          labels: ["needs-triage"],
          createdAt: "2026-06-04T10:00:00Z",
        },
        {
          number: 305,
          title: "Available work",
          body: "Ralph should diagnose this.\n\nAcceptance criteria:\n- collect evidence",
          labels: ["needs-triage"],
          createdAt: "2026-06-05T10:00:00Z",
        },
      ],
      fetchComments: async ({ issueNumber }) => {
        fetchedCommentsFor.push(issueNumber);
        if (issueNumber === 304) throw new Error("rate limit exceeded");
        return [];
      },
    });

    assert.deepEqual(result.repos[0].skipped, [
      { issueNumber: 301, reason: "assigned_issue" },
      { issueNumber: 302, reason: "linked_open_pr" },
      { issueNumber: 303, reason: "active_ralph_work" },
    ]);
    assert.deepEqual(fetchedCommentsFor, [304, 305]);
    assert.deepEqual(result.repos[0].processed.map((item) => item.issueNumber), [305]);
    assert.equal(result.repos[0].errors[0].issueNumber, 304);
    assert.equal(result.repos[0].errors[0].type, "fetch_comments_failed");
  });

  it("applies trusted-author guard to fast-lane candidate promotion", () => {
    const tjAuthoredIssue = {
      number: 401,
      title: "Prevent unsafe launches when generated files are dirty",
      body: "Ralph can waste quota or corrupt work if workers start from a dirty repo.\n\nAcceptance criteria:\n- preflight blocks unsafe launches\n- tests cover dirty generated files",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba", is_bot: false },
      authorAssociation: "OWNER",
    };

    const externalIssue = {
      number: 402,
      title: "Prevent unsafe launches when generated files are dirty",
      body: "Ralph can waste quota or corrupt work if workers start from a dirty repo.\n\nAcceptance criteria:\n- preflight blocks unsafe launches\n- tests cover dirty generated files",
      labels: ["ralph:needs-triage"],
      author: { login: "external-contributor", is_bot: false },
      authorAssociation: "CONTRIBUTOR",
    };

    const memberIssue = {
      number: 403,
      title: "Prevent unsafe launches when generated files are dirty",
      body: "Ralph can waste quota or corrupt work if workers start from a dirty repo.\n\nAcceptance criteria:\n- preflight blocks unsafe launches\n- tests cover dirty generated files",
      labels: ["ralph:needs-triage"],
      author: { login: "team-member", is_bot: false },
      authorAssociation: "MEMBER",
    };

    const botIssue = {
      number: 404,
      title: "Prevent unsafe launches when generated files are dirty",
      body: "Ralph can waste quota or corrupt work if workers start from a dirty repo.\n\nAcceptance criteria:\n- preflight blocks unsafe launches\n- tests cover dirty generated files",
      labels: ["ralph:needs-triage"],
      author: { login: "github-actions[bot]", is_bot: true },
    };

    const opinion1 = evaluateIssueForTriage({ issue: tjAuthoredIssue });
    assert.equal(opinion1.recommendation, "Pursue");
    assert.equal(opinion1.confidence, "high");
    assert.equal(opinion1.fastLaneCandidate, true);

    const opinion2 = evaluateIssueForTriage({ issue: externalIssue });
    assert.equal(opinion2.recommendation, "Pursue");
    assert.equal(opinion2.confidence, "high");
    assert.equal(opinion2.fastLaneCandidate, false);

    const opinion3 = evaluateIssueForTriage({ issue: memberIssue });
    assert.equal(opinion3.recommendation, "Pursue");
    assert.equal(opinion3.confidence, "high");
    assert.equal(opinion3.fastLaneCandidate, true);

    const opinion4 = evaluateIssueForTriage({ issue: botIssue });
    assert.equal(opinion4.recommendation, "Pursue");
    assert.equal(opinion4.confidence, "high");
    assert.equal(opinion4.fastLaneCandidate, true);
  });

  it("excludes issues with blockers from fast-lane candidacy", () => {
    const blockedIssue = {
      number: 405,
      title: "Prevent unsafe launches when generated files are dirty",
      body: "Ralph can waste quota or corrupt work if workers start from a dirty repo.\n\nAcceptance criteria:\n- preflight blocks unsafe launches\n- tests cover dirty generated files\n\n## Blocked by\n- #17",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba", is_bot: false },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue: blockedIssue });
    assert.equal(opinion.recommendation, "Pursue");
    assert.equal(opinion.confidence, "high");
    assert.equal(opinion.fastLaneCandidate, false);
  });

  it("requires high confidence and safe after prep for fast-lane", () => {
    const mediumConfidenceIssue = {
      number: 406,
      title: "Maybe improve Ralph safety",
      body: "Ralph could be better somehow.",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba", is_bot: false },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue: mediumConfidenceIssue });
    assert.equal(opinion.fastLaneCandidate, false);
  });

  it("accepts both work:slice and work:standalone for fast-lane", () => {
    const standaloneIssue = {
      number: 407,
      title: "Prevent unsafe launches when generated files are dirty",
      body: "Ralph can waste quota or corrupt work if workers start from a dirty repo.\n\nAcceptance criteria:\n- preflight blocks unsafe launches\n- tests cover dirty generated files",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba", is_bot: false },
      authorAssociation: "OWNER",
    };

    const sliceIssue = {
      number: 408,
      title: "Slice 3: Add preflight check for dirty generated files",
      body: "Implement the preflight check.\n\nParent #100\n\nAcceptance criteria:\n- preflight blocks unsafe launches\n- tests cover dirty generated files",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba", is_bot: false },
      authorAssociation: "OWNER",
    };

    const opinion1 = evaluateIssueForTriage({ issue: standaloneIssue });
    assert.equal(opinion1.workTypeRecommendation, "work:standalone");
    assert.equal(opinion1.fastLaneCandidate, true);

    const opinion2 = evaluateIssueForTriage({ issue: sliceIssue });
    assert.equal(opinion2.workTypeRecommendation, "work:slice");
    assert.equal(opinion2.fastLaneCandidate, true);
  });

  it("triage workflow does not run lane promotion when promoteLanes is not configured", async () => {
    const mockIssues = [
      {
        number: 501,
        title: "Prevent unsafe launches",
        body: "Ralph can waste quota.\n\nAcceptance criteria:\n- preflight blocks unsafe launches",
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
    ];

    const result = await runIssueTriage({
      mode: "dry-run",
      config: {
        repos: [{ owner: "test", name: "repo", taxonomyMode: "canonical" }],
        botLogin: "test-bot[bot]",
      },
      fetchIssues: async () => mockIssues,
      fetchComments: async () => [],
      createComment: async () => {},
    });

    assert.equal(result.repos.length, 1);
    const repoResult = result.repos[0];
    assert.equal(repoResult.processed.length, 1);
    const entry = repoResult.processed[0];
    
    // Should not have promotion field when promoteLanes is disabled
    assert.equal(entry.promotion, undefined);
  });

  it("triage workflow invokes lane promotion when promoteLanes is enabled (dry-run)", async () => {
    const mockIssues = [
      {
        number: 502,
        title: "Prevent unsafe launches",
        body: "Ralph can waste quota.\n\nAcceptance criteria:\n- preflight blocks unsafe launches",
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
    ];

    const result = await runIssueTriage({
      mode: "dry-run",
      config: {
        repos: [{ owner: "test", name: "repo", taxonomyMode: "canonical", promoteLanes: true }],
        botLogin: "test-bot[bot]",
      },
      fetchIssues: async () => mockIssues,
      fetchComments: async () => [],
      createComment: async () => {},
    });

    assert.equal(result.repos.length, 1);
    const repoResult = result.repos[0];
    assert.equal(repoResult.processed.length, 1);
    const entry = repoResult.processed[0];
    
    // Should include promotion result when promoteLanes is enabled
    assert.ok(entry.promotion, "entry should have promotion field");
    assert.equal(entry.promotion.issueNumber, 502);
    assert.equal(entry.promotion.lane, "AUTO");
    assert.deepEqual(entry.promotion.labelsAdded, ["ralph:fast-lane"]);
    assert.deepEqual(entry.promotion.labelsRemoved, ["ralph:needs-triage"]);
    assert.equal(entry.promotion.skipped, false);
  });
});

