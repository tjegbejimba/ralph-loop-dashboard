import { readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { validateModel } from "../extension/lib/run-options.mjs";

const prompt = readFileSync("ralph/RALPH.md.template", "utf8");

test("Ralph prompt requires body-file PR creation instead of inline PR bodies", () => {
  assert.match(prompt, /--body-file \.ralph-pr-body-<N>\.md/);
  assert.match(prompt, /Do not pass multi-line PR bodies via inline `--body`/);
  assert.doesNotMatch(prompt, /gh pr create --base main --title "<conventional title>" --body "<body>"/);
  assert.match(prompt, /not a shell heredoc and not `\/tmp`/);
});

test("Ralph prompt respects branch protections during merge", () => {
  assert.match(prompt, /Do \*\*not\*\* use `--admin`/);
  assert.match(prompt, /gh pr checks <pr> --repo \{\{REPO\}\} --required --watch --fail-fast/);
  assert.doesNotMatch(prompt, /gh pr merge <pr> --repo \{\{REPO\}\} --squash --delete-branch --admin/);
});

test("Ralph prompt review models are permitted by the run-options allowlist", () => {
  const reviewModels = [...prompt.matchAll(/`(claude-opus-[\d.]+)`/g)].map((m) => m[1]);

  assert.ok(reviewModels.length > 0, "expected at least one claude-opus review model in the template");
  assert.ok(
    reviewModels.includes("claude-opus-4.8"),
    "template should reference claude-opus-4.8 as the review model",
  );

  for (const model of new Set(reviewModels)) {
    const result = validateModel(model);
    assert.equal(result.valid, true, `${model} referenced in RALPH.md.template must be in the allowlist`);
  }
});
