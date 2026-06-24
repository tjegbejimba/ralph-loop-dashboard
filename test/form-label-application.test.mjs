import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { evaluateIssueForTriage } from "../extension/lib/issue-triage.mjs";
import { promoteLaneForIssue } from "../extension/lib/lane-promotion.mjs";

describe("Form field label application", () => {
  it("applies canonical priority label from form field", () => {
    const issue = {
      number: 1,
      title: "Test issue",
      body: `### Priority

P0 - Critical (stop-the-line)

### Acceptance Criteria / Reproduction Steps

High-value Ralph work.`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    
    // Form priority should override scorer's priority
    assert.equal(opinion.priority, "P0");
  });

  it("applies work:standalone label from form field", () => {
    const issue = {
      number: 2,
      title: "Test issue",
      body: `### Work Type

Standalone work

### Acceptance Criteria / Reproduction Steps

Test passes.`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    
    assert.equal(opinion.workTypeRecommendation, "work:standalone");
  });

  it("applies work:slice for 'Part of a PRD' form value", () => {
    const issue = {
      number: 3,
      title: "Test issue",
      body: `### Work Type

Part of a PRD (specify parent)

### Parent PRD Number (if applicable)

106

### Acceptance Criteria / Reproduction Steps

Test passes.`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    
    assert.equal(opinion.workTypeRecommendation, "work:slice");
  });

  it("applies work:prd for 'New PRD parent' form value", () => {
    const issue = {
      number: 4,
      title: "Test issue",
      body: `### Work Type

New PRD parent

### Acceptance Criteria / Reproduction Steps

PRD description.`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    
    assert.equal(opinion.workTypeRecommendation, "work:prd");
  });

  it("falls back to scorer when form fields are missing", () => {
    const issue = {
      number: 5,
      title: "Test issue",
      body: `Test passes.

Acceptance criteria:
- test passes`,
      labels: ["ralph:form-verified", "ralph:needs-triage"],
      author: { login: "tjegbejimba" },
      authorAssociation: "OWNER",
    };

    const opinion = evaluateIssueForTriage({ issue });
    
    // Should use scorer's decisions
    assert.ok(["P0", "P1", "P2", "P3"].includes(opinion.priority));
    assert.ok(["work:standalone", "work:slice", "work:prd"].includes(opinion.workTypeRecommendation));
  });

  it("ignores form fields without ralph:form-verified label", () => {
    const issue = {
      number: 6,
      title: "Test issue",
      body: `### Priority

P0 - Critical (stop-the-line)

### Work Type

Standalone work

Test passes.`,
      labels: ["ralph:needs-triage"], // Missing ralph:form-verified
      author: { login: "external-user" },
      authorAssociation: "CONTRIBUTOR",
    };

    const opinion = evaluateIssueForTriage({ issue });
    
    // Should use scorer's decisions, ignoring forged form fields
    // Likely P3 because low-scoring body
    assert.ok(["P1", "P2", "P3"].includes(opinion.priority));
  });
});
