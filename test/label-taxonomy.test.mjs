import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  CANONICAL_LABELS,
  buildLabelSchemaPlan,
  classifyIssue,
  orderIssuesForQueue,
  planBackfill,
  planRepair,
  planRuntimeTransition,
  priorityRankFromShort,
  validateRunnableForClaim,
  validatePrdForEnqueue,
  validateRunnableForEnqueue,
} from "../extension/lib/label-taxonomy.mjs";

describe("priorityRankFromShort", () => {
  it("maps short priority strings to their numeric rank", () => {
    assert.equal(priorityRankFromShort("P0"), 0);
    assert.equal(priorityRankFromShort("P1"), 1);
    assert.equal(priorityRankFromShort("P2"), 2);
    assert.equal(priorityRankFromShort("P3"), 3);
  });

  it("accepts values that still carry the priority: prefix", () => {
    assert.equal(priorityRankFromShort("priority:P0"), 0);
    assert.equal(priorityRankFromShort("priority:P1"), 1);
    assert.equal(priorityRankFromShort("priority:P3"), 3);
  });

  it("defaults null/undefined/unknown to the P2 band", () => {
    const p2 = priorityRankFromShort("P2");
    assert.equal(priorityRankFromShort(null), p2);
    assert.equal(priorityRankFromShort(undefined), p2);
    assert.equal(priorityRankFromShort("nonsense"), p2);
    assert.equal(priorityRankFromShort(""), p2);
  });
});


