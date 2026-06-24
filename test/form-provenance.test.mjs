import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { parse } from "yaml";

const WORKFLOW_PATH = ".github/workflows/form-provenance.yml";

describe("Form provenance workflow", () => {
  it("exists at expected path", () => {
    assert.ok(
      existsSync(WORKFLOW_PATH),
      `Expected workflow at ${WORKFLOW_PATH}`
    );
  });

  it("runs on issues opened event", () => {
    const content = readFileSync(WORKFLOW_PATH, "utf8");
    const workflow = parse(content);

    assert.ok(workflow.on, "Workflow must have 'on' trigger");
    assert.ok(
      workflow.on.issues?.types?.includes("opened"),
      "Workflow must trigger on issues.opened"
    );
  });

  it("adds ralph:form-verified label for structured-intake form", () => {
    const content = readFileSync(WORKFLOW_PATH, "utf8");
    const workflow = parse(content);

    assert.ok(workflow.jobs, "Workflow must have jobs");
    const jobKeys = Object.keys(workflow.jobs);
    assert.ok(jobKeys.length > 0, "Workflow must have at least one job");

    const job = workflow.jobs[jobKeys[0]];
    assert.ok(Array.isArray(job.steps), "Job must have steps");

    // Check for conditional that verifies form template
    const workflowStr = content.toLowerCase();
    assert.ok(
      workflowStr.includes("issue_template") ||
        workflowStr.includes("structured-intake"),
      "Workflow must check for structured-intake form template"
    );

    // Check for label addition
    assert.ok(
      workflowStr.includes("ralph:form-verified"),
      "Workflow must add ralph:form-verified label"
    );
  });

  it("only adds label when issue uses the form template", () => {
    const content = readFileSync(WORKFLOW_PATH, "utf8");
    
    // Workflow must have a conditional check, not run unconditionally
    assert.ok(
      content.includes("if:"),
      "Workflow must conditionally add label based on form usage"
    );
  });
});
