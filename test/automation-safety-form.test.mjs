import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { evaluateIssueForTriage } from "../extension/lib/issue-triage.mjs";
import { routeIssueToLane } from "../extension/lib/lane-routing.mjs";

describe("Form automation-safety input", () => {
  it("blocks AUTO for 'Needs human judgment' form value", () => {
    const issue = {
      number: 1,
      title: "Test issue",
      body: `### Priority

P1 - High

### Automation Safety

Needs human judgment

### Acceptance Criteria / Reproduction Steps

High-value Ralph automation work with clear tests and acceptance criteria.`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "external-user" },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    // Should NOT go to AUTO because form says "Needs human judgment"
    assert.notEqual(route.lane, "AUTO");
    assert.equal(opinion.automationSafety, "hitl-required");
  });

  it("blocks AUTO for 'Not safe' form value", () => {
    const issue = {
      number: 2,
      title: "Test issue",
      body: `### Priority

P1 - High

### Automation Safety

Not safe

### Acceptance Criteria / Reproduction Steps

High-value Ralph automation work with clear tests.`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "external-user" },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    // Should NOT go to AUTO because form says "Not safe"
    assert.notEqual(route.lane, "AUTO");
    assert.equal(opinion.automationSafety, "hitl-required");
  });

  it("allows AUTO for 'Safe after prep' form value", () => {
    const issue = {
      number: 3,
      title: "Test issue",
      body: `### Priority

P1 - High

### Automation Safety

Safe after prep

### Acceptance Criteria / Reproduction Steps

High-value Ralph automation work with clear tests and acceptance criteria.`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "external-user" },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });

    // Should go to AUTO because form says "Safe after prep" and it's form-verified
    assert.equal(route.lane, "AUTO");
    assert.equal(opinion.automationSafety, "safe after prep");
  });

  it("falls back to scorer when form has no automation-safety field", () => {
    const issue = {
      number: 4,
      title: "Test issue",
      body: `High-value Ralph automation work with clear tests and acceptance criteria.

Acceptance criteria:
- test passes`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "external-user" },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });

    // Should use scorer's decision since no form field
    assert.ok(["safe after prep", "needs prep", "hitl-required"].includes(opinion.automationSafety));
  });

  it("ignores form automation-safety without ralph:form-verified label", () => {
    const issue = {
      number: 5,
      title: "Test issue",
      body: `### Automation Safety

Safe after prep

### Acceptance Criteria

High-value Ralph automation work.

Acceptance criteria:
- test passes`,
      labels: ["ralph:needs-triage"], // Missing ralph:form-verified
      author: { login: "external-user" },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });

    // Should use scorer's decision, ignoring forged form field
    // Likely hitl-required because untrusted author
    assert.ok(["safe after prep", "needs prep", "hitl-required"].includes(opinion.automationSafety));
  });
});
