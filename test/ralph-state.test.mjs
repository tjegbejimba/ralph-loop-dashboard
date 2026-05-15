import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";

const lib = resolve("ralph/lib/state.sh");

function runStateFn({ gh, fnCall, env = {} }) {
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
      `. ${JSON.stringify(lib)}; REPO=owner/repo; ${fnCall}`,
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

function runIsIssueSatisfied({ gh, issueNum, env = {} }) {
  return runStateFn({ gh, env, fnCall: `is_issue_satisfied ${issueNum}` });
}

function runIssueSatisfactionDetail({ gh, issueNum, env = {} }) {
  return runStateFn({ gh, env, fnCall: `issue_satisfaction_detail ${issueNum}` });
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

test("is_issue_satisfied: accepts CLOSED + stateReason=COMPLETED when RALPH_ACCEPT_MANUALLY_CLOSED=1", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    env: { RALPH_ACCEPT_MANUALLY_CLOSED: "1" },
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED","stateReason":"COMPLETED"}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "1");
});

test("is_issue_satisfied: rejects CLOSED + stateReason=NOT_PLANNED even when RALPH_ACCEPT_MANUALLY_CLOSED=1", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    env: { RALPH_ACCEPT_MANUALLY_CLOSED: "1" },
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED","stateReason":"NOT_PLANNED"}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0");
});

