// Unit tests for the close-completed-prds reconcile logic.
//
// The orchestrator MAY close a `work:prd` parent as completed ONLY when ALL of:
//   - the parent is OPEN and labeled `work:prd`;
//   - it has at least ONE child slice (body carries an exact `Parent #<parent>`
//     marker — markers inside fenced/inline code do NOT count);
//   - EVERY child is CLOSED and each was closed via a MERGED PR.
// This is the only issue closure the orchestrator may perform.
//
// These tests use the REAL `gh` JSON shapes: closedByPullRequestsReferences
// carries { number, url, repository } and NO merge/state field, so merge status
// is determined by a separate `gh pr view <n> --json mergedAt` lookup (stubbed
// here via the injectable getPrMergedAt). `--dry-run` is proven to mutate
// nothing.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  stripCodeBlocks,
  parentNumberFromBody,
  closingPrRefs,
  groupChildrenByParent,
  resolveChildMergeStatus,
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

// A child issue in the REAL gh shape. closedByPullRequestsReferences entries
// carry { number, url, repository } only — NO state/merge field. Pass
// prNumber:null to model a CLOSED child with no closing PR ref (manual /
// not_planned close).
function child(number, parent, { state = "CLOSED", prNumber = number + 1000, body } = {}) {
  const refs =
    state === "CLOSED" && prNumber != null
      ? [
          {
            number: prNumber,
            url: `https://github.com/octo/alisterr/pull/${prNumber}`,
            repository: { name: "alisterr", owner: { login: "octo" } },
          },
        ]
      : [];
  return {
    number,
    title: `Slice ${number}`,
    url: `https://github.com/octo/alisterr/issues/${number}`,
    state,
    labels: [{ name: "work:slice" }],
    body: body ?? `Parent #${parent}\n\nDo the thing.`,
    closedByPullRequestsReferences: refs,
  };
}

// A child already resolved to its merge status, for the pure evaluatePrdClosure.
function resolvedChild(number, { state = "CLOSED", mergedClosed = true, prNumber = number + 1000 } = {}) {
  return {
    number,
    url: `https://github.com/octo/alisterr/issues/${number}`,
    state,
    mergedClosed,
    mergePr: mergedClosed
      ? { number: prNumber, url: `https://github.com/octo/alisterr/pull/${prNumber}` }
      : null,
  };
}

// Stub for `gh pr view <n> --json mergedAt`: returns a timestamp for merged PRs,
// null otherwise. PR numbers in throwFor simulate an undeterminable lookup.
function makeGetPrMergedAt(mergedPrNumbers, { throwFor = new Set() } = {}) {
  const merged = new Set(mergedPrNumbers);
  return async ({ prNumber }) => {
    if (throwFor.has(prNumber)) throw new Error("gh pr view failed");
    return merged.has(prNumber) ? "2026-06-10T12:00:00Z" : null;
  };
}

// ---- Fix 2: code-fence stripping --------------------------------------------

test("stripCodeBlocks — removes fenced and inline code so example markers don't leak", () => {
  assert.equal(parentNumberFromBody("```\nParent #1\n```"), null);
  assert.equal(parentNumberFromBody("~~~\nParent #7\n~~~"), null);
  assert.equal(parentNumberFromBody("see `Parent #9` inline"), null);
  // A genuine top-level marker still parses.
  assert.equal(parentNumberFromBody("Parent #42\n\nbody"), 42);
  // A marker outside a fence is found even if an unrelated fence exists.
  assert.equal(parentNumberFromBody("Parent #5\n\n```\nsome code\n```"), 5);
  // sanity: stripping leaves non-code text intact
  assert.match(stripCodeBlocks("a\n```\ncode\n```\nb"), /a[\s\S]*b/);
});

// ---- closingPrRefs ----------------------------------------------------------

test("closingPrRefs — reads number/url from the real ref shape (no state field)", () => {
  const issue = child(2, 1, { prNumber: 1002 });
  assert.deepEqual(closingPrRefs(issue), [
    { number: 1002, url: "https://github.com/octo/alisterr/pull/1002" },
  ]);
  // No refs on an open issue.
  assert.deepEqual(closingPrRefs(child(2, 1, { state: "OPEN" })), []);
});

// ---- groupChildrenByParent --------------------------------------------------

test("groupChildrenByParent — groups by exact Parent #N marker, ignoring code blocks", () => {
  const issues = [
    child(2, 1),
    child(3, 1),
    child(9, 5),
    { number: 7, body: "no parent marker here" },
    { number: 8, body: "See Parent #1 mentioned mid-line, not a real marker" },
    // An UNRELATED issue that only shows the marker inside a fenced code example
    // must NOT be grouped as a child of #1 (Fix 2 over-close guard).
    { number: 11, body: "Example usage:\n```\nParent #1\n```\nnot a real child" },
  ];
  const map = groupChildrenByParent(issues);
  assert.deepEqual(map.get(1).map((c) => c.number), [2, 3]);
  assert.deepEqual(map.get(5).map((c) => c.number), [9]);
  assert.equal(map.has(7), false);
  assert.equal(map.has(8), false);
  // #11's code-block marker is ignored entirely.
  assert.equal((map.get(1) || []).some((c) => c.number === 11), false);
});

