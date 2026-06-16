import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { runGithubPreflight, checkGithubAuth } from "../extension/lib/github-preflight.mjs";

// A scripted runCommand: maps a key (command + first args) to a result.
function makeRunner(overrides = {}) {
  const calls = [];
  const ok = { exitCode: 0, stdout: "", stderr: "" };
  const defaults = {
    "gh auth status": { exitCode: 0, stdout: "Logged in to github.com", stderr: "" },
    "gh api user": { exitCode: 0, stdout: "octocat", stderr: "" },
    "gh api graphql": { exitCode: 0, stdout: '{"data":{"viewer":{"login":"octocat"}}}', stderr: "" },
    "gh issue list": { exitCode: 0, stdout: "[]", stderr: "" },
  };
  const table = { ...defaults, ...overrides };
  const runCommand = (command, args = []) => {
    calls.push([command, ...args]);
    const key2 = `${command} ${args[0] ?? ""}`.trim();
    const key3 = `${command} ${args[0] ?? ""} ${args[1] ?? ""}`.trim();
    if (Object.prototype.hasOwnProperty.call(table, key3)) return table[key3];
    if (Object.prototype.hasOwnProperty.call(table, key2)) return table[key2];
    return ok;
  };
  return { runCommand, calls };
}

describe("runGithubPreflight", () => {
  it("passes when auth, REST, GraphQL, and repo reads all succeed", () => {
    const { runCommand } = makeRunner();
    const result = runGithubPreflight({
      repos: [{ owner: "tjegbejimba", name: "ralph-loop-dashboard" }],
      runCommand,
    });
    assert.equal(result.ok, true);
    assert.equal(result.login, "octocat");
    assert.equal(result.error, null);
    assert.ok(result.checks.every((c) => c.ok));
    assert.ok(result.checks.some((c) => c.id === "repo-read:tjegbejimba/ralph-loop-dashboard"));
  });

  it("resolves the login from gh api user", () => {
    const { runCommand } = makeRunner({ "gh api user": { exitCode: 0, stdout: "  dj-tj  ", stderr: "" } });
    const result = runGithubPreflight({ runCommand });
    assert.equal(result.login, "dj-tj");
  });

  it("fails loud when gh auth status fails", () => {
    const { runCommand } = makeRunner({
      "gh auth status": { exitCode: 1, stdout: "", stderr: "not logged in" },
    });
    const result = runGithubPreflight({ runCommand });
    assert.equal(result.ok, false);
    assert.match(result.error, /gh auth status/);
    assert.match(result.error, /not logged in/);
    const authCheck = result.checks.find((c) => c.id === "gh-auth-status");
    assert.equal(authCheck.ok, false);
  });

  it("fails when REST api.github.com is unreachable", () => {
    const { runCommand } = makeRunner({
      "gh api user": { exitCode: 1, stdout: "", stderr: "dial tcp: connect: connection refused" },
    });
    const result = runGithubPreflight({ runCommand });
    assert.equal(result.ok, false);
    assert.equal(result.login, null);
    assert.match(result.error, /REST api\.github\.com/);
  });

  it("fails when GraphQL api.github.com is unreachable", () => {
    const { runCommand } = makeRunner({
      "gh api graphql": { exitCode: 1, stdout: "", stderr: "Post https://api.github.com/graphql: connection refused" },
    });
    const result = runGithubPreflight({ runCommand });
    assert.equal(result.ok, false);
    assert.match(result.error, /GraphQL api\.github\.com/);
  });

  it("fails when a target repo cannot be read", () => {
    const { runCommand } = makeRunner({
      "gh issue list": { exitCode: 1, stdout: "", stderr: "HTTP 403: Resource not accessible" },
    });
    const result = runGithubPreflight({ repos: ["octocat/secret"], runCommand });
    assert.equal(result.ok, false);
    assert.match(result.error, /Cannot read octocat\/secret/);
    const probe = result.checks.find((c) => c.id === "repo-read:octocat/secret");
    assert.equal(probe.ok, false);
  });

  it("treats a missing login as a REST failure even on exit 0", () => {
    const { runCommand } = makeRunner({ "gh api user": { exitCode: 0, stdout: "", stderr: "" } });
    const result = runGithubPreflight({ runCommand });
    assert.equal(result.ok, false);
    assert.equal(result.login, null);
  });

  it("aggregates multiple failing checks into one error message", () => {
    const { runCommand } = makeRunner({
      "gh auth status": { exitCode: 1, stdout: "", stderr: "no token" },
      "gh api graphql": { exitCode: 1, stdout: "", stderr: "refused" },
    });
    const result = runGithubPreflight({ runCommand });
    assert.equal(result.ok, false);
    assert.match(result.error, /2 checks/);
  });
});

describe("checkGithubAuth", () => {
  it("delegates to the injected runner and returns its shape", () => {
    let received = null;
    const runCommand = (command, args) => {
      received = [command, ...args];
      return { exitCode: 0, stdout: "ok", stderr: "" };
    };
    const result = checkGithubAuth(runCommand);
    assert.deepEqual(received, ["gh", "auth", "status"]);
    assert.deepEqual(result, { exitCode: 0, stdout: "ok", stderr: "" });
  });
});
