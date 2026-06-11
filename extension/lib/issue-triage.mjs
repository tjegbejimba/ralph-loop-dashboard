import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { classifyIssue, parseBlockerNumbers } from "./label-taxonomy.mjs";

export const TRIAGE_COMMENT_MARKER = "<!-- ralph-triage-opinion:v1";
const FINGERPRINT_RE = /<!-- ralph-triage-opinion:v1 fingerprint=([a-f0-9]{64}) -->/;

const RECOMMENDATIONS = ["Pursue", "Refine", "Needs info", "Defer", "Close", "Uncertain"];
const PRIORITIES = ["P0", "P1", "P2", "P3"];
const AUTOMATION_SAFETY = ["safe after prep", "needs prep", "hitl-required"];

export const DEFAULT_TRIAGE_CONFIG = {
  repos: [
    {
      owner: "tjegbejimba",
      name: "ralph-loop-dashboard",
      taxonomyMode: "legacy",
    },
  ],
  limits: {
    dryRun: 20,
    live: 10,
  },
  botLogin: "github-actions[bot]",
};

function namesFromLabels(labels) {
  if (!Array.isArray(labels)) return [];
  return labels
    .map((label) => (typeof label === "string" ? label : label?.name))
    .filter((name) => typeof name === "string" && name.length > 0);
}

function authorLogin(comment) {
  if (typeof comment?.author === "string") return comment.author;
  return comment?.author?.login || comment?.user?.login || "";
}

function pullRequestReferences(issue) {
  if (Array.isArray(issue?.closingPullRequestsReferences)) return issue.closingPullRequestsReferences;
  if (Array.isArray(issue?.closedByPullRequestsReferences)) return issue.closedByPullRequestsReferences;
  return [];
}

function textFor(issue) {
  return `${issue?.title || ""}\n${issue?.body || ""}`.toLowerCase();
}

function hasAny(text, patterns) {
  return patterns.some((pattern) => pattern.test(text));
}

function scoreIssue(issue, repoContext = {}) {
  const text = textFor(issue);
  const valueSignals = Array.isArray(repoContext.valueSignals) ? repoContext.valueSignals : [];
  const valueSignalHit = valueSignals.some((signal) => text.includes(String(signal).toLowerCase()));
  const value = valueSignalHit || hasAny(text, [
    /ralph/,
    /afk/,
    /agent/,
    /worker/,
    /preflight/,
    /quota/,
    /corrupt/,
    /unsafe/,
    /operator friction/,
    /diagnos/,
    /observab/,
    /reliab/,
  ]) ? 2 : hasAny(text, [/annoyance/, /pain/, /bug/, /manual/, /friction/, /opportunity/]) ? 1 : 0;
  const urgency = hasAny(text, [/unsafe/, /corrupt/, /waste/, /quota/, /fail/, /block/, /data loss/, /security/, /broken/])
    ? 2
    : hasAny(text, [/soon/, /slow/, /friction/, /manual/, /annoy/]) ? 1 : 0;
  const leverage = hasAny(text, [/preflight/, /automation/, /afk/, /agent/, /worker/, /diagnos/, /observab/, /reliab/, /repeat/, /quota/])
    ? 2
    : hasAny(text, [/cleanup/, /simplify/, /reduce/, /avoid/]) ? 1 : 0;
  const clarity = hasAny(text, [/acceptance criteria/, /test/, /clear outcome/, /user-visible/, /steps? to reproduce/])
    ? 2
    : String(issue?.body || "").trim().length >= 80 ? 1 : 0;
  const labels = namesFromLabels(issue?.labels);
  const automationSafety = labels.includes("hitl") || labels.includes("ralph:hitl")
    ? 0
    : clarity >= 2 && hasAny(text, [/test/, /preflight/, /safe/, /acceptance criteria/]) ? 2 : clarity >= 1 ? 1 : 0;
  return { value, urgency, leverage, clarity, automationSafety };
}

