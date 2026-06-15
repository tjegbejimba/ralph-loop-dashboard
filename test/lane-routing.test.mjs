import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { evaluateIssueForTriage } from "../extension/lib/issue-triage.mjs";
import { routeIssueToLane } from "../extension/lib/lane-routing.mjs";

describe("lane routing", () => {
  it("routes high-confidence Pursue with safe prep and work:standalone to AUTO", () => {
    const issue = {
      number: 101,
      title: "Prevent unsafe launches when generated files are dirty",
      body: [
        "Ralph can waste quota or corrupt work if workers start from a dirty repo with generated artifacts.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches with a user-visible reason",
        "- tests cover dirty generated files and clean repos",
      ].join("\n"),
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "AUTO");
    assert.equal(route.targetLabel, "ralph:fast-lane");
    assert.match(route.reason, /meets strict AUTO predicate/i);
  });

  it("routes high-confidence Pursue with safe prep and work:slice to AUTO", () => {
    const issue = {
      number: 102,
      title: "Slice 1: Bootstrap worktree isolation",
      body: [
        "Parent #50",
        "",
        "Implement worktree isolation so workers don't corrupt each other's state.",
        "",
        "Acceptance criteria:",
        "- each worker gets dedicated worktree",
        "- test covers isolation boundary",
      ].join("\n"),
      labels: ["ralph:needs-triage", "work:slice"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "AUTO");
    assert.equal(route.targetLabel, "ralph:fast-lane");
    assert.match(route.reason, /meets strict AUTO predicate/i);
  });

  it("routes medium-confidence or underspecified Pursue to REFINE", () => {
    const issue = {
      number: 103,
      title: "Make Ralph queue recovery safer",
      body: "Ralph recovery can be unsafe.",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "REFINE");
    assert.equal(route.targetLabel, null);
    assert.match(route.reason, /needs human shaping/i);
  });

  it("routes work:prd to PRD lane with ralph:evaluated label", () => {
    const issue = {
      number: 104,
      title: "PRD: Implement deterministic lane routing",
      body: [
        "Ralph needs deterministic lane routing to safely classify AUTO/REFINE/PRD/HOLD without LLM instability.",
        "This will prevent quota waste on unsafe auto-launches and improve AFK agent reliability.",
        "",
        "## Acceptance criteria",
        "- AUTO predicate is strict and deterministic",
        "- PRD issues get ralph:evaluated",
        "- child slices re-enter AUTO evaluation",
        "- routing behavior is testable and explainable",
      ].join("\n"),
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "PRD");
    assert.equal(route.targetLabel, "ralph:evaluated");
    assert.match(route.reason, /PRD parent.*reviewed but not runnable/i);
  });

  it("routes issues with blockers to HOLD", () => {
    const issue = {
      number: 105,
      title: "Implement final cleanup step",
      body: [
        "Complete cleanup after workers finish.",
        "",
        "## Blocked by",
        "- #50",
        "",
        "## Acceptance criteria",
        "- cleanup removes temp files",
        "- test covers cleanup success",
      ].join("\n"),
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "HOLD");
    assert.equal(route.targetLabel, "ralph:blocked");
    assert.match(route.reason, /blocked by.*dependencies/i);
  });

  it("routes untrusted-author issues to REFINE even with high confidence", () => {
    const issue = {
      number: 106,
      title: "Fix critical Ralph worker safety bug",
      body: [
        "Ralph workers can corrupt work when preflight checks are bypassed during unsafe launches.",
        "",
        "Acceptance criteria:",
        "- preflight always runs before worker launch",
        "- test covers bypass attempt and shows corruption prevented",
      ].join("\n"),
      labels: ["ralph:needs-triage"],
      author: { login: "external-contributor" },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "REFINE");
    assert.equal(route.targetLabel, null);
    assert.match(route.reason, /trusted.*author/i);
  });

  it("routes Defer recommendation to HOLD", () => {
    const issue = {
      number: 107,
      title: "Add success confetti to the dashboard",
      body: "Nice-to-have UI polish someday; no known TJ pain or operator urgency yet.",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "HOLD");
    assert.equal(route.targetLabel, null);
    assert.match(route.reason, /deferred.*low priority/i);
  });

  it("routes Close recommendation to HOLD", () => {
    const issue = {
      number: 108,
      title: "Duplicate dashboard status idea",
      body: "Duplicate of #55, which already covers this exact status panel request.",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "HOLD");
    assert.equal(route.targetLabel, null);
    assert.match(route.reason, /closure.*human action/i);
  });

  it("routes Needs info to REFINE", () => {
    const issue = {
      number: 109,
      title: "TODO",
      body: "",
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "REFINE");
    assert.equal(route.targetLabel, null);
    assert.match(route.reason, /needs info/i);
  });

  it("includes strict AUTO predicate check in routing logic", () => {
    const highConfidenceIssue = {
      number: 110,
      title: "Fix critical safety bug",
      body: [
        "Ralph launches can corrupt work when preflight is bypassed.",
        "",
        "Acceptance criteria:",
        "- preflight always runs before launch",
        "- test covers bypass attempt",
      ].join("\n"),
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue: highConfidenceIssue });
    assert.equal(opinion.recommendation, "Pursue");
    assert.equal(opinion.confidence, "high");
    assert.equal(opinion.automationSafety, "safe after prep");

    const route = routeIssueToLane({ issue: highConfidenceIssue, opinion });
    assert.equal(route.lane, "AUTO");

    // Violate one part of predicate: remove acceptance criteria
    const lowClarityIssue = {
      ...highConfidenceIssue,
      number: 111,
      body: "Ralph launches can corrupt work when preflight is bypassed.",
    };
    const lowClarityOpinion = evaluateIssueForTriage({ issue: lowClarityIssue });
    const lowClarityRoute = routeIssueToLane({ issue: lowClarityIssue, opinion: lowClarityOpinion });
    assert.notEqual(lowClarityRoute.lane, "AUTO");
  });
});
