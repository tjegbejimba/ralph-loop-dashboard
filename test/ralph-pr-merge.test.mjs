import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";

const helper = resolve("ralph/lib/pr-merge.sh");

function runHelper(fakeGhBody, invocation = "ralph_merge_ready_open_pr_for_issue 13 main") {
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
      `. ${JSON.stringify(helper)}; REPO=owner/repo; ${invocation}`,
    ],
    {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH || ""}` },
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

// -- Release-branch fallback --------------------------------------------------

test("release-branch fallback merges + closes when PR body has Closes #N and checks pass", () => {
  const { result, calls } = runHelper(
    `
if [[ "$1 $2" == "pr list" ]]; then
  # gh pr list ... --json number,isDraft,baseRefName,mergeable,body --jq '...'
  printf '42\\tfalse\\tmulti-user\\tMERGEABLE\\n'
elif [[ "$1 $2" == "pr checks" ]]; then
  printf '[{"bucket":"pass"}]\\n'
elif [[ "$1 $2" == "pr merge" ]]; then
  exit 0
elif [[ "$1 $2" == "issue close" ]]; then
  exit 0
else
  echo "unexpected gh call: $*" >&2
  exit 2
fi
`,
    "ralph_merge_release_branch_pr_for_issue 13 multi-user",
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(calls, /pr merge 42 --repo owner\/repo --squash --delete-branch/);
  assert.match(calls, /issue close 13 --repo owner\/repo --reason completed/);
});

test("release-branch fallback does not merge when checks are pending", () => {
  const { result, calls } = runHelper(
    `
if [[ "$1 $2" == "pr list" ]]; then
  printf '42\\tfalse\\tmulti-user\\tMERGEABLE\\n'
elif [[ "$1 $2" == "pr checks" ]]; then
  printf '[{"bucket":"pending"}]\\n'
  exit 8
elif [[ "$1 $2" == "pr merge" ]]; then
  exit 99
elif [[ "$1 $2" == "issue close" ]]; then
  exit 99
else
  echo "unexpected gh call: $*" >&2
  exit 2
fi
`,
    "ralph_merge_release_branch_pr_for_issue 13 multi-user",
  );

  assert.equal(result.status, 1, result.stderr);
  assert.doesNotMatch(calls, /pr merge/);
  assert.doesNotMatch(calls, /issue close/);
});

test("release-branch fallback no-ops when release_branch is empty", () => {
  const { result, calls } = runHelper(
    `
echo "should not be called: $*" >&2
exit 99
`,
    'ralph_merge_release_branch_pr_for_issue 13 ""',
  );

  assert.equal(result.status, 1, result.stderr);
  assert.equal(calls.trim(), "", "gh must not be invoked when release_branch is empty");
});

// -- Branch-only fallback (no PR exists yet) ----------------------------------

test("branch-only fallback opens a PR for a pushed `${prefix}${N}-…` branch", () => {
  const { result, calls } = runHelper(
    `
case "$1 $2" in
  "api repos/owner/repo/branches")
    # Paginated branches listing — return one matching branch.
    printf 'mu-13-something\\n'
    ;;
  "api repos/owner/repo/branches/mu-13-something")
    printf 'abc123\\n'
    ;;
  "api repos/owner/repo/commits/abc123")
    printf 'feat: do the thing\\n'
    ;;
  "pr create")
    exit 0
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 2
    ;;
esac
`,
    "ralph_open_pr_for_pushed_branch 13 multi-user mu-",
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(calls, /pr create --repo owner\/repo --base multi-user --head mu-13-something/);
  assert.match(calls, /--title feat: do the thing/);
});

test("branch-only fallback no-ops when prefix is empty", () => {
  const { result, calls } = runHelper(
    `
echo "should not be called: $*" >&2
exit 99
`,
    'ralph_open_pr_for_pushed_branch 13 multi-user ""',
  );

  assert.equal(result.status, 1, result.stderr);
  assert.equal(calls.trim(), "", "gh must not be invoked when branch_prefix is empty");
});

test("branch-only fallback no-ops when no matching branch exists", () => {
  const { result, calls } = runHelper(
    `
case "$1 $2" in
  "api repos/owner/repo/branches")
    # No branches match the prefix — return empty.
    printf ''
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 2
    ;;
esac
`,
    "ralph_open_pr_for_pushed_branch 13 multi-user mu-",
  );

  assert.equal(result.status, 1, result.stderr);
  assert.doesNotMatch(calls, /pr create/);
});
