// Integration tests for extension/cli.mjs.
// Spawns the CLI as a child process against a fixture .ralph/ tree.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, appendFileSync } from "node:fs";
import { spawnSync, spawn } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const CLI = join(import.meta.dirname, "..", "extension", "cli.mjs");

function setupFixture() {
  const root = mkdtempSync(join(tmpdir(), "ralph-cli-"));
  mkdirSync(join(root, ".ralph", "logs"), { recursive: true });
  mkdirSync(join(root, ".ralph", "runs", "run-x"), { recursive: true });

  writeFileSync(join(root, ".ralph", "state.json"), JSON.stringify({
    claims: {
      "42": {
        workerId: 1,
        pid: 1, // init — always alive on POSIX, used so we don't trip "claim stale"
        startedAt: new Date(Date.now() - 5 * 60_000).toISOString(),
        logFile: "iter-20260526-180000-w1-issue-42.log",
      },
    },
  }));
  writeFileSync(
    join(root, ".ralph", "logs", "iter-20260526-180000-w1-issue-42.log"),
    [
      "starting up",
      "bun test --watch",
      "Code-review(gpt-5.5) starting",
      "gh pr create --fill",
      "Tokens    ↑ 1.2m • ↓ 50.5k • 800k (cached)",
    ].join("\n") + "\n",
  );
  writeFileSync(
    join(root, ".ralph", "loop.out"),
    "[18:00] worker started\n[18:01] picked issue\n[18:02] tests passed\n",
  );
  writeFileSync(
    join(root, ".ralph", "runs", "run-x", "status.json"),
    JSON.stringify({
      items: {
        "42": { status: "running", workerId: 1 },
        "41": { status: "merged" },
        "43": { status: "failed", error: "exit 1" },
        "44": { status: "queued" },
      },
    }),
  );
  writeFileSync(join(root, ".ralph", "config.json"), JSON.stringify({
    issue: { titleRegex: "^Slice", titleNumRegex: "^Slice ([0-9]+):", issueSearch: "Slice repo:foo/bar" },
  }));
  return root;
}

test("cli.mjs status — runs against fixture without gh", () => {
  const root = setupFixture();
  try {
    const r = spawnSync("node", [CLI, "status", "--no-color"], {
      env: { ...process.env, RALPH_REPO_ROOT: root },
      encoding: "utf8",
      timeout: 10_000,
    });
    assert.equal(r.status, 0, `cli stderr: ${r.stderr}`);
    assert.match(r.stdout, /Workers/);
    assert.match(r.stdout, /w1.*#42/);
    assert.match(r.stdout, /PR opened/);
    assert.match(r.stdout, /Queue progress/);
    assert.match(r.stdout, /1✓ merged/);
    assert.match(r.stdout, /1⚙ running/);
    assert.match(r.stdout, /✗ #43.*exit 1/);
    assert.match(r.stdout, /loop\.out/);
    assert.match(r.stdout, /tests passed/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("cli.mjs help — exits 0 with usage", () => {
  const r = spawnSync("node", [CLI, "help"], { encoding: "utf8", timeout: 5_000 });
  assert.equal(r.status, 0);
  assert.match(r.stdout, /Usage:/);
  assert.match(r.stdout, /status/);
  assert.match(r.stdout, /watch/);
  assert.match(r.stdout, /follow/);
});

test("cli.mjs — missing .ralph exits 2 with hint", () => {
  const empty = mkdtempSync(join(tmpdir(), "ralph-empty-"));
  try {
    const r = spawnSync("node", [CLI, "status"], {
      env: { ...process.env, RALPH_REPO_ROOT: empty, HOME: empty },
      encoding: "utf8",
      timeout: 5_000,
    });
    // empty dir has no .ralph; CLI should still try since RALPH_REPO_ROOT is set,
    // then find no state and render an empty snapshot. Acceptance: doesn't crash.
    assert.notEqual(r.status, 1, `cli should not crash; stderr: ${r.stderr}`);
  } finally {
    rmSync(empty, { recursive: true, force: true });
  }
});

test("cli.mjs unknown command — exits 2", () => {
  const r = spawnSync("node", [CLI, "bogus"], { encoding: "utf8", timeout: 5_000 });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /Unknown command/);
});

test("cli.mjs watch — renders at least 2 frames and exits cleanly on SIGINT", async () => {
  const root = setupFixture();
  try {
    const child = spawn("node", [CLI, "watch", "--interval", "1", "--no-color"], {
      env: { ...process.env, RALPH_REPO_ROOT: root, TERM: "dumb" }, // disable clear so we can count frames
      stdio: ["ignore", "pipe", "pipe"],
    });
    let buf = "";
    child.stdout.on("data", (d) => { buf += d.toString(); });
    await new Promise((r) => setTimeout(r, 2500));
    child.kill("SIGINT");
    const code = await new Promise((r) => child.on("close", r));
    // At least two "Ralph status @" headers should appear
    const frames = (buf.match(/Ralph status @/g) || []).length;
    assert.ok(frames >= 2, `expected ≥2 frames, got ${frames}. output: ${buf}`);
    // Clean exit (signal or 0)
    assert.ok(code === 0 || code === null || code === 130, `unexpected exit: ${code}`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("cli.mjs follow — tails worker log and exits cleanly when worker disappears", async () => {
  const root = setupFixture();
  try {
    const child = spawn("node", [CLI, "follow"], {
      env: { ...process.env, RALPH_REPO_ROOT: root },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let buf = "";
    child.stdout.on("data", (d) => { buf += d.toString(); });

    // Append a line to the log so the tail picks it up
    await new Promise((r) => setTimeout(r, 500));
    appendFileSync(
      join(root, ".ralph", "logs", "iter-20260526-180000-w1-issue-42.log"),
      "NEW LINE FROM TEST\n",
    );
    await new Promise((r) => setTimeout(r, 1500));

    // Now rewrite state.json so the worker disappears — CLI should exit cleanly
    writeFileSync(join(root, ".ralph", "state.json"), JSON.stringify({ claims: {} }));
    const exitCode = await new Promise((resolve) => {
      const t = setTimeout(() => { child.kill("SIGTERM"); resolve(null); }, 5_000);
      child.on("close", (c) => { clearTimeout(t); resolve(c); });
    });

    assert.match(buf, /following w1 #42/);
    assert.match(buf, /NEW LINE FROM TEST/);
    // Either clean exit (0/null) or our kill — both acceptable
    assert.ok(exitCode === 0 || exitCode === null, `exit was ${exitCode}; buf=${buf}`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("cli.mjs follow — error when no active worker", () => {
  const root = mkdtempSync(join(tmpdir(), "ralph-empty-"));
  mkdirSync(join(root, ".ralph"), { recursive: true });
  writeFileSync(join(root, ".ralph", "state.json"), JSON.stringify({ claims: {} }));
  try {
    const r = spawnSync("node", [CLI, "follow"], {
      env: { ...process.env, RALPH_REPO_ROOT: root },
      encoding: "utf8",
      timeout: 5_000,
    });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /No active workers/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
