// Shell launcher module tests — validates detached shell engine launching

import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { launchRun } from "../extension/lib/shell-launcher.mjs";

async function waitForFile(path, { timeoutMs = 2000 } = {}) {
  const { existsSync } = await import("node:fs");
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return true;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  return existsSync(path);
}

test("launchRun defaults to installed .ralph launcher and passes run environment", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-installed";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 2, model: "claude-sonnet-4.5" };
    const envOut = join(tmpRepo, "env-out.txt");
    const installedDir = join(tmpRepo, ".ralph");
    const installedLauncher = join(installedDir, "launch.sh");
    mkdirSync(installedDir, { recursive: true });
    writeFileSync(
      installedLauncher,
      `#!/usr/bin/env bash\nprintf '%s\\n' "$RALPH_RUN_ID|$RALPH_RUN_DIR|$RALPH_MAIN_REPO|$RALPH_MODEL|$RALPH_PARALLELISM|$RALPH_RUN_MODE|$*" > ${envOut}\n`,
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
      `${runId}|${runDir}|${tmpRepo}|claude-sonnet-4.5|2|until-empty|`,
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
      `#!/usr/bin/env bash\necho "$RALPH_RUN_ID" > ${envOut}\nexit 0\n`,
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
    const { readFileSync, existsSync } = await import("node:fs");
    if (existsSync(envOut)) {
      const capturedRunId = readFileSync(envOut, "utf-8").trim();
      assert.equal(capturedRunId, runId, "Run ID should be passed via RALPH_RUN_ID");
    }
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
      `#!/usr/bin/env bash\nprintf '%s\\n' "$*" > ${argsOut}\nexit 0\n`,
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
    assert.equal(readFileSync(argsOut, "utf-8").trim(), "--once");
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

test("launchRun terminates POSIX launcher when startup confirmation fails", async () => {
  const tmpRepo = mkdtempSync(join(tmpdir(), "ralph-test-"));
  try {
    const runId = "20260504-120000-timeout";
    const runDir = join(tmpRepo, ".ralph", "runs", runId);
    const runOptions = { runMode: "until-empty", parallelism: 1, model: "claude-sonnet-4.5" };
    const mockScript = join(tmpRepo, "launch-hangs.sh");
    const killed = [];
    writeFileSync(mockScript, "#!/usr/bin/env bash\nsleep 10\n", "utf-8");

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
      `#!/usr/bin/env bash\nprintf '%s\\n' "$*" > ${argsOut}\nsleep 1\n`,
      "utf-8",
    );
    chmodSync(mockScript, 0o755);

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      isWindows: true,
      resolveBash: () => "/bin/bash",
      startupTimeoutMs: 100,
    });

    assert.equal(result.success, true, result.error);
    const { readFileSync, existsSync } = await import("node:fs");
    const pidfile = join(tmpRepo, ".ralph", "launcher.pid");
    assert.equal(existsSync(pidfile), true);
    assert.equal(Number(readFileSync(pidfile, "utf-8")) > 0, true);
    assert.equal(await waitForFile(argsOut), true, "Windows launcher should receive args");
    assert.equal(readFileSync(argsOut, "utf-8").trim(), "--foreground");
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
      resolveBash: () => "/bin/bash",
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
      resolveBash: () => "/bin/bash",
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
    writeFileSync(mockScript, "#!/usr/bin/env bash\nsleep 5\n", "utf-8");
    chmodSync(mockScript, 0o755);

    const result = await launchRun({
      runId,
      runDir,
      repoRoot: tmpRepo,
      runOptions,
      isWindows: true,
      resolveBash: () => "/bin/bash",
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
