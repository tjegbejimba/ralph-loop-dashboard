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
import { resolveBashExe, toBashPath } from "../extension/lib/platform-shim.mjs";

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
    const globalExcludes = join(fixtureRoot, "global-excludes");
    writeFileSync(globalExcludes, "", "utf8");
    git(mainRepo, "config", "core.excludesFile", globalExcludes);
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
        "dirty=\"$(git status --porcelain --untracked-files=normal)\"",
        "[[ -z \"$dirty\" ]] || { printf 'worker worktree is dirty:\\n%s\\n' \"$dirty\" >&2; exit 1; }",
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
      startupTimeoutMs: 30000,
      startupPollMs: 25,
    });

    assert.equal(result.success, true, result.error);
    assert.equal(existsSync(loopRepo), true, "worker worktree should be created");
    const excludePath = git(coordinatorRepo, "rev-parse", "--git-path", "info/exclude");
    assert.match(readFileSync(excludePath, "utf8"), /^\.ralph$/m);
    const status = JSON.parse(readFileSync(statusPath, "utf8"));
    assert.equal(status.items?.["42"]?.status, "running");
  } finally {
    if (previousLoopRepo === undefined) delete process.env.RALPH_LOOP_REPO;
    else process.env.RALPH_LOOP_REPO = previousLoopRepo;
    await new Promise((resolve) => setTimeout(resolve, 1200));
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test("native Windows startup treats slow worktree checkout output as progress", {
  skip: process.platform !== "win32" ? "requires native Windows timing" : false,
}, async () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "ralph-windows-checkout-progress-"));
  const runId = "windows-slow-worktree";
  const runDir = join(fixtureRoot, ".ralph", "runs", runId);
  const startupPath = join(runDir, "startup.json");
  const startedPath = join(runDir, "started");
  const launcherLog = join(runDir, "launcher.log");
  const launchScript = join(fixtureRoot, "slow-worktree.sh");
  const checkoutSamples = [];
  let observedCheckoutLines = 0;
  let observer;

  try {
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      launchScript,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'exec >> "$RALPH_LAUNCH_LOG" 2>&1',
        `printf '%s\\n' '{"sequence":1,"phase":"worktree-checkout"}' > '${toBashPath(startupPath)}'`,
        "for progress in 10 20 30 40 50; do",
        "  printf 'Updating files: %s%%\\n' \"$progress\"",
        "  sleep 1",
        "done",
        `touch '${toBashPath(startedPath)}'`,
        "",
      ].join("\n"),
      "utf8",
    );
    chmodSync(launchScript, 0o755);
    observer = setInterval(() => {
      if (!existsSync(launcherLog)) return;
      const checkoutLines = readFileSync(launcherLog, "utf8")
        .split(/\r?\n/)
        .filter((line) => line.startsWith("Updating files:")).length;
      if (checkoutLines <= observedCheckoutLines) return;
      observedCheckoutLines = checkoutLines;
      checkoutSamples.push(readFileSync(startupPath, "utf8"));
    }, 50);

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: fixtureRoot,
      runOptions: { runMode: "until-empty", parallelism: 1, model: "fixture-model" },
      shellScript: launchScript,
      isWindows: true,
      resolveBash: resolveBashExe,
      confirmStarted: async () => existsSync(startedPath),
      startupTimeoutMs: 3500,
      startupMaxTimeoutMs: 20000,
      startupPollMs: 25,
    });

    assert.ok(checkoutSamples.length >= 3, "fixture must emit repeated checkout progress");
    assert.equal(new Set(checkoutSamples).size, 1, "startup.json must stay unchanged during checkout");
    assert.equal(result.success, true, result.error);
  } finally {
    clearInterval(observer);
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});
