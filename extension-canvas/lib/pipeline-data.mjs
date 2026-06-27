// Pure pipeline computation module — no gh/fs/network dependencies
// Computes pipeline buckets from issue/PR/claim data
//
// Buckets:
// - running: issues with ralph:running + worker metadata
// - ready: unblocked, runnable work types, no assignee, no open PR
// - deferred: ready but blocked/assigned/has open PR
// - awaiting: fast-lane / evaluated issues
// - held: blocked / hitl issues (not autonomously runnable)
// - needsTriage: ralph:needs-triage
// - recent: ralph:done / ralph:failed (closed)

const QUEUE_CAP = 3; // bounded queue: at most 3 issues per tick, priority-first
const RUNNABLE_WORK = new Set(["work:slice", "work:standalone"]);
const PRIORITY_RANK = new Map([
  ["priority:P0", 0],
  ["priority:P1", 1],
  ["priority:P2", 2],
  ["priority:P3", 3],
]);
const STATE_ORDER = [
  "ralph:running",
  "ralph:ready",
  "ralph:fast-lane",
  "ralph:evaluated",
  "ralph:blocked",
  "ralph:hitl",
  "ralph:needs-triage",
];

function labelNames(issue) {
  return (issue.labels || []).map((l) => (typeof l === "string" ? l : l.name));
}

function primaryState(names) {
  for (const s of STATE_ORDER) if (names.includes(s)) return s;
  return null;
}

function pick(names, prefix) {
  return names.find((n) => n.startsWith(prefix)) || null;
}

function priorityRank(priority) {
  return PRIORITY_RANK.get(priority) ?? PRIORITY_RANK.get("priority:P2");
}

// Predicted lane the orchestrator/triage would route this issue to.
function predictLane(names) {
  if (names.includes("ralph:hitl") || names.includes("ralph:blocked")) return "HOLD";
  if (names.includes("ralph:fast-lane")) return "AUTO";
  if (names.includes("work:prd")) return "PRD";
  if (names.includes("ralph:ready") && RUNNABLE_WORK.has(pick(names, "work:") || "")) return "REFINE";
  return null;
}

// Parse a "## Blocked by\n- #N" section into blocker issue numbers.
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
    if (inSection) {
      if (/^#{1,6}\s/.test(line)) break; // next header ends section
      if (/^-?\s*none/i.test(line)) break;
      const m = line.match(/#(\d+)/);
      if (m) out.push(Number(m[1]));
      else if (line === "" && out.length) break;
    }
  }
  return out;
}

function ageDays(iso) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.round((Date.now() - t) / 86400000));
}

/**
 * Compute pipeline state from raw issue/PR/claim data
 * @param {Object} input
 * @param {Array} input.issues - Open issues (from gh issue list --state open)
 * @param {Array} [input.closedIssues] - Recently closed issues (from gh issue list --state closed)
 * @param {Object} input.claims - Worker claims from .ralph/state.json {issueNumber: {pid, startedAt, ...}}
 * @param {Array} input.openPrs - Open PRs (from gh pr list --state open)
 * @returns {Object} Pipeline state buckets
 */
export function computePipelineState({ issues, closedIssues = [], claims = {}, openPrs = [] }) {
  // Map open PRs -> issue numbers they close / reference
  const prByIssue = new Map();
  for (const pr of openPrs || []) {
    const refs = new Set();
    for (const r of pr.closingIssuesReferences || []) if (r && r.number) refs.add(r.number);
    const bm = (pr.headRefName || "").match(/(?:issue|slice)-(\d+)/i);
    if (bm) refs.add(Number(bm[1]));
    for (const n of refs) {
      if (!prByIssue.has(n)) prByIssue.set(n, { number: pr.number, url: pr.url, title: pr.title });
    }
  }

  const openNums = new Set((issues || []).map((i) => i.number));

  const card = (i, extra = {}) => {
    const names = labelNames(i);
    const linkedPR = prByIssue.get(i.number) || null;
    return {
      number: i.number,
      title: i.title,
      url: i.url,
      priority: pick(names, "priority:"),
      workType: pick(names, "work:"),
      state: primaryState(names),
      lane: predictLane(names),
      ageDays: ageDays(i.createdAt),
      assignee: (i.assignees || []).map((a) => (typeof a === "string" ? a : a.login))[0] || null,
      linkedPR,
      ...extra,
    };
  };

  const running = [];
  const ready = [];
  const deferred = [];
  const awaiting = [];
  const needsTriage = [];
  const held = [];

  for (const i of issues || []) {
    const names = labelNames(i);
    const st = primaryState(names);
    const blockers = parseBlockers(i.body).filter((n) => openNums.has(n));
    const linkedPR = prByIssue.get(i.number) || null;

    if (st === "ralph:running") {
      const cl = claims[String(i.number)] || null;
      running.push(
        card(i, {
          worker: cl
            ? {
                pid: cl.pid,
                startedAt: cl.startedAt,
                logFile: cl.logFile,
                workerId: cl.workerId,
                resumeAttempt: cl.resumeAttempt || 0,
              }
            : null,
        }),
      );
    } else if (st === "ralph:ready") {
      const runnable = RUNNABLE_WORK.has(pick(names, "work:") || "");
      const assignee = (i.assignees || []).length > 0;
      if (blockers.length === 0 && runnable && !assignee && !linkedPR) {
        ready.push(card(i));
      } else {
        let reason;
        if (linkedPR) reason = `open PR #${linkedPR.number}`;
        else if (blockers.length) reason = `blocked by ${blockers.map((n) => "#" + n).join(", ")}`;
        else if (assignee) reason = "assigned";
        else reason = "not a runnable work type";
        deferred.push(card(i, { reason, blockers }));
      }
    } else if (st === "ralph:fast-lane" || st === "ralph:evaluated") {
      awaiting.push(
        card(i, {
          note: st === "ralph:fast-lane" ? "AUTO candidate — awaiting one-tap" : "PRD parent — reviewed",
        }),
      );
    } else if (st === "ralph:blocked") {
      const reason = blockers.length
        ? `blocked by ${blockers.map((n) => "#" + n).join(", ")}`
        : "blocked before pickup";
      held.push(card(i, { kind: "blocked", reason, blockers }));
    } else if (st === "ralph:hitl") {
      held.push(card(i, { kind: "hitl", note: "human-in-the-loop — not autonomous" }));
    } else if (st === "ralph:needs-triage") {
      needsTriage.push(card(i));
    }
  }

  // Sort ready by priority then number, compute next-run queue
  ready.sort((a, b) => priorityRank(a.priority) - priorityRank(b.priority) || a.number - b.number);
  const nextQueue = ready.slice(0, QUEUE_CAP).map((c) => c.number);
  ready.forEach((c, idx) => {
    c.queued = idx < QUEUE_CAP;
  });

  // Recent closed issues
  const recent = (closedIssues || [])
    .map((i) => ({ i, names: labelNames(i) }))
    .filter(({ names }) => names.includes("ralph:done") || names.includes("ralph:failed"))
    .map(({ i, names }) => ({
      number: i.number,
      title: i.title,
      url: i.url,
      closedAt: i.closedAt,
      outcome: names.includes("ralph:failed") ? "failed" : "done",
    }))
    .sort((a, b) => String(b.closedAt).localeCompare(String(a.closedAt)))
    .slice(0, 8);

  return {
    running,
    ready,
    deferred,
    awaiting,
    held,
    needsTriage,
    recent,
    nextQueue,
    queueCap: QUEUE_CAP,
    counts: {
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
