// Regression guard: on POSIX (Linux/macOS), the Windows-only pidfile
// (.ralph/launcher.pid) must never be touched by the dashboard. The
// Windows code paths added for issue #31 are gated on
// process.platform === "win32" — this test asserts those guards hold.

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";

const posixTest = process.platform === "win32" ? test.skip : test;

posixTest("platform-shim is importable on POSIX without side effects", async () => {
  // Must not throw on Linux/macOS even though the helpers target Windows.
  const shim = await import("../extension/lib/platform-shim.mjs");
  assert.equal(typeof shim.isAlive, "function");
  assert.equal(typeof shim.readPidFile, "function");
  assert.equal(typeof shim.writePidFile, "function");
  assert.equal(typeof shim.removePidFile, "function");
  assert.equal(typeof shim.resolveBashExe, "function");
  assert.equal(typeof shim.toBashPath, "function");
});

posixTest("toBashPath returns POSIX paths unchanged on POSIX", async () => {
  const { toBashPath } = await import("../extension/lib/platform-shim.mjs");
  assert.equal(toBashPath("/usr/local/bin/foo"), "/usr/local/bin/foo");
  assert.equal(toBashPath("/Users/me/repo"), "/Users/me/repo");
});

posixTest("isAlive on POSIX agrees with process.kill(pid, 0)", async () => {
  const { isAlive } = await import("../extension/lib/platform-shim.mjs");
  assert.equal(isAlive(process.pid), true, "current process is alive");
  // PID 999999 is almost certainly not in use; isAlive should return false.
  assert.equal(isAlive(999999), false, "non-existent pid is not alive");
});

posixTest("dashboard does not create launcher.pid in repo on POSIX", () => {
  // The dashboard's own repo-root .ralph dir should never accumulate a
  // launcher.pid file as a side effect of running the test suite on POSIX.
  // (On Windows this file is the source of truth; on POSIX it must not exist
  // because nothing should be writing it.)
  const candidate = new URL("../.ralph/launcher.pid", import.meta.url).pathname;
  assert.equal(
    existsSync(candidate),
    false,
    `launcher.pid must not exist on POSIX (found at ${candidate})`
  );
});
