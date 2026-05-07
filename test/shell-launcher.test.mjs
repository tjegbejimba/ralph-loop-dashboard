// Shell launcher module tests — validates detached shell engine launching

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { launchRun } from "../extension/lib/shell-launcher.mjs";

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


