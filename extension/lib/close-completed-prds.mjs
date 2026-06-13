// close-completed-prds — the ONE issue closure the orchestrator may perform.
//
// The orchestrator MAY close a `work:prd` parent issue as completed ONLY when
// ALL of these hold (see skills/ralph-orchestrator/references/policy.md, which
// is the single source of truth for this rule):
//
//   1. the parent is OPEN and labeled `work:prd`;
//   2. it has at least ONE child slice (a child is an issue whose body carries
//      an exact `Parent #<parent>` marker — the same marker preflight /
//      label-taxonomy use);
//   3. EVERY child slice is CLOSED, and each was closed via a MERGED PR.
//
// A PRD parent is a tracking issue with no code of its own; its closure is
// justified entirely by its children's merged PRs. If ANY child is still open,
// or a child was closed WITHOUT a merged PR, or the parent has zero children,
// the parent is NOT closed.
//
// This module never closes a `work:slice` / `work:standalone` issue (those
// close only via their own merged PR, by the worker), never uses `--admin`, and
// never bypasses branch protection. All gh interaction is injectable so the
// rule can be unit-tested without the network.

import { spawnSync } from "node:child_process";

import { parseParentNumber } from "./label-taxonomy.mjs";

function labelNames(labels) {
  if (!Array.isArray(labels)) return [];
  return labels
    .map((label) => (typeof label === "string" ? label : label?.name))
    .filter((name) => typeof name === "string" && name.length > 0);
}

function upper(value) {
  return String(value || "").toUpperCase();
}

/**
 * True only when an issue is CLOSED and at least one of its
 * closedByPullRequestsReferences is MERGED. A closed-as-not_planned issue with
 * no merged PR returns false (we never treat that as "delivered").
 */
export function isClosedByMergedPr(issue) {
  if (!issue || typeof issue !== "object") return false;
  if (upper(issue.state) !== "CLOSED") return false;
  const refs = Array.isArray(issue.closedByPullRequestsReferences)
    ? issue.closedByPullRequestsReferences
    : [];
  return refs.some((pr) => pr && upper(pr.state) === "MERGED");
}

/** Return the merged PR reference (number/url) that closed an issue, or null. */
export function mergedPrRef(issue) {
  const refs = Array.isArray(issue?.closedByPullRequestsReferences)
    ? issue.closedByPullRequestsReferences
    : [];
  const merged = refs.find((pr) => pr && upper(pr.state) === "MERGED");
  if (!merged) return null;
  return { number: merged.number ?? null, url: merged.url ?? null };
}

/**
 * Group issues into a Map keyed by their parent number, using the exact
 * `Parent #N` body marker (parseParentNumber). Issues without a marker are
 * dropped. Reuses the repo's canonical child-detection logic so child
 * identification matches preflight / enqueue.
 *
 * @param {Array<object>} allIssues
 * @returns {Map<number, Array<object>>}
 */
export function groupChildrenByParent(allIssues = []) {
  const map = new Map();
  for (const issue of allIssues) {
    const parent = parseParentNumber(issue?.body || "");
    if (parent == null) continue;
    if (!map.has(parent)) map.set(parent, []);
    map.get(parent).push(issue);
  }
  return map;
}

/**
 * Evaluate a single PRD parent against its children and decide whether the
 * orchestrator may close it. Pure — no I/O.
 *
 * @param {object} parent  The candidate `work:prd` issue.
 * @param {Array<object>} children  Issues whose body marks this parent.
 * @returns {{
 *   close: boolean,
 *   skipReason: string|null,
 *   childCount: number,
 *   mergedChildren: Array<{number:number, prNumber:number|null, prUrl:string|null, url:string|null}>,
 *   openChildren: Array<object>,
 * }}
 */
export function evaluatePrdClosure(parent, children = []) {
  const labels = labelNames(parent?.labels);
  const isOpen = upper(parent?.state) === "OPEN";
  const isPrd = labels.includes("work:prd");

  const base = {
    close: false,
    skipReason: null,
    childCount: Array.isArray(children) ? children.length : 0,
    mergedChildren: [],
    openChildren: [],
  };

  if (!isOpen) {
    return { ...base, skipReason: "parent is not open" };
  }
  if (!isPrd) {
    return { ...base, skipReason: "parent is not labeled work:prd" };
  }
  if (!Array.isArray(children) || children.length === 0) {
    return { ...base, skipReason: "no child slices (zero children)" };
  }

  // A child blocks closure if it is not closed-via-merged-PR (still open, or
  // closed without a merged PR).
  const blocking = children.filter((child) => !isClosedByMergedPr(child));
  if (blocking.length > 0) {
    const anyOpen = blocking.some((child) => upper(child.state) !== "CLOSED");
    const reason = anyOpen
      ? "has an open child slice (not yet delivered)"
      : "has a child closed without a merged PR";
    return { ...base, skipReason: reason, openChildren: blocking };
  }

  const mergedChildren = children.map((child) => {
    const ref = mergedPrRef(child);
    return {
      number: child.number,
      url: child.url ?? null,
      prNumber: ref?.number ?? null,
      prUrl: ref?.url ?? null,
    };
  });

  return { ...base, close: true, mergedChildren };
}