test("is_issue_satisfied: rejects CLOSED with missing stateReason even when RALPH_ACCEPT_MANUALLY_CLOSED=1", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    env: { RALPH_ACCEPT_MANUALLY_CLOSED: "1" },
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

test("is_issue_satisfied: ignores stateReason=COMPLETED when RALPH_ACCEPT_MANUALLY_CLOSED is unset (default-strict)", () => {
  const r = runIsIssueSatisfied({
    issueNum: 42,
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED","stateReason":"COMPLETED"}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0");
});

test("issue_satisfaction_detail: emits satisfied|state|reason|prs for satisfied (merged PR) blocker", () => {
  const r = runIssueSatisfactionDetail({
    issueNum: 42,
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[{"number":99},{"number":100}],"state":"CLOSED","stateReason":"COMPLETED"}\\n'
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
  assert.equal(r.stdout.trim(), "1|CLOSED|COMPLETED|99,100");
});

test("issue_satisfaction_detail: emits 0|state|reason|prs for unsatisfied open blocker", () => {
  const r = runIssueSatisfactionDetail({
    issueNum: 42,
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"OPEN","stateReason":""}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0|OPEN||");
});

test("issue_satisfaction_detail: emits comma-joined prs even with multiple references (single-line invariant)", () => {
  const r = runIssueSatisfactionDetail({
    issueNum: 42,
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[{"number":1},{"number":2},{"number":3}],"state":"CLOSED","stateReason":"COMPLETED"}\\n'
    ;;
  "pr view")
    printf 'null\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  // Three PRs were referenced; none were merged. Detail should still capture all three on one line.
  const out = r.stdout.trim();
  assert.match(out, /^0\|CLOSED\|COMPLETED\|1,2,3$/, `got: ${out}`);
});

test("is_issue_satisfied: RALPH_ACCEPT_MANUALLY_CLOSED=false is treated as disabled (strict-1 match)", () => {
  // Direct state.sh callers that don't run through ralph.sh's normalize_bool
  // must still see the fallback as disabled when the variable is set to a
  // common falsy string. Otherwise `[[ -n "$X" ]]` would foot-gun.
  const r = runIsIssueSatisfied({
    issueNum: 42,
    env: { RALPH_ACCEPT_MANUALLY_CLOSED: "false" },
    gh: `
case "$1 $2" in
  "issue view")
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED","stateReason":"COMPLETED"}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "0");
});

test("issue_satisfaction_detail: retries without stateReason when older gh rejects the field", () => {
  // Old `gh` (<2.13) doesn't recognise `stateReason` in --json. Our code
  // must retry without the field so the strict merged-PR path still works;
  // the manual-close fallback simply cannot fire because state_reason is "".
  const r = runIssueSatisfactionDetail({
    issueNum: 42,
    env: { RALPH_ACCEPT_MANUALLY_CLOSED: "1" },
    gh: `
# Track how often each --json variant was requested via the gh.log.
flags=""
for arg in "$@"; do flags="$flags $arg"; done
if [[ "$flags" == *"stateReason"* ]]; then
  echo "Unknown JSON field: 'stateReason'" >&2
  exit 1
fi
case "$1 $2" in
  "issue view")
    # Only the retry (no stateReason) returns valid JSON. closedBy is empty
    # but a merged PR is reachable via the regular merged-PR path? No — we
    # want to assert that the retry path survives and still produces a
    # parseable detail line even when the manual-close fallback can't fire.
    printf '{"closedByPullRequestsReferences":[],"state":"CLOSED"}\\n'
    ;;
  *)
    echo "unexpected: $*" >&2; exit 2 ;;
esac
`,
  });
  assert.equal(r.status, 0, r.stderr);
  // Without stateReason support the issue cannot be satisfied via the manual
  // fallback (state_reason is empty), but the function must still emit a
  // well-formed detail line — not the all-empty `0|||` "closure failed" sentinel.
  assert.equal(r.stdout.trim(), "0|CLOSED||");
});

// ----------------------------------------------------------------------------
// normalize_bool — keeps RALPH_* boolean flags from foot-gunning. Pre-fix,
// `[[ -n "$RALPH_X" ]]` would treat `RALPH_X=false` as enabled.
// ----------------------------------------------------------------------------

function runNormalizeBool(value) {
  const result = spawnSync(
    "bash",
    [
      "-c",
      `. ${JSON.stringify(lib)}; normalize_bool ${JSON.stringify(value)}`,
    ],
    { encoding: "utf8" },
  );
  return { stdout: result.stdout.trim(), stderr: result.stderr, status: result.status };
}

test("normalize_bool: accepts truthy variants → 1", () => {
  for (const truthy of ["1", "true", "TRUE", "True", "yes", "YES", "on", "ON"]) {
    const r = runNormalizeBool(truthy);
    assert.equal(r.status, 0, `value ${truthy}: ${r.stderr}`);
    assert.equal(r.stdout, "1", `value ${truthy}`);
  }
});

test("normalize_bool: accepts falsy variants → empty", () => {
  for (const falsy of ["0", "false", "FALSE", "False", "no", "NO", "off", "OFF", ""]) {
    const r = runNormalizeBool(falsy);
    assert.equal(r.status, 0, `value ${falsy}: ${r.stderr}`);
    assert.equal(r.stdout, "", `value ${falsy}`);
  }
});

test("normalize_bool: rejects unknown values with non-zero exit", () => {
  const r = runNormalizeBool("maybe");
  assert.notEqual(r.status, 0, "non-bool value should exit non-zero");
  assert.match(r.stderr, /normalize_bool/);
});

// ----------------------------------------------------------------------------
// count_claimed_issues — counts non-empty issue-number lines so the idle
// message reports `claimed=0` when state.json has no claims (was `claimed=1`
// because `echo "" | wc -l` returns 1).
// ----------------------------------------------------------------------------

function runCountClaimedIssues(input) {
  const result = spawnSync(
    "bash",
    [
      "-c",
      `. ${JSON.stringify(lib)}; count_claimed_issues`,
    ],
    { encoding: "utf8", input },
  );
  return { stdout: result.stdout.trim(), stderr: result.stderr, status: result.status };
}

test("count_claimed_issues: empty string → 0", () => {
  const r = runCountClaimedIssues("");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "0");
});

test("count_claimed_issues: whitespace-only → 0", () => {
  const r = runCountClaimedIssues("   \n\t\n  ");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "0");
});

test("count_claimed_issues: single number → 1", () => {
  const r = runCountClaimedIssues("125");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "1");
});

test("count_claimed_issues: multiple numbers, one per line → matching count", () => {
  const r = runCountClaimedIssues("125\n126\n127");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "3");
});
