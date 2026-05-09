// Tests for the hitl label convention — verifies profile configs exclude hitl issues
// and that label documentation exists.
// Run via `node --test test/labels.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function readJson(rel) {
  return JSON.parse(readFileSync(join(ROOT, rel), "utf8"));
}

// RED: All profile configs must exclude hitl-labelled issues
for (const profile of ["generic", "bun", "python"]) {
  test(`profile ${profile} issueSearch excludes hitl label`, () => {
    const cfg = readJson(`ralph/profiles/${profile}.json`);
    const search = cfg.issue.issueSearch;
    assert.ok(
      typeof search === "string",
      `${profile} issueSearch should be a string`
    );
    assert.ok(
      search.includes("-label:hitl"),
      `${profile} issueSearch ("${search}") must include -label:hitl`
    );
  });
}

// RED: docs/labels.md must exist and document the three Ralph-relevant labels
test("docs/labels.md documents needs-triage, ready-for-agent, and hitl labels", () => {
  let content;
  try {
    content = readFileSync(join(ROOT, "docs/labels.md"), "utf8");
  } catch {
    assert.fail("docs/labels.md does not exist");
  }
  assert.ok(content.includes("needs-triage"), "docs/labels.md must mention needs-triage");
  assert.ok(content.includes("ready-for-agent"), "docs/labels.md must mention ready-for-agent");
  assert.ok(content.includes("hitl"), "docs/labels.md must mention hitl");
});

// RED: docs/labels.md explains mutual exclusivity of ready-for-agent and hitl
test("docs/labels.md explains ready-for-agent and hitl are mutually exclusive", () => {
  const content = readFileSync(join(ROOT, "docs/labels.md"), "utf8");
  // Check that it mentions Ralph's issueSearch exclusion
  assert.ok(
    content.includes("issueSearch") || content.includes("mutually exclusive") || content.includes("naturally skipped"),
    "docs/labels.md should explain how hitl interacts with Ralph's issueSearch"
  );
});

// RED: install.sh must include a hint about creating the hitl label
test("install.sh contains a hint to create the hitl label in target repos", () => {
  const content = readFileSync(join(ROOT, "install.sh"), "utf8");
  assert.ok(
    content.includes("hitl"),
    "install.sh should mention the hitl label to guide maintainers"
  );
});