/**
 * Build the cross-linking comment posted when a PRD parent is closed. Lists each
 * completed child slice and its merge PR, and names the rule for auditability.
 */
export function buildCloseComment(decision) {
  const lines = [];
  const n = decision.mergedChildren.length;
  lines.push(
    `Closing as completed — all ${n} child slice${n === 1 ? "" : "s"} have been ` +
      `delivered via merged PRs:`,
  );
  lines.push("");
  for (const child of decision.mergedChildren) {
    const pr = child.prNumber ? ` (merged in #${child.prNumber})` : " (merged PR)";
    lines.push(`- #${child.number}${pr}`);
  }
  lines.push("");
  lines.push(
    "This PRD parent is a tracking issue with no code of its own; its closure is " +
      "justified by the merged PRs above. Closed automatically by ralph-orchestrator " +
      "under the work:prd parent-close rule (all child slices closed via merged PRs).",
  );
  return lines.join("\n");
}

// ---- Default (real) gh collaborators -------------------------------------

function ghJson(args) {
  const result = spawnSync("gh", args, { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || "gh command failed");
  return JSON.parse(result.stdout || "[]");
}

function defaultListOpenPrds(slug) {
  return ghJson([
    "issue", "list",
    "--repo", slug,
    "--label", "work:prd",
    "--state", "open",
    "--json", "number,title,url,state,labels,body",
    "--limit", "200",
  ]);
}

function defaultListAllIssues(slug) {
  return ghJson([
    "issue", "list",
    "--repo", slug,
    "--state", "all",
    "--json", "number,title,url,state,labels,body,closedByPullRequestsReferences",
    "--limit", "1000",
  ]);
}

function defaultCloseIssue({ slug, number, comment }) {
  const args = ["issue", "close", String(number), "--repo", slug, "--reason", "completed"];
  if (comment) args.push("--comment", comment);
  const result = spawnSync("gh", args, { encoding: "utf8", maxBuffer: 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || "gh issue close failed");
  return result.stdout;
}

/**
 * Reconcile open `work:prd` parents for a repo: close any whose child slices are
 * ALL closed-via-merged-PR. OPT-IN — callers gate this behind an explicit flag.
 *
 * Read-only discovery (listOpenPrds + listAllIssues). With `dryRun: true` it
 * computes decisions and performs ZERO mutations. Without it, each closable
 * parent is closed as completed with a cross-link comment.
 *
 * All gh interaction is injectable for testing.
 */
export async function runCloseCompletedPrds(options = {}) {
  const {
    slug,
    dryRun = false,
    now = () => new Date(),
    listOpenPrds = defaultListOpenPrds,
    listAllIssues = defaultListAllIssues,
    closeIssue = defaultCloseIssue,
  } = options;

  if (!slug) throw new Error("runCloseCompletedPrds requires a repo slug (owner/name)");

  const prds = (await listOpenPrds(slug)) || [];
  const allIssues = (await listAllIssues(slug)) || [];
  const childrenByParent = groupChildrenByParent(allIssues);

  const decisions = prds.map((prd) => {
    const children = childrenByParent.get(Number(prd.number)) || [];
    const decision = evaluatePrdClosure(prd, children);
    return {
      number: prd.number,
      url: prd.url ?? null,
      title: prd.title ?? null,
      ...decision,
    };
  });

  const closable = decisions.filter((d) => d.close);
  const closed = [];
  const errors = [];

  if (!dryRun) {
    for (const decision of closable) {
      const comment = buildCloseComment(decision);
      try {
        await closeIssue({ slug, number: decision.number, reason: "completed", comment });
        closed.push(decision.number);
      } catch (err) {
        errors.push({ number: decision.number, message: String(err?.message || err) });
      }
    }
  }

  return {
    slug,
    dryRun,
    at: now().toISOString(),
    decisions,
    closable: closable.map((d) => d.number),
    closed,
    errors,
    mutations: dryRun ? 0 : closed.length,
  };
}

/** Render a concise human summary of a close-completed-prds run. */
export function renderCloseCompletedPrds(result) {
  const lines = [];
  const mode = result.dryRun ? "dry-run (no mutations)" : "live";
  lines.push(`Ralph PRD reconcile — ${result.slug} (${mode})`);
  if (result.decisions.length === 0) {
    lines.push("  no open work:prd parents found");
    return lines.join("\n");
  }
  for (const d of result.decisions) {
    if (d.close) {
      const children = d.mergedChildren
        .map((c) => `#${c.number}${c.prNumber ? `→#${c.prNumber}` : ""}`)
        .join(", ");
      const verb = result.dryRun ? "WOULD CLOSE" : "CLOSED";
      lines.push(`  #${d.number} ${verb} — ${d.childCount} child slice(s) delivered: ${children}`);
    } else {
      lines.push(`  #${d.number} skip — ${d.skipReason}`);
    }
  }
  if (result.errors.length > 0) {
    lines.push("  errors:");
    for (const e of result.errors) lines.push(`    #${e.number}: ${e.message}`);
  }
  lines.push(
    `  ${result.dryRun ? "would close" : "closed"}: ${result.closable.length}, mutations: ${result.mutations}`,
  );
  return lines.join("\n");
}
