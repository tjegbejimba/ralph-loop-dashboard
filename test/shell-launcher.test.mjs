// Shell launcher module tests — validates detached shell engine launching

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { launchRun } from "../extension/lib/shell-launcher.mjs";
import { isAlive, resolveBashExe, toBashPath } from "../extension/lib/platform-shim.mjs";

async function waitForFile(path, { timeoutMs = 2000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return true;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  return existsSync(path);
}

function resolveTestBash() {
  return process.platform === "win32" ? resolveBashExe() : "/bin/bash";
}

test("launchRun defaults to installed .ralph launcher and passes run environment", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-installed";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };
    const envOut = join(tmpRepo, "env-out.txt");
    const installedDir = join(tmpRepo, ".ralph");
    const installedLauncher = join(installedDir, "launch.sh");
    mkdirSync(installedDir, { recursive: true });
    writeFileSync(
      installedLauncher,
      `#!/usr/bin/env bash\nprintf '%s\\n' "$RALPH_RUN_ID|$RALPH_RUN_DIR|$RALPH_MAIN_REPO|$RALPH_MODEL|$RALPH_PARALLELISM|$RALPH_RUN_MODE|$*" > '${toBashPath(envOut)}'\n`,
      "utf-8"
    );

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
    });

    assert.ok(result.success, result.error);
    const { readFileSync, existsSync } = await import("node:fs");
    assert.equal(await waitForFile(envOut), true, "installed launcher should have run");
    assert.equal(
      readFileSync(envOut, "utf-8").trim(),
      `${runId}|${runDir}|${tmpRepo}|claude-sonnet-4.5|1|until-empty|` +
        (process.platform === "win32" ? "--foreground" : ""),
    );
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun spawns detached process", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-test1234";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    // Mock shell script that exits immediately
    const mockScript = join(tmpRepo, "launch-mock.sh");
    writeFileSync(mockScript, "#!/usr/bin/env bash\necho 'launched'\nexit 0\n", "utf-8");
    
    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: mockScript,
    });
    
    assert.ok(result.success, "Launch should succeed");
    assert.ok(result.pid > 0, "Should return valid PID");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun passes run ID via environment", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-test5678";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    // Mock shell script that captures environment
    const envOut = join(tmpRepo, "env-out.txt");
    const mockScript = join(tmpRepo, "launch-mock.sh");
    writeFileSync(
      mockScript,
      `#!/usr/bin/env bash\necho "$RALPH_RUN_ID" > '${toBashPath(envOut)}'\nexit 0\n`,
      "utf-8"
    );
    
    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: mockScript,
    });
    
    assert.ok(result.success, "Launch should succeed");
    
    // Give process time to write file
    await new Promise(resolve => setTimeout(resolve, 100));
    
    // Verify run ID was passed via environment
    const { readFileSync } = await import("node:fs");
    assert.equal(await waitForFile(envOut), true, "launcher should capture the run ID");
    const capturedRunId = readFileSync(envOut, "utf-8").trim();
    assert.equal(capturedRunId, runId, "Run ID should be passed via RALPH_RUN_ID");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun passes the preflight-approved base via environment", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-base-"));
  try {
    const runId = "20260824-120000-approved-base";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    const base = {
      remote: "upstream",
      branch: "release/v2",
      ref: "upstream/release/v2",
      commit: "0123456789abcdef0123456789abcdef01234567",
    };
    const envOut = join(tmpRepo, "base-env-out.txt");
    const envOutBash = toBashPath(envOut);
    const mockScript = join(tmpRepo, "launch-base-mock.sh");
    writeFileSync(
      mockScript,
      `#!/usr/bin/env bash\nprintf '%s\\n' "$RALPH_BASE_REMOTE|$RALPH_BASE_BRANCH|$RALPH_BASE_COMMIT" > '${envOutBash}'\n`,
      "utf-8",
    );

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: mockScript,
      base,
    });

    assert.ok(result.success, result.error);
    const { readFileSync } = await import("node:fs");
    assert.equal(await waitForFile(envOut), true, "launcher should receive approved base env");
    assert.equal(
      readFileSync(envOut, "utf-8").trim(),
      `${base.remote}|${base.branch}|${base.commit}`,
    );
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun passes --once to launcher for one-pass runs", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-once";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    const argsOut = join(tmpRepo, "args-out.txt");
    const mockScript = join(tmpRepo, "launch-mock.sh");
    writeFileSync(
      mockScript,
      `#!/usr/bin/env bash\nprintf '%s\\n' "$*" > '${toBashPath(argsOut)}'\nexit 0\n`,
      "utf-8"
    );

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: mockScript,
    });

    assert.ok(result.success, result.error);
    const { readFileSync } = await import("node:fs");
    assert.equal(await waitForFile(argsOut), true, "launcher should have received args");
    assert.equal(
      readFileSync(argsOut, "utf-8").trim(),
      process.platform === "win32" ? "--foreground --once" : "--once",
    );
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun returns immediately without blocking", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-test9999";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    // Mock shell script that sleeps for a while (simulates long-running process)
    const mockScript = join(tmpRepo, "launch-mock.sh");
    writeFileSync(mockScript, "#!/usr/bin/env bash\nsleep 5\nexit 0\n", "utf-8");
    
    const startTime = Date.now();
    
    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: mockScript,
    });
    
    const elapsed = Date.now() - startTime;
    
    assert.ok(result.success, "Launch should succeed");
    assert.ok(elapsed < 500, `Launch should return immediately (took ${elapsed}ms)`);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun reports error when script not found", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-test0000";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "one-pass", parallelism: 1, model: "claude-sonnet-4.5" };
    
    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: join(tmpRepo, "nonexistent.sh"),
    });
    
    assert.equal(result.success, false, "Launch should fail");
    assert.ok(result.error, "Should include error message");
    assert.match(result.error, /not found/, "Error should mention script not found");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun rejects an installed launcher without the startup protocol", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-stale-launcher-"));
  try {
    const runId = "20260825-120000-stale-launcher";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    mkdirSync(join(tmpRepo, ".ralph"), { recursive: true });
    writeFileSync(mockScript, "#!/usr/bin/env bash\nexit 0\n", "utf-8");

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions: { runMode: "until-empty", parallelism: 1, model: "fixture-model" },
      confirmStarted: async () => false,
    });

    assert.equal(result.success, false);
    assert.match(result.error, /does not support the controller startup protocol/);
    assert.match(result.error, /Refresh.*Ralph scripts/);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun reports immediate launcher failure instead of spawn success", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-fails";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };
    const mockScript = join(tmpRepo, "launch-fails.sh");
    writeFileSync(mockScript, "#!/usr/bin/env bash\nexit 7\n", "utf-8");

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: mockScript,
      startupTimeoutMs: 3000,
    });

    assert.equal(result.success, false);
    assert.match(result.error, /exited.*7/);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun terminates POSIX launcher when launcher output stalls before confirmation", {
  skip: process.platform === "win32" ? "requires POSIX signal semantics" : false,
}, async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-timeout";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };
    const mockScript = join(tmpRepo, "launch-hangs.sh");
    const killed = [];
    writeFileSync(
      mockScript,
      '#!/usr/bin/env bash\nexec >> "$RALPH_LAUNCH_LOG" 2>&1\necho "checkout started"\nsleep 10\n',
      "utf-8",
    );

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      shellScript: mockScript,
      confirmStarted: async () => false,
      startupTimeoutMs: 50,
      killProcess: (pid, signal) => {
        killed.push({ pid, signal });
        process.kill(pid, signal);
      },
    });

    assert.equal(result.success, false);
    assert.match(result.error, /Timed out waiting/);
    assert.deepEqual(killed, [{ pid: result.pid, signal: "SIGTERM" }]);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun treats advancing setup phases as startup progress", {
  skip: process.platform !== "win32" ? "requires native Windows timing" : false,
}, async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-startup-progress-"));
  try {
    const runId = "20260825-120000-progress";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const startupPath = join(runDir, "startup.json");
    const mockScript = join(tmpRepo, "launch-progress.sh");
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      mockScript,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'exec >> "$RALPH_LAUNCH_LOG" 2>&1',
        `printf '%s\\n' '{"sequence":1,"phase":"prd-ready"}' > '${toBashPath(startupPath)}'`,
        "sleep 1.2",
        `printf '%s\\n' '{"sequence":2,"phase":"worktree-ready"}' > '${toBashPath(startupPath)}'`,
        "sleep 1.2",
        `printf '%s\\n' '{"sequence":3,"phase":"worker-started"}' > '${toBashPath(startupPath)}'`,
        "",
      ].join("\n"),
      "utf-8",
    );

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions: { runMode: "until-empty", parallelism: 1, model: "fixture-model" },
      shellScript: mockScript,
      isWindows: process.platform === "win32",
      resolveBash: resolveTestBash,
      confirmStarted: async () => {
        if (!existsSync(startupPath)) return false;
        const { readFileSync } = await import("node:fs");
        return readFileSync(startupPath, "utf-8").includes('"sequence":3');
      },
      getStartupProgress: async () => {
        if (!existsSync(startupPath)) return null;
        const { readFileSync } = await import("node:fs");
        return readFileSync(startupPath, "utf-8");
      },
      startupTimeoutMs: 2000,
      startupPollMs: 10,
    });
    assert.equal(result.success, true, result.error);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun enforces a hard cap despite continuous startup progress", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-startup-hard-cap-"));
  try {
    const runId = "20260825-120000-hard-cap";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const mockScript = join(tmpRepo, "launch-progress-forever.sh");
    writeFileSync(mockScript, "#!/usr/bin/env bash\nsleep 5\n", "utf-8");
    let sequence = 0;

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions: { runMode: "until-empty", parallelism: 1, model: "fixture-model" },
      shellScript: mockScript,
      isWindows: process.platform === "win32",
      resolveBash: resolveTestBash,
      confirmStarted: async () => false,
      getStartupProgress: async () => String(++sequence),
      startupTimeoutMs: 100,
      startupMaxTimeoutMs: 250,
      startupPollMs: 10,
    });

    assert.equal(result.success, false);
    assert.match(result.error, /hard startup limit/i);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun surfaces diagnostics and removes token-owned setup locks after a Windows timeout", {
  skip: process.platform !== "win32" ? "requires native Windows" : false,
}, async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-windows-timeout-cleanup-"));
  try {
    execFileSync("git", ["init", "--quiet", tmpRepo]);
    const runId = "20260825-120000-timeout-cleanup";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const setupLock = join(tmpRepo, ".ralph", "launch.lock");
    const commonLock = join(tmpRepo, ".git", "ralph-launch.lock");
    const ownershipPath = join(runDir, "ownership.json");
    const childPidPath = join(runDir, "child.pid");
    const childScript = join(runDir, "child.ps1");
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      childScript,
      [
        `[IO.File]::WriteAllText('${childPidPath.replaceAll("'", "''")}', [string]$PID)`,
        "Start-Sleep -Seconds 10",
        "",
      ].join("\n"),
    );
    writeFileSync(
      mockScript,
      [
        "#!/usr/bin/env bash",
        "# RALPH_LAUNCH_PROTOCOL: 1",
        "set -euo pipefail",
        'exec >> "$RALPH_LAUNCH_LOG" 2>&1',
        `setup_lock='${toBashPath(setupLock)}'`,
        `common_lock='${toBashPath(commonLock)}'`,
        `run_dir='${toBashPath(runDir)}'`,
        'mkdir -p "$setup_lock" "$common_lock" "$run_dir"',
        'printf "%s\\n" "${RALPH_LAUNCH_TOKEN:-missing}" > "$setup_lock/token"',
        'printf "%s\\n" "${RALPH_LAUNCH_TOKEN:-missing}" > "$common_lock/token"',
        'trap \'rm -rf "$common_lock" "$setup_lock"\' EXIT',
        'printf "%s\\n" \'{"run_id":"fixture"}\' > "$run_dir/ownership.json"',
        'echo "[fixture-post-ownership] waiting before worker registration" >&2',
        `powershell.exe -NoLogo -NoProfile -File "$(cygpath -w '${toBashPath(childScript)}')" &`,
        "sleep 5",
        "",
      ].join("\n"),
      "utf-8",
    );

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions: { runMode: "until-empty", parallelism: 1, model: "fixture-model" },
      isWindows: true,
      resolveBash: resolveTestBash,
      confirmStarted: async () => false,
      startupTimeoutMs: 1500,
      startupPollMs: 10,
    });

    assert.equal(result.success, false);
    assert.equal(existsSync(ownershipPath), true, "fixture must reach post-ownership setup");
    assert.match(result.error, /\[fixture-post-ownership\]/);
    assert.equal(existsSync(setupLock), false, "per-repo setup lock must be released");
    assert.equal(existsSync(commonLock), false, "common-gitdir setup lock must be released");
    assert.equal(await waitForFile(childPidPath), true, "fixture descendant must start");
    const childPid = Number(readFileSync(childPidPath, "utf-8").trim());
    assert.equal(isAlive(childPid), false, "Windows timeout must terminate launcher descendants");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun writes Windows launcher pidfile for status and stop tracking", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-windows";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    const argsOut = join(tmpRepo, "windows-args.txt");
    mkdirSync(join(tmpRepo, ".ralph"), { recursive: true });
    writeFileSync(
      mockScript,
      `#!/usr/bin/env bash\nprintf '%s\\n' "$*" > '${toBashPath(argsOut)}'\nsleep 1\n`,
      "utf-8",
    );
    chmodSync(mockScript, 0o755);

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      isWindows: true,
      resolveBash: resolveTestBash,
      startupTimeoutMs: 100,
    });

    assert.equal(result.success, true, result.error);
    const pidfile = join(tmpRepo, ".ralph", "launcher.pid");
    assert.equal(existsSync(pidfile), true);
    assert.equal(Number(readFileSync(pidfile, "utf-8")) > 0, true);
    assert.equal(await waitForFile(argsOut), true, "Windows launcher should receive args");
    assert.equal(readFileSync(argsOut, "utf-8").trim(), "--foreground");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun does not replace a live Windows launcher pidfile", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-live-launcher-"));
  try {
    const runId = "20260825-120000-live-launcher";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    const markerPath = join(tmpRepo, "unexpected-launch");
    mkdirSync(join(tmpRepo, ".ralph"), { recursive: true });
    writeFileSync(mockScript, `#!/usr/bin/env bash\ntouch '${toBashPath(markerPath)}'\n`, "utf-8");
    writeFileSync(join(tmpRepo, ".ralph", "launcher.pid"), String(process.pid), "utf-8");

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions: { runMode: "until-empty", parallelism: 1, model: "fixture-model" },
      isWindows: true,
      resolveBash: resolveTestBash,
    });

    assert.equal(result.success, false);
    assert.match(result.error, new RegExp(`already running with PID ${process.pid}`));
    assert.equal(existsSync(markerPath), false);
    assert.equal(
      readFileSync(join(tmpRepo, ".ralph", "launcher.pid"), "utf-8"),
      String(process.pid),
    );
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun starts the repo-local launcher and confirms worker registration on Windows", {
  skip: process.platform !== "win32" ? "requires native Windows" : false,
}, async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-windows-registration-"));
  try {
    const bashExe = resolveBashExe();
    assert.ok(bashExe, "Git Bash must be installed for the native Windows launch test");

    const runId = "20260824-120000-windows-registration";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "fixture-model" };
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    const statePath = join(tmpRepo, ".ralph", "state.json");
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      mockScript,
      [
        "#!/usr/bin/env bash",
        "# RALPH_LAUNCH_PROTOCOL: 1",
        "set -euo pipefail",
        `printf '%s\\n' '{"worker":{"pid":12345}}' > '${toBashPath(statePath)}'`,
        "sleep 2",
        "",
      ].join("\n"),
      "utf-8",
    );

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      isWindows: true,
      resolveBash: () => bashExe,
      confirmStarted: async () => existsSync(statePath),
      startupTimeoutMs: 750,
      startupPollMs: 20,
    });

    assert.equal(result.success, true, result.error);
    assert.equal(existsSync(statePath), true, "worker registration state must be created");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun rejects native Windows parallelism above one", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runOptions = { runMode: "until-empty", parallelism: 2, model: "claude-sonnet-4.5" };
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    mkdirSync(join(tmpRepo, ".ralph"), { recursive: true });
    writeFileSync(mockScript, "#!/usr/bin/env bash\nexit 0\n", "utf-8");

    const result = await launchRun({
      runId: "20260504-120000-windows-parallel",
      runDir: join(tmpRepo, ".ralph", "runs", "20260504-120000-windows-parallel"),
      repoRoot: tmpRepo,
      runOptions,
      isWindows: true,
      resolveBash: resolveTestBash,
    });

    assert.equal(result.success, false);
    assert.match(result.error, /Windows native mode runs one worker/);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun removes Windows pidfile when startup fails", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-windows-fail";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    mkdirSync(join(tmpRepo, ".ralph"), { recursive: true });
    writeFileSync(mockScript, "#!/usr/bin/env bash\nexit 7\n", "utf-8");
    chmodSync(mockScript, 0o755);

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      isWindows: true,
      resolveBash: resolveTestBash,
      startupTimeoutMs: 3000,
    });

    assert.equal(result.success, false);
    assert.match(result.error, /exited.*7/);
    const { existsSync } = await import("node:fs");
    assert.equal(existsSync(join(tmpRepo, ".ralph", "launcher.pid")), false);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun terminates Windows foreground worker when startup confirmation fails", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-windows-timeout";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };
    const mockScript = join(tmpRepo, ".ralph", "launch.sh");
    let killed = null;
    mkdirSync(join(tmpRepo, ".ralph"), { recursive: true });
    writeFileSync(
      mockScript,
      "#!/usr/bin/env bash\n# RALPH_LAUNCH_PROTOCOL: 1\nsleep 5\n",
      "utf-8",
    );
    chmodSync(mockScript, 0o755);

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      isWindows: true,
      resolveBash: resolveTestBash,
      confirmStarted: async () => false,
      startupTimeoutMs: 500,
      startupPollMs: 10,
      killProcess: (pid, signal) => {
        killed = { pid, signal };
        process.kill(pid, signal);
      },
    });

    assert.equal(result.success, false);
    assert.equal(killed?.signal, "SIGTERM");
    assert.equal(Number.isInteger(killed?.pid) && killed.pid > 0, true);
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

