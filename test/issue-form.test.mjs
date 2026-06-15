import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { parse } from "yaml";

const ISSUE_FORM_PATH = ".github/ISSUE_TEMPLATE/structured-intake.yml";

describe("GitHub issue form for structured intake", () => {
  it("exists at the expected path", () => {
    assert.ok(
      existsSync(ISSUE_FORM_PATH),
      `Expected issue form at ${ISSUE_FORM_PATH}`
    );
  });

  it("applies ralph:needs-triage label on submit", () => {
    const content = readFileSync(ISSUE_FORM_PATH, "utf8");
    const form = parse(content);

    assert.ok(form.labels, "Form must have labels array");
    assert.ok(
      form.labels.includes("ralph:needs-triage"),
      "Form must auto-apply ralph:needs-triage label"
    );
  });

  it("captures priority as a structured field", () => {
    const content = readFileSync(ISSUE_FORM_PATH, "utf8");
    const form = parse(content);

    const priorityField = form.body.find(
      (field) => field.id === "priority"
    );
    assert.ok(priorityField, "Form must have a priority field");
    assert.ok(
      ["dropdown", "checkboxes"].includes(priorityField.type),
      "Priority field should be dropdown or checkboxes"
    );
    assert.ok(
      priorityField.attributes.required === true ||
        priorityField.validations?.required === true,
      "Priority field should be required"
    );
  });

  it("captures automation-safety as a structured field", () => {
    const content = readFileSync(ISSUE_FORM_PATH, "utf8");
    const form = parse(content);

    const safetyField = form.body.find(
      (field) => field.id === "automation_safety"
    );
    assert.ok(safetyField, "Form must have an automation_safety field");
    assert.ok(
      ["dropdown", "checkboxes"].includes(safetyField.type),
      "Automation-safety field should be dropdown or checkboxes"
    );
  });

  it("captures acceptance criteria or repro as a structured field", () => {
    const content = readFileSync(ISSUE_FORM_PATH, "utf8");
    const form = parse(content);

    const acceptanceField = form.body.find(
      (field) => field.id === "acceptance_criteria"
    );
    assert.ok(
      acceptanceField,
      "Form must have an acceptance_criteria field"
    );
    assert.equal(
      acceptanceField.type,
      "textarea",
      "Acceptance criteria should be a textarea"
    );
    assert.ok(
      acceptanceField.attributes.required === true ||
        acceptanceField.validations?.required === true,
      "Acceptance criteria field should be required"
    );
  });

  it("is identifiable as form-sourced for trusted provenance", () => {
    const content = readFileSync(ISSUE_FORM_PATH, "utf8");
    const form = parse(content);

    // GitHub automatically adds "issue_template" to body when created via form
    // We verify the form has a name that will appear in the body
    assert.ok(form.name, "Form must have a name for provenance tracking");
    assert.match(
      form.name,
      /structured|intake|form/i,
      "Form name should indicate it's a structured intake form"
    );
  });
});
