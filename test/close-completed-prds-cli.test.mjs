// CLI-level integration tests for `orchestrate-repo --close-completed-prds`.
//
// Fix 3: the close path MUST enforce the same orchestrateAllowedRepoRoots
// allowlist as the launch path (resolveOrchestrateRepoRoot). An operator-supplied
// --repo-root that is NOT the extension's trusted default and NOT in the
// allowlist must hard-stop with a nonzero exit BEFORE any gh mutation. These
// tests spawn the real CLI with:
//   - a stub `gh` on PATH that logs every invocation (to prove zero calls on
//     reject), and
//   - HOME pointed at a temp dir so loadUserConfig reads OUR allowlist.

import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";

const cli = resolve("extension/cli.mjs");

// Build a sandbox: a temp HOME with a dashboard config, a target repo checkout
// with .ralph/config.json, and a stub gh on PATH that records its calls.
function sandbox({ allowlist = [], ghBody = "echo '[]'" } = {}) {
  const root = mkdtempSync(join(tmpdir(), "close-prds-cli-"));

  const home = join(root, "home");
  mkdirSync(join(home, ".ralph-dashboard"), { recursive: true });
  writeFileSync(
    join(home, ".ralph-dashboard", "config.json"),
    JSON.stringify({ orchestrateAllowedRepoRoots: allowlist }),
  );

  const repo = join(root, "target-repo");
  mkdirSync(join(repo, ".ralph"), { recursive: true });
  writeFileSync(
    join(repo, ".ralph", "config.json"),
    JSON.stringify({ repo: "octo/alisterr" }),
  );

  const binDir = join(root, "bin");
  mkdirSync(binDir, { recursive: true });
  const ghLog = join(root, "gh.log");
  writeFileSync(
    join(binDir, "gh"),
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >> ${JSON.stringify(ghLog)}
${ghBody}
`,
    { mode: 0o755 },
  );

  return { root, home, repo, binDir, ghLog };
}

function runCli(args, { home, binDir }) {
  return spawnSync("node", [cli, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      PATH: `${binDir}:${process.env.PATH || ""}`,
    },
  });
}

function ghCalls(ghLog) {
  if (!existsSync(ghLog)) return "";
  return readFileSync(ghLog, "utf8");
}

test("close path: non-allowlisted --repo-root hard-stops with zero gh calls", () => {
  const sb = sandbox({ allowlist: [] }); // empty allowlist → override rejected
  const result = runCli(
    ["orchestrate-repo", "--close-completed-prds", "--repo-root", sb.repo, "--dry-run"],
    sb,
  );

  assert.notEqual(result.status, 0, "must exit nonzero on a non-allowlisted target");
  assert.match(result.stderr, /orchestrateAllowedRepoRoots/);
  assert.equal(ghCalls(sb.ghLog).trim(), "", "gh must NOT be invoked when the target is rejected");
});

test("close path: allowlisted --repo-root proceeds to the (read-only) gh discovery", () => {
  // Pre-resolve the target path, then allowlist it. Build the sandbox so its
  // dashboard config lists the resolved repo path.
  const root = mkdtempSync(join(tmpdir(), "close-prds-cli-ok-"));
  const home = join(root, "home");
  const repo = join(root, "target-repo");
  const binDir = join(root, "bin");
  const ghLog = join(root, "gh.log");
  mkdirSync(join(home, ".ralph-dashboard"), { recursive: true });
  mkdirSync(join(repo, ".ralph"), { recursive: true });
  mkdirSync(binDir, { recursive: true });
  writeFileSync(
    join(home, ".ralph-dashboard", "config.json"),
    JSON.stringify({ orchestrateAllowedRepoRoots: [resolve(repo)] }),
  );
  writeFileSync(join(repo, ".ralph", "config.json"), JSON.stringify({ repo: "octo/alisterr" }));
  writeFileSync(
    join(binDir, "gh"),
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >> ${JSON.stringify(ghLog)}
echo '[]'
`,
    { mode: 0o755 },
  );

  const result = runCli(
    ["orchestrate-repo", "--close-completed-prds", "--repo-root", repo, "--dry-run"],
    { home, binDir },
  );

  assert.equal(result.status, 0, `expected exit 0, got ${result.status}: ${result.stderr}`);
  assert.doesNotMatch(result.stderr, /orchestrateAllowedRepoRoots/);
  // It reached gh discovery (issue list) — at least one read call, and no close.
  const calls = ghCalls(ghLog);
  assert.match(calls, /issue list/);
  assert.doesNotMatch(calls, /issue close/);
});
