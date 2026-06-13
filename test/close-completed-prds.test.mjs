// Unit tests for the close-completed-prds reconcile logic.
//
// The orchestrator MAY close a `work:prd` parent as completed ONLY when ALL of:
//   - the parent is OPEN and labeled `work:prd`;
//   - it has at least ONE child slice (body carries an exact `Parent #<parent>`);
//   - EVERY child is CLOSED and each was closed via a MERGED PR.
// This is the only issue closure the orchestrator may perform. These tests stub
// gh entirely so nothing hits the network and `--dry-run` is proven to mutate
// nothing.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isClosedByMergedPr,
  groupChildrenByParent,
  evaluatePrdClosure,
  buildCloseComment,
  runCloseCompletedPrds,
} from "../extension/lib/close-completed-prds.mjs";

const FIXED_NOW = () => new Date("2026-06-13T00:00:00.000Z");

function prd(number, extra = {}) {
  return {
    number,
    title: `PRD: feature ${number}`,
    url: `https://github.com/octo/alisterr/issues/${number}`,
    state: "OPEN",
    labels: [{ name: "work:prd" }, { name: "ralph:evaluated" }],
    body: "",
    ...extra,
  };
}

function child(number, parent, { state = "CLOSED", merged = true, prNumber } = {}) {
  const pr = prNumber ?? number + 1000;
  return {
    number,
    title: `Slice ${number}`,
    url: `https://github.com/octo/alisterr/issues/${number}`,
    state,
    labels: [{ name: "work:slice" }],
    body: `Parent #${parent}\n\nDo the thing.`,
    closedByPullRequestsReferences: merged
      ? [{ number: pr, url: `https://github.com/octo/alisterr/pull/${pr}`, state: "MERGED" }]
      : [],
  };
}

test("isClosedByMergedPr — true only when closed AND a merged PR ref exists", () => {
  assert.equal(isClosedByMergedPr(child(2, 1, { state: "CLOSED", merged: true })), true);
  // closed but no merged PR (e.g. closed as not_planned)
  assert.equal(isClosedByMergedPr(child(2, 1, { state: "CLOSED", merged: false })), false);
  // open with a merged ref is impossible in practice, but state gates it
  assert.equal(isClosedByMergedPr(child(2, 1, { state: "OPEN", merged: true })), false);
  assert.equal(isClosedByMergedPr(null), false);
  assert.equal(isClosedByMergedPr({}), false);
});

test("groupChildrenByParent — groups issues by exact Parent #N marker", () => {
  const issues = [
    child(2, 1),
    child(3, 1),
    child(9, 5),
    { number: 7, body: "no parent marker here" },
    { number: 8, body: "See Parent #1 mentioned mid-line, not a real marker" },
  ];
  const map = groupChildrenByParent(issues);
  assert.deepEqual(map.get(1).map((c) => c.number), [2, 3]);
  assert.deepEqual(map.get(5).map((c) => c.number), [9]);
  assert.equal(map.has(7), false);
  assert.equal(map.has(8), false);
});

test("evaluatePrdClosure — closes when parent open/work:prd and ALL children merged-closed", () => {
  const decision = evaluatePrdClosure(prd(1), [child(2, 1), child(3, 1)]);
  assert.equal(decision.close, true);
  assert.equal(decision.childCount, 2);
  assert.deepEqual(decision.mergedChildren.map((c) => c.number), [2, 3]);
  assert.deepEqual(decision.mergedChildren.map((c) => c.prNumber), [1002, 1003]);
  assert.equal(decision.skipReason, null);
});

test("evaluatePrdClosure — skips when ANY child is still open", () => {
  const decision = evaluatePrdClosure(prd(1), [
    child(2, 1),
    child(3, 1, { state: "OPEN", merged: false }),
  ]);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /open|unmerged/i);
  assert.deepEqual(decision.openChildren.map((c) => c.number), [3]);
});

test("evaluatePrdClosure — skips when a child is closed WITHOUT a merged PR", () => {
  const decision = evaluatePrdClosure(prd(1), [
    child(2, 1),
    child(3, 1, { state: "CLOSED", merged: false }),
  ]);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /merged/i);
  assert.deepEqual(decision.openChildren.map((c) => c.number), [3]);
});

test("evaluatePrdClosure — skips when there are ZERO children", () => {
  const decision = evaluatePrdClosure(prd(1), []);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /no child|zero/i);
  assert.equal(decision.childCount, 0);
});

test("evaluatePrdClosure — skips when parent is not labeled work:prd", () => {
  const decision = evaluatePrdClosure(prd(1, { labels: [{ name: "work:standalone" }] }), [child(2, 1)]);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /work:prd/);
});

test("evaluatePrdClosure — skips when parent is not open", () => {
  const decision = evaluatePrdClosure(prd(1, { state: "CLOSED" }), [child(2, 1)]);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /open/i);
});

test("buildCloseComment — cross-links completed children and their merge PRs", () => {
  const decision = evaluatePrdClosure(prd(1), [child(2, 1), child(3, 1)]);
  const comment = buildCloseComment(decision);
  assert.match(comment, /#2/);
  assert.match(comment, /#1002/);
  assert.match(comment, /#3/);
  assert.match(comment, /#1003/);
  assert.match(comment, /ralph-orchestrator/i);
});

test("runCloseCompletedPrds — selects all-merged PRD, skips open-child and zero-child", async () => {
  const prds = [prd(1), prd(5), prd(8)];
  const allIssues = [
    // #1 — all children merged-closed → CLOSE
    child(2, 1),
    child(3, 1),
    // #5 — one open child → SKIP
    child(6, 5),
    child(7, 5, { state: "OPEN", merged: false }),
    // #8 — zero children → SKIP
  ];
  const closeCalls = [];
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: false,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    closeIssue: async (args) => closeCalls.push(args),
  });

  assert.deepEqual(result.closable, [1]);
  assert.deepEqual(result.closed, [1]);
  assert.equal(result.mutations, 1);
  assert.equal(closeCalls.length, 1);
  assert.equal(closeCalls[0].number, 1);
  assert.equal(closeCalls[0].reason, "completed");
  assert.match(closeCalls[0].comment, /#2/);

  const skipped = result.decisions.filter((d) => !d.close);
  assert.deepEqual(skipped.map((d) => d.number).sort((a, b) => a - b), [5, 8]);
});

test("runCloseCompletedPrds — --dry-run performs ZERO mutations but still reports closable", async () => {
  const prds = [prd(1), prd(5)];
  const allIssues = [child(2, 1), child(3, 1), child(7, 5, { state: "OPEN", merged: false })];
  let closeCalled = false;
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: true,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    closeIssue: async () => {
      closeCalled = true;
    },
  });

  assert.equal(closeCalled, false);
  assert.equal(result.dryRun, true);
  assert.equal(result.mutations, 0);
  assert.deepEqual(result.closed, []);
  // Still computes which parent WOULD be closed and why the other is skipped.
  assert.deepEqual(result.closable, [1]);
  const skip5 = result.decisions.find((d) => d.number === 5);
  assert.equal(skip5.close, false);
  assert.match(skip5.skipReason, /open|merged/i);
});