// ---- Fix 1: resolveChildMergeStatus -----------------------------------------

test("resolveChildMergeStatus — CLOSED child with a MERGED closing PR counts", async () => {
  const status = await resolveChildMergeStatus(child(2, 1, { prNumber: 1002 }), {
    slug: "octo/alisterr",
    getPrMergedAt: makeGetPrMergedAt([1002]),
  });
  assert.equal(status.mergedClosed, true);
  assert.deepEqual(status.mergePr, {
    number: 1002,
    url: "https://github.com/octo/alisterr/pull/1002",
  });
});

test("resolveChildMergeStatus — CLOSED child whose closing PR is NOT merged blocks", async () => {
  const status = await resolveChildMergeStatus(child(3, 1, { prNumber: 1003 }), {
    slug: "octo/alisterr",
    getPrMergedAt: makeGetPrMergedAt([]), // 1003 not merged → mergedAt null
  });
  assert.equal(status.mergedClosed, false);
  assert.equal(status.mergePr, null);
});

test("resolveChildMergeStatus — CLOSED child with NO closing PR ref blocks", async () => {
  const status = await resolveChildMergeStatus(child(4, 1, { prNumber: null }), {
    slug: "octo/alisterr",
    getPrMergedAt: makeGetPrMergedAt([9999]),
  });
  assert.equal(status.mergedClosed, false);
});

test("resolveChildMergeStatus — OPEN child is never merged-closed", async () => {
  const status = await resolveChildMergeStatus(child(5, 1, { state: "OPEN" }), {
    slug: "octo/alisterr",
    getPrMergedAt: makeGetPrMergedAt([1005]),
  });
  assert.equal(status.mergedClosed, false);
});

test("resolveChildMergeStatus — fail-safe: an undeterminable merge lookup blocks", async () => {
  const status = await resolveChildMergeStatus(child(6, 1, { prNumber: 1006 }), {
    slug: "octo/alisterr",
    getPrMergedAt: makeGetPrMergedAt([1006], { throwFor: new Set([1006]) }),
  });
  assert.equal(status.mergedClosed, false);
});

// ---- evaluatePrdClosure (pure, over resolved children) ----------------------

test("evaluatePrdClosure — closes when parent open/work:prd and ALL children merged-closed", () => {
  const decision = evaluatePrdClosure(prd(1), [resolvedChild(2), resolvedChild(3)]);
  assert.equal(decision.close, true);
  assert.equal(decision.childCount, 2);
  assert.deepEqual(decision.mergedChildren.map((c) => c.number), [2, 3]);
  assert.deepEqual(decision.mergedChildren.map((c) => c.prNumber), [1002, 1003]);
  assert.equal(decision.skipReason, null);
});

test("evaluatePrdClosure — skips when ANY child is still open", () => {
  const decision = evaluatePrdClosure(prd(1), [
    resolvedChild(2),
    resolvedChild(3, { state: "OPEN", mergedClosed: false }),
  ]);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /open|unmerged/i);
  assert.deepEqual(decision.openChildren.map((c) => c.number), [3]);
});