function inferWorkTypeRecommendation(issue, scores) {
  const text = textFor(issue);
  if (/^slice\s+\d+:/i.test(String(issue?.title || "")) || /(?:^|\n)parent #[1-9][0-9]*\b/i.test(String(issue?.body || ""))) {
    return "work:slice";
  }
  if (hasAny(text, [/prd:/, /roadmap/, /product design/, /broad/, /multi-step/, /architecture/])) {
    return "work:prd";
  }
  if (scores.clarity >= 1) return "work:standalone";
  return "work:prd";
}

function mapRecommendation(issue, scores, options = {}) {
  const text = textFor(issue);
  if (options.closeEvidence === true || hasAny(text, [/duplicate of #[1-9][0-9]*/, /obsolete because/, /out of scope/, /empty template/])) {
    return "Close";
  }
  if (String(issue?.body || "").trim().length === 0) return "Needs info";
  if (scores.value === 0 && scores.clarity === 0) return "Needs info";
  if (scores.value === 2 && (scores.urgency === 2 || scores.leverage === 2) && scores.clarity >= 1 && scores.automationSafety >= 1) {
    return "Pursue";
  }
  if (scores.value === 2 && (scores.clarity < 2 || scores.automationSafety < 2)) return "Refine";
  if (scores.value >= 1 && scores.urgency === 0 && scores.leverage === 0) return "Defer";
  return "Uncertain";
}

function mapPriority(scores, recommendation) {
  if (recommendation === "Close") return "P3";
  if (scores.urgency === 2 && scores.value === 2 && /2/.test(String(scores.leverage))) return "P1";
  if (scores.urgency === 2 || scores.leverage === 2) return "P1";
  if (scores.value === 2) return "P2";
  return "P3";
}

function mapAutomationSafety(scores, issue, recommendation) {
  if (["Close", "Needs info", "Uncertain"].includes(recommendation)) return "hitl-required";
  const labels = namesFromLabels(issue?.labels);
  if (labels.includes("hitl") || labels.includes("ralph:hitl") || scores.automationSafety === 0) return "hitl-required";
  if (scores.automationSafety === 2 && scores.clarity >= 2) return "safe after prep";
  return "needs prep";
}

function confidenceFor(recommendation, scores, preflight) {
  const conflicts = preflight.some((item) => /conflict/i.test(item));
  if (conflicts || recommendation === "Uncertain") return "low";
  if (recommendation === "Close") return "high";
  if (scores.clarity >= 2 && scores.value >= 2 && scores.automationSafety >= 2) return "high";
  return "medium";
}

function confidenceReasonFor(recommendation, confidence) {
  if (recommendation === "Close") {
    return "the duplicate, obsolete, or out-of-scope evidence is explicit";
  }
  if (recommendation === "Needs info") {
    return "core dimensions cannot be scored from the current issue text";
  }
  if (recommendation === "Defer") {
    return "value exists, but urgency and leverage evidence are weak";
  }
  if (recommendation === "Uncertain") {
    return "the available evidence is ambiguous or conflicting";
  }
  if (confidence === "high") {
    return "the issue has concrete impact, urgency/leverage, and testable acceptance criteria";
  }
  if (confidence === "medium") {
    return "the direction is plausible but still needs human shaping";
  }
  return "the available evidence is ambiguous or conflicting";
}

function preflightFor(issue) {
  const classification = classifyIssue(issue, { compatibilityAliases: true });
  const items = [];
  for (const conflict of classification.conflicts) {
    items.push(conflict.message);
  }
  for (const warning of classification.warnings) {
    if (warning.type === "missing_priority") {
      items.push("Missing priority label; analyzing as default priority:P2 until a human applies taxonomy.");
    } else if (warning.type === "missing_work_type") {
      items.push("Missing work:* label; recommend applying one after human triage.");
    } else if (warning.type === "missing_state") {
      items.push("Missing canonical ralph:* lifecycle label.");
    } else if (warning.type === "legacy_alias") {
      items.push(warning.legacy
        ? `${warning.legacy} is a migration alias for ${warning.canonical}; future query should use ${warning.canonical}.`
        : warning.message);
    } else {
      items.push(warning.message);
    }
  }
  for (const blockerNumber of parseBlockerNumbers(issue?.body || "")) {
    items.push(`Visible blocker #${blockerNumber} should be resolved or accounted for before any Ralph readiness decision.`);
  }
  const openPrs = pullRequestReferences(issue).filter((pr) => pr?.state === "OPEN");
  for (const pr of openPrs) {
    items.push(`Linked open PR already appears to cover this work: ${pr.url || "open pull request"}.`);
  }
  return [...new Set(items)];
}

function whyFor(issue, scores, recommendation) {
  if (recommendation === "Needs info") {
    return [
      "The body does not provide enough concrete context to score value or urgency.",
      "A human answer is needed before this can be shaped safely.",
    ];
  }
  if (recommendation === "Close") {
    return [
      "The issue includes explicit evidence that it is duplicate, obsolete, or out of scope.",
      "Closing should still be a human action because V1 triage is advisory only.",
    ];
  }
  const reasons = [];
  if (scores.value === 2) reasons.push("It addresses a real Ralph safety/reliability/operator-friction concern.");
  if (scores.urgency === 2) reasons.push("The described failure mode can waste quota, corrupt work, or permit unsafe launches.");
  if (scores.leverage === 2) reasons.push("Fixing it improves repeatable AFK agent execution rather than one-off polish.");
  if (scores.clarity >= 1) reasons.push("The issue has a user-visible outcome that can be covered by tests.");
  if (reasons.length < 2) reasons.push("More concrete impact evidence would make the recommendation stronger.");
  return reasons.slice(0, 4);
}

function nextActionFor(recommendation, workTypeRecommendation) {
  if (recommendation === "Pursue") {
    return `Shape this as ${workTypeRecommendation} with explicit acceptance criteria before marking it ready for Ralph.`;
  }
  if (recommendation === "Refine") {
    return "Add the missing outcome, safety, or testability detail before deciding whether to pursue.";
  }
  if (recommendation === "Needs info") {
    return "Ask one specific clarifying question that would make the issue scoreable.";
  }
  if (recommendation === "Defer") {
    return "Leave it in triage until there is concrete urgency or leverage evidence.";
  }
  if (recommendation === "Close") {
    return "Have a human close it only after confirming the cited duplicate, obsolete, or out-of-scope evidence.";
  }
  return "Have a human choose between the competing interpretations before changing labels or creating slices.";
}

export function evaluateIssueForTriage({ issue, repoContext = {}, closeEvidence = false } = {}) {
  if (!issue || typeof issue !== "object") {
    throw new TypeError("issue is required");
  }
  const scores = scoreIssue(issue, repoContext);
  let recommendation = mapRecommendation(issue, scores, { closeEvidence });
  const workTypeRecommendation = inferWorkTypeRecommendation(issue, scores);
  const preflight = preflightFor(issue);
  let priority = mapPriority(scores, recommendation);
  let automationSafety = mapAutomationSafety(scores, issue, recommendation);
  let confidence = confidenceFor(recommendation, scores, preflight);

  if ((recommendation === "Close" || recommendation === "Pursue") && confidence === "low") {
    recommendation = recommendation === "Close" ? "Uncertain" : "Refine";
    priority = mapPriority(scores, recommendation);
    automationSafety = mapAutomationSafety(scores, issue, recommendation);
    confidence = confidenceFor(recommendation, scores, preflight);
  }

  return {
    issueNumber: Number(issue.number) || null,
    recommendation,
    confidence,
    confidenceReason: confidenceReasonFor(recommendation, confidence),
    priority,
    automationSafety,
    preflight,
    why: whyFor(issue, scores, recommendation),
    nextAction: nextActionFor(recommendation, workTypeRecommendation),
    workTypeRecommendation,
    plannedMutations: [],
    scores,
  };
}

function assertOpinion(opinion) {
  if (!RECOMMENDATIONS.includes(opinion?.recommendation)) {
    throw new TypeError("opinion.recommendation is invalid");
  }
  if (!["high", "medium", "low"].includes(opinion.confidence)) {
    throw new TypeError("opinion.confidence is invalid");
  }
  if (!PRIORITIES.includes(opinion.priority)) {
    throw new TypeError("opinion.priority is invalid");
  }
  if (!AUTOMATION_SAFETY.includes(opinion.automationSafety)) {
    throw new TypeError("opinion.automationSafety is invalid");
  }
}

export function renderTriageComment(opinion) {
  assertOpinion(opinion);
  const preflight = Array.isArray(opinion.preflight) && opinion.preflight.length > 0
    ? opinion.preflight.map((item) => `- ${item}`).join("\n")
    : "- No advisory preflight warnings found.";
  const why = (Array.isArray(opinion.why) ? opinion.why : [])
    .slice(0, 4)
    .map((item) => `- ${item}`)
    .join("\n");

  return [
    "## Triage opinion",
    "",
    `**Recommendation:** I recommend ${opinion.recommendation}.`,
    `**Confidence:** ${opinion.confidence} — ${opinion.confidenceReason}`,
    `**Priority:** ${opinion.priority}`,
    `**Automation safety:** ${opinion.automationSafety}`,
    "",
    "**Preflight:**",
    preflight,
    "",
    "**Why:**",
    why,
    "",
    `**Next action:** ${opinion.nextAction}`,
    "",
    "_No labels, closure, Ralph enqueue, PRD creation, or slice creation happened automatically._",
  ].join("\n");
}

function latestBotComment(comments, botLogin) {
  return [...(Array.isArray(comments) ? comments : [])]
    .filter((comment) => authorLogin(comment) === botLogin && FINGERPRINT_RE.test(String(comment.body || "")))
    .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")) || Number(b.id || 0) - Number(a.id || 0))[0] || null;
}

function humanComments(comments, botLogin) {
  return (Array.isArray(comments) ? comments : [])
    .filter((comment) => authorLogin(comment) !== botLogin)
    .map((comment) => ({
      author: authorLogin(comment),
      body: String(comment.body || ""),
      createdAt: comment.createdAt || null,
    }));
}

function humanRepliedAfterBot(comments, botComment, botLogin) {
  if (!botComment?.createdAt) return false;
  const botTime = Date.parse(botComment.createdAt);
  if (!Number.isFinite(botTime)) return false;
  return (Array.isArray(comments) ? comments : []).some((comment) => {
    if (authorLogin(comment) === botLogin) return false;
    const time = Date.parse(comment.createdAt || "");
    return Number.isFinite(time) && time > botTime;
  });
}

function fingerprintTriageInputs({ issue, comments, botLogin, preflight }) {
  const payload = {
    issue: {
      number: Number(issue?.number) || null,
      title: issue?.title || "",
      body: issue?.body || "",
      labels: namesFromLabels(issue?.labels).sort(),
      state: issue?.state || null,
      pullRequestReferences: pullRequestReferences(issue).map((pr) => ({
        state: pr?.state || null,
        url: pr?.url || null,
      })),
    },
    comments: humanComments(comments, botLogin),
    preflight,
  };
  return createHash("sha256").update(JSON.stringify(payload)).digest("hex");
}

function appendFingerprint(commentBody, fingerprint) {
  return `${commentBody}\n\n${TRIAGE_COMMENT_MARKER} fingerprint=${fingerprint} -->`;
}

export function planTriageComment({ issue, comments = [], botLogin = "github-actions[bot]", repoContext = {} } = {}) {
  if (!issue || typeof issue !== "object") {
    throw new TypeError("issue is required");
  }
  const opinion = evaluateIssueForTriage({ issue, repoContext });
  const fingerprint = fingerprintTriageInputs({
    issue,
    comments,
    botLogin,
    preflight: opinion.preflight,
  });
  const commentBody = appendFingerprint(renderTriageComment(opinion), fingerprint);
  const botComment = latestBotComment(comments, botLogin);
  const previousFingerprint = botComment ? String(botComment.body || "").match(FINGERPRINT_RE)?.[1] : null;
  const humanReply = humanRepliedAfterBot(comments, botComment, botLogin);

  if (!botComment) {
    return {
      action: "create",
      reason: "missing_bot_comment",
      commentBody,
      fingerprint,
      opinion,
      plannedMutations: [],
    };
  }
  if (previousFingerprint === fingerprint && !humanReply) {
    return {
      action: "skip",
      reason: "unchanged",
      commentId: botComment.id,
      fingerprint,
      opinion,
      plannedMutations: [],
    };
  }
  return {
    action: "update",
    reason: humanReply ? "human_reply_after_bot" : "input_changed",
    commentId: botComment.id,
    commentBody,
    fingerprint,
    opinion,
    plannedMutations: [],
  };
}

export function buildTriageQuery(repoConfig = {}) {
  if (repoConfig.query) return repoConfig.query;
  return repoConfig.taxonomyMode === "canonical" || repoConfig.taxonomyMode === "future"
    ? "label:ralph:needs-triage"
    : "label:needs-triage";
}

function repoFullName(repoConfig) {
  const repo = repoConfig.repo || (repoConfig.owner && repoConfig.name ? `${repoConfig.owner}/${repoConfig.name}` : null);
  if (!repo || typeof repo !== "string" || !repo.includes("/")) {
    throw new TypeError("triage repo must be owner/name");
  }
  return repo;
}

function normalizeConfig(config = {}) {
  const merged = {
    ...DEFAULT_TRIAGE_CONFIG,
    ...config,
    limits: { ...DEFAULT_TRIAGE_CONFIG.limits, ...(config.limits || {}) },
  };
  if (!Array.isArray(merged.repos) || merged.repos.length === 0) {
    throw new TypeError("config.repos must include at least one allowed repository");
  }
  return merged;
}

function compareOldestFirst(a, b) {
  const aTime = Date.parse(a?.createdAt || "");
  const bTime = Date.parse(b?.createdAt || "");
  return (
    (Number.isFinite(aTime) ? aTime : Number.POSITIVE_INFINITY) -
    (Number.isFinite(bTime) ? bTime : Number.POSITIVE_INFINITY) ||
    Number(a?.number || 0) - Number(b?.number || 0)
  );
}

function activeSkipReason(issue) {
  const assignees = Array.isArray(issue?.assignees) ? issue.assignees : [];
  if (assignees.length > 0) return "assigned_issue";
  const labels = namesFromLabels(issue?.labels);
  if (labels.includes("ralph:queued") || labels.includes("ralph:running")) return "active_ralph_work";
  const openPrs = pullRequestReferences(issue).filter((pr) => pr?.state === "OPEN");
  if (openPrs.length > 0) return "linked_open_pr";
  return null;
}

function assertCommandOk(result, label) {
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr || `${label} failed`);
  }
}

