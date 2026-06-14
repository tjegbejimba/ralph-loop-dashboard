export const RALPH_STATES = [
  "ralph:needs-triage",
  "ralph:evaluated",
  "ralph:fast-lane",
  "ralph:ready",
  "ralph:blocked",
  "ralph:hitl",
  "ralph:queued",
  "ralph:running",
  "ralph:done",
  "ralph:failed",
];

export const PRIORITIES = ["priority:P0", "priority:P1", "priority:P2", "priority:P3"];
export const WORK_TYPES = ["work:prd", "work:slice", "work:standalone"];

export const CANONICAL_LABELS = [
  { name: "ralph:needs-triage", color: "FBCA04", description: "Needs human triage before Ralph automation", dimension: "state" },
  { name: "ralph:evaluated", color: "C5DEF5", description: "Reviewed and accepted, but not yet queued for Ralph", dimension: "state" },
  { name: "ralph:fast-lane", color: "BFD4F2", description: "AUTO-eligible candidate; awaiting one-tap promotion to ralph:ready", dimension: "state" },
  { name: "ralph:ready", color: "0E8A16", description: "Safe for Ralph to queue and run", dimension: "state" },
  { name: "ralph:blocked", color: "D93F0B", description: "Ralph-ready but waiting on unsatisfied dependencies", dimension: "state" },
  { name: "ralph:hitl", color: "B60205", description: "Requires human judgment/action; Ralph must not run", dimension: "state" },
  { name: "ralph:queued", color: "1D76DB", description: "Queued for Ralph workers", dimension: "state" },
  { name: "ralph:running", color: "0052CC", description: "Currently claimed by a Ralph worker", dimension: "state" },
  { name: "ralph:done", color: "CED0D4", description: "Completed by Ralph-verified merged work", dimension: "state" },
  { name: "ralph:failed", color: "E11D21", description: "Ralph attempted work but human recovery is required", dimension: "state" },
  { name: "priority:P0", color: "B60205", description: "Stop-the-line priority; sorts first, no auto-preemption", dimension: "priority" },
  { name: "priority:P1", color: "D93F0B", description: "High priority", dimension: "priority" },
  { name: "priority:P2", color: "FBCA04", description: "Normal/default priority", dimension: "priority" },
  { name: "priority:P3", color: "C2E0C6", description: "Nice-to-have / low priority", dimension: "priority" },
  { name: "work:prd", color: "5319E7", description: "Parent PRD/spec issue; not directly runnable", dimension: "work" },
  { name: "work:slice", color: "1D76DB", description: "PRD child tracer-bullet issue", dimension: "work" },
  { name: "work:standalone", color: "C5DEF5", description: "Runnable one-off issue with no PRD parent", dimension: "work" },
];

export const CANONICAL_LABEL_BY_NAME = new Map(CANONICAL_LABELS.map((label) => [label.name, label]));

export const LEGACY_STATE_ALIASES = new Map([
  ["needs-triage", "ralph:needs-triage"],
  ["ready-for-agent", "ralph:ready"],
  ["hitl", "ralph:hitl"],
]);
export const LEGACY_SAFETY_LABELS = ["hitl", "needs-triage"];

const PRIORITY_RANK = new Map([
  ["priority:P0", 0],
  ["priority:P1", 1],
  ["priority:P2", 2],
  ["priority:P3", 3],
]);

const PRIORITY_FROM_SEVERITY = new Map([
  ["severity:critical", "priority:P1"],
  ["severity:high", "priority:P1"],
  ["severity:medium", "priority:P2"],
  ["severity:low", "priority:P3"],
]);

function namesFromLabels(labels) {
  if (!Array.isArray(labels)) return [];
  return labels
    .map((label) => (typeof label === "string" ? label : label?.name))
    .filter((name) => typeof name === "string" && name.length > 0);
}

