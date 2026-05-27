// Unit tests for resolveActiveRun() and createStatusReader() in status-data.mjs.
// Focuses on the "which run is the active one?" logic that the rubber-duck
// critique flagged as the highest-risk part of the new terminal CLI.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolveActiveRun, createStatusReader } from "../extension/lib/status-data.mjs";

function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), "ralph-active-run-"));
  mkdirSync(join(root, ".ralph", "runs"), { recursive: true });
  mkdirSync(join(root, ".ralph", "logs"), { recursive: true });
  return root;
}

function seedRun(root, runId, statusJson, mtime) {
  const runDir = join(root, ".ralph", "runs", runId);
  mkdirSync(runDir, { recursive: true });
  const sf = join(runDir, "status.json");
  writeFileSync(sf, JSON.stringify(statusJson));
  if (mtime) {
    const t = new Date(mtime);
    utimesSync(sf, t, t);
    utimesSync(runDir, t, t);
  }
}

test("resolveActiveRun — null when no runs/ dir", () => {
  const root = mkdtempSync(join(tmpdir(), "ralph-noruns-"));
  try {
    assert.equal(resolveActiveRun(root), null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveActiveRun — picks the run with non-terminal items, even when older", () => {
  const root = makeFixture();
  try {
    // Newer mtime, but all terminal:
    seedRun(root, "newer-terminal", {
      items: { "1": { status: "merged" }, "2": { status: "failed" } },
    }, "2026-05-26T18:00:00Z");
    // Older mtime, but has a running item:
    seedRun(root, "older-active", {
      items: { "3": { status: "running", workerId: 1 } },
    }, "2026-05-26T17:00:00Z");

    const r = resolveActiveRun(root);
    assert.equal(r.runId, "older-active");
    assert.equal(r.isActive, true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveActiveRun — mtime tiebreak when no run is active", () => {
  const root = makeFixture();
  try {
    seedRun(root, "old", { items: { "1": { status: "merged" } } }, "2026-05-26T17:00:00Z");
    seedRun(root, "new", { items: { "2": { status: "merged" } } }, "2026-05-26T18:00:00Z");
    const r = resolveActiveRun(root);
    assert.equal(r.runId, "new");
    assert.equal(r.isActive, false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveActiveRun — treats claimed and queued as non-terminal", () => {
  const root = makeFixture();
  try {
    seedRun(root, "terminal", {
      items: { "1": { status: "merged" }, "2": { status: "skipped" } },
    }, "2026-05-26T18:00:00Z");
    seedRun(root, "queued-only", {
      items: { "3": { status: "queued" } },
    }, "2026-05-26T17:00:00Z");
    const r = resolveActiveRun(root);
    assert.equal(r.runId, "queued-only");
    assert.equal(r.isActive, true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveActiveRun — tolerates corrupt status.json", () => {
  const root = makeFixture();
  try {
    const bad = join(root, ".ralph", "runs", "broken");
    mkdirSync(bad, { recursive: true });
    writeFileSync(join(bad, "status.json"), "{ this is not json");
    // Should still return a run, just marked inactive
    const r = resolveActiveRun(root);
    assert.equal(r.runId, "broken");
    assert.equal(r.isActive, false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("createStatusReader.buildLocalPayload — assembles workers + activeRun + tail", () => {
  const root = makeFixture();
  try {
    // state.json with a claim
    writeFileSync(join(root, ".ralph", "state.json"), JSON.stringify({
      claims: {
        "42": {
          workerId: 1,
          pid: 1, // pid 1 is always alive on POSIX (init)
          startedAt: new Date().toISOString(),
          logFile: "iter-20260526-180000-w1-issue-42.log",
        },
      },
    }));
    // iteration log so stage detection has something to chew on
    writeFileSync(
      join(root, ".ralph", "logs", "iter-20260526-180000-w1-issue-42.log"),
      "bun test --watch\ngh pr create --fill\n",
    );
    // loop.out tail
    writeFileSync(join(root, ".ralph", "loop.out"), "line a\nline b\nline c\n");
    // active run
    seedRun(root, "run-1", {
      items: { "42": { status: "running", workerId: 1 } },
    }, new Date().toISOString());

    const reader = createStatusReader({ repoRoot: root });
    const payload = reader.buildLocalPayload();

    assert.equal(payload.workers.length, 1);
    assert.equal(payload.workers[0].issue, 42);
    assert.equal(payload.workers[0].stage.stage, "pr-open");
    assert.equal(payload.activeRun.runId, "run-1");
    assert.equal(payload.activeRun.isActive, true);
    assert.match(payload.loopOutTail, /line c/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
