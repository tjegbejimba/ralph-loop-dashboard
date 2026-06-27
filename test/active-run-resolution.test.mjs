// Unit tests for resolveActiveRun() and createStatusReader() in status-data.mjs.
// Focuses on the "which run is the active one?" logic that the rubber-duck
// critique flagged as the highest-risk part of the new terminal CLI.

import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  commandLooksRalphRelated,
  createStatusReader,
  isRalphPidAlive,
  resolveActiveRun,
} from "../extension/lib/status-data.mjs";

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

test("resolveActiveRun — picks the run with live worker pid evidence, even when older", () => {
  const root = makeFixture();
  try {
    // Newer mtime, but all terminal:
    seedRun(root, "newer-terminal", {
      items: { "1": { status: "merged" }, "2": { status: "failed" } },
    }, "2026-05-26T18:00:00Z");
    // Older mtime, but has a running item:
    seedRun(root, "older-active", {
      items: { "3": { status: "running", workerId: 1, pid: 4242 } },
    }, "2026-05-26T17:00:00Z");

    const r = resolveActiveRun(root, { isRalphPidAlive: (pid) => pid === 4242 });
    assert.equal(r.runId, "older-active");
    assert.equal(r.isActive, true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveActiveRun — stale non-terminal status without live local evidence is not active", () => {
  const root = makeFixture();
  try {
    seedRun(root, "stale-running", {
      items: {
        "138": {
          status: "running",
          workerId: 1,
          pid: 67519,
          logFile: "iter-20260627-081801-w1-issue-138.log",
          startedAt: "2026-06-27T15:18:01Z",
        },
      },
    }, "2026-06-27T15:18:01Z");

    const r = resolveActiveRun(root, { isRalphPidAlive: () => false });
    assert.equal(r.runId, "stale-running");
    assert.equal(r.isActive, false);
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

test("resolveActiveRun — queued-only status without live evidence is inactive", () => {
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
    assert.equal(r.isActive, false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveActiveRun — claimed status with live Ralph worker pid is active", () => {
  const root = makeFixture();
  try {
    seedRun(root, "claimed-live", {
      items: { "3": { status: "claimed", workerId: 1, pid: 4321 } },
    }, "2026-05-26T17:00:00Z");

    const r = resolveActiveRun(root, { isRalphPidAlive: (pid) => pid === 4321 });
    assert.equal(r.runId, "claimed-live");
    assert.equal(r.isActive, true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("isRalphPidAlive — requires a Ralph-related command line, not just an existing PID", () => {
  assert.equal(commandLooksRalphRelated("/repo/.ralph/ralph.sh --run-id x"), true);
  assert.equal(commandLooksRalphRelated("/repo/.ralph/launch.sh --foreground"), true);
  assert.equal(commandLooksRalphRelated("copilot -p prompt.md"), true);
  assert.equal(commandLooksRalphRelated("/bin/sleep 120"), false);

  assert.equal(isRalphPidAlive(1234, {
    spawnSyncFn: () => ({ status: 0, stdout: "/bin/sleep 120\n" }),
  }), false);
  assert.equal(isRalphPidAlive(1234, {
    spawnSyncFn: () => ({ status: 0, stdout: "/repo/.ralph/ralph.sh --run-id x\n" }),
  }), true);
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

test("resolveActiveRun — prefers run containing live claims over non-terminal run", () => {
  const root = makeFixture();
  try {
    // Run A: has a non-terminal queued item but no live claim
    seedRun(root, "queue-only", {
      items: { "5": { status: "queued" } },
    }, "2026-05-26T18:00:00Z");
    // Run B: status items all terminal, but contains the live-claimed issue #42
    seedRun(root, "terminal-but-live", {
      items: { "42": { status: "merged" }, "41": { status: "merged" } },
    }, "2026-05-26T17:00:00Z");

    const r = resolveActiveRun(root, { liveIssues: [42] });
    assert.equal(r.runId, "terminal-but-live");
    assert.equal(r.isActive, true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveActiveRun — live state.json claim keeps its matching run active", () => {
  const root = makeFixture();
  try {
    writeFileSync(join(root, ".ralph", "state.json"), JSON.stringify({
      claims: {
        "42": {
          workerId: 1,
          pid: 4444,
          startedAt: "2026-05-26T17:00:00Z",
          logFile: "iter-20260526-170000-w1-issue-42.log",
        },
      },
    }));
    seedRun(root, "terminal-but-claimed", {
      items: { "42": { status: "merged" } },
    }, "2026-05-26T17:00:00Z");

    const r = resolveActiveRun(root, { isRalphPidAlive: (pid) => pid === 4444 });
    assert.equal(r.runId, "terminal-but-claimed");
    assert.equal(r.isActive, true);
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
          pid: 1234,
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

    const reader = createStatusReader({ repoRoot: root, isRalphPidAlive: (pid) => pid === 1234 });
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

test("createStatusReader.buildLocalPayload — stale state claim does not keep activeRun active", () => {
  const root = makeFixture();
  try {
    writeFileSync(join(root, ".ralph", "state.json"), JSON.stringify({
      claims: {
        "42": {
          workerId: 1,
          pid: 999999,
          startedAt: "2026-05-26T18:00:00Z",
          logFile: "iter-20260526-180000-w1-issue-42.log",
        },
      },
    }));
    seedRun(root, "stale-run", {
      items: { "42": { status: "running", workerId: 1, pid: 999999 } },
    }, "2026-05-26T18:00:00Z");

    const reader = createStatusReader({ repoRoot: root, isRalphPidAlive: () => false });
    const payload = reader.buildLocalPayload();

    assert.equal(payload.activeRun.runId, "stale-run");
    assert.equal(payload.activeRun.isActive, false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("createStatusReader.getOpenSlices — canonical standalone issues do not require Slice titles", async () => {
  const root = makeFixture();
  try {
    const ghBin = join(root, "gh-mock.sh");
    writeFileSync(ghBin, `#!/usr/bin/env bash
if [[ "$1 $2" == "issue list" ]]; then
  cat <<'JSON'
[
  {
    "number": 12,
    "title": "Fix standalone bug",
    "body": "No PRD parent needed",
    "state": "OPEN",
    "url": "https://github.com/owner/repo/issues/12",
    "labels": [{"name":"ralph:ready"},{"name":"priority:P2"},{"name":"work:standalone"}],
    "assignees": []
  },
  {
    "number": 13,
    "title": "Slice 13: PRD child",
    "body": "Parent #1",
    "state": "OPEN",
    "url": "https://github.com/owner/repo/issues/13",
    "labels": [{"name":"ralph:ready"},{"name":"priority:P2"},{"name":"work:slice"}],
    "assignees": []
  }
]
JSON
  exit 0
fi
echo "[]"
`);
    chmodSync(ghBin, 0o755);

    const reader = createStatusReader({ repoRoot: root, ghBin });
    const issues = await reader.getOpenSlices();

    assert.deepEqual(new Set(issues.map((issue) => issue.number)), new Set([12, 13]));
    assert.equal(issues.find((issue) => issue.number === 12).taxonomy.workType, "work:standalone");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
