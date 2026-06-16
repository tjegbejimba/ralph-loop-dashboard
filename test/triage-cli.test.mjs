import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, mkdirSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const CLI = join(import.meta.dirname, "..", "extension", "cli.mjs");

// Builds a fake `gh` that satisfies the github-preflight probes and the triage
// command's own gh calls. Behaviour is tuned via options so each test can
// exercise a different failure mode.
function writeTriageGh(root, {
  issues = [],
  comments = [],
  authStatusExit = 0,
  apiUserExit = 0,
  apiUserLogin = "octocat",
  commentsExit = 0,
} = {}) {
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  const commentLog = join(root, "gh-comments.log");
  const gh = join(bin, "gh");
  writeFileSync(gh, `#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
const issues = ${JSON.stringify(issues)};
const comments = ${JSON.stringify(comments)};
function isGraphqlEnrichment() { return args.some((a) => String(a).startsWith("owner=")); }
function isGraphqlUpdate() { return args.includes("--input"); }
if (args[0] === "auth" && args[1] === "status") {
  if (${authStatusExit} !== 0) { process.stderr.write("not authenticated"); process.exit(${authStatusExit}); }
  process.stdout.write("Logged in");
} else if (args[0] === "api" && args[1] === "user") {
  if (${apiUserExit} !== 0) { process.stderr.write("connection refused"); process.exit(${apiUserExit}); }
  process.stdout.write(${JSON.stringify(apiUserLogin)} + "\\n");
} else if (args[0] === "api" && args[1] === "graphql") {
  if (isGraphqlUpdate()) { process.stdout.write(JSON.stringify({ data: { updateIssueComment: { issueComment: { id: "c1" } } } })); }
  else if (isGraphqlEnrichment()) { process.stdout.write(JSON.stringify({ data: { repository: {} } })); }
  else { process.stdout.write(JSON.stringify({ data: { viewer: { login: "octocat" }, rateLimit: { remaining: 5000 } } })); }
} else if (args[0] === "issue" && args[1] === "list") {
  process.stdout.write(JSON.stringify(issues));
} else if (args[0] === "issue" && args[1] === "view") {
  if (${commentsExit} !== 0) { process.stderr.write("dial tcp: connection refused"); process.exit(${commentsExit}); }
  process.stdout.write(JSON.stringify({ comments }));
} else if (args[0] === "issue" && args[1] === "comment") {
  fs.appendFileSync(${JSON.stringify(commentLog)}, args.join(" ") + "\\n");
  process.stdout.write("");
} else {
  process.stderr.write("unexpected gh args: " + JSON.stringify(args));
  process.exit(1);
}
`);
  chmodSync(gh, 0o755);
  return { bin, commentLog };
}

function runTriage(bin, extraArgs) {
  return spawnSync("node", [CLI, "triage", ...extraArgs], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
    encoding: "utf8",
    timeout: 10_000,
  });
}

const trustedIssue = (number) => ({
  number,
  title: "Prevent unsafe launches",
  body: "Ralph can waste quota.\n\nAcceptance criteria:\n- preflight blocks unsafe launches",
  labels: [{ name: "ralph:needs-triage" }],
  author: { login: "tjegbejimba" },
  assignees: [],
  closedByPullRequestsReferences: [],
});

describe("triage CLI preflight + exit codes", () => {
  it("aborts non-zero with a clear message and no mutations when gh auth fails", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-triage-authfail-"));
    const { bin, commentLog } = writeTriageGh(root, {
      issues: [trustedIssue(101)],
      authStatusExit: 1,
    });
    try {
      const result = runTriage(bin, ["--live", "--repo", "octocat/hello-world"]);
      assert.equal(result.status, 1, `stdout: ${result.stdout}`);
      assert.match(result.stderr, /GitHub preflight failed/);
      assert.match(result.stderr, /gh auth status/);
      assert.equal(existsSync(commentLog), false, "no comments should be written");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("emits a structured preflight failure with --json", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-triage-json-"));
    const { bin } = writeTriageGh(root, { issues: [trustedIssue(101)], apiUserExit: 1 });
    try {
      const result = runTriage(bin, ["--live", "--json", "--repo", "octocat/hello-world"]);
      assert.equal(result.status, 1);
      const payload = JSON.parse(result.stdout);
      assert.equal(payload.ok, false);
      assert.equal(payload.phase, "github-preflight");
      assert.ok(Array.isArray(payload.checks));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("exits 0 with a success outcome on a clean dry-run", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-triage-ok-"));
    const { bin } = writeTriageGh(root, { issues: [trustedIssue(101)], comments: [] });
    try {
      const result = runTriage(bin, ["--dry-run", "--repo", "octocat/hello-world"]);
      assert.equal(result.status, 0, `stderr: ${result.stderr}`);
      assert.match(result.stdout, /Outcome: success/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("reports success_no_eligible_work and exits 0 when nothing is eligible", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-triage-empty-"));
    const { bin } = writeTriageGh(root, { issues: [] });
    try {
      const result = runTriage(bin, ["--dry-run", "--json", "--repo", "octocat/hello-world"]);
      assert.equal(result.status, 0, `stderr: ${result.stderr}`);
      const payload = JSON.parse(result.stdout);
      assert.equal(payload.outcome, "success_no_eligible_work");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("exits non-zero with partial_failure when comment fetches fail", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-triage-partial-"));
    const { bin } = writeTriageGh(root, { issues: [trustedIssue(101)], commentsExit: 1 });
    try {
      const result = runTriage(bin, ["--dry-run", "--json", "--repo", "octocat/hello-world"]);
      assert.equal(result.status, 1, `stdout: ${result.stdout}`);
      const payload = JSON.parse(result.stdout);
      assert.equal(payload.outcome, "partial_failure");
      assert.match(result.stderr, /partial_failure/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("honors an explicit --bot-login over the preflight-resolved login", () => {
    // An existing triage comment authored by "octocat" (the preflight login).
    // With --bot-login set to a different login, that comment is NOT recognized
    // as the bot's own, so triage CREATES a new comment — proving the flag wins.
    const botComment = {
      author: { login: "octocat" },
      body: "old opinion\n\n<!-- ralph-triage-opinion:v1 fingerprint=deadbeef -->",
    };
    const root = mkdtempSync(join(tmpdir(), "ralph-triage-botlogin-"));
    const { bin, commentLog } = writeTriageGh(root, {
      issues: [trustedIssue(101)],
      comments: [botComment],
      apiUserLogin: "octocat",
    });
    try {
      const result = runTriage(bin, [
        "--live",
        "--repo",
        "octocat/hello-world",
        "--bot-login",
        "someone-else",
      ]);
      assert.equal(result.status, 0, `stderr: ${result.stderr}`);
      assert.equal(existsSync(commentLog), true, "a new comment should be created");
      assert.match(readFileSync(commentLog, "utf8"), /issue comment 101/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