test("launchRun validates required parameters", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  const mockScript = join(tmpRepo, "mock.sh");
  writeFileSync(mockScript, "#!/usr/bin/env bash\nexit 0\n", "utf-8");
  
  try {
    await assert.rejects(() => launchRun({}), TypeError, "Should reject missing parameters");
    await assert.rejects(() => launchRun({ runId: "test", runDir: "/tmp", repoRoot: tmpRepo, runOptions: {} }), TypeError, "Should reject empty runOptions");
    await assert.rejects(() => launchRun({ runId: "test", runDir: "/tmp", repoRoot: tmpRepo, runOptions: { model: "test", parallelism: NaN, runMode: "one-pass" } }), TypeError, "Should reject NaN parallelism");
    await assert.rejects(() => launchRun({ runId: "test", runDir: "/tmp", repoRoot: tmpRepo, runOptions: { model: "test", parallelism: 1.5, runMode: "one-pass" } }), TypeError, "Should reject float parallelism");
  } finally {
    rmSync(tmpRepo, { recursive: true, force: true });
  }
});

function seedExactRecoveryFixture() {
  const repoRoot = mkdtempSync(join(tmpdir(), "ralph-exact-recovery-"));
  const worktreePath = `${repoRoot}-worker`;
  const runId = "20260829-002627-229db024";
  const issueNumber = 509;
  const workerId = 1;
  const sessionId = "595b45ce-c350-40b1-8844-a16e4bd5baa9";
  const branch = "slice-509-backlog-parent-hierarchy";
  const prdNumber = 505;
  execFileSync("git", ["init", "--quiet", repoRoot]);
  execFileSync("git", ["-C", repoRoot, "config", "user.email", "test@example.com"]);
  execFileSync("git", ["-C", repoRoot, "config", "user.name", "Test"]);
  writeFileSync(join(repoRoot, "README.md"), "base\n");
  execFileSync("git", ["-C", repoRoot, "add", "README.md"]);
  execFileSync("git", ["-C", repoRoot, "commit", "--quiet", "-m", "base"]);
  const baseCommit = execFileSync("git", ["-C", repoRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  execFileSync("git", ["-C", repoRoot, "worktree", "add", "--quiet", "-b", branch, worktreePath]);
  writeFileSync(join(worktreePath, "README.md"), "preserved dirty work\n");

  const ralphDir = join(repoRoot, ".ralph");
  const runDir = join(ralphDir, "runs", runId);
  const sessionRoot = join(repoRoot, "session-state");
  mkdirSync(join(worktreePath, ".ralph"), { recursive: true });
  mkdirSync(runDir, { recursive: true });
  mkdirSync(join(sessionRoot, sessionId), { recursive: true });
  writeFileSync(join(ralphDir, "state.json"), JSON.stringify({ claims: {}, active_prd: String(prdNumber), active_run_id: runId }));
  writeFileSync(join(runDir, "queue.json"), JSON.stringify([{ number: issueNumber, title: "Slice" }]));
  writeFileSync(join(runDir, "status.json"), JSON.stringify({ items: { [issueNumber]: { status: "failed", workerId, error: "Worker process died" } } }));
  writeFileSync(join(runDir, "ownership.json"), JSON.stringify({ run_id: runId, prd_number: String(prdNumber), initial_base_sha: baseCommit }));
  writeFileSync(join(runDir, "copilot-sessions.jsonl"), `${JSON.stringify({ event: "start", runId, issue: issueNumber, workerId, sessionId, cwd: worktreePath })}\n`);
  writeFileSync(join(sessionRoot, sessionId, "workspace.yaml"), `id: ${sessionId}\ncwd: ${worktreePath}\nname: "Ralph #${issueNumber} w${workerId} ${runId}"\n`);
  const capture = join(repoRoot, "recovery-env.txt");
  writeFileSync(join(worktreePath, ".ralph", "ralph.sh"), `#!/usr/bin/env bash\nprintf '%s\\n' "$PWD|$RALPH_RECOVERY_SESSION_ID|$RALPH_RECOVERY_BRANCH|$RALPH_LOG_DIR|$RALPH_REPO" > '${toBashPath(capture)}'\n`);
  return {
    repoRoot, worktreePath, runId, runDir, sessionRoot, capture,
    recovery: { runId, issueNumber, workerId, sessionId, worktreePath, branch, prdNumber, baseCommit },
    runOptions: { runMode: "one-pass", parallelism: 1, model: "fixture-model" },
  };
}

test("launchRun resumes only an exact registered dirty worker session and revalidates before spawn", async () => {
  const fixture = seedExactRecoveryFixture();
  const priorSessionRoot = process.env.RALPH_COPILOT_SESSION_STATE_DIR;
  process.env.RALPH_COPILOT_SESSION_STATE_DIR = fixture.sessionRoot;
  const issueJson = JSON.stringify({ number: 509, state: "OPEN", labels: [{ name: "ralph:running" }, { name: "work:slice" }] });
  const ghCwds = [];
  const ghCalls = [];
  const recoveryExecFile = (command, args, options) => {
    if (command === "gh") {
      ghCwds.push(options?.cwd);
      ghCalls.push(args);
    }
    if (command === "gh" && args[0] === "repo") return "testowner/testrepo";
    if (command === "gh" && args[0] === "issue") return issueJson;
    if (command === "gh" && args[0] === "pr") return "[]";
    return execFileSync(command, args, { encoding: "utf8" });
  };
  try {
    const result = await launchRun({
      ...fixture,
      recovery: fixture.recovery,
      recoveryExecFile,
      resolveBash: resolveTestBash,
      confirmStarted: async () => true,
    });
    assert.equal(result.success, true, result.error);
    assert.deepEqual([...new Set(ghCwds)], [fixture.repoRoot]);
    assert.equal(ghCalls.filter(([type]) => type === "issue" || type === "pr")
      .every((args) => args.includes("--repo") && args.includes("testowner/testrepo")), true);
    assert.equal(await waitForFile(fixture.capture), true);
    const [actualWorktree, ...actualFields] = readFileSync(fixture.capture, "utf8").trim().split("|");
    const nativeWorktree = process.platform === "win32" ? execFileSync(resolveTestBash(), ["-lc", `cygpath -w '${actualWorktree}'`], { encoding: "utf8" }).trim() : actualWorktree;
    assert.equal(realpathSync(nativeWorktree), realpathSync(fixture.worktreePath));
    assert.equal(
      actualFields.join("|"),
      `${fixture.recovery.sessionId}|${fixture.recovery.branch}|${toBashPath(join(fixture.repoRoot, ".ralph", "logs"))}|testowner/testrepo`,
    );

    const mutated = seedExactRecoveryFixture();
    process.env.RALPH_COPILOT_SESSION_STATE_DIR = mutated.sessionRoot;
    const statusPath = join(mutated.runDir, "status.json");
    const failed = await launchRun({
      ...mutated,
      recovery: mutated.recovery,
      recoveryExecFile: (command, args, options) => {
        if (command === "gh" && args[0] === "repo") writeFileSync(statusPath, JSON.stringify({ items: { 509: { status: "running", workerId: 1 } } }));
        return recoveryExecFile(command, args, options);
      },
      confirmStarted: async () => true,
    });
    assert.equal(failed.success, false);
    assert.match(failed.error, /recovery proof changed before spawn/i);
    rmSync(mutated.repoRoot, { recursive: true, force: true });
    rmSync(mutated.worktreePath, { recursive: true, force: true });

    const mismatched = seedExactRecoveryFixture();
    process.env.RALPH_COPILOT_SESSION_STATE_DIR = mismatched.sessionRoot;
    let repoChecks = 0;
    const mismatchResult = await launchRun({
      ...mismatched,
      recovery: mismatched.recovery,
      recoveryExecFile: (command, args) => {
        if (command === "gh" && args[0] === "repo") return ++repoChecks === 1 ? "testowner/testrepo" : "other/repo";
        if (command === "gh" && args[0] === "issue") return issueJson;
        if (command === "gh" && args[0] === "pr") return "[]";
        return execFileSync(command, args, { encoding: "utf8" });
      },
      resolveBash: resolveTestBash,
      confirmStarted: async () => true,
    });
    assert.equal(mismatchResult.success, false);
    assert.match(mismatchResult.error, /target repository identity changed/i);
    rmSync(mismatched.repoRoot, { recursive: true, force: true });
    rmSync(mismatched.worktreePath, { recursive: true, force: true });

    const caseColliding = seedExactRecoveryFixture();
    process.env.RALPH_COPILOT_SESSION_STATE_DIR = caseColliding.sessionRoot;
    let caseRepoChecks = 0;
    const caseResult = await launchRun({
      ...caseColliding,
      recovery: { ...caseColliding.recovery, worktreePath: caseColliding.worktreePath.toUpperCase() },
      isWindows: false,
      recoveryExecFile: (command, args) => command === "gh" && args[0] === "repo"
        ? (++caseRepoChecks === 1 ? "testowner/testrepo" : "other/repo")
        : recoveryExecFile(command, args, { cwd: caseColliding.repoRoot }),
    });
    assert.match(caseResult.error, /worktree path is not canonical/i);
    rmSync(caseColliding.repoRoot, { recursive: true, force: true });
    rmSync(caseColliding.worktreePath, { recursive: true, force: true });
  } finally {
    if (priorSessionRoot === undefined) delete process.env.RALPH_COPILOT_SESSION_STATE_DIR;
    else process.env.RALPH_COPILOT_SESSION_STATE_DIR = priorSessionRoot;
    rmSync(fixture.repoRoot, { recursive: true, force: true });
    rmSync(fixture.worktreePath, { recursive: true, force: true });
  }
});
