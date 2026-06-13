// close-completed-prds — the ONE issue closure the orchestrator may perform.
//
// The orchestrator MAY close a `work:prd` parent issue as completed ONLY when
// ALL of these hold (see skills/ralph-orchestrator/references/policy.md, which
// is the single source of truth for this rule):
//
//   1. the parent is OPEN and labeled `work:prd`;
//   2. it has at least ONE child slice (a child is an issue whose body carries
//      an exact top-level `Parent #<parent>` marker — the same marker preflight /
//      label-taxonomy use; markers inside fenced/inline code do NOT count);
//   3. EVERY child slice is CLOSED, and each was closed via a MERGED PR.
//
// A PRD parent is a tracking issue with no code of its own; its closure is
// justified entirely by its children's merged PRs. If ANY child is still open,
// or a child was closed WITHOUT a merged PR (closed manually / not_planned), or
// the parent has zero children, the parent is NOT closed.
//
// Merged-PR detection (IMPORTANT): `gh issue list/view --json
// closedByPullRequestsReferences` returns refs with { number, url, repository }
// and NO `state`/merge field (see ralph/lib/state.sh, ralph/ralph.sh). So we
// cannot infer "merged" from the ref alone — for each closing PR ref of a CLOSED
// child we look up `gh pr view <n> --json mergedAt` and require mergedAt != null.
// This mirrors issue_satisfaction_detail() in ralph/lib/state.sh. The check is
// fail-safe: if merge status can't be determined, the child is treated as NOT
// merged and BLOCKS the parent.
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
 * Remove fenced code blocks (``` … ``` / ~~~ … ~~~) and inline code (`…`) from a
 * body before scanning for the `Parent #N` marker. Without this, an unrelated
 * issue that merely shows `Parent #<n>` inside a code example would be misread
 * as a child slice. Only balanced fences are stripped so a real top-level marker
 * is never accidentally removed.
 */
