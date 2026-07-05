import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  promoteLaneForIssue,
  promoteOneTapReadiness,
} from "../extension/lib/lane-promotion.mjs";
import { evaluateIssueForTriage } from "../extension/lib/issue-triage.mjs";
import { routeIssueToLane } from "../extension/lib/lane-routing.mjs";

// Build the AUTO-eligible, standalone-shaped issue used across these tests.
// Trusted author + clear acceptance criteria + no PRD/parent markers routes to
// the AUTO lane with workTypeRecommendation === "work:standalone".
function autoStandaloneIssue(overrides = {}) {
  return {
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
    ...overrides,
  };
}

function workLabels(labelsAdded) {
  return labelsAdded.filter((label) => label.startsWith("work:"));
}

describe("Work-type label application during lane promotion", () => {
  it("materializes the recommended runnable work type when routing to AUTO with no existing work label", () => {
    const issue = autoStandaloneIssue();

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(promotion.lane, "AUTO");
    assert.equal(promotion.skipped, false);
    assert.ok(
      promotion.labelsAdded.includes("ralph:fast-lane"),
      "Should still add the fast-lane state label",
    );

    const work = workLabels(promotion.labelsAdded);
    assert.equal(work.length, 1, "Should add exactly one work:* label");
    assert.equal(
      work[0],
      opinion.workTypeRecommendation,
      "Added work label should equal the triage opinion's recommendation",
    );
    assert.match(
      work[0],
      /^work:(slice|standalone)$/,
      "Only runnable work types are materialized",
    );
  });

  it("never overwrites an existing work:* label on the AUTO lane", () => {
    const issue = autoStandaloneIssue({
      labels: [{ name: "ralph:needs-triage" }, { name: "work:standalone" }],
    });

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(promotion.lane, "AUTO");
    assert.equal(
      workLabels(promotion.labelsAdded).length,
      0,
      "Should not add a work label when one already exists",
    );
    assert.ok(
      promotion.labelsAdded.includes("ralph:fast-lane"),
      "Should still add the fast-lane state label",
    );
  });

  it("does not materialize a runnable work type for the PRD lane", () => {
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

    assert.equal(promotion.lane, "PRD");
    assert.ok(
      !promotion.labelsAdded.includes("work:slice"),
      "PRD lane must not add work:slice",
    );
    assert.ok(
      !promotion.labelsAdded.includes("work:standalone"),
      "PRD lane must not add work:standalone",
    );
  });

  it("does not add a work label when the route has no target label (REFINE lane)", () => {
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

    assert.equal(promotion.lane, "REFINE");
    assert.equal(promotion.skipped, true);
    assert.equal(
      workLabels(promotion.labelsAdded).length,
      0,
      "REFINE lane should not add work labels",
    );
  });

  it("does not add a work label when a guard skips promotion (ralph:hitl)", () => {
    const issue = autoStandaloneIssue({
      number: 501,
      labels: [{ name: "ralph:needs-triage" }, { name: "ralph:hitl" }],
    });

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(promotion.skipped, true);
    assert.equal(
      workLabels(promotion.labelsAdded).length,
      0,
      "Guarded issues should not receive work labels",
    );
  });

  it("regression: an AUTO-routed standalone issue is directly one-tap promotable after lane promotion", () => {
    const issue = autoStandaloneIssue();

    // Stage 1: lane promotion (needs-triage -> fast-lane), which must now also
    // materialize the runnable work type.
    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const lanePromotion = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.ok(
      lanePromotion.labelsAdded.includes("work:standalone"),
      "Lane promotion must materialize work:standalone (the fix under test)",
    );

    // Apply the planned mutations to derive the post-promotion label set.
    const original = issue.labels.map((l) => l.name);
    const removed = new Set(lanePromotion.labelsRemoved);
    const postLabels = [
      ...original.filter((name) => !removed.has(name)),
      ...lanePromotion.labelsAdded,
    ];

    const postPromotionIssue = {
      number: issue.number,
      title: issue.title,
      body: issue.body,
      labels: postLabels,
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    // Stage 2: the human one-tap gate must now succeed with no manual labeling.
    const readiness = promoteOneTapReadiness({ issue: postPromotionIssue, live: false });

    assert.equal(readiness.promoted, true, readiness.skipReason || "should promote");
    assert.deepEqual(readiness.labelsAdded, ["ralph:ready"]);
    assert.deepEqual(readiness.labelsRemoved, ["ralph:fast-lane"]);
    assert.equal(readiness.skipReason, null);
  });
});
