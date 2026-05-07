// Tests for extension/lib/platform-shim.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  isAlive,
  readPidFile,
  writePidFile,
  removePidFile,
  resolveBashExe,
  toBashPath,
} from "../extension/lib/platform-shim.mjs";

test("isAlive returns true for the current process", () => {
  assert.equal(isAlive(process.pid), true);
});

test("isAlive returns false for a clearly-dead PID", () => {
  // PID 999999 is virtually never alive on either Windows or POSIX runners.
  assert.equal(isAlive(999999), false);
});

test("isAlive rejects non-integer / non-positive inputs", () => {
  assert.equal(isAlive(0), false);
  assert.equal(isAlive(-1), false);
  assert.equal(isAlive(null), false);
  assert.equal(isAlive(undefined), false);
  assert.equal(isAlive("123"), false);
  assert.equal(isAlive(1.5), false);
});

test("pidfile round-trip: write then read returns the same pid", () => {
  const dir = mkdtempSync(join(tmpdir(), "ralph-shim-"));
  try {
    const path = join(dir, "nested", "launcher.pid");
    writePidFile(path, 12345);
    assert.equal(readPidFile(path), 12345);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("readPidFile returns null when the file is missing", () => {
  const dir = mkdtempSync(join(tmpdir(), "ralph-shim-"));
  try {
    assert.equal(readPidFile(join(dir, "nope.pid")), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("readPidFile returns null when the file is empty or garbage", () => {
  const dir = mkdtempSync(join(tmpdir(), "ralph-shim-"));
  try {
    const path = join(dir, "garbage.pid");
    // empty
    writeFileSync(path, "", "utf-8");
    assert.equal(readPidFile(path), null);
    // garbage
    writeFileSync(path, "not-a-number", "utf-8");
    assert.equal(readPidFile(path), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("writePidFile rejects invalid pids", () => {
  const dir = mkdtempSync(join(tmpdir(), "ralph-shim-"));
  try {
    const path = join(dir, "x.pid");
    assert.throws(() => writePidFile(path, 0), TypeError);
    assert.throws(() => writePidFile(path, -1), TypeError);
    assert.throws(() => writePidFile(path, "123"), TypeError);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("removePidFile is a no-op when file is missing", () => {
  const dir = mkdtempSync(join(tmpdir(), "ralph-shim-"));
  try {
    // Should not throw.
    removePidFile(join(dir, "missing.pid"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("removePidFile deletes an existing file", () => {
  const dir = mkdtempSync(join(tmpdir(), "ralph-shim-"));
  try {
    const path = join(dir, "x.pid");
    writePidFile(path, 1234);
    assert.equal(existsSync(path), true);
    removePidFile(path);
    assert.equal(existsSync(path), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("resolveBashExe honours RALPH_BASH_EXE override", () => {
  const dir = mkdtempSync(join(tmpdir(), "ralph-shim-"));
  try {
    // Use a real existing file so the probe sees it.
    const fakeBash = join(dir, "fake-bash.exe");
    writeFileSync(fakeBash, "", "utf-8");
    const original = process.env.RALPH_BASH_EXE;
    process.env.RALPH_BASH_EXE = fakeBash;
    try {
      assert.equal(resolveBashExe(), fakeBash);
    } finally {
      if (original === undefined) delete process.env.RALPH_BASH_EXE;
      else process.env.RALPH_BASH_EXE = original;
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("resolveBashExe falls back to 'bash' when nothing matches", () => {
  const original = process.env.RALPH_BASH_EXE;
  // Point at a path that definitely does not exist.
  process.env.RALPH_BASH_EXE = join(tmpdir(), "does-not-exist-xyz.exe");
  try {
    const result = resolveBashExe();
    // On a real POSIX runner, the Git-for-Windows paths don't exist either,
    // so we should fall through to "bash". On Windows runners that have Git
    // installed, we'll find one of the standard locations — also fine.
    assert.ok(
      result === "bash" ||
        result === "C:\\Program Files\\Git\\usr\\bin\\bash.exe" ||
        result === "C:\\Program Files\\Git\\bin\\bash.exe",
      `unexpected resolveBashExe result: ${result}`,
    );
  } finally {
    if (original === undefined) delete process.env.RALPH_BASH_EXE;
    else process.env.RALPH_BASH_EXE = original;
  }
});

test("toBashPath converts Windows paths to /c/... form", () => {
  assert.equal(toBashPath("C:\\Users\\foo\\bar"), "/c/Users/foo/bar");
  assert.equal(toBashPath("D:\\repo\\.ralph\\launch.sh"), "/d/repo/.ralph/launch.sh");
});

test("toBashPath passes through POSIX paths unchanged", () => {
  assert.equal(toBashPath("/home/foo/bar"), "/home/foo/bar");
  assert.equal(toBashPath("./relative"), "./relative");
  assert.equal(toBashPath(""), "");
});
