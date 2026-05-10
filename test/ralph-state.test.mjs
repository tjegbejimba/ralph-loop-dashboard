import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";

const lib = resolve("ralph/lib/state.sh");

function runIsIssueSatisfied({ gh, issueNum, env = {} }) {
  const dir = mkdtempSync(join(tmpdir(), "ralph-state-"));
  const bin = join(dir, "gh");
  const log = join(dir, "gh.log");
  writeFileSync(
    bin,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> ${JSON.stringify(log)}
${gh}
`,
    { mode: 0o755 },
  );
  const result = spawnSync(
    "bash",
    [
      "-c",
      `. ${JSON.stringify(lib)}; REPO=owner/repo; is_issue_satisfied ${issueNum}`,
    ],
    {
      env: { ...process.env, ...env, PATH: `${dir}:${process.env.PATH || ""}` },
      encoding: "utf8",
    },
  );
  const calls = (() => {
    try {
      return readFileSync(log, "utf8");
    } catch (e) {
      if (e.code === "ENOENT") return "";
      throw e;
    }
  })();
  return { stdout: result.stdout, stderr: result.stderr, status: result.status, calls };
}

test("is_issue_satisfied returns 1 when closedByPullRequestsReferences includes a merged PR", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[{"number":99}],"state":"CLOSED"}\\n'
    ;;
  "pr view")
    printf '2026-05-09T12:00:00Z\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "1");
});

test("is_issue_satisfied returns 0 when state is OPEN", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"OPEN"}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0");
});

test("is_issue_satisfied returns 0 when CLOSED but no PR references AND release-branch unset", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED"}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0");
});

test("is_issue_satisfied: release-branch fallback returns 1 when CLOSED + merged PR has Closes #N body", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    env: { RALPH_RELEASE_BRANCH: "multi-user" },
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED"}\\n'
    ;;
  "pr list")
    # gh pr list ... --json number -q '.[0].number'
    printf '99\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "1");
  assert.match(r.calls, /pr list .* --base multi-user/);
  assert.match(r.calls, /Closes #42/);
});

test("is_issue_satisfied: release-branch fallback returns 0 when no matching merged PR exists", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    env: { RALPH_RELEASE_BRANCH: "multi-user" },
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED"}\\n'
    ;;
  "pr list")
    printf ''
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0");
});

// parse_blockers must succeed (exit 0) on bodies with no "## Blocked by"
// section. The function is invoked from ralph.sh as `blockers=$(parse_blockers
// "$body")` under set -e + pipefail; any non-zero exit silently kills the
// worker. Regression test for the empty-section / no-matches case.
function runParseBlockers(body) {
  return spawnSync(
    "bash",
    [
      "-c",
      `set -euo pipefail; LOG_DIR=/tmp; . ${JSON.stringify(lib)}; parse_blockers "$1"`,
      "_",
      body,
    ],
    { encoding: "utf8" },
  );
}

test("parse_blockers exits 0 when body has no '## Blocked by' section", () => {
  const r = runParseBlockers("## Problem Statement\n\nNo blocked-by here.\n");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "");
});

test("parse_blockers exits 0 when section is present but lists no #refs", () => {
  const r = runParseBlockers("## Blocked by\n\nSomething narrative.\n\n## Next");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "");
});

test("parse_blockers extracts numeric refs from '## Blocked by' section", () => {
  const r = runParseBlockers("## Blocked by\n\n- #42\n- #7 (note)\n\n## Next");
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(
    r.stdout.trim().split("\n").sort(),
    ["42", "7"].sort(),
  );
});

test("parse_blockers short-circuits on 'None'", () => {
  const r = runParseBlockers("## Blocked by\n\nNone — can start.\n\n## Next");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "");
});
