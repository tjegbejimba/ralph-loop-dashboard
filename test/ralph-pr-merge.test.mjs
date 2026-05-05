import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";

const helper = resolve("ralph/lib/pr-merge.sh");

function runHelper(fakeGhBody) {
  const dir = mkdtempSync(join(tmpdir(), "ralph-pr-merge-"));
  const bin = join(dir, "gh");
  const log = join(dir, "gh.log");
  writeFileSync(
    bin,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> ${JSON.stringify(log)}
${fakeGhBody}
`,
    { mode: 0o755 },
  );
  const result = spawnSync(
    "bash",
    [
      "-c",
      `. ${JSON.stringify(helper)}; REPO=owner/repo; ralph_merge_ready_open_pr_for_issue 13 main`,
    ],
    {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH || ""}` },
      encoding: "utf8",
    },
  );
  const calls = readFileSync(log, "utf8");
  return { result, calls };
}

test("merge fallback squashes a linked open PR when checks are green", () => {
  const { result, calls } = runHelper(`
if [[ "$1 $2" == "pr list" ]]; then
  printf '23\\tfalse\\tmain\\tMERGEABLE\\n'
elif [[ "$1 $2" == "pr view" ]]; then
  printf '13\\n'
elif [[ "$1 $2" == "pr checks" ]]; then
  printf '[{"bucket":"pass"}]\\n'
elif [[ "$1 $2" == "pr merge" ]]; then
  exit 0
else
  echo "unexpected gh call: $*" >&2
  exit 2
fi
`);

  assert.equal(result.status, 0, result.stderr);
  assert.match(calls, /pr merge 23 --repo owner\/repo --squash --delete-branch/);
});

test("merge fallback does not merge when checks are still pending", () => {
  const { result, calls } = runHelper(`
if [[ "$1 $2" == "pr list" ]]; then
  printf '23\\tfalse\\tmain\\tMERGEABLE\\n'
elif [[ "$1 $2" == "pr view" ]]; then
  printf '13\\n'
elif [[ "$1 $2" == "pr checks" ]]; then
  printf '[{"bucket":"pending"}]\\n'
  exit 8
elif [[ "$1 $2" == "pr merge" ]]; then
  exit 99
else
  echo "unexpected gh call: $*" >&2
  exit 2
fi
`);

  assert.equal(result.status, 1, result.stderr);
  assert.doesNotMatch(calls, /pr merge/);
});

test("merge fallback treats a PR with no checks as ready", () => {
  const { result, calls } = runHelper(`
if [[ "$1 $2" == "pr list" ]]; then
  printf '23\\tfalse\\tmain\\tMERGEABLE\\n'
elif [[ "$1 $2" == "pr view" ]]; then
  printf '13\\n'
elif [[ "$1 $2" == "pr checks" ]]; then
  printf '[]\\n'
elif [[ "$1 $2" == "pr merge" ]]; then
  exit 0
else
  echo "unexpected gh call: $*" >&2
  exit 2
fi
`);

  assert.equal(result.status, 0, result.stderr);
  assert.match(calls, /pr merge 23 --repo owner\/repo --squash --delete-branch/);
});
