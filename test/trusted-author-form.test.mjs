import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { evaluateIssueForTriage } from "../extension/lib/issue-triage.mjs";
import { routeIssueToLane } from "../extension/lib/lane-routing.mjs";

describe("Form-verified provenance for trusted author", () => {
  it("treats ralph:form-verified label as trusted for AUTO eligibility", () => {
    const issue = {
      number: 1,
      title: "Test issue",
      body: `High-value Ralph automation work with clear tests.

Acceptance criteria:
- preflight validates form-verified label
- test covers AUTO eligibility for form-verified issues`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "external-user", is_bot: false },
      authorAssociation: "CONTRIBUTOR", // Not OWNER/MEMBER
    };

    // This issue should score high and route to AUTO because it has ralph:form-verified
    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    // Verify it meets AUTO predicate (trusted author due to form verification)
    assert.equal(route.lane, "AUTO");
    assert.equal(route.targetLabel, "ralph:fast-lane");
  });

  it("rejects forged form body without ralph:form-verified label", () => {
    const issue = {
      number: 2,
      title: "Test issue",
      body: `### Priority

P1 - High

### Acceptance Criteria

- [ ] Test passes

High-value Ralph automation work with clear tests.

Acceptance criteria:
- test passes`,
      labels: ["ralph:needs-triage"], // Missing ralph:form-verified
      author: { login: "external-user", is_bot: false },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    // Should NOT go to AUTO without form verification
    assert.notEqual(route.lane, "AUTO");
    assert.equal(route.lane, "REFINE");
    assert.ok(route.reason.includes("trusted") || route.reason.includes("Untrusted"));
  });

  it("still trusts OWNER/MEMBER authors without form verification", () => {
    const issue = {
      number: 3,
      title: "Test issue",
      body: `High-value Ralph automation work with clear tests.

Acceptance criteria:
- test passes for OWNER`,
      labels: ["ralph:needs-triage"],
      author: { login: "team-member", is_bot: false },
      authorAssociation: "OWNER", // OWNER is always trusted
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    // OWNER should still be trusted for AUTO
    assert.equal(route.lane, "AUTO");
  });

  it("still trusts tjegbejimba without form verification", () => {
    const issue = {
      number: 4,
      title: "Test issue",
      body: `High-value Ralph automation work with clear tests.

Acceptance criteria:
- test passes for tjegbejimba`,
      labels: ["ralph:needs-triage"],
      author: { login: "tjegbejimba", is_bot: false },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    assert.equal(route.lane, "AUTO");
  });
});
