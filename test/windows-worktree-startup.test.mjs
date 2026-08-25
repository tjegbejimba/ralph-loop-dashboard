import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { launchRun } from "../extension/lib/shell-launcher.mjs";
import { resolveBashExe } from "../extension/lib/platform-shim.mjs";

const sourceRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

function git(cwd, ...args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

test("native Windows launch registers a worker from a linked worktree", {
  skip: process.platform !== "win32" ? "requires native Windows" : false,
}, async () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "ralph-windows-worktree-"));
  const mainRepo = join(fixtureRoot, "main");
  const originRepo = join(fixtureRoot, "origin.git");
  const coordinatorRepo = join(fixtureRoot, "coordinator");
  const loopRepo = join(fixtureRoot, "worker");
  const ralphDir = join(coordinatorRepo, ".ralph");
  const runId = "windows-worktree-startup";
  const runDir = join(ralphDir, "runs", runId);
  const statusPath = join(runDir, "status.json");
  const previousLoopRepo = process.env.RALPH_LOOP_REPO;

  try {
    mkdirSync(mainRepo, { recursive: true });
    execFileSync("git", ["init", "--bare", originRepo], { stdio: "ignore" });
    git(mainRepo, "init");
    git(mainRepo, "checkout", "-b", "main");
    git(mainRepo, "config", "user.email", "ralph-fixture@example.invalid");
    git(mainRepo, "config", "user.name", "Ralph Fixture");
    writeFileSync(join(mainRepo, "README.md"), "safe Windows worktree fixture\n", "utf8");
    git(mainRepo, "add", "README.md");
    git(mainRepo, "commit", "-m", "fixture");
    git(mainRepo, "remote", "add", "origin", originRepo);
    git(mainRepo, "push", "-u", "origin", "main");
    git(mainRepo, "worktree", "add", "-b", "coordinator", coordinatorRepo, "main");
    const baseCommit = git(coordinatorRepo, "rev-parse", "HEAD");

    mkdirSync(join(ralphDir, "lib"), { recursive: true });
    mkdirSync(runDir, { recursive: true });
    copyFileSync(join(sourceRoot, "ralph", "launch.sh"), join(ralphDir, "launch.sh"));
    copyFileSync(join(sourceRoot, "ralph", "lib", "state.sh"), join(ralphDir, "lib", "state.sh"));
    writeFileSync(
      join(ralphDir, "ralph.sh"),
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "printf '{\"items\":{\"42\":{\"status\":\"running\",\"workerId\":1,\"pid\":%s}}}\\n' \"$$\" > \"$RALPH_RUN_DIR/status.json\"",
        "sleep 1",
        "",
      ].join("\n"),
      "utf8",
    );
    chmodSync(join(ralphDir, "ralph.sh"), 0o755);
    writeFileSync(statusPath, '{"items":{}}\n', "utf8");
    process.env.RALPH_LOOP_REPO = loopRepo;

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: coordinatorRepo,
      runOptions: {
        runMode: "until-empty",
        parallelism: 1,
        model: "gpt-5.6-sol",
      },
      base: {
        remote: "origin",
        branch: "main",
        commit: baseCommit,
      },
      isWindows: true,
      resolveBash: resolveBashExe,
      confirmStarted: async () => {
        try {
          const status = JSON.parse(readFileSync(statusPath, "utf8"));
          return status.items?.["42"]?.status === "running";
        } catch (error) {
          if (error instanceof SyntaxError) return false;
          throw error;
        }
      },
      startupTimeoutMs: 12000,
      startupPollMs: 25,
    });

    assert.equal(result.success, true, result.error);
    assert.equal(existsSync(loopRepo), true, "worker worktree should be created");
    const status = JSON.parse(readFileSync(statusPath, "utf8"));
    assert.equal(status.items?.["42"]?.status, "running");
  } finally {
    if (previousLoopRepo === undefined) delete process.env.RALPH_LOOP_REPO;
    else process.env.RALPH_LOOP_REPO = previousLoopRepo;
    await new Promise((resolve) => setTimeout(resolve, 1200));
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});
