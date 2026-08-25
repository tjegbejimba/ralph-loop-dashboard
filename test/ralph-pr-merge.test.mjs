import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";

const helper = resolve("ralph/lib/pr-merge.sh");
const expectedSha = "0123456789abcdef0123456789abcdef01234567";
const expectedBranch = "mu-13-something";
const expectedAuthor = "trusted-user";

function runHelper(
  fakeGhBody,
  invocation = `ralph_merge_ready_open_pr_for_issue 13 main ${expectedBranch} ${expectedSha} ${expectedAuthor}`,
  fakeGitBody = 'echo "unexpected git call: $*" >&2; exit 2',
) {
  const dir = mkdtempSync(join(tmpdir(), "ralph-pr-merge-"));
  const gh = join(dir, "gh");
  const ghLog = join(dir, "gh.log");
  const gitLog = join(dir, "git.log");
  writeFileSync(
    gh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> ${JSON.stringify(ghLog)}
${fakeGhBody}
`,
    { mode: 0o755 },
  );
  const result = spawnSync(
    "bash",
    [
      "-c",
      `git() {
  printf '%s\\n' "$*" >> ${JSON.stringify(gitLog)}
  ${fakeGitBody}
}
. ${JSON.stringify(helper)}; REPO=owner/repo; ${invocation}`,
    ],
    {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH || ""}` },
      encoding: "utf8",
    },
  );
  const readLog = (path) => {
    try {
      return readFileSync(path, "utf8");
    } catch (e) {
      if (e.code === "ENOENT") return "";
      throw e;
    }
  };
  return { result, calls: readLog(ghLog), gitCalls: readLog(gitLog) };
}

test("merge fallback squashes a linked open PR when checks are green", () => {
  const { result, calls } = runHelper(`
if [[ "$1 $2" == "pr list" ]]; then
  printf '23\\tfalse\\tmain\\tMERGEABLE\\t${expectedBranch}\\t${expectedSha}\\towner/repo\\t${expectedAuthor}\\t\\n'
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
  assert.match(calls, new RegExp(`--match-head-commit ${expectedSha}`));
});

test("merge fallback does not merge when checks are still pending", () => {
  const { result, calls } = runHelper(`
if [[ "$1 $2" == "pr list" ]]; then
  printf '23\\tfalse\\tmain\\tMERGEABLE\\t${expectedBranch}\\t${expectedSha}\\towner/repo\\t${expectedAuthor}\\t\\n'
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

test("merge fallback rejects a PR with no checks", () => {
  const { result, calls } = runHelper(`
if [[ "$1 $2" == "pr list" ]]; then
  printf '23\\tfalse\\tmain\\tMERGEABLE\\t${expectedBranch}\\t${expectedSha}\\towner/repo\\t${expectedAuthor}\\t\\n'
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

  assert.equal(result.status, 1, result.stderr);
  assert.doesNotMatch(calls, /pr merge/);
});

// -- Release-branch fallback --------------------------------------------------

test("release-branch fallback merges + closes when PR body has Closes #N and checks pass", () => {
  const { result, calls } = runHelper(
    `
if [[ "$1 $2" == "pr list" ]]; then
  # Emit the provenance fields selected by the helper's gh --jq expression.
  printf '42\\tfalse\\tmulti-user\\tMERGEABLE\\t${expectedBranch}\\t${expectedSha}\\towner/repo\\t${expectedAuthor}\\tCloses #13\\n'
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
    `ralph_merge_release_branch_pr_for_issue 13 multi-user ${expectedBranch} ${expectedSha} ${expectedAuthor}`,
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(calls, /pr merge 42 --repo owner\/repo --squash --delete-branch/);
  assert.match(calls, new RegExp(`--match-head-commit ${expectedSha}`));
  assert.match(calls, /issue close 13 --repo owner\/repo --reason completed/);
});

test("release-branch fallback does not merge when checks are pending", () => {
  const { result, calls } = runHelper(
    `
if [[ "$1 $2" == "pr list" ]]; then
  printf '42\\tfalse\\tmulti-user\\tMERGEABLE\\t${expectedBranch}\\t${expectedSha}\\towner/repo\\t${expectedAuthor}\\tCloses #13\\n'
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
    `ralph_merge_release_branch_pr_for_issue 13 multi-user ${expectedBranch} ${expectedSha} ${expectedAuthor}`,
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
    `ralph_merge_release_branch_pr_for_issue 13 "" ${expectedBranch} ${expectedSha} ${expectedAuthor}`,
  );

  assert.equal(result.status, 1, result.stderr);
  assert.equal(calls.trim(), "", "gh must not be invoked when release_branch is empty");
});

// -- Branch-only fallback (no PR exists yet) ----------------------------------

test("branch-only fallback opens a PR for the approved pushed branch", () => {
  const { result, calls, gitCalls } = runHelper(
    `
case "$1 $2" in
  "api repos/owner/repo/commits/${expectedSha}")
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
    `ralph_open_pr_for_pushed_branch 13 multi-user mu- ${expectedBranch} ${expectedSha}`,
    `printf '${expectedSha}\\trefs/heads/${expectedBranch}\\n'`,
  );

  assert.equal(result.status, 0, result.stderr);
  assert.equal(gitCalls.trim(), `ls-remote --heads origin refs/heads/${expectedBranch}`);
  assert.match(calls, /pr create --repo owner\/repo --base multi-user --head mu-13-something/);
  assert.match(calls, /--title feat: do the thing/);
});

test("branch-only fallback no-ops when prefix is empty", () => {
  const { result, calls } = runHelper(
    `
echo "should not be called: $*" >&2
exit 99
`,
    `ralph_open_pr_for_pushed_branch 13 multi-user "" ${expectedBranch} ${expectedSha}`,
  );

  assert.equal(result.status, 1, result.stderr);
  assert.equal(calls.trim(), "", "gh must not be invoked when branch_prefix is empty");
});

test("branch-only fallback no-ops when the approved branch is not pushed", () => {
  const { result, calls, gitCalls } = runHelper(
    `
echo "unexpected gh call: $*" >&2
exit 2
`,
    `ralph_open_pr_for_pushed_branch 13 multi-user mu- ${expectedBranch} ${expectedSha}`,
    "printf ''",
  );

  assert.equal(result.status, 1, result.stderr);
  assert.equal(gitCalls.trim(), `ls-remote --heads origin refs/heads/${expectedBranch}`);
  assert.doesNotMatch(calls, /pr create/);
});

test("branch-only fallback rejects a pushed branch at an unapproved SHA", () => {
  const { result, calls } = runHelper(
    `
echo "unexpected gh call: $*" >&2
exit 2
`,
    `ralph_open_pr_for_pushed_branch 13 multi-user mu- ${expectedBranch} ${expectedSha}`,
    "printf '1111111111111111111111111111111111111111\\trefs/heads/mu-13-something\\n'",
  );

  assert.equal(result.status, 1, result.stderr);
  assert.doesNotMatch(calls, /pr create/);
});
