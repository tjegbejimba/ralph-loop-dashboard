import { RALPH_STATES, classifyIssue, parseParentNumber, parseBlockerNumbers } from "./label-taxonomy.mjs";
import { evaluateIssueForTriage } from "./issue-triage.mjs";
import { routeIssueToLane } from "./lane-routing.mjs";

function labelNames(labels) {
  if (!Array.isArray(labels)) return [];
  return labels
    .map((label) => (typeof label === "string" ? label : label?.name))
    .filter((name) => typeof name === "string" && name.length > 0);
}

/**
 * Check if an issue can be promoted, applying promotion guards.
 * Returns null if promotion is allowed, or an error reason if blocked.
 *
 * @param {object} issue
 * @param {string} targetLabel
 * @param {string} lane
 * @returns {string | null}
 */
function checkPromotionGuards(issue, targetLabel, lane) {
  // Guard: Taxonomy conflicts
  const classification = classifyIssue(issue);
  if (classification.conflicts && classification.conflicts.length > 0) {
    return `Taxonomy conflict: ${classification.conflicts[0].message}`;
  }

  // Guard: Open linked PR
  // NOTE: gh issue list/view does NOT return PR state in closedByPullRequestsReferences.
  // The guard relies on the caller enriching PR state before invoking promoteLaneForIssue.
  // If state is missing, we assume the PR may be open and block as a fail-safe.
  const linkedPrs = issue?.closedByPullRequestsReferences || [];
  const openPrs = linkedPrs.filter((pr) => {
    // If state is explicitly set, trust it
    if (pr?.state === "CLOSED" || pr?.state === "MERGED") return false;
    if (pr?.state === "OPEN") return true;
    // If state is missing, treat as potentially open (fail-safe)
    return pr?.number != null;
  });
  if (openPrs.length > 0) {
    return `Open linked PR exists: ${openPrs[0].url || "PR #" + openPrs[0].number}`;
  }

  // Guard: Assignee
  if (Array.isArray(issue?.assignees) && issue.assignees.length > 0) {
    return `Issue has assignee: ${issue.assignees[0].login}`;
  }

  // Guard: Unresolved blockers (except when routing to HOLD/ralph:blocked)
  const blockerNumbers = parseBlockerNumbers(issue?.body || "");
  if (blockerNumbers.length > 0 && targetLabel !== "ralph:blocked") {
    return `Unresolved blockers: ${blockerNumbers.map((n) => `#${n}`).join(", ")}`;
  }

  // Guard: Missing Parent for work:slice
  const currentLabels = labelNames(issue.labels);
  if (currentLabels.includes("work:slice")) {
    const parentNumber = parseParentNumber(issue?.body || "");
    if (parentNumber === null) {
      return "Missing Parent #N marker for work:slice issue";
    }
  }

  // Guard: Open questions / TBD evidence
  const body = String(issue?.body || "");
  if (/(?:^|\n)##\s+Open questions\b/i.test(body) || /\bTBD\b/.test(body)) {
    return "Open questions or TBD markers in body";
  }

  return null;
}

/**
 * Promote an issue to its target lane by adding the lane's target label and
 * removing conflicting ralph:* state labels.
 *
 * @param {object} params
 * @param {object} params.issue - The GitHub issue object
 * @param {object} params.opinion - The triage opinion from evaluateIssueForTriage
 * @param {object} params.route - The lane routing decision from routeIssueToLane
 * @param {boolean} params.live - Whether to actually apply mutations (false = dry-run)
 * @returns {object} - { issueNumber, lane, labelsAdded, labelsRemoved, skipped, skipReason, reason }
 */
export function promoteLaneForIssue({ issue, opinion, route, live = false }) {
  if (!issue || !opinion || !route) {
    throw new TypeError("issue, opinion, and route are required");
  }

  const issueNumber = Number(issue.number);
  const lane = route.lane;
  const targetLabel = route.targetLabel;
  const reason = route.reason;

  // Check promotion guards first (before targetLabel null check)
  const guardError = checkPromotionGuards(issue, targetLabel, lane);
  if (guardError) {
    return {
      issueNumber,
      lane,
      labelsAdded: [],
      labelsRemoved: [],
      skipped: true,
      skipReason: guardError,
      reason,
    };
  }

  // No-op when targetLabel is null (REFINE lane, closure-recommended HOLD)
  if (targetLabel === null) {
    return {
      issueNumber,
      lane,
      labelsAdded: [],
      labelsRemoved: [],
      skipped: true,
      skipReason: "Lane has no target label (no-op per design)",
      reason,
    };
  }

  // Calculate label mutations
  const currentLabels = labelNames(issue.labels);
  const currentRalphStates = currentLabels.filter((name) => RALPH_STATES.includes(name));

  const labelsAdded = [];
  const labelsRemoved = [];

  // Add target label if not present
  if (!currentLabels.includes(targetLabel)) {
    labelsAdded.push(targetLabel);
  }

  // PRD lane: ensure work:prd label
  if (lane === "PRD" && !currentLabels.includes("work:prd")) {
    labelsAdded.push("work:prd");
  }

  // Remove conflicting ralph:* state labels
  for (const stateLabel of currentRalphStates) {
    if (stateLabel !== targetLabel) {
      labelsRemoved.push(stateLabel);
    }
  }

  return {
    issueNumber,
    lane,
    labelsAdded,
    labelsRemoved,
    skipped: false,
    reason,
  };
}

/**
 * Run lane promotion for a batch of issues.
 *
 * @param {object} params
 * @param {Array<object>} params.issues - Array of GitHub issue objects
 * @param {boolean} params.live - Whether to actually apply mutations (false = dry-run)
 * @returns {object} - { promotions: [...], summary: { total, promoted, noOp, skipped } }
 */
export function runPromoteLanes({ issues, live = false }) {
  if (!Array.isArray(issues)) {
    throw new TypeError("issues must be an array");
  }

  const promotions = [];

  for (const issue of issues) {
    const opinion = evaluateIssueForTriage({ issue });
    const route = routeIssueToLane({ issue, opinion });
    const promotion = promoteLaneForIssue({ issue, opinion, route, live });

    promotions.push(promotion);
  }

  // Calculate summary stats
  const summary = {
    total: promotions.length,
    promoted: promotions.filter((p) => !p.skipped && (p.labelsAdded.length > 0 || p.labelsRemoved.length > 0)).length,
    noOp: promotions.filter((p) => !p.skipped && p.labelsAdded.length === 0 && p.labelsRemoved.length === 0).length,
    skipped: promotions.filter((p) => p.skipped).length,
  };

  return {
    promotions,
    summary,
  };
}