export function stripCodeBlocks(body = "") {
  return String(body || "")
    .replace(/```[\s\S]*?```/g, "\n")
    .replace(/~~~[\s\S]*?~~~/g, "\n")
    .replace(/`[^`\n]*`/g, " ");
}

/**
 * The parent number a child body declares, ignoring code blocks. Reuses the
 * canonical, line-anchored `label-taxonomy.parseParentNumber` so child detection
 * stays consistent with preflight/enqueue; the only addition is code-fence
 * stripping (close-path concern, doesn't touch the shared parser).
 */
export function parentNumberFromBody(body = "") {
  return parseParentNumber(stripCodeBlocks(body));
}

/**
 * The closing PR references on an issue, as { number, url }. `gh`'s
 * closedByPullRequestsReferences carries no merge state, so callers must look up
 * each PR's mergedAt separately.
 */
export function closingPrRefs(issue) {
  const refs = Array.isArray(issue?.closedByPullRequestsReferences)
    ? issue.closedByPullRequestsReferences
    : [];
  return refs
    .map((pr) => ({ number: Number(pr?.number), url: pr?.url ?? null }))
    .filter((ref) => Number.isFinite(ref.number));
}

/**
 * Group issues into a Map keyed by their parent number, using the exact
 * top-level `Parent #N` body marker (code blocks ignored). Issues without a
 * real marker are dropped.
 *
 * @param {Array<object>} allIssues
 * @returns {Map<number, Array<object>>}
 */
export function groupChildrenByParent(allIssues = []) {
  const map = new Map();
  for (const issue of allIssues) {
    const parent = parentNumberFromBody(issue?.body || "");
    if (parent == null) continue;
    if (!map.has(parent)) map.set(parent, []);
    map.get(parent).push(issue);
  }
  return map;
}

/**
 * Resolve whether a child issue is "closed via a merged PR".
 *
 * A child qualifies only when it is CLOSED and at least one of its closing PR
 * references has a non-null mergedAt. `getPrMergedAt` is injected (defaults to
 * `gh pr view <n> --json mergedAt`). Fail-safe: a lookup that throws or returns
 * nullish counts as NOT merged, so an undeterminable child blocks the parent.
 *
 * @returns {Promise<{number:number, url:string|null, state:string|null,
 *   mergedClosed:boolean, mergePr:{number:number, url:string|null}|null}>}
 */
export async function resolveChildMergeStatus(issue, { slug, getPrMergedAt } = {}) {
  const base = {
    number: issue?.number,
    url: issue?.url ?? null,
    state: issue?.state ?? null,
    mergedClosed: false,
    mergePr: null,
  };
  if (upper(issue?.state) !== "CLOSED") return base;

  for (const ref of closingPrRefs(issue)) {
    let mergedAt = null;
    try {
      mergedAt = await getPrMergedAt({ slug, prNumber: ref.number });
    } catch {
      mergedAt = null; // fail-safe: undeterminable → treat as not merged
    }
    if (mergedAt && String(mergedAt) !== "null") {
      return { ...base, mergedClosed: true, mergePr: { number: ref.number, url: ref.url } };
    }
  }
  return base; // closed but no merged PR (or no closing PR ref) → blocks
}

/**
 * Evaluate a single PRD parent against its RESOLVED children and decide whether
 * the orchestrator may close it. Pure — no I/O. Each resolved child must carry a
 * boolean `mergedClosed` (see resolveChildMergeStatus).
 *
 * @param {object} parent  The candidate `work:prd` issue.
 * @param {Array<object>} resolvedChildren  Children with merge status resolved.
 * @returns {{
 *   close: boolean,
 *   skipReason: string|null,
 *   childCount: number,
 *   mergedChildren: Array<{number:number, url:string|null, prNumber:number|null, prUrl:string|null}>,
 *   openChildren: Array<object>,
 * }}
 */
export function evaluatePrdClosure(parent, resolvedChildren = []) {
  const labels = labelNames(parent?.labels);
  const isOpen = upper(parent?.state) === "OPEN";
  const isPrd = labels.includes("work:prd");
  const children = Array.isArray(resolvedChildren) ? resolvedChildren : [];

  const base = {
    close: false,
    skipReason: null,
    childCount: children.length,
    mergedChildren: [],
    openChildren: [],
  };

  if (!isOpen) {
    return { ...base, skipReason: "parent is not open" };
  }
  if (!isPrd) {
    return { ...base, skipReason: "parent is not labeled work:prd" };
  }
  if (children.length === 0) {
    return { ...base, skipReason: "no child slices (zero children)" };
  }

  // A child blocks closure if it is not closed-via-merged-PR (still open, or
  // closed without a merged PR).
  const blocking = children.filter((child) => child?.mergedClosed !== true);
  if (blocking.length > 0) {
    const anyOpen = blocking.some((child) => upper(child.state) !== "CLOSED");
    const reason = anyOpen
      ? "has an open child slice (not yet delivered)"
      : "has a child closed without a merged PR";
    return { ...base, skipReason: reason, openChildren: blocking };
  }

  const mergedChildren = children.map((child) => ({
    number: child.number,
    url: child.url ?? null,
    prNumber: child.mergePr?.number ?? null,
    prUrl: child.mergePr?.url ?? null,
  }));

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

// Mirror ralph/lib/state.sh: look up a PR's mergedAt and treat non-null as
// merged. Returns the mergedAt string, or null when not merged / unknown.
function defaultGetPrMergedAt({ slug, prNumber }) {
  const result = spawnSync(
    "gh",
    ["pr", "view", String(prNumber), "--repo", slug, "--json", "mergedAt", "-q", ".mergedAt"],
    { encoding: "utf8", maxBuffer: 1024 * 1024 },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || "gh pr view failed");
  const out = String(result.stdout || "").trim();
  return out && out !== "null" ? out : null;
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
 * Read-only discovery (listOpenPrds + listAllIssues) plus a per-child
 * `gh pr view <n> --json mergedAt` merge lookup. With `dryRun: true` it computes
 * decisions and performs ZERO mutations. Without it, each closable parent is
 * closed as completed with a cross-link comment.
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
    getPrMergedAt = defaultGetPrMergedAt,
    closeIssue = defaultCloseIssue,
  } = options;

  if (!slug) throw new Error("runCloseCompletedPrds requires a repo slug (owner/name)");

  const prds = (await listOpenPrds(slug)) || [];
  const allIssues = (await listAllIssues(slug)) || [];
  const childrenByParent = groupChildrenByParent(allIssues);

  const decisions = [];
  for (const prd of prds) {
    const rawChildren = childrenByParent.get(Number(prd.number)) || [];
    const resolvedChildren = [];
    for (const child of rawChildren) {
      resolvedChildren.push(await resolveChildMergeStatus(child, { slug, getPrMergedAt }));
    }
    const decision = evaluatePrdClosure(prd, resolvedChildren);
    decisions.push({
      number: prd.number,
      url: prd.url ?? null,
      title: prd.title ?? null,
      ...decision,
    });
  }

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
