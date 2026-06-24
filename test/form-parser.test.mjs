import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parseFormFields } from "../extension/lib/form-parser.mjs";

describe("parseFormFields", () => {
  it("extracts priority field from form body", () => {
    const body = `### Priority

P1 - High

### Acceptance Criteria / Reproduction Steps

- [ ] Test criterion

### Additional Context

Some context`;

    const fields = parseFormFields(body);
    assert.equal(fields.priority, "P1");
  });

  it("extracts automation safety field", () => {
    const body = `### Priority

P2 - Normal

### Automation Safety

Needs human judgment

### Acceptance Criteria / Reproduction Steps

- [ ] Test criterion`;

    const fields = parseFormFields(body);
    assert.equal(fields.automationSafety, "needs human judgment");
  });

  it("extracts work type field", () => {
    const body = `### Priority

P1 - High

### Work Type

Part of a PRD (specify parent)

### Parent PRD Number (if applicable)

106

### Acceptance Criteria / Reproduction Steps

- [ ] Test criterion`;

    const fields = parseFormFields(body);
    assert.equal(fields.workType, "part of a prd");
    assert.equal(fields.parentPrd, 106);
  });

  it("returns null for missing fields", () => {
    const body = `### Acceptance Criteria / Reproduction Steps

- [ ] Test criterion`;

    const fields = parseFormFields(body);
    assert.equal(fields.priority, null);
    assert.equal(fields.automationSafety, null);
    assert.equal(fields.workType, null);
    assert.equal(fields.parentPrd, null);
  });

  it("normalizes priority to canonical format", () => {
    const body = `### Priority

P0 - Critical (stop-the-line)`;

    const fields = parseFormFields(body);
    assert.equal(fields.priority, "P0");
  });

  it("normalizes automation safety values", () => {
    const testCases = [
      { input: "Safe after prep", expected: "safe after prep" },
      { input: "Needs human judgment", expected: "needs human judgment" },
      { input: "Not safe", expected: "not safe" },
    ];

    for (const { input, expected } of testCases) {
      const body = `### Automation Safety\n\n${input}`;
      const fields = parseFormFields(body);
      assert.equal(fields.automationSafety, expected);
    }
  });

  it("parses parent PRD as number", () => {
    const body = `### Parent PRD Number (if applicable)

123`;

    const fields = parseFormFields(body);
    assert.equal(fields.parentPrd, 123);
    assert.strictEqual(typeof fields.parentPrd, "number");
  });

  it("handles empty parent PRD field", () => {
    const body = `### Parent PRD Number (if applicable)

_No response_`;

    const fields = parseFormFields(body);
    assert.equal(fields.parentPrd, null);
  });

  it("normalizes work type values", () => {
    const testCases = [
      { input: "Standalone work", expected: "standalone work" },
      { input: "Part of a PRD (specify parent)", expected: "part of a prd" },
      { input: "New PRD parent", expected: "new prd parent" },
    ];

    for (const { input, expected } of testCases) {
      const body = `### Work Type\n\n${input}`;
      const fields = parseFormFields(body);
      assert.equal(fields.workType, expected);
    }
  });
});
