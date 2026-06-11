// Tests for Ralph's canonical label taxonomy documentation and profile defaults.
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

// RED: All profile configs must use canonical queue eligibility labels.
for (const profile of ["generic", "bun", "python"]) {
  test(`profile ${profile} issueSearch uses canonical ready work labels`, () => {
    const cfg = readJson(`ralph/profiles/${profile}.json`);
    const search = cfg.issue.issueSearch;
    assert.ok(
      typeof search === "string",
      `${profile} issueSearch should be a string`
    );
    assert.ok(
      search.includes("label:ralph:ready"),
      `${profile} issueSearch ("${search}") must include label:ralph:ready`
    );
    assert.ok(
      search.includes("label:work:slice") && search.includes("label:work:standalone"),
      `${profile} issueSearch ("${search}") must include canonical work labels`
    );
  });
}

// RED: docs/labels.md must exist and document the canonical dimensions.
test("docs/labels.md documents canonical state, priority, and work labels", () => {
  let content;
  try {
    content = readFileSync(join(ROOT, "docs/labels.md"), "utf8");
  } catch {
    assert.fail("docs/labels.md does not exist");
  }
  assert.ok(content.includes("ralph:ready"), "docs/labels.md must mention ralph:ready");
  assert.ok(content.includes("priority:P2"), "docs/labels.md must mention priority:P2");
  assert.ok(content.includes("work:slice"), "docs/labels.md must mention work:slice");
});

// RED: docs/labels.md explains one-label-per-dimension conflict rules.
test("docs/labels.md explains dimension conflicts are invalid", () => {
  const content = readFileSync(join(ROOT, "docs/labels.md"), "utf8");
  assert.ok(
    content.includes("Exactly one") || content.includes("one label per dimension") || content.includes("conflict"),
    "docs/labels.md should explain conflicts within taxonomy dimensions"
  );
});

// RED: install.sh must include a hint about creating canonical Ralph-owned labels.
test("install.sh contains a hint to create canonical Ralph labels in target repos", () => {
  const content = readFileSync(join(ROOT, "install.sh"), "utf8");
  assert.ok(
    content.includes("ralph:ready") && content.includes("work:slice") && content.includes("priority:P2"),
    "install.sh should mention canonical labels to guide maintainers"
  );
});

// RED: ralph.sh must read issueSearch from config and pass it to gh issue list
test("ralph.sh reads issueSearch config and passes it as --search to gh issue list", () => {
  const content = readFileSync(join(ROOT, "ralph/ralph.sh"), "utf8");
  assert.ok(
    content.includes("issueSearch") || content.includes("ISSUE_SEARCH"),
    "ralph.sh must reference issueSearch / ISSUE_SEARCH"
  );
  assert.ok(
    content.includes("--search"),
    "ralph.sh must pass --search to gh issue list"
  );
});
