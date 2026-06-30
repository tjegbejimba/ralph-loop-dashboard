import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { promoteLaneForIssue } from "../extension/lib/lane-promotion.mjs";
import { evaluateIssueForTriage } from "../extension/lib/issue-triage.mjs";
import { routeIssueToLane } from "../extension/lib/lane-routing.mjs";

describe("Priority label application during lane promotion", () => {
  it("adds computed priority label when routing to AUTO lane with no existing priority", () => {
    const issue = {
      number: 101,
      title: "Prevent unsafe launches",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    // Should add ralph:fast-lane and a computed priority label
    assert.equal(promotion.lane, "AUTO");
    assert.equal(promotion.skipped, false);
    assert.ok(promotion.labelsAdded.includes("ralph:fast-lane"), "Should add ralph:fast-lane");
    
    // Should add a computed priority label
    const priorityLabels = promotion.labelsAdded.filter((label) => label.startsWith("priority:"));
    assert.equal(priorityLabels.length, 1, "Should add exactly one priority label");
    assert.match(priorityLabels[0], /^priority:P[123]$/, "Priority should be P1, P2, or P3 (never P0)");
  });

  it("adds computed priority label when routing to PRD lane with no existing priority", () => {
    const issue = {
      number: 201,
      title: "PRD: Authentication overhaul",
      body: [
        "Broad PRD for Ralph authentication improvements.",
        "",
        "Acceptance criteria:",
        "- Document design",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }, { name: "work:prd" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    // Should add ralph:evaluated, work:prd, and priority
    assert.equal(promotion.lane, "PRD");
    assert.equal(promotion.skipped, false);
    assert.ok(promotion.labelsAdded.includes("ralph:evaluated"), "Should add ralph:evaluated");
    
    const priorityLabels = promotion.labelsAdded.filter((label) => label.startsWith("priority:"));
    assert.equal(priorityLabels.length, 1, "Should add exactly one priority label");
    assert.match(priorityLabels[0], /^priority:P[123]$/, "Priority should be P1, P2, or P3");
  });

  it("adds computed priority label when routing to HOLD lane with ralph:blocked", () => {
    const issue = {
      number: 301,
      title: "Blocked work",
      body: [
        "Depends on other work.",
        "",
        "## Blocked by",
        "- #100",
        "",
        "Acceptance criteria:",
        "- Complete after blocker resolved",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    // Should add ralph:blocked and priority
    assert.equal(promotion.lane, "HOLD");
    assert.equal(promotion.skipped, false);
    assert.ok(promotion.labelsAdded.includes("ralph:blocked"), "Should add ralph:blocked");
    
    const priorityLabels = promotion.labelsAdded.filter((label) => label.startsWith("priority:"));
    assert.equal(priorityLabels.length, 1, "Should add exactly one priority label");
    assert.match(priorityLabels[0], /^priority:P[123]$/, "Priority should be P1, P2, or P3");
  });

  it("preserves existing priority label and does not add another", () => {
    const issue = {
      number: 102,
      title: "Already prioritized",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }, { name: "priority:P1" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    // Should not add another priority label
    const priorityLabels = promotion.labelsAdded.filter((label) => label.startsWith("priority:"));
    assert.equal(priorityLabels.length, 0, "Should not add priority when one already exists");
    assert.ok(promotion.labelsAdded.includes("ralph:fast-lane"), "Should still add lane label");
  });

  it("does not add priority label when route has no target label (REFINE lane)", () => {
    const issue = {
      number: 401,
      title: "Needs refinement",
      body: "Vague issue without clear acceptance criteria",
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "external-contributor" },
      authorAssociation: "NONE",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    // REFINE lane has targetLabel === null, so no labels should be added
    assert.equal(promotion.lane, "REFINE");
    assert.equal(promotion.skipped, true);
    assert.equal(promotion.labelsAdded.length, 0, "REFINE lane should not add labels");
  });

  it("does not add priority label when promotion is skipped due to guard", () => {
    const issue = {
      number: 501,
      title: "Issue with HITL",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }, { name: "ralph:hitl" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    // Guard should block promotion
    assert.equal(promotion.skipped, true);
    assert.equal(promotion.labelsAdded.length, 0, "Guarded issues should not receive labels");
  });

  it("never emits priority:P0 in auto-applied labels", () => {
    // Create multiple issues with different characteristics
    const issues = [
      {
        number: 601,
        title: "Urgent blocker",
        body: "Ralph can waste quota and is unsafe. Acceptance criteria:\n- Fix now",
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
        assignees: [],
        closedByPullRequestsReferences: [],
      },
      {
        number: 602,
        title: "Critical data loss",
        body: "Ralph corruption leads to data loss. Acceptance criteria:\n- Prevent corruption",
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
        assignees: [],
        closedByPullRequestsReferences: [],
      },
      {
        number: 603,
        title: "Security vulnerability",
        body: "Ralph security flaw allows unauthorized access. Acceptance criteria:\n- Close security hole",
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
        assignees: [],
        closedByPullRequestsReferences: [],
      },
    ];

    // Test every issue
    for (const issue of issues) {
      const opinion = evaluateIssueForTriage({ issue });
      const route = routeIssueToLane({ issue, opinion });
      const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

      const priorityLabels = promotion.labelsAdded.filter((label) => label.startsWith("priority:"));
      for (const label of priorityLabels) {
        assert.notEqual(label, "priority:P0", `Issue #${issue.number} must not receive priority:P0 auto-label`);
      }
    }
  });

  it("includes priority label in dry-run labelsAdded array", () => {
    const issue = {
      number: 701,
      title: "Dry-run test",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    // Dry-run (live: false)
    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    // Check labelsAdded includes both lane and priority
    assert.ok(promotion.labelsAdded.includes("ralph:fast-lane"), "Dry-run should report lane label");
    const priorityLabels = promotion.labelsAdded.filter((label) => label.startsWith("priority:"));
    assert.equal(priorityLabels.length, 1, "Dry-run should report priority label");
  });
});