test("evaluatePrdClosure — skips when a child is closed WITHOUT a merged PR", () => {
  const decision = evaluatePrdClosure(prd(1), [
    resolvedChild(2),
    resolvedChild(3, { state: "CLOSED", mergedClosed: false }),
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
  const decision = evaluatePrdClosure(prd(1, { labels: [{ name: "work:standalone" }] }), [
    resolvedChild(2),
  ]);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /work:prd/);
});

test("evaluatePrdClosure — skips when parent is not open", () => {
  const decision = evaluatePrdClosure(prd(1, { state: "CLOSED" }), [resolvedChild(2)]);
  assert.equal(decision.close, false);
  assert.match(decision.skipReason, /open/i);
});

test("buildCloseComment — cross-links completed children and their merge PRs", () => {
  const decision = evaluatePrdClosure(prd(1), [resolvedChild(2), resolvedChild(3)]);
  const comment = buildCloseComment(decision);
  assert.match(comment, /#2/);
  assert.match(comment, /#1002/);
  assert.match(comment, /#3/);
  assert.match(comment, /#1003/);
  assert.match(comment, /ralph-orchestrator/i);
});

// ---- runCloseCompletedPrds (end-to-end with stubbed gh, REAL shapes) --------

test("runCloseCompletedPrds — selects all-merged PRD, skips open-child and zero-child", async () => {
  const prds = [prd(1), prd(5), prd(8)];
  const allIssues = [
    // #1 — both children closed via merged PRs (1002, 1003) → CLOSE
    child(2, 1, { prNumber: 1002 }),
    child(3, 1, { prNumber: 1003 }),
    // #5 — one open child → SKIP
    child(6, 5, { prNumber: 1006 }),
    child(7, 5, { state: "OPEN" }),
    // #8 — zero children → SKIP
  ];
  const closeCalls = [];
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: false,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    getPrMergedAt: makeGetPrMergedAt([1002, 1003, 1006]),
    closeIssue: async (args) => closeCalls.push(args),
  });

  assert.deepEqual(result.closable, [1]);
  assert.deepEqual(result.closed, [1]);
  assert.equal(result.mutations, 1);
  assert.equal(closeCalls.length, 1);
  assert.equal(closeCalls[0].number, 1);
  assert.equal(closeCalls[0].reason, "completed");
  assert.match(closeCalls[0].comment, /#2/);
  assert.match(closeCalls[0].comment, /#1002/);

  const skipped = result.decisions.filter((d) => !d.close);
  assert.deepEqual(skipped.map((d) => d.number).sort((a, b) => a - b), [5, 8]);
});

test("runCloseCompletedPrds — a child closed WITHOUT a merged PR blocks the parent", async () => {
  const prds = [prd(1)];
  const allIssues = [
    child(2, 1, { prNumber: 1002 }),
    // #3 is closed but its closing PR 1003 was never merged.
    child(3, 1, { prNumber: 1003 }),
  ];
  const closeCalls = [];
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: false,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    getPrMergedAt: makeGetPrMergedAt([1002]), // 1003 NOT merged
    closeIssue: async (args) => closeCalls.push(args),
  });
  assert.deepEqual(result.closable, []);
  assert.equal(result.mutations, 0);
  assert.equal(closeCalls.length, 0);
  const d = result.decisions.find((x) => x.number === 1);
  assert.match(d.skipReason, /merged/i);
});

test("runCloseCompletedPrds — a child closed with NO closing PR ref blocks the parent", async () => {
  const prds = [prd(1)];
  const allIssues = [
    child(2, 1, { prNumber: 1002 }),
    child(3, 1, { prNumber: null }), // closed manually / not_planned, no PR ref
  ];
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: false,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    getPrMergedAt: makeGetPrMergedAt([1002, 1003]),
    closeIssue: async () => {
      throw new Error("must not close");
    },
  });
  assert.deepEqual(result.closable, []);
  assert.equal(result.mutations, 0);
});

test("runCloseCompletedPrds — fail-safe: an undeterminable merge lookup blocks", async () => {
  const prds = [prd(1)];
  const allIssues = [child(2, 1, { prNumber: 1002 }), child(3, 1, { prNumber: 1003 })];
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: false,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    getPrMergedAt: makeGetPrMergedAt([1002, 1003], { throwFor: new Set([1003]) }),
    closeIssue: async () => {
      throw new Error("must not close");
    },
  });
  assert.deepEqual(result.closable, []);
  assert.equal(result.mutations, 0);
});

test("runCloseCompletedPrds — code-block 'Parent #N' example does NOT make a zero-child PRD eligible", async () => {
  const prds = [prd(1)];
  const allIssues = [
    // An unrelated CLOSED+merged issue that only shows the marker in a fenced
    // code example. It must NOT be counted as a child of #1, so #1 has zero real
    // children and stays open.
    {
      number: 99,
      title: "Docs: how parents work",
      url: "https://github.com/octo/alisterr/issues/99",
      state: "CLOSED",
      labels: [{ name: "documentation" }],
      body: "Example:\n```\nParent #1\n```\nThat is how it links.",
      closedByPullRequestsReferences: [
        { number: 1099, url: "https://github.com/octo/alisterr/pull/1099", repository: { name: "alisterr" } },
      ],
    },
  ];
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: false,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    getPrMergedAt: makeGetPrMergedAt([1099]),
    closeIssue: async () => {
      throw new Error("must not close a zero-child PRD");
    },
  });
  assert.deepEqual(result.closable, []);
  assert.equal(result.mutations, 0);
  const d = result.decisions.find((x) => x.number === 1);
  assert.match(d.skipReason, /no child|zero/i);
});

test("runCloseCompletedPrds — --dry-run performs ZERO mutations but still reports closable", async () => {
  const prds = [prd(1), prd(5)];
  const allIssues = [
    child(2, 1, { prNumber: 1002 }),
    child(3, 1, { prNumber: 1003 }),
    child(7, 5, { state: "OPEN" }),
  ];
  let closeCalled = false;
  const result = await runCloseCompletedPrds({
    slug: "octo/alisterr",
    dryRun: true,
    now: FIXED_NOW,
    listOpenPrds: async () => prds,
    listAllIssues: async () => allIssues,
    getPrMergedAt: makeGetPrMergedAt([1002, 1003]),
    closeIssue: async () => {
      closeCalled = true;
    },
  });

  assert.equal(closeCalled, false);
  assert.equal(result.dryRun, true);
  assert.equal(result.mutations, 0);
  assert.deepEqual(result.closed, []);
  assert.deepEqual(result.closable, [1]);
  const skip5 = result.decisions.find((d) => d.number === 5);
  assert.equal(skip5.close, false);
  assert.match(skip5.skipReason, /open|merged/i);
});