async function defaultFetchIssues({ repo, query }) {
  const result = spawnSync("gh", [
    "issue",
    "list",
    "--repo",
    repo,
    "--search",
    query,
    "--json",
    "number,title,body,labels,state,createdAt,updatedAt,assignees,closedByPullRequestsReferences,url",
    "--limit",
    "100",
  ], { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 });
  assertCommandOk(result, "gh issue list");
  return JSON.parse(result.stdout || "[]");
}

async function defaultFetchComments({ repo, issueNumber }) {
  const result = spawnSync("gh", [
    "issue",
    "view",
    String(issueNumber),
    "--repo",
    repo,
    "--comments",
    "--json",
    "comments",
  ], { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 });
  assertCommandOk(result, "gh issue view");
  return JSON.parse(result.stdout || "{}").comments || [];
}

async function defaultCreateComment({ repo, issueNumber, body }) {
  const result = spawnSync("gh", [
    "issue",
    "comment",
    String(issueNumber),
    "--repo",
    repo,
    "--body-file",
    "-",
  ], { encoding: "utf8", input: body, maxBuffer: 10 * 1024 * 1024 });
  assertCommandOk(result, "gh issue comment");
  return { stdout: result.stdout };
}

async function defaultUpdateComment({ commentId, body }) {
  const query = `
    mutation UpdateRalphTriageComment($id: ID!, $body: String!) {
      updateIssueComment(input: { id: $id, body: $body }) {
        issueComment { id }
      }
    }
  `;
  const result = spawnSync("gh", [
    "api",
    "graphql",
    "--input",
    "-",
  ], {
    encoding: "utf8",
    input: JSON.stringify({ query, variables: { id: String(commentId), body } }),
    maxBuffer: 10 * 1024 * 1024,
  });
  assertCommandOk(result, "gh api graphql update issue comment");
  return JSON.parse(result.stdout || "{}");
}

