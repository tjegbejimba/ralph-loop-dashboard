import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { runPromoteLanes } from "../extension/lib/lane-promotion.mjs";

describe("promote-lanes CLI integration", () => {
  it("processes issues and returns promotion results", () => {
    const issues = [
      {
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
      },
    ];

    const result = runPromoteLanes({ issues, live: false });

    assert.equal(result.promotions.length, 1);
    assert.equal(result.promotions[0].issueNumber, 101);
    assert.equal(result.promotions[0].lane, "AUTO");
    assert.deepEqual(result.promotions[0].labelsAdded, ["ralph:fast-lane"]);
    assert.deepEqual(result.promotions[0].labelsRemoved, ["ralph:needs-triage"]);
  });

  it("skips issues that fail guards", () => {
    const issues = [
      {
        number: 102,
        title: "Conflicted issue",
        body: "Test issue",
        labels: [
          { name: "ralph:needs-triage" },
          { name: "priority:P1" },
          { name: "priority:P2" },
        ],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
    ];

    const result = runPromoteLanes({ issues, live: false });

    assert.equal(result.promotions.length, 1);
    assert.equal(result.promotions[0].skipped, true);
    assert.match(result.promotions[0].skipReason, /taxonomy conflict/i);
  });

  it("reports summary stats", () => {
    const issues = [
      {
        number: 101,
        title: "Good issue",
        body: [
          "Ralph can waste quota.",
          "",
          "Acceptance criteria:",
          "- preflight blocks",
        ].join("\n"),
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
      {
        number: 102,
        title: "Already correct",
        body: [
          "Ralph can waste quota.",
          "",
          "Acceptance criteria:",
          "- preflight blocks",
        ].join("\n"),
        labels: [{ name: "ralph:fast-lane" }, { name: "work:standalone" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
    ];

    const result = runPromoteLanes({ issues, live: false });

    assert.equal(result.summary.total, 2);
    assert.equal(result.summary.promoted, 1);
    assert.equal(result.summary.noOp, 1);
    assert.equal(result.summary.skipped, 0);
  });
});
