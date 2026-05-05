import { readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";

const prompt = readFileSync("ralph/RALPH.md.template", "utf8");

test("Ralph prompt requires body-file PR creation instead of inline PR bodies", () => {
  assert.match(prompt, /--body-file \.ralph-pr-body-<N>\.md/);
  assert.match(prompt, /Do not pass multi-line PR bodies via inline `--body`/);
  assert.doesNotMatch(prompt, /gh pr create --base main --title "<conventional title>" --body "<body>"/);
  assert.match(prompt, /not a shell heredoc and not `\/tmp`/);
});