export async function runIssueTriage({
  mode = "dry-run",
  config = {},
  fetchIssues = defaultFetchIssues,
  fetchComments = defaultFetchComments,
  createComment = defaultCreateComment,
  updateComment = defaultUpdateComment,
} = {}) {
  const dryRun = mode !== "live";
  const effectiveConfig = normalizeConfig(config);
  const botLogin = effectiveConfig.botLogin || DEFAULT_TRIAGE_CONFIG.botLogin;
  const runResult = {
    dryRun,
    mode: dryRun ? "dry-run" : "live",
    repos: [],
  };

  for (const repoConfig of effectiveConfig.repos) {
    const repo = repoFullName(repoConfig);
    const query = buildTriageQuery(repoConfig);
    const repoResult = {
      repo,
      query,
      processed: [],
      skipped: [],
      errors: [],
    };
    runResult.repos.push(repoResult);

    let issues;
    try {
      issues = await fetchIssues({ repo, query, repoConfig });
    } catch (err) {
      repoResult.errors.push({ type: "fetch_issues_failed", message: String(err.message || err) });
      continue;
    }

    const sortedIssues = [...(Array.isArray(issues) ? issues : [])].sort(compareOldestFirst);
    const cap = dryRun ? effectiveConfig.limits.dryRun : effectiveConfig.limits.live;
    let changedCount = 0;

    for (const issue of sortedIssues) {
      if (dryRun && repoResult.processed.length >= cap) break;
      if (!dryRun && changedCount >= cap) break;

      const issueNumber = Number(issue?.number);
      const skipReason = activeSkipReason(issue);
      if (skipReason) {
        repoResult.skipped.push({ issueNumber, reason: skipReason });
        continue;
      }

      let comments;
      try {
        comments = await fetchComments({ repo, issueNumber, issue });
      } catch (err) {
        repoResult.errors.push({ issueNumber, type: "fetch_comments_failed", message: String(err.message || err) });
        continue;
      }

      const plan = planTriageComment({
        issue,
        comments,
        botLogin,
        repoContext: effectiveConfig.repoContext || {},
      });
      const entry = {
        issueNumber,
        action: plan.action,
        reason: plan.reason,
        commentId: plan.commentId,
        commentBody: plan.commentBody,
        recommendation: plan.opinion.recommendation,
        plannedMutations: [],
      };

      if (dryRun) {
        repoResult.processed.push(entry);
        continue;
      }

      if (plan.action === "skip") {
        repoResult.skipped.push({ issueNumber, reason: plan.reason, commentId: plan.commentId });
        continue;
      }

      try {
        if (plan.action === "create") {
          await createComment({ repo, issueNumber, body: plan.commentBody });
        } else if (plan.action === "update") {
          await updateComment({ repo, issueNumber, commentId: plan.commentId, body: plan.commentBody });
        }
        changedCount += 1;
        repoResult.processed.push({ ...entry, posted: true });
      } catch (err) {
        repoResult.errors.push({ issueNumber, type: "comment_write_failed", message: String(err.message || err) });
      }
    }
  }

  return runResult;
}
