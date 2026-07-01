import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join } from "node:path";

const QUEUE_CAP = 10;
const RUNNABLE_WORK = new Set(["work:slice", "work:standalone"]);
const PRIORITY_RANK = new Map([
  ["priority:P0", 0],
  ["priority:P1", 1],
  ["priority:P2", 2],
  ["priority:P3", 3],
]);
const STATE_ORDER = [
  "ralph:failed",
  "ralph:running",
  "ralph:blocked",
  "ralph:hitl",
  "ralph:ready",
  "ralph:fast-lane",
  "ralph:evaluated",
  "ralph:needs-triage",
];

function readJsonSafe(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function labelNames(issue) {
  return (issue?.labels || []).map((label) => (typeof label === "string" ? label : label.name)).filter(Boolean);
}

function primaryState(names) {
  for (const state of STATE_ORDER) if (names.includes(state)) return state;
  return null;
}

function pick(names, prefix) {
  return names.find((name) => name.startsWith(prefix)) || null;
}

function priorityRank(priority) {
  return PRIORITY_RANK.get(priority) ?? PRIORITY_RANK.get("priority:P2");
}

function predictLane(names) {
  if (names.includes("ralph:hitl") || names.includes("ralph:blocked")) return "HOLD";
  if (names.includes("ralph:fast-lane")) return "AUTO";
  if (names.includes("work:prd")) return "PRD";
  if (names.includes("ralph:ready") && RUNNABLE_WORK.has(pick(names, "work:") || "")) return "REFINE";
  return null;
}

function parseBlockers(body) {
  if (!body) return [];
  const lines = body.split(/\r?\n/);
  const out = [];
  let inSection = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (/^#{1,6}\s*blocked by/i.test(line)) {
      inSection = true;
      continue;
    }
    if (!inSection) continue;
    if (/^#{1,6}\s/.test(line) || /^-?\s*none/i.test(line)) break;
    const match = line.match(/#(\d+)/);
    if (match) out.push(Number(match[1]));
    else if (line === "" && out.length) break;
  }
  return out;
}

function ageDays(iso, now = Date.now()) {
  if (!iso) return null;
  const time = Date.parse(iso);
  if (Number.isNaN(time)) return null;
  return Math.max(0, Math.round((now - time) / 86400000));
}

function runSortTime(run) {
  return Date.parse(run.metadata?.createdAt || run.mtimeIso || "") || run.mtimeMs || 0;
}

export function discoverFailedRunItems(repoRoot, { maxRuns = 20, maxItems = 20 } = {}) {
  const runsDir = join(repoRoot, ".ralph", "runs");
  if (!existsSync(runsDir)) return [];

  const runs = [];
  for (const entry of readdirSync(runsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const runId = entry.name;
    const runDir = join(runsDir, runId);
    const statusPath = join(runDir, "status.json");
    const queuePath = join(runDir, "queue.json");
    const metadataPath = join(runDir, "metadata.json");
    if (!existsSync(statusPath)) continue;

    const status = readJsonSafe(statusPath);
    const queue = readJsonSafe(queuePath);
    const metadata = readJsonSafe(metadataPath) || {};
    if (!status?.items || typeof status.items !== "object") continue;

    let mtimeMs = 0;
    let statusMtimeMs = 0;
    for (const path of [statusPath, queuePath, metadataPath]) {
      try {
        const fileMtimeMs = statSync(path).mtimeMs;
        if (path === statusPath) statusMtimeMs = fileMtimeMs;
        mtimeMs = Math.max(mtimeMs, fileMtimeMs);
      } catch {
        // Missing queue/metadata is tolerated; status.json is the durable signal.
      }
    }
    runs.push({ runId, runDir, status, queue: Array.isArray(queue) ? queue : [], metadata, mtimeMs, statusMtimeMs });
  }

  return runs
    .sort((a, b) => runSortTime(b) - runSortTime(a) || b.runId.localeCompare(a.runId))
    .slice(0, maxRuns)
    .flatMap((run) => {
      const queueByIssue = new Map(run.queue.map((item) => [Number(item.number), item]));
      return Object.entries(run.status.items)
        .filter(([, item]) => item?.status === "failed")
        .map(([issueNumber, item]) => {
          const number = Number(issueNumber);
          const queueItem = queueByIssue.get(number) || {};
          const logFile = typeof item.logFile === "string" && item.logFile ? basename(item.logFile) : null;
          const failedAt =
            item.failedAt ||
            (run.statusMtimeMs ? new Date(run.statusMtimeMs).toISOString() : null) ||
            item.startedAt ||
            run.metadata.createdAt ||
            new Date(run.mtimeMs).toISOString();
          return {
            number,
            title: queueItem.title || `Issue #${number}`,
            url: queueItem.url || null,
            labels: Array.isArray(queueItem.labels) ? queueItem.labels : [],
            status: "failed",
            reason: item.error || "Ralph worker failed",
            runId: run.runId,
            runDir: run.runDir,
            runCreatedAt: run.metadata.createdAt || null,
            runMode: run.metadata.runMode || null,
            model: run.metadata.model || null,
            parallelism: run.metadata.parallelism || null,
            workerId: item.workerId ?? null,
            pid: item.pid ?? null,
            logFile,
            logFilePath: logFile ? join(repoRoot, ".ralph", "logs", logFile) : null,
            startedAt: item.startedAt || null,
            failedAt,
          };
        });
    })
    .sort((a, b) => String(b.failedAt || "").localeCompare(String(a.failedAt || "")))
    .slice(0, maxItems);
}

export function discoverRecoverableRunItems(repoRoot, { maxRuns = 20, maxItems = 20 } = {}) {
  const runsDir = join(repoRoot, ".ralph", "runs");
  if (!existsSync(runsDir)) return [];

  const runs = [];
  for (const entry of readdirSync(runsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const runId = entry.name;
    const runDir = join(runsDir, runId);
    const statusPath = join(runDir, "status.json");
    const queuePath = join(runDir, "queue.json");
    const metadataPath = join(runDir, "metadata.json");
    if (!existsSync(statusPath)) continue;

    const status = readJsonSafe(statusPath);
    const queue = readJsonSafe(queuePath);
    const metadata = readJsonSafe(metadataPath) || {};
    if (!status?.items || typeof status.items !== "object") continue;

    let mtimeMs = 0;
    for (const path of [statusPath, queuePath, metadataPath]) {
      try {
        mtimeMs = Math.max(mtimeMs, statSync(path).mtimeMs);
      } catch {
        // Missing queue/metadata is tolerated; status.json is the durable signal.
      }
    }
    runs.push({ runId, runDir, status, queue: Array.isArray(queue) ? queue : [], metadata, mtimeMs });
  }

  const ledgerDir = join(repoRoot, ".ralph", "recovery");
  const ledgerByIssue = new Map();
  if (existsSync(ledgerDir)) {
    for (const entry of readdirSync(ledgerDir, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
      const issueNumber = Number(basename(entry.name, ".json"));
      if (!Number.isFinite(issueNumber)) continue;
      const ledgerData = readJsonSafe(join(ledgerDir, entry.name));
      if (ledgerData) ledgerByIssue.set(issueNumber, ledgerData);
    }
  }

  return runs
    .sort((a, b) => runSortTime(b) - runSortTime(a) || b.runId.localeCompare(a.runId))
    .slice(0, maxRuns)
    .flatMap((run) => {
      const queueByIssue = new Map(run.queue.map((item) => [Number(item.number), item]));
      return Object.entries(run.status.items)
        .filter(([, item]) => item?.status === "recoverable")
        .map(([issueNumber, item]) => {
          const number = Number(issueNumber);
          const queueItem = queueByIssue.get(number) || {};
          const ledger = ledgerByIssue.get(number) || {};
          const logFile = typeof item.logFile === "string" && item.logFile ? basename(item.logFile) : null;
          return {
            number,
            title: queueItem.title || `Issue #${number}`,
            url: queueItem.url || null,
            labels: Array.isArray(queueItem.labels) ? queueItem.labels : [],
            status: "recoverable",
            reason: item.error || ledger.reason || "Worker exited before merge",
            runId: run.runId,
            runDir: run.runDir,
            runCreatedAt: run.metadata.createdAt || null,
            runMode: run.metadata.runMode || null,
            model: run.metadata.model || null,
            parallelism: run.metadata.parallelism || null,
            workerId: item.workerId ?? null,
            pid: item.pid ?? null,
            logFile,
            logFilePath: logFile ? join(repoRoot, ".ralph", "logs", logFile) : null,
            startedAt: item.startedAt || ledger.lastAttemptAt || null,
            attemptCount: item.attemptCount ?? ledger.attemptCount ?? 0,
            maxAttempts: ledger.maxAttempts ?? 2,
            nextRetryAt: item.nextRetryAt || ledger.nextRetryAt || null,
            prNumber: ledger.prNumber ?? null,
            branch: ledger.branch ?? null,
          };
        });
    })
    .sort((a, b) => String(b.nextRetryAt || "").localeCompare(String(a.nextRetryAt || "")))
    .slice(0, maxItems);
}

function issueMap(issues, closedIssues) {
  const byNumber = new Map();
  for (const issue of [...(closedIssues || []), ...(issues || [])]) {
    if (Number.isFinite(Number(issue?.number))) byNumber.set(Number(issue.number), issue);
  }
  return byNumber;
}

function prMap(openPrs) {
  const byIssue = new Map();
  for (const pr of openPrs || []) {
    const refs = new Set();
    for (const ref of pr.closingIssuesReferences || []) if (ref?.number) refs.add(Number(ref.number));
    const branchMatch = String(pr.headRefName || "").match(/(?:issue|slice)-(\d+)/i);
    if (branchMatch) refs.add(Number(branchMatch[1]));
    for (const number of refs) {
      if (!byIssue.has(number)) byIssue.set(number, { number: pr.number, url: pr.url, title: pr.title });
    }
  }
  return byIssue;
}

function newerTimestamp(value) {
  return Date.parse(value?.failedAt || value?.startedAt || value?.runCreatedAt || value?.closedAt || value?.updatedAt || "") || 0;
}

function failureTimestamp(failure) {
  return Date.parse(failure?.failedAt || failure?.startedAt || failure?.runCreatedAt || "") || 0;
}

function shouldSuppressRunFailureForCurrentIssue(failure, currentIssue) {
  if (!currentIssue) return false;
  const currentLabels = labelNames(currentIssue);
  if (currentLabels.includes("ralph:failed") || currentLabels.includes("ralph:running")) return false;
  if (!currentLabels.some((name) => name.startsWith("ralph:"))) return false;

  const failedAt = failureTimestamp(failure);
  if (!failedAt) return true;
  const issueChangedAt = Date.parse(currentIssue.updatedAt || currentIssue.closedAt || currentIssue.createdAt || "") || 0;
  return issueChangedAt > failedAt;
}

export function computePipelineErrorState({ repo, error, now = Date.now() }) {
  return {
    repoSlug: repo?.slug || null,
    label: repo?.label || null,
    mainCheckout: repo?.mainCheckout || null,
    generatedAt: new Date(now).toISOString(),
    error,
    failed: [],
    recoverable: [],
    running: [],
    ready: [],
    deferred: [],
    awaiting: [],
    held: [],
    needsTriage: [],
    recent: [],
    nextQueue: [],
    queueCap: QUEUE_CAP,
    lastTick: null,
    counts: {
      failed: 0,
      recoverable: 0,
      running: 0,
      ready: 0,
      deferred: 0,
      awaiting: 0,
      held: 0,
      needsTriage: 0,
      recent: 0,
    },
  };
}

export function computePipelineState({
  repo,
  openIssues = [],
  closedIssues = [],
  claims = {},
  openPrs = [],
  failedRunItems = [],
  recoverableRunItems = [],
  ledger = null,
  now = Date.now(),
}) {
  const repoSlug = repo?.slug || null;
  const mainCheckout = repo?.mainCheckout || null;
  const linkedPrByIssue = prMap(openPrs);
  const openNums = new Set(openIssues.map((issue) => issue.number));
  const issuesByNumber = issueMap(openIssues, closedIssues);
  const currentRunFailures = new Set(
    (failedRunItems || [])
      .filter((failure) => !shouldSuppressRunFailureForCurrentIssue(failure, issuesByNumber.get(Number(failure.number))))
      .map((failure) => Number(failure.number)),
  );

  const card = (issue, extra = {}) => {
    const names = labelNames(issue);
    return {
      repoSlug,
      label: repo?.label || null,
      mainCheckout,
      number: issue.number,
      title: issue.title,
      url: issue.url,
      priority: pick(names, "priority:"),
      workType: pick(names, "work:"),
      state: primaryState(names),
      lane: predictLane(names),
      ageDays: ageDays(issue.createdAt, now),
      assignee: (issue.assignees || []).map((assignee) => (typeof assignee === "string" ? assignee : assignee.login))[0] || null,
      linkedPR: linkedPrByIssue.get(issue.number) || null,
      ...extra,
    };
  };

  const failedByIssue = new Map();
  const upsertFailure = (failure) => {
    if (!Number.isFinite(Number(failure?.number))) return;
    const number = Number(failure.number);
    const existing = failedByIssue.get(number);
    if (!existing) {
      failedByIssue.set(number, failure);
      return;
    }
    const shouldReplace =
      (!existing.runId && failure.runId) ||
      (Boolean(existing.runId) === Boolean(failure.runId) && newerTimestamp(failure) >= newerTimestamp(existing));
    failedByIssue.set(number, shouldReplace ? { ...existing, ...failure } : { ...failure, ...existing });
  };

  const running = [];
  const recoverable = [];
  const ready = [];
  const deferred = [];
  const awaiting = [];
  const needsTriage = [];
  const held = [];

  for (const issue of openIssues) {
    const names = labelNames(issue);
    const st = primaryState(names);
    const blockers = parseBlockers(issue.body).filter((number) => openNums.has(number));
    const linkedPR = linkedPrByIssue.get(issue.number) || null;

    if (names.includes("ralph:failed")) {
      upsertFailure(
        card(issue, {
          state: "ralph:failed",
          reason: "Issue has ralph:failed label",
          failedAt: issue.updatedAt || issue.createdAt || null,
          source: "issue-label",
        }),
      );
      continue;
    }

    if (currentRunFailures.has(Number(issue.number))) {
      continue;
    }

    if (st === "ralph:running") {
      const claim = claims[String(issue.number)] || null;
      running.push(
        card(issue, {
          worker: claim
            ? {
                pid: claim.pid,
                startedAt: claim.startedAt,
                logFile: claim.logFile ? basename(claim.logFile) : null,
                workerId: claim.workerId,
                resumeAttempt: claim.resumeAttempt || 0,
              }
            : null,
        }),
      );
    } else if (st === "ralph:ready") {
      const runnable = RUNNABLE_WORK.has(pick(names, "work:") || "");
      const assigned = (issue.assignees || []).length > 0;
      if (blockers.length === 0 && runnable && !assigned && !linkedPR) {
        ready.push(card(issue));
      } else {
        let reason;
        if (linkedPR) reason = `open PR #${linkedPR.number}`;
        else if (blockers.length) reason = `blocked by ${blockers.map((number) => `#${number}`).join(", ")}`;
        else if (assigned) reason = "assigned";
        else reason = "not a runnable work type";
        deferred.push(card(issue, { reason, blockers }));
      }
    } else if (st === "ralph:fast-lane" || st === "ralph:evaluated") {
      awaiting.push(card(issue, { note: st === "ralph:fast-lane" ? "AUTO candidate - awaiting one-tap" : "PRD parent - reviewed" }));
    } else if (st === "ralph:blocked") {
      const reason = blockers.length ? `blocked by ${blockers.map((number) => `#${number}`).join(", ")}` : "blocked before pickup";
      held.push(card(issue, { kind: "blocked", reason, blockers }));
    } else if (st === "ralph:hitl") {
      held.push(card(issue, { kind: "hitl", note: "human-in-the-loop - not autonomous" }));
    } else if (st === "ralph:needs-triage") {
      needsTriage.push(card(issue));
    }
  }

  for (const issue of closedIssues) {
    const names = labelNames(issue);
    if (!names.includes("ralph:failed")) continue;
    upsertFailure({
      ...card(issue, {
        state: "ralph:failed",
        reason: "Closed with ralph:failed label",
        failedAt: issue.closedAt || null,
        source: "closed-issue-label",
      }),
      ageDays: null,
    });
  }

  for (const failure of failedRunItems || []) {
    const currentIssue = issuesByNumber.get(Number(failure.number));
    if (shouldSuppressRunFailureForCurrentIssue(failure, currentIssue)) continue;
    const issue =
      currentIssue ||
      {
        number: Number(failure.number),
        title: failure.title || `Issue #${failure.number}`,
        url: failure.url,
        labels: failure.labels || [],
        assignees: [],
        body: "",
        createdAt: null,
        updatedAt: failure.failedAt || failure.startedAt || failure.runCreatedAt || null,
      };
    upsertFailure(
      card(issue, {
        state: "ralph:failed",
        reason: failure.reason || "Ralph worker failed",
        runId: failure.runId,
        runDir: failure.runDir,
        runCreatedAt: failure.runCreatedAt || null,
        runMode: failure.runMode || null,
        model: failure.model || null,
        parallelism: failure.parallelism || null,
        workerId: failure.workerId ?? null,
        pid: failure.pid ?? null,
        logFile: failure.logFile || null,
        logFilePath: failure.logFilePath || null,
        startedAt: failure.startedAt || null,
        failedAt: failure.failedAt || failure.startedAt || failure.runCreatedAt || null,
        source: "run-status",
      }),
    );
  }

  ready.sort((a, b) => priorityRank(a.priority) - priorityRank(b.priority) || a.number - b.number);
  const nextQueue = ready.slice(0, QUEUE_CAP).map((item) => item.number);
  ready.forEach((item, index) => {
    item.queued = index < QUEUE_CAP;
  });

  const recent = (closedIssues || [])
    .map((issue) => ({ issue, names: labelNames(issue) }))
    .filter(({ names }) => names.includes("ralph:done") || names.includes("ralph:failed"))
    .map(({ issue, names }) => ({
      number: issue.number,
      title: issue.title,
      url: issue.url,
      closedAt: issue.closedAt,
      outcome: names.includes("ralph:failed") ? "failed" : "done",
    }))
    .sort((a, b) => String(b.closedAt).localeCompare(String(a.closedAt)))
    .slice(0, 8);

  const failed = [...failedByIssue.values()]
    .sort((a, b) => newerTimestamp(b) - newerTimestamp(a) || a.number - b.number)
    .slice(0, 20);

  // Process recoverable run items
  const currentRecoverableNums = new Set((recoverableRunItems || []).map((item) => Number(item.number)));
  for (const rec of recoverableRunItems || []) {
    const currentIssue = issuesByNumber.get(Number(rec.number));
    // Skip if issue has a live running claim
    const claim = claims[String(rec.number)] || null;
    if (claim) continue;
    
    const issue =
      currentIssue ||
      {
        number: Number(rec.number),
        title: rec.title || `Issue #${rec.number}`,
        url: rec.url,
        labels: rec.labels || [],
        assignees: [],
        body: "",
        createdAt: null,
        updatedAt: rec.startedAt || rec.runCreatedAt || null,
      };
    
    recoverable.push(
      card(issue, {
        state: primaryState(labelNames(issue)) || "ralph:queued",
        reason: rec.reason || "Worker exited before merge",
        runId: rec.runId,
        runDir: rec.runDir,
        runCreatedAt: rec.runCreatedAt || null,
        runMode: rec.runMode || null,
        model: rec.model || null,
        parallelism: rec.parallelism || null,
        workerId: rec.workerId ?? null,
        pid: rec.pid ?? null,
        logFile: rec.logFile || null,
        logFilePath: rec.logFilePath || null,
        startedAt: rec.startedAt || null,
        attemptCount: rec.attemptCount ?? 0,
        maxAttempts: rec.maxAttempts ?? 2,
        nextRetryAt: rec.nextRetryAt || null,
        prNumber: rec.prNumber ?? null,
        branch: rec.branch ?? null,
      }),
    );
  }

  let lastTick = null;
  if (ledger) {
    const blockers = Array.isArray(ledger.blockers) ? ledger.blockers : [];
    const phase = ledger.phase || null;
    const outcome = ledger.noReadyWork ? "no ready work" : blockers.length ? "blocked" : phase || "ok";
    const firstBlocker = blockers[0];
    lastTick = {
      phase,
      outcome,
      blockerCount: blockers.length,
      blocker: firstBlocker ? (firstBlocker.kind || firstBlocker.type || "") + (firstBlocker.detail ? `: ${firstBlocker.detail}` : "") : null,
      runId: ledger.run?.runId || null,
      queuedIssues: (ledger.queuedIssues || []).map((item) => item.number),
      updatedAt: ledger.updatedAt || ledger.lastSuccessfulAutomatedStart || null,
    };
  }

  return {
    repoSlug,
    label: repo?.label || null,
    mainCheckout,
    generatedAt: new Date(now).toISOString(),
    error: null,
    failed,
    recoverable,
    running,
    ready,
    deferred,
    awaiting,
    held,
    needsTriage,
    recent,
    nextQueue,
    queueCap: QUEUE_CAP,
    lastTick,
    counts: {
      failed: failed.length,
      recoverable: recoverable.length,
      running: running.length,
      ready: ready.length,
      deferred: deferred.length,
      awaiting: awaiting.length,
      held: held.length,
      needsTriage: needsTriage.length,
      recent: recent.length,
    },
  };
}