describe("Ralph label taxonomy", () => {
  it("defines the canonical label schema with exact names, colors, and descriptions", () => {
    assert.deepEqual(
      CANONICAL_LABELS.map(({ name, color, description }) => ({ name, color, description })),
      [
        { name: "ralph:needs-triage", color: "FBCA04", description: "Needs human triage before Ralph automation" },
        { name: "ralph:evaluated", color: "C5DEF5", description: "Reviewed and accepted, but not yet queued for Ralph" },
        { name: "ralph:fast-lane", color: "BFD4F2", description: "AUTO-eligible candidate; awaiting one-tap promotion to ralph:ready" },
        { name: "ralph:ready", color: "0E8A16", description: "Safe for Ralph to queue and run" },
        { name: "ralph:blocked", color: "D93F0B", description: "Ralph-ready but waiting on unsatisfied dependencies" },
        { name: "ralph:hitl", color: "B60205", description: "Requires human judgment/action; Ralph must not run" },
        { name: "ralph:queued", color: "1D76DB", description: "Queued for Ralph workers" },
        { name: "ralph:running", color: "0052CC", description: "Currently claimed by a Ralph worker" },
        { name: "ralph:done", color: "CED0D4", description: "Completed by Ralph-verified merged work" },
        { name: "ralph:failed", color: "E11D21", description: "Ralph attempted work but human recovery is required" },
        { name: "priority:P0", color: "B60205", description: "Stop-the-line priority; sorts first, no auto-preemption" },
        { name: "priority:P1", color: "D93F0B", description: "High priority" },
        { name: "priority:P2", color: "FBCA04", description: "Normal/default priority" },
        { name: "priority:P3", color: "C2E0C6", description: "Nice-to-have / low priority" },
        { name: "work:prd", color: "5319E7", description: "Parent PRD/spec issue; not directly runnable" },
        { name: "work:slice", color: "1D76DB", description: "PRD child tracer-bullet issue" },
        { name: "work:standalone", color: "C5DEF5", description: "Runnable one-off issue with no PRD parent" },
      ],
    );
  });

  it("parses exactly one state, priority, and work label without removing repo labels", () => {
    const result = classifyIssue({
      number: 12,
      title: "Implement queue health",
      labels: ["bug", "ralph:ready", "priority:P1", "work:standalone", "area:dashboard"],
    });

    assert.equal(result.state, "ralph:ready");
    assert.equal(result.priority, "priority:P1");
    assert.equal(result.workType, "work:standalone");
    assert.deepEqual(result.repoLabels, ["bug", "area:dashboard"]);
    assert.deepEqual(result.conflicts, []);
  });

  it("reports conflicts when exclusive dimensions contain multiple canonical labels", () => {
    const result = classifyIssue({
      number: 13,
      title: "Conflicting issue",
      labels: [
        "ralph:ready",
        "ralph:hitl",
        "priority:P1",
        "priority:P3",
        "work:slice",
        "work:standalone",
      ],
    });

    assert.deepEqual(result.conflicts.map((conflict) => conflict.dimension), ["state", "priority", "work"]);
    assert.equal(result.runnable, false);
  });

  it("defaults missing priority to P2 with a warning", () => {
    const result = classifyIssue({
      number: 14,
      title: "Default priority",
      labels: ["ralph:ready", "work:standalone"],
    });

    assert.equal(result.priority, "priority:P2");
    assert.ok(result.warnings.some((warning) => warning.type === "missing_priority"));
  });

  it("rejects legacy aliases in canonical-only mode and warns when compatibility mode maps them", () => {
    const issue = {
      number: 15,
      title: "Legacy ready task",
      labels: ["ready-for-agent"],
      body: "Standalone task",
    };

    const canonicalOnly = classifyIssue(issue);
    assert.equal(canonicalOnly.state, null);
    assert.equal(canonicalOnly.runnable, false);
    assert.ok(canonicalOnly.warnings.some((warning) => warning.type === "missing_state"));

    const compat = classifyIssue(issue, { compatibilityAliases: true });
    assert.equal(compat.state, "ralph:ready");
    assert.equal(compat.workType, "work:standalone");
    assert.ok(compat.warnings.some((warning) => warning.type === "legacy_alias"));
    assert.equal(compat.runnable, true);
  });

  it("emits a dry-run schema plan unless apply is explicit", () => {
    const dryRun = buildLabelSchemaPlan({ repo: "owner/repo" });
    assert.equal(dryRun.dryRun, true);
    assert.equal(dryRun.commands[0], "gh label create ralph:needs-triage --repo 'owner/repo' --color FBCA04 --description 'Needs human triage before Ralph automation'");

    const quotedRepo = buildLabelSchemaPlan({ repo: "owner/repo; touch /tmp/pwned" });
    assert.match(quotedRepo.commands[0], /--repo 'owner\/repo; touch \/tmp\/pwned'/);
    assert.doesNotMatch(quotedRepo.commands[0], /--repo owner\/repo; touch/);

    const apply = buildLabelSchemaPlan({ repo: "owner/repo", apply: true });
    assert.equal(apply.dryRun, false);
    assert.equal(apply.commands.length, CANONICAL_LABELS.length);
  });

  it("validates PRD parents and runnable child/standalone issues for enqueue", () => {
    const prd = validatePrdForEnqueue({
      number: 20,
      state: "OPEN",
      labels: ["ralph:evaluated", "priority:P1", "work:prd"],
    });
    assert.equal(prd.ok, true);

    const badPrd = validatePrdForEnqueue({
      number: 21,
      state: "OPEN",
      labels: ["ralph:ready", "priority:P1", "work:prd"],
    });
    assert.equal(badPrd.ok, false);
    assert.match(badPrd.reasons.join(" "), /ralph:evaluated/);

    const runnable = validateRunnableForEnqueue({
      number: 22,
      state: "OPEN",
      labels: ["ralph:ready", "priority:P0", "work:slice"],
      body: "Parent #20\n\n## Blocked by\nNone",
      assignees: [],
    });
    assert.equal(runnable.ok, true);

    const queued = {
      number: 24,
      state: "OPEN",
      labels: ["ralph:queued", "priority:P2", "work:standalone"],
      body: "Standalone task",
      assignees: [],
    };
    const queuedForEnqueue = validateRunnableForEnqueue(queued);
    assert.equal(queuedForEnqueue.ok, false);
    assert.match(queuedForEnqueue.reasons.join(" "), /ralph:ready/);

    const queuedForClaim = validateRunnableForClaim(queued);
    assert.equal(queuedForClaim.ok, true);

    const assigned = validateRunnableForEnqueue({
      number: 23,
      state: "OPEN",
      labels: ["ralph:ready", "priority:P2", "work:standalone"],
      assignees: [{ login: "human" }],
    });
    assert.equal(assigned.ok, false);
    assert.match(assigned.reasons.join(" "), /assigned/);
  });

  it("plans non-destructive open-issue backfill and never infers P0", () => {
    const plan = planBackfill([
      {
        number: 30,
        state: "OPEN",
        title: "PRD: Improve queue",
        labels: ["needs-triage", "severity:critical", "domain:music"],
      },
      {
        number: 31,
        state: "OPEN",
        title: "Slice 1: Build model",
        body: "Parent #30",
        labels: ["ready-for-agent", "severity:low"],
      },
      {
        number: 32,
        state: "CLOSED",
        title: "Old closed task",
        labels: ["ready-for-agent"],
      },
    ]);

    assert.equal(plan.dryRun, true);
    assert.deepEqual(plan.actions.find((action) => action.issueNumber === 30).addLabels, [
      "ralph:needs-triage",
      "work:prd",
      "priority:P1",
    ]);
    assert.deepEqual(plan.actions.find((action) => action.issueNumber === 31).addLabels, [
      "ralph:ready",
      "work:slice",
      "priority:P3",
    ]);
    assert.equal(plan.actions.some((action) => action.issueNumber === 32), false);
    assert.equal(plan.actions.flatMap((action) => action.addLabels).includes("priority:P0"), false);
  });

  it("orders queues dependency-first with priority sorting only on the unblocked frontier", () => {
    const ordered = orderIssuesForQueue([
      { number: 40, title: "Low dependency", labels: ["ralph:ready", "priority:P3", "work:standalone"] },
      { number: 41, title: "P0 dependent", body: "## Blocked by\n- #40", labels: ["ralph:ready", "priority:P0", "work:standalone"] },
      { number: 42, title: "P1 independent", labels: ["ralph:ready", "priority:P1", "work:standalone"] },
    ]);

    assert.deepEqual(ordered.map((issue) => issue.number), [42, 40, 41]);
    assert.equal(ordered.preemptActiveWorkers, false);
  });

  it("treats failed blockers as unsatisfied dependencies", () => {
    const ordered = orderIssuesForQueue([
      { number: 50, title: "Failed prerequisite", labels: ["ralph:failed", "priority:P1", "work:standalone"] },
      { number: 51, title: "Dependent", body: "## Blocked by\n- #50", labels: ["ralph:ready", "priority:P0", "work:standalone"] },
    ]);

    assert.deepEqual(ordered.blocked.map((entry) => entry.issue.number), [51]);
    assert.match(ordered.blocked[0].reason, /failed/i);
  });

  it("plans stale runtime repair without mutating labels", () => {
    const plan = planRepair([
      { number: 60, labels: ["ralph:running", "priority:P2", "work:standalone"] },
      { number: 61, labels: ["ralph:queued", "ralph:running", "priority:P2", "work:standalone"] },
    ], { liveClaims: [] });

    assert.equal(plan.dryRun, true);
    assert.deepEqual(plan.actions.find((action) => action.issueNumber === 60).addLabels, ["ralph:queued"]);
    assert.deepEqual(plan.actions.find((action) => action.issueNumber === 60).removeLabels, ["ralph:running"]);
    assert.equal(plan.actions.find((action) => action.issueNumber === 61).type, "conflict");
  });

  it("plans normal runtime label transitions and rejects invalid transitions", () => {
    const queued = planRuntimeTransition({
      issue: { number: 70, labels: ["ralph:ready", "priority:P2", "work:standalone"] },
      transition: "enqueue",
    });
    assert.deepEqual(queued.addLabels, ["ralph:queued"]);
    assert.deepEqual(queued.removeLabels, ["ralph:ready", "ralph:blocked"]);

    const done = planRuntimeTransition({
      issue: { number: 71, labels: ["ralph:running", "priority:P2", "work:standalone"] },
      transition: "complete",
    });
    assert.deepEqual(done.addLabels, ["ralph:done"]);
    assert.deepEqual(done.removeLabels, ["ralph:running"]);

    assert.throws(
      () => planRuntimeTransition({
        issue: { number: 72, labels: ["ralph:ready", "priority:P2", "work:standalone"] },
        transition: "complete",
      }),
      /requires ralph:running/,
    );
  });
});
