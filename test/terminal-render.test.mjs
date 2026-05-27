// Unit tests for extension/lib/terminal-render.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  shouldUseColor,
  renderWorkers,
  renderQueueProgress,
  renderLoopTail,
  renderLocalStatus,
  renderStatus,
} from "../extension/lib/terminal-render.mjs";

const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, "");
const c = (text) => text; // no-color identity

test("shouldUseColor — respects NO_COLOR", () => {
  assert.equal(shouldUseColor({ NO_COLOR: "1" }), false);
});

test("shouldUseColor — respects TERM=dumb", () => {
  assert.equal(shouldUseColor({ TERM: "dumb" }), false);
});

test("shouldUseColor — opts.color overrides env", () => {
  assert.equal(shouldUseColor({ NO_COLOR: "1" }, { color: true }), true);
  assert.equal(shouldUseColor({}, { color: false }), false);
});

test("renderWorkers — empty list shows placeholder", () => {
  const out = renderWorkers([], c);
  assert.match(out, /no active workers/);
});

test("renderWorkers — single worker shows stage + runtime + tokens", () => {
  const out = renderWorkers([{
    workerId: 1,
    issue: 42,
    startedAt: new Date(Date.now() - 60_000).toISOString(),
    ageSec: 5,
    stage: { icon: "↑", label: "PR opened" },
    cumulativeTokens: { total: 1_250_500, input: 1_200_000, output: 50_500, iterations: 1 },
    pid: 12345,
    pidAlive: true,
    stuck: false,
  }], c);
  assert.match(out, /w1.*#42/);
  assert.match(out, /PR opened/);
  assert.match(out, /1m/);
  assert.match(out, /↑1\.2m/);
  assert.doesNotMatch(out, /claim stale/);
  assert.doesNotMatch(out, /stuck/);
});

test("renderWorkers — stale claim warning when pid not alive", () => {
  const out = renderWorkers([{
    workerId: 2, issue: 99, startedAt: new Date().toISOString(),
    ageSec: 1, stage: { icon: "⚙", label: "working" },
    pid: 99999, pidAlive: false,
  }], c);
  assert.match(out, /claim stale/);
  assert.match(out, /launch\.sh --cleanup/);
});

test("renderWorkers — stuck warning when ageSec exceeds threshold", () => {
  const out = renderWorkers([{
    workerId: 1, issue: 10, startedAt: new Date().toISOString(),
    ageSec: 600, stage: { icon: "⚙", label: "working" },
    pid: 1234, pidAlive: true, stuck: true,
  }], c);
  assert.match(out, /stuck >5m/);
});

test("renderWorkers — surfaces currentPr check counts", () => {
  const out = renderWorkers([{
    workerId: 1, issue: 5, startedAt: new Date().toISOString(),
    ageSec: 1, stage: { icon: "⚙", label: "working" }, pidAlive: true,
    currentPr: { number: 77, isDraft: false, checks: { total: 3, pass: 2, fail: 0, pending: 1 } },
  }], c);
  assert.match(out, /PR #77/);
  assert.match(out, /2✓\/0✗\/1⏱/);
});

test("renderQueueProgress — null activeRun shows placeholder", () => {
  assert.match(renderQueueProgress(null, c), /no run history/);
});

test("renderQueueProgress — counts items by status", () => {
  const out = renderQueueProgress({
    runId: "run-1",
    isActive: true,
    statusData: {
      items: {
        "1": { status: "merged" },
        "2": { status: "running", workerId: 1 },
        "3": { status: "failed", error: "Copilot exited 1" },
        "4": { status: "queued" },
        "5": { status: "skipped" },
      },
    },
  }, c);
  assert.match(out, /active run/);
  assert.match(out, /1✓ merged/);
  assert.match(out, /1⚙ running/);
  assert.match(out, /1✗ failed/);
  assert.match(out, /1○ queued/);
  assert.match(out, /1⤼ skipped/);
});

test("renderQueueProgress — surfaces failed item errors inline", () => {
  const out = renderQueueProgress({
    runId: "run-1",
    isActive: false,
    statusData: {
      items: {
        "43": { status: "failed", error: "Tests crashed" },
      },
    },
  }, c);
  assert.match(out, /✗ #43: Tests crashed/);
  assert.match(out, /latest run/);
});

test("renderQueueProgress — shows running items with worker id", () => {
  const out = renderQueueProgress({
    runId: "r",
    isActive: true,
    statusData: { items: { "7": { status: "running", workerId: 3 } } },
  }, c);
  assert.match(out, /#7 \(w3\)/);
});

test("renderLoopTail — empty buffer shows placeholder", () => {
  assert.match(renderLoopTail("", c), /loop\.out is empty/);
});

test("renderLoopTail — keeps last N lines", () => {
  const tail = ["a", "b", "c", "d", "e"].join("\n");
  const out = renderLoopTail(tail, c, { maxLines: 3 });
  assert.doesNotMatch(out, /^  a$/m);
  assert.match(out, /^  c$/m);
  assert.match(out, /^  e$/m);
});

test("renderLocalStatus — composes all sections", () => {
  const out = renderLocalStatus({
    timestamp: "2026-05-26T18:00:00.000Z",
    repoRoot: "/tmp/x",
    workers: [],
    loopOutTail: "hi",
    activeRun: null,
  }, { color: false });
  assert.match(out, /Ralph status @/);
  assert.match(out, /Workers/);
  assert.match(out, /Queue progress/);
  assert.match(out, /loop\.out \(tail\)/);
});

test("renderStatus — opts.withPrs gates the Recent PRs section", () => {
  const payload = {
    timestamp: new Date().toISOString(),
    headerText: "Ralph Loop — foo/bar",
    loopRunning: true,
    workers: [],
    activeRun: null,
    recentPrs: [{ number: 1, title: "First", state: "MERGED" }],
    loopOutTail: "",
  };
  const withoutPrs = renderStatus(payload, { color: false, withPrs: false });
  assert.doesNotMatch(withoutPrs, /Recent PRs/);
  const withPrs = renderStatus(payload, { color: false, withPrs: true });
  assert.match(withPrs, /Recent PRs/);
  assert.match(withPrs, /#1/);
  assert.match(withPrs, /First/);
});

test("renderStatus — NO_COLOR yields plain text", () => {
  const out = renderStatus({
    timestamp: new Date().toISOString(),
    loopRunning: false,
    workers: [{
      workerId: 1, issue: 9, startedAt: new Date().toISOString(),
      ageSec: 0, stage: { icon: "⚙", label: "working" }, pidAlive: true,
    }],
    activeRun: null,
    loopOutTail: "x",
  }, { color: false });
  assert.equal(stripAnsi(out), out);
});
