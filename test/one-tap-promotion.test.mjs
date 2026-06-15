import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { promoteOneTapReadiness } from "../extension/lib/lane-promotion.mjs";

describe("one-tap promotion from ralph:fast-lane to ralph:ready", () => {
  it("promotes a valid ralph:fast-lane issue to ralph:ready", () => {
    const issue = {
      number: 42,
      title: "Fix dashboard crash on empty queue",
      body: [
        "Bug: dashboard crashes when queue is empty.",
        "",
        "Acceptance criteria:",
        "- Empty queue renders without crash",
        "- Tests cover empty queue case",
      ].join("\n"),
      labels: ["ralph:fast-lane", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, true);
    assert.equal(result.issueNumber, 42);
    assert.deepEqual(result.labelsAdded, ["ralph:ready"]);
    assert.deepEqual(result.labelsRemoved, ["ralph:fast-lane"]);
    assert.equal(result.skipReason, null);
  });

  it("refuses promotion when issue is not in ralph:fast-lane state", () => {
    const issue = {
      number: 43,
      title: "Fix bug",
      body: "Acceptance criteria:\n- Fixed",
      labels: ["ralph:needs-triage", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 43);
    assert.deepEqual(result.labelsAdded, []);
    assert.deepEqual(result.labelsRemoved, []);
    assert.match(result.skipReason, /not in ralph:fast-lane state/i);
  });

  it("refuses promotion for non-runnable work types (work:prd)", () => {
    const issue = {
      number: 44,
      title: "PRD: Improve dashboard",
      body: "Design a better dashboard",
      labels: ["ralph:fast-lane", "work:prd", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 44);
    assert.match(result.skipReason, /not a runnable work type/i);
  });

  it("refuses promotion when priority label is missing", () => {
    const issue = {
      number: 45,
      title: "Fix bug",
      body: "Acceptance criteria:\n- Fixed",
      labels: ["ralph:fast-lane", "work:standalone"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 45);
    assert.match(result.skipReason, /missing priority/i);
  });

  it("refuses promotion when issue has an assignee", () => {
    const issue = {
      number: 46,
      title: "Fix bug",
      body: "Acceptance criteria:\n- Fixed",
      labels: ["ralph:fast-lane", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [{ login: "tjegbejimba" }],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 46);
    assert.match(result.skipReason, /has assignee/i);
  });

  it("refuses promotion when issue has an open linked PR", () => {
    const issue = {
      number: 47,
      title: "Fix bug",
      body: "Acceptance criteria:\n- Fixed",
      labels: ["ralph:fast-lane", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [{ number: 100, state: "OPEN", url: "https://github.com/owner/repo/pull/100" }],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 47);
    assert.match(result.skipReason, /open linked pr/i);
  });

  it("refuses promotion when issue has unresolved blockers", () => {
    const issue = {
      number: 48,
      title: "Fix bug",
      body: "Acceptance criteria:\n- Fixed\n\n## Blocked by\n\n- #99\n- #100",
      labels: ["ralph:fast-lane", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 48);
    assert.match(result.skipReason, /unresolved blockers/i);
  });

  it("refuses promotion when issue has open questions", () => {
    const issue = {
      number: 49,
      title: "Fix bug",
      body: "Acceptance criteria:\n- Fixed\n\n## Open questions\n\n- How should this work?",
      labels: ["ralph:fast-lane", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 49);
    assert.match(result.skipReason, /open questions/i);
  });

  it("is idempotent when issue is already in ralph:ready state", () => {
    const issue = {
      number: 50,
      title: "Fix bug",
      body: "Acceptance criteria:\n- Fixed",
      labels: ["ralph:ready", "work:standalone", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, false);
    assert.equal(result.issueNumber, 50);
    assert.deepEqual(result.labelsAdded, []);
    assert.deepEqual(result.labelsRemoved, []);
    assert.match(result.skipReason, /not in ralph:fast-lane state/i);
  });

  it("promotes work:slice issues (PRD child slices)", () => {
    const issue = {
      number: 51,
      title: "Slice 1: Bootstrap dashboard",
      body: "Parent #100\n\nAcceptance criteria:\n- Dashboard initialized",
      labels: ["ralph:fast-lane", "work:slice", "priority:P2"],
      state: "OPEN",
      assignees: [],
      closedByPullRequestsReferences: [],
    };

    const result = promoteOneTapReadiness({ issue, live: false });

    assert.equal(result.promoted, true);
    assert.equal(result.issueNumber, 51);
    assert.deepEqual(result.labelsAdded, ["ralph:ready"]);
    assert.deepEqual(result.labelsRemoved, ["ralph:fast-lane"]);
    assert.equal(result.skipReason, null);
  });
});
