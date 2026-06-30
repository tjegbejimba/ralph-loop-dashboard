import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { promoteLaneForIssue } from "../extension/lib/lane-promotion.mjs";
import { evaluateIssueForTriage } from "../extension/lib/issue-triage.mjs";
import { routeIssueToLane } from "../extension/lib/lane-routing.mjs";

describe("lane promotion", () => {
  it("AUTO lane: adds ralph:fast-lane when issue has no state label", () => {
    const issue = {
      number: 101,
      title: "Prevent unsafe launches when generated files are dirty",
      body: [
        "Ralph can waste quota or corrupt work if workers start from a dirty repo.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
        "- tests cover dirty files",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.lane, "AUTO");
    // Now includes computed priority label
    assert.deepEqual(result.labelsAdded, ["ralph:fast-lane", "priority:P1"]);
    assert.deepEqual(result.labelsRemoved, ["ralph:needs-triage"]);
    assert.equal(result.skipped, false);
  });

  it("removes conflicting ralph:* state label when adding target label", () => {
    const issue = {
      number: 102,
      title: "Prevent unsafe launches",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
      ].join("\n"),
      labels: [{ name: "ralph:evaluated" }, { name: "work:standalone" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.lane, "AUTO");
    // Now includes computed priority label
    assert.deepEqual(result.labelsAdded, ["ralph:fast-lane", "priority:P1"]);
    assert.deepEqual(result.labelsRemoved, ["ralph:evaluated"]);
  });

  it("idempotent: already-correct issue produces zero mutations", () => {
    const issue = {
      number: 103,
      title: "Prevent unsafe launches",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
      ].join("\n"),
      // Include priority to prevent auto-addition
      labels: [{ name: "ralph:fast-lane" }, { name: "work:standalone" }, { name: "priority:P2" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.lane, "AUTO");
    assert.deepEqual(result.labelsAdded, []);
    assert.deepEqual(result.labelsRemoved, []);
    assert.equal(result.skipped, false);
  });

  it("PRD lane: adds ralph:evaluated and work:prd", () => {
    const issue = {
      number: 104,
      title: "PRD: Implement deterministic lane routing",
      body: [
        "Ralph needs deterministic lane routing to safely classify AUTO/REFINE/PRD/HOLD without LLM instability.",
        "This prevents quota waste on unsafe auto-launches and improves AFK agent reliability.",
        "",
        "## Acceptance criteria",
        "- AUTO predicate is strict and deterministic",
        "- PRD issues get ralph:evaluated",
        "- routing behavior is testable",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.lane, "PRD");
    // Now includes computed priority label
    assert.deepEqual(result.labelsAdded, ["ralph:evaluated", "work:prd", "priority:P1"]);
    assert.deepEqual(result.labelsRemoved, ["ralph:needs-triage"]);
  });

  it("HOLD lane with blockers: adds ralph:blocked", () => {
    const issue = {
      number: 105,
      title: "Implement worker timeout handling",
      body: [
        "## Blocked by",
        "",
        "- #104",
        "",
        "Ralph workers need timeout handling.",
        "",
        "Acceptance criteria:",
        "- workers timeout after 30min",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.lane, "HOLD");
    // Now includes computed priority label
    assert.deepEqual(result.labelsAdded, ["ralph:blocked", "priority:P1"]);
    assert.deepEqual(result.labelsRemoved, ["ralph:needs-triage"]);
  });

  it("REFINE lane: no-op when targetLabel is null", () => {
    const issue = {
      number: 106,
      title: "Make Ralph queue recovery safer",
      body: "Ralph recovery can be unsafe.",
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.lane, "REFINE");
    assert.deepEqual(result.labelsAdded, []);
    assert.deepEqual(result.labelsRemoved, []);
    assert.equal(result.skipped, true);
    assert.match(result.skipReason, /no target label/i);
  });

  it("guard: refuses promotion when issue has taxonomy conflicts", () => {
    const issue = {
      number: 107,
      title: "Prevent unsafe launches",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
      ].join("\n"),
      labels: [
        { name: "ralph:needs-triage" },
        { name: "priority:P1" },
        { name: "priority:P2" }, // conflict!
      ],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.skipped, true);
    assert.match(result.skipReason, /taxonomy conflict/i);
    assert.deepEqual(result.labelsAdded, []);
    assert.deepEqual(result.labelsRemoved, []);
  });

  it("guard: refuses promotion when issue has open linked PR", () => {
    const issue = {
      number: 108,
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
      closedByPullRequestsReferences: [
        { number: 100, state: "OPEN", url: "https://github.com/owner/repo/pull/100" },
      ],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.skipped, true);
    assert.match(result.skipReason, /open.*PR/i);
  });

  it("guard: refuses promotion when issue has assignee", () => {
    const issue = {
      number: 109,
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
      assignees: [{ login: "someone" }],
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.skipped, true);
    assert.match(result.skipReason, /assignee/i);
  });

  it("guard: refuses promotion when issue has unresolved blockers (except for HOLD lane)", () => {
    const issue = {
      number: 110,
      title: "Prevent unsafe launches",
      body: [
        "## Blocked by",
        "",
        "- #99",
        "",
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }, { name: "work:standalone" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    // This routes to HOLD, which is exempt from blocker guard
    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.lane, "HOLD");
    assert.equal(result.skipped, false); // HOLD lane is allowed despite blockers
  });

  it("guard: refuses promotion for work:slice missing Parent marker", () => {
    const issue = {
      number: 111,
      title: "Slice 1: Bootstrap",
      body: [
        "Bootstrap the system.",
        "",
        "Acceptance criteria:",
        "- tests pass",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }, { name: "work:slice" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.skipped, true);
    assert.match(result.skipReason, /missing.*parent/i);
  });

  it("guard: refuses promotion when body has open questions", () => {
    const issue = {
      number: 112,
      title: "Prevent unsafe launches",
      body: [
        "Ralph can waste quota.",
        "",
        "## Open questions",
        "",
        "- Should we use timeout or polling?",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    const result = promoteLaneForIssue({ issue, opinion, route, live: false });

    assert.equal(result.skipped, true);
    assert.match(result.skipReason, /open questions|TBD/i);
  });
});