export function parseParentNumber(body = "") {
  const match = String(body || "").match(/(?:^|\n)Parent #([1-9][0-9]*)\b/);
  return match ? Number(match[1]) : null;
}

export function parseBlockerNumbers(body = "") {
  const blockers = new Set();
  const lines = String(body || "").split(/\r?\n/);
  let inSection = false;
  for (const line of lines) {
    if (/^##\s+Blocked by\b/i.test(line)) {
      inSection = true;
      continue;
    }
    if (inSection && /^##\s+/.test(line)) break;
    if (!inSection) continue;
    if (/^\s*-?\s*(none|no\s+blockers)\b/i.test(line)) break;
    if (!/^\s*[-*+]\s+/.test(line)) continue;
    for (const match of line.matchAll(/#([1-9][0-9]*)\b/g)) {
      blockers.add(Number(match[1]));
    }
  }
  return [...blockers].sort((a, b) => a - b);
}

function inferWorkType(issue, labels, state) {
  const title = String(issue?.title || "");
  const body = String(issue?.body || "");
  if (labels.includes("prd") || /^PRD:/i.test(title)) return "work:prd";
  if (parseParentNumber(body) || /^Slice\s+\d+:/i.test(title)) return "work:slice";
  if (state === "ralph:ready") return "work:standalone";
  return null;
}

function dimensionLabels(labels, canonicalSet, options, issue, warnings, dimension) {
  const found = labels.filter((label) => canonicalSet.includes(label));
  if (dimension === "state" && options.compatibilityAliases) {
    for (const [legacy, canonical] of LEGACY_STATE_ALIASES) {
      if (!labels.includes(legacy) || found.includes(canonical)) continue;
      found.push(canonical);
      warnings.push({
        type: "legacy_alias",
        dimension,
        legacy,
        canonical,
        message: `${legacy} is a temporary compatibility alias for ${canonical}`,
      });
    }
  }
  if (dimension === "work" && options.compatibilityAliases && found.length === 0) {
    const inferred = inferWorkType(issue, labels, issue?._stateForWorkInference);
    if (inferred) {
      found.push(inferred);
      warnings.push({
        type: "legacy_alias",
        dimension,
        canonical: inferred,
        message: `Inferred ${inferred} from legacy title/body shape`,
      });
    }
  }
  return found;
}

function conflictFor(dimension, labels) {
  if (labels.length <= 1) return null;
  return {
    dimension,
    labels,
    message: `${dimension} has conflicting Ralph labels: ${labels.join(", ")}`,
  };
}

export function classifyIssue(issue = {}, options = {}) {
  const opts = { compatibilityAliases: false, blockersSatisfied: true, ...options };
  const labels = namesFromLabels(issue.labels);
  const warnings = [];

  const stateLabels = dimensionLabels(labels, RALPH_STATES, opts, issue, warnings, "state");
  const state = stateLabels.length === 1 ? stateLabels[0] : null;
  const workIssue = { ...issue, _stateForWorkInference: state };
  const priorityLabels = dimensionLabels(labels, PRIORITIES, opts, workIssue, warnings, "priority");
  const workLabels = dimensionLabels(labels, WORK_TYPES, opts, workIssue, warnings, "work");
  const conflicts = [
    conflictFor("state", stateLabels),
    conflictFor("priority", priorityLabels),
    conflictFor("work", workLabels),
  ].filter(Boolean);

  let priority = priorityLabels.length === 1 ? priorityLabels[0] : null;
  if (!priority) {
    priority = "priority:P2";
    warnings.push({
      type: "missing_priority",
      dimension: "priority",
      defaultedTo: priority,
      message: "Missing priority label; defaulting to priority:P2 for ordering",
    });
  }

  const workType = workLabels.length === 1 ? workLabels[0] : null;
  if (!state) {
    warnings.push({
      type: "missing_state",
      dimension: "state",
      message: "Missing canonical ralph:* lifecycle label",
    });
  }
  if (!workType) {
    warnings.push({
      type: "missing_work_type",
      dimension: "work",
      message: "Missing canonical work:* label",
    });
  }

  const parentNumber = parseParentNumber(issue.body || "");
  if (workType === "work:slice" && !parentNumber) {
    warnings.push({
      type: "missing_parent_marker",
      message: "work:slice issues must include exact Parent #N body syntax",
    });
  }
  if (workType === "work:standalone" && parentNumber) {
    warnings.push({
      type: "work_body_disagreement",
      parentNumber,
      message: "work:standalone issue body contains Parent #N",
    });
  }
  if (workType === "work:prd" && ["ralph:ready", "ralph:blocked", "ralph:queued", "ralph:running", "ralph:failed"].includes(state)) {
    warnings.push({
      type: "invalid_prd_state",
      message: `work:prd cannot use runnable/runtime state ${state}`,
    });
  }

  const repoLabels = labels.filter((label) => !CANONICAL_LABEL_BY_NAME.has(label));
  const runnableState =
    state === "ralph:ready" ||
    (state === "ralph:blocked" && opts.blockersSatisfied === true);
  const runnable =
    conflicts.length === 0 &&
    runnableState &&
    (workType === "work:slice" || workType === "work:standalone");

  return {
    number: Number.isFinite(Number(issue.number)) ? Number(issue.number) : null,
    labels,
    state,
    stateLabels,
    priority,
    priorityLabels,
    priorityRank: PRIORITY_RANK.get(priority) ?? PRIORITY_RANK.get("priority:P2"),
    workType,
    workLabels,
    repoLabels,
    conflicts,
    warnings,
    parentNumber,
    blockers: parseBlockerNumbers(issue.body || ""),
    runnable,
  };
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

export function buildLabelSchemaPlan({ repo, apply = false } = {}) {
  if (!repo || typeof repo !== "string") {
    throw new TypeError("repo is required");
  }
  return {
    dryRun: apply !== true,
    labels: CANONICAL_LABELS.map((label) => ({ ...label })),
    commands: CANONICAL_LABELS.map((label) =>
      `gh label create ${label.name} --repo ${shellQuote(repo)} --color ${label.color} --description ${shellQuote(label.description)}`),
  };
}

export function validatePrdForEnqueue(issue = {}) {
  const classification = classifyIssue(issue);
  const reasons = [];
  const ghState = String(issue.state || "").toUpperCase();
  if (ghState && ghState !== "OPEN") reasons.push(`#${issue.number} is ${ghState}, not OPEN`);
  if (classification.conflicts.length > 0) {
    reasons.push(...classification.conflicts.map((conflict) => conflict.message));
  }
  if (classification.workType !== "work:prd") {
    reasons.push(`#${issue.number} must be labeled work:prd`);
  }
  if (classification.state !== "ralph:evaluated") {
    reasons.push(`#${issue.number} PRD parent must be ralph:evaluated before enqueue`);
  }
  return {
    ok: reasons.length === 0,
    reasons,
    warnings: classification.warnings,
    classification,
  };
}

function validateRunnableWithAllowedStates(issue = {}, options = {}, allowedStates = []) {
  const blockersSatisfied = options.blockersSatisfied ?? true;
  const classification = classifyIssue(issue, { blockersSatisfied });
  const reasons = [];
  const ghState = String(issue.state || "").toUpperCase();
  const assignees = Array.isArray(issue.assignees) ? issue.assignees : [];
  if (ghState && ghState !== "OPEN") reasons.push(`#${issue.number} is ${ghState}, not OPEN`);
  if (assignees.length > 0) reasons.push(`#${issue.number} is assigned; Ralph skips assigned issues by default`);
  if (classification.conflicts.length > 0) {
    reasons.push(...classification.conflicts.map((conflict) => conflict.message));
  }
  for (const legacyLabel of LEGACY_SAFETY_LABELS) {
    if (classification.repoLabels.includes(legacyLabel)) {
      reasons.push(`#${issue.number} has legacy do-not-run label ${legacyLabel}`);
    }
  }
  if (classification.workType !== "work:slice" && classification.workType !== "work:standalone") {
    reasons.push(`#${issue.number} must be work:slice or work:standalone`);
  }
  if (classification.state === "ralph:blocked" && blockersSatisfied !== true) {
    reasons.push(`#${issue.number} is ralph:blocked with unsatisfied blockers`);
  } else if (!allowedStates.includes(classification.state)) {
    reasons.push(`#${issue.number} must be ${allowedStates.join(", ")}`);
  }
  if (classification.workType === "work:slice" && !classification.parentNumber) {
    reasons.push(`#${issue.number} work:slice is missing exact Parent #N body marker`);
  }
  return {
    ok: reasons.length === 0,
    reasons,
    warnings: classification.warnings,
    classification,
  };
}

export function validateRunnableForEnqueue(issue = {}, options = {}) {
  return validateRunnableWithAllowedStates(issue, options, ["ralph:ready", "ralph:blocked"]);
}

export function validateRunnableForClaim(issue = {}, options = {}) {
  return validateRunnableWithAllowedStates(issue, options, ["ralph:ready", "ralph:blocked", "ralph:queued"]);
}

function inferPriority(labels) {
  for (const label of labels) {
    const priority = PRIORITY_FROM_SEVERITY.get(label);
    if (priority) return priority;
  }
  return "priority:P2";
}

export function planBackfill(issues = [], options = {}) {
  const includeClosed = options.includeClosed === true;
  const actions = [];
  for (const issue of issues) {
    const ghState = String(issue?.state || "").toUpperCase();
    if (ghState === "CLOSED" && !includeClosed) continue;
    const labels = namesFromLabels(issue.labels);
    const addLabels = [];
    const hasCanonical = (names) => names.some((name) => labels.includes(name));
    for (const [legacy, canonical] of LEGACY_STATE_ALIASES) {
      if (labels.includes(legacy) && !labels.includes(canonical)) addLabels.push(canonical);
    }
    if (!hasCanonical(WORK_TYPES)) {
      const inferredWork = inferWorkType(issue, labels, addLabels.find((label) => RALPH_STATES.includes(label)) || null);
      if (inferredWork) addLabels.push(inferredWork);
    }
    if (!hasCanonical(PRIORITIES)) {
      addLabels.push(inferPriority(labels));
    }
    if (addLabels.length === 0) continue;
    actions.push({
      type: "backfill",
      issueNumber: Number(issue.number),
      addLabels: [...new Set(addLabels)],
      preserveLabels: labels,
    });
  }
  return { dryRun: options.apply !== true, actions };
}

function sliceOrderValue(issue) {
  const match = String(issue?.title || "").match(/^Slice\s+([0-9]+):/i);
  return match ? Number(match[1]) : Number.POSITIVE_INFINITY;
}

function compareByPriorityAndTieBreakers(a, b) {
  const ca = classifyIssue(a);
  const cb = classifyIssue(b);
  return (
    ca.priorityRank - cb.priorityRank ||
    sliceOrderValue(a) - sliceOrderValue(b) ||
    String(a.title || "").localeCompare(String(b.title || "")) ||
    Number(a.number) - Number(b.number)
  );
}

export function orderIssuesForQueue(issues = []) {
  const byNumber = new Map(issues.map((issue) => [Number(issue.number), issue]));
  const remaining = new Map(issues.map((issue) => [Number(issue.number), issue]));
  const ordered = [];
  const blocked = [];

  for (const issue of issues) {
    const blockers = parseBlockerNumbers(issue.body || "");
    const failedBlocker = blockers.find((number) => classifyIssue(byNumber.get(number) || {}).state === "ralph:failed");
    if (failedBlocker != null) {
      blocked.push({
        issue,
        reason: `Blocker #${failedBlocker} is ralph:failed`,
      });
      remaining.delete(Number(issue.number));
    }
  }

  while (remaining.size > 0) {
    const frontier = [...remaining.values()].filter((issue) => {
      const blockers = parseBlockerNumbers(issue.body || "");
      return blockers.every((number) => !remaining.has(number));
    });
    if (frontier.length === 0) {
      for (const issue of remaining.values()) {
        blocked.push({ issue, reason: "Dependency cycle or unsatisfied dependency" });
      }
      break;
    }
    frontier.sort(compareByPriorityAndTieBreakers);
    const next = frontier[0];
    ordered.push(next);
    remaining.delete(Number(next.number));
  }

  ordered.blocked = blocked;
  ordered.preemptActiveWorkers = false;
  return ordered;
}

export function planRepair(issues = [], options = {}) {
  const liveClaims = new Set((options.liveClaims || []).map(Number));
  const actions = [];
  for (const issue of issues) {
    const classification = classifyIssue(issue);
    if (classification.conflicts.length > 0) {
      actions.push({
        type: "conflict",
        issueNumber: Number(issue.number),
        conflicts: classification.conflicts,
        addLabels: [],
        removeLabels: [],
      });
      continue;
    }
    if (classification.state === "ralph:running" && !liveClaims.has(Number(issue.number))) {
      actions.push({
        type: "stale-running",
        issueNumber: Number(issue.number),
        addLabels: ["ralph:queued"],
        removeLabels: ["ralph:running"],
      });
    }
  }
  return { dryRun: options.apply !== true, actions };
}

const TRANSITIONS = {
  enqueue: {
    from: ["ralph:ready", "ralph:blocked"],
    addLabels: ["ralph:queued"],
    removeLabels: ["ralph:ready", "ralph:blocked"],
  },
  claim: {
    from: ["ralph:queued"],
    addLabels: ["ralph:running"],
    removeLabels: ["ralph:queued"],
  },
  complete: {
    from: ["ralph:running"],
    addLabels: ["ralph:done"],
    removeLabels: ["ralph:running"],
  },
  retry: {
    from: ["ralph:running", "ralph:failed"],
    addLabels: ["ralph:queued"],
    removeLabels: ["ralph:running", "ralph:failed"],
  },
  fail: {
    from: ["ralph:running", "ralph:queued"],
    addLabels: ["ralph:failed"],
    removeLabels: ["ralph:running", "ralph:queued"],
  },
};

export function planRuntimeTransition({ issue, transition }) {
  const rule = TRANSITIONS[transition];
  if (!rule) throw new Error(`Unknown Ralph runtime transition: ${transition}`);
  const classification = classifyIssue(issue);
  if (!rule.from.includes(classification.state)) {
    throw new Error(`${transition} requires ${rule.from.join(" or ")} (got ${classification.state || "none"})`);
  }
  return {
    issueNumber: Number(issue.number),
    transition,
    addLabels: [...rule.addLabels],
    removeLabels: [...rule.removeLabels],
  };
}
