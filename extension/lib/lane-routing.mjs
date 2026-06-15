import { parseBlockerNumbers, classifyIssue } from "./label-taxonomy.mjs";

/**
 * Route an issue to a lane (AUTO / REFINE / PRD / HOLD) based on triage opinion
 * and additional deterministic signals.
 *
 * @param {object} params
 * @param {object} params.issue - The GitHub issue object
 * @param {object} params.opinion - The triage opinion from evaluateIssueForTriage
 * @returns {{ lane: string, targetLabel: string | null, reason: string }}
 */
export function routeIssueToLane({ issue, opinion }) {
  if (!issue || !opinion) {
    throw new TypeError("issue and opinion are required");
  }

  // Close/Defer/Needs info recommendations - check these first
  if (opinion.recommendation === "Close") {
    return {
      lane: "HOLD",
      targetLabel: null,
      reason: "Recommended for closure — requires human action",
    };
  }

  if (opinion.recommendation === "Needs info") {
    return {
      lane: "REFINE",
      targetLabel: null,
      reason: "Needs info — missing critical context for scoring",
    };
  }

  // Check for blockers early (before AUTO predicate)
  const blockerNumbers = parseBlockerNumbers(issue?.body || "");
  if (blockerNumbers.length > 0) {
    return {
      lane: "HOLD",
      targetLabel: "ralph:blocked",
      reason: `Blocked by ${blockerNumbers.length} dependencies: ${blockerNumbers.map((n) => `#${n}`).join(", ")}`,
    };
  }

  // PRD lane: actual work:prd labeled issues OR (Pursue + inferred work:prd)
  // Check canonical label first to prevent labeled PRDs from routing to AUTO
  const classification = classifyIssue(issue);
  const hasWorkPrdLabel = classification.workType === "work:prd";
  const isPrdParent = hasWorkPrdLabel || (opinion.recommendation === "Pursue" && opinion.workTypeRecommendation === "work:prd");
  
  if (isPrdParent) {
    return {
      lane: "PRD",
      targetLabel: "ralph:evaluated",
      reason: "PRD parent issue — reviewed but not runnable by workers",
    };
  }

  // Defer after PRD check (non-PRD defers go to HOLD)
  if (opinion.recommendation === "Defer") {
    return {
      lane: "HOLD",
      targetLabel: null,
      reason: "Deferred — low priority until urgency/leverage increases",
    };
  }

  // Strict AUTO predicate:
  // Pursue + high + safe after prep + (work:slice OR work:standalone) + trusted author
  if (meetsAutoLanePredicate(issue, opinion)) {
    return {
      lane: "AUTO",
      targetLabel: "ralph:fast-lane",
      reason: "Meets strict AUTO predicate — candidate for autonomous work",
    };
  }

  // Default to REFINE for everything else (Pursue with medium confidence, Refine recommendation, untrusted authors, etc.)
  return {
    lane: "REFINE",
    targetLabel: null,
    reason: buildRefineReason(issue, opinion),
  };
}

/**
 * Check if an issue meets the strict AUTO lane predicate.
 * AUTO predicate: Pursue + high + safe after prep + (work:slice OR work:standalone) + trusted author
 *
 * @param {object} issue
 * @param {object} opinion
 * @returns {boolean}
 */
function meetsAutoLanePredicate(issue, opinion) {
  return (
    opinion.recommendation === "Pursue" &&
    opinion.confidence === "high" &&
    opinion.automationSafety === "safe after prep" &&
    (opinion.workTypeRecommendation === "work:slice" || opinion.workTypeRecommendation === "work:standalone") &&
    isTrustedAuthor(issue)
  );
}

/**
 * Build a descriptive reason for REFINE lane routing.
 *
 * @param {object} issue
 * @param {object} opinion
 * @returns {string}
 */
function buildRefineReason(issue, opinion) {
  if (opinion.confidence === "medium") {
    return "Needs human shaping before automation readiness";
  }
  if (opinion.recommendation === "Refine") {
    return "Needs human refinement before pursuing";
  }
  if (!isTrustedAuthor(issue)) {
    return "Untrusted author — requires human review before AUTO eligibility";
  }
  return "Does not meet strict AUTO criteria — requires human review";
}

/**
 * Check if issue author is trusted for AUTO-lane promotion.
 * Trusted authors: TJ, OWNER, MEMBER, or bot-sourced intake.
 *
 * @param {object} issue
 * @returns {boolean}
 */
function isTrustedAuthor(issue) {
  const authorLogin = issue?.author?.login || "";
  const isBot = issue?.author?.is_bot === true;
  const authorAssociation = issue?.authorAssociation;
  
  // TJ-authored issues are always trusted
  if (authorLogin === "tjegbejimba") return true;
  
  // OWNER/MEMBER associations are trusted (team members)
  if (authorAssociation === "OWNER" || authorAssociation === "MEMBER") return true;
  
  // Bot-authored issues (e.g., issue forms) are trusted
  if (isBot) return true;
  
  // Future: check for issue-form sourced intake (tracked separately as #111)
  return false;
}
