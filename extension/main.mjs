import { execFile, spawn } from "node:child_process";
import { existsSync, openSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { joinSession } from "@github/copilot-sdk/extension";
import { CopilotWebview } from "./lib/copilot-webview.js";

const execFileAsync = promisify(execFile);

// Walk up from `start` looking for a directory containing any of `markers`.
// Returns the first match, or null. Used to resolve the project repo root
// when the extension is installed at the user level (~/.copilot/extensions/).
function findUpward(start, markers) {
  let dir = resolve(start);
  while (true) {
    for (const marker of markers) {
      if (existsSync(join(dir, marker))) return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// Resolve the target project root. Precedence:
//   1. RALPH_REPO_ROOT env var (explicit override)
//   2. Walk up from process.cwd() to a directory containing .ralph/
//   3. Walk up from process.cwd() to a directory containing .git/
//   4. Walk up from this file (legacy in-repo install at .github/extensions/...)
//   5. process.cwd() (last resort)
function resolveRepoRoot() {
  if (process.env.RALPH_REPO_ROOT) return resolve(process.env.RALPH_REPO_ROOT);
  return (
    findUpward(process.cwd(), [".ralph"]) ||
    findUpward(process.cwd(), [".git"]) ||
    findUpward(import.meta.dirname, [".ralph"]) ||
    process.cwd()
  );
}

const REPO_ROOT = resolveRepoRoot();
const LOOP_LOG = join(REPO_ROOT, ".ralph", "loop.out");
const LOGS_DIR = join(REPO_ROOT, ".ralph", "logs");

// Issue title pattern. Default matches "Slice N:" but can be overridden so
// other workflows (e.g., "Task N:" or "Step N:") work without code changes.
const TITLE_REGEX_SOURCE = process.env.RALPH_TITLE_REGEX || "^Slice [0-9]+:";
const TITLE_REGEX = new RegExp(TITLE_REGEX_SOURCE);
const TITLE_NUM_RE = new RegExp(process.env.RALPH_TITLE_NUM_REGEX || "^Slice ([0-9]+):");
// gh search query — see https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests
const ISSUE_SEARCH = process.env.RALPH_ISSUE_SEARCH || "Slice in:title";

async function getLoopProcess() {
  try {
    // Use ps -ax with full command output for cross-platform support
    // (macOS pgrep -a doesn't print command lines like Linux pgrep -a does).
    const { stdout } = await execFileAsync("ps", ["-axww", "-o", "pid=,command="], {
      timeout: 3000,
    });
    const lines = stdout.split("\n").filter((l) => {
      if (!l.trim()) return false;
      if (l.includes("ps -axww")) return false;
      if (l.includes("ralph_dashboard") || l.includes("ralph-dashboard")) return false;
      return /ralph\.sh|copilot -p/.test(l);
    });
    return lines.map((l) => {
      const trimmed = l.trim();
      const sp = trimmed.indexOf(" ");
      return { pid: Number(trimmed.slice(0, sp)), cmd: trimmed.slice(sp + 1) };
    });
  } catch {
    return [];
  }
}

// Heuristic stage detector. Scans the iteration log from end to beginning,
// returning the latest matching stage marker (most-recent activity wins).
function detectStage(logBody) {
  if (!logBody) return { stage: "starting", label: "starting", icon: "○" };
  const lines = logBody.split("\n");
  // walk backwards — last marker wins
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i];
    if (/gh pr merge\b/.test(l)) return { stage: "merging", label: "merging", icon: "✓" };
    if (/gh pr checks\b/.test(l)) return { stage: "ci-wait", label: "waiting on CI", icon: "⏱" };
    if (/Code-review\(/i.test(l)) return { stage: "review", label: "code review", icon: "🔍" };
    if (/gh pr create\b/.test(l)) return { stage: "pr-open", label: "PR opened", icon: "↑" };
    if (/Rubber-duck\(/i.test(l))
      return { stage: "planning", label: "planning critique", icon: "🦆" };
    if (/\bbun test\b/.test(l)) return { stage: "testing", label: "running tests", icon: "🧪" };
    if (/\bgit (commit|push)\b/.test(l))
      return { stage: "implementing", label: "committing", icon: "✎" };
  }
  return { stage: "working", label: "working", icon: "⚙" };
}

// Count dual-model code-review dispatches in the log (proxy for "review ran").
function detectReviewStats(logBody) {
  if (!logBody) return null;
  const gpt = (logBody.match(/Code-review\(gpt-5\.5\)/gi) || []).length;
  const opus = (logBody.match(/Code-review\(claude-opus-4\.7\)/gi) || []).length;
  if (gpt === 0 && opus === 0) return null;
  return { gpt, opus, total: gpt + opus };
}

// Best-effort token usage parser. Copilot CLI doesn't currently print usage
// to stdout but if/when it does, regexes below catch common formats.
function detectTokens(logBody) {
  if (!logBody) return null;
  const patterns = [
    /total tokens?:\s*([\d,]+)/i,
    /tokens used:\s*([\d,]+)/i,
    /usage:\s*([\d,]+)\s*tokens?/i,
  ];
  for (const re of patterns) {
    const m = logBody.match(re);
    if (m) return Number(m[1].replace(/,/g, ""));
  }
  return null;
}

function getCurrentIteration() {
  if (!existsSync(LOGS_DIR)) return null;
  try {
    const files = readdirSync(LOGS_DIR)
      .filter((f) => /^iter-.*-issue-\d+\.log$/.test(f))
      .map((f) => ({ name: f, mtime: statSync(join(LOGS_DIR, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime);
    if (!files.length) return null;
    const latest = files[0];
    const m = latest.name.match(/^iter-(\d{8})-(\d{6})-issue-(\d+)\.log$/);
    if (!m) return null;
    const [, date, time, issue] = m;
    const startedAt = new Date(
      `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${time.slice(0, 2)}:${time.slice(2, 4)}:${time.slice(4, 6)}`,
    ).toISOString();
    let tail = "";
    let fullBody = "";
    try {
      fullBody = readFileSync(join(LOGS_DIR, latest.name), "utf8");
      tail = fullBody.split("\n").slice(-40).join("\n");
    } catch {}
    // Heartbeat — seconds since last log write. >300s = stuck.
    const lastWriteMs = latest.mtime;
    const ageSec = Math.floor((Date.now() - lastWriteMs) / 1000);
    return {
      issue: Number(issue),
      startedAt,
      logFile: latest.name,
      tail,
      stage: detectStage(fullBody),
      reviewStats: detectReviewStats(fullBody),
      tokens: detectTokens(fullBody),
      lastWriteAt: new Date(lastWriteMs).toISOString(),
      ageSec,
      stuck: ageSec > 300,
    };
  } catch {
    return null;
  }
}

function getLoopOutTail(lines = 20) {
  if (!existsSync(LOOP_LOG)) return "";
  try {
    const buf = readFileSync(LOOP_LOG, "utf8");
    return buf.split("\n").slice(-lines).join("\n");
  } catch {
    return "";
  }
}

function getIterationHistory(limit = 20) {
  if (!existsSync(LOGS_DIR)) return { iterations: [], stats: null };
  try {
    const files = readdirSync(LOGS_DIR)
      .filter((f) => /^iter-(\d{8})-(\d{6})-issue-\d+\.log$/.test(f))
      .map((f) => {
        const m = f.match(/^iter-(\d{8})-(\d{6})-issue-(\d+)\.log$/);
        const [, date, time, issue] = m;
        const startedAt = new Date(
          `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${time.slice(0, 2)}:${time.slice(2, 4)}:${time.slice(4, 6)}`,
        );
        const stat = statSync(join(LOGS_DIR, f));
        return {
          issue: Number(issue),
          startedAt: startedAt.toISOString(),
          startedAtMs: startedAt.getTime(),
          finishedAtMs: stat.mtimeMs,
          durationMs: Math.max(0, stat.mtimeMs - startedAt.getTime()),
          sizeBytes: stat.size,
          logFile: f,
        };
      })
      .sort((a, b) => b.startedAtMs - a.startedAtMs);

    const now = Date.now();
    const dayAgo = now - 24 * 60 * 60 * 1000;
    const recent = files.filter((f) => f.startedAtMs >= dayAgo);
    const durations = files.filter((f) => f.durationMs > 0).map((f) => f.durationMs);
    const avgMs = durations.length ? durations.reduce((a, b) => a + b, 0) / durations.length : 0;

    return {
      iterations: files.slice(0, limit),
      stats: {
        total: files.length,
        last24h: recent.length,
        avgDurationMs: Math.round(avgMs),
        lastIterationAt: files[0]?.startedAt || null,
      },
    };
  } catch {
    return { iterations: [], stats: null };
  }
}

async function ghJson(args) {
  try {
    const env = {
      ...process.env,
      PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || ""}`,
    };
    const { stdout } = await execFileAsync("gh", args, { cwd: REPO_ROOT, timeout: 10000, env });
    return JSON.parse(stdout);
  } catch (err) {
    return { error: String(err.message || err) };
  }
}

async function getOpenSlices() {
  const data = await ghJson([
    "issue",
    "list",
    "--state",
    "open",
    "--limit",
    "30",
    "--search",
    ISSUE_SEARCH,
    "--json",
    "number,title,url",
  ]);
  if (!Array.isArray(data)) return [];
  return data
    .map((i) => {
      const m = i.title.match(TITLE_NUM_RE);
      return { ...i, slice: m ? Number(m[1]) : 999 };
    })
    .filter((i) => TITLE_REGEX.test(i.title))
    .sort((a, b) => a.slice - b.slice);
}

async function getRecentPrs() {
  const data = await ghJson([
    "pr",
    "list",
    "--state",
    "all",
    "--limit",
    "10",
    "--json",
    "number,title,state,mergedAt,url,additions,deletions,changedFiles",
  ]);
  if (!Array.isArray(data)) return [];
  return data;
}

async function getPrDetail(number) {
  if (!Number.isInteger(number) || number <= 0) {
    return { error: "invalid PR number" };
  }
  const data = await ghJson([
    "pr",
    "view",
    String(number),
    "--json",
    "number,title,body,state,url,mergedAt,createdAt,closedAt,headRefName,baseRefName,additions,deletions,changedFiles,author,labels,isDraft",
  ]);
  return data;
}

async function getIssueDetail(number) {
  const data = await ghJson([
    "issue",
    "view",
    String(number),
    "--json",
    "number,title,body,labels,state,createdAt,updatedAt,comments,url,milestone",
  ]);
  return data;
}

// Find the open PR (if any) that closes the given issue, with CI/review summary.
async function getCurrentPr(issueNumber) {
  if (!issueNumber) return null;
  // gh pr list lets us filter by `linked` issue via search
  const list = await ghJson([
    "pr",
    "list",
    "--state",
    "open",
    "--search",
    `linked:issue ${issueNumber}`,
    "--json",
    "number,title,url,isDraft,headRefName",
    "--limit",
    "5",
  ]);
  let pr = Array.isArray(list) && list.length ? list[0] : null;
  // Fallback: scan recent open PRs for the issue number in title/body via gh issue.
  if (!pr) {
    const issueData = await ghJson([
      "issue",
      "view",
      String(issueNumber),
      "--json",
      "closedByPullRequestsReferences",
    ]);
    const ref = issueData?.closedByPullRequestsReferences?.find?.((p) => p.state === "OPEN");
    if (ref)
      pr = { number: ref.number, title: ref.title, url: ref.url, isDraft: false, headRefName: "" };
  }
  if (!pr) return null;
  const detail = await ghJson([
    "pr",
    "view",
    String(pr.number),
    "--json",
    "number,title,url,isDraft,state,statusCheckRollup,reviewDecision,additions,deletions,changedFiles,commits",
  ]);
  if (detail?.error) return { ...pr, error: detail.error };
  const checks = detail.statusCheckRollup || [];
  const summary = { total: checks.length, pass: 0, fail: 0, pending: 0 };
  for (const c of checks) {
    const concl = (c.conclusion || c.status || "").toUpperCase();
    if (["SUCCESS", "NEUTRAL", "SKIPPED"].includes(concl)) summary.pass++;
    else if (["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"].includes(concl))
      summary.fail++;
    else summary.pending++;
  }
  return {
    number: detail.number,
    title: detail.title,
    url: detail.url,
    isDraft: detail.isDraft,
    state: detail.state,
    reviewDecision: detail.reviewDecision || null,
    additions: detail.additions ?? 0,
    deletions: detail.deletions ?? 0,
    changedFiles: detail.changedFiles ?? 0,
    commitCount: detail.commits?.length ?? 0,
    checks: summary,
  };
}

// Cumulative stats for "today" (local date), derived from recentPrs.
function getCumulativeStats(prs) {
  if (!Array.isArray(prs)) return null;
  const todayLocal = new Date();
  todayLocal.setHours(0, 0, 0, 0);
  const startMs = todayLocal.getTime();
  const merged = prs.filter(
    (p) => p.state === "MERGED" && p.mergedAt && new Date(p.mergedAt).getTime() >= startMs,
  );
  return {
    mergedToday: merged.length,
    additions: merged.reduce((a, p) => a + (p.additions ?? 0), 0),
    deletions: merged.reduce((a, p) => a + (p.deletions ?? 0), 0),
    changedFiles: merged.reduce((a, p) => a + (p.changedFiles ?? 0), 0),
  };
}

async function getStatus() {
  const [procs, slices, prs] = await Promise.all([
    getLoopProcess(),
    getOpenSlices(),
    getRecentPrs(),
  ]);
  const history = getIterationHistory(20);
  const openIssueNums = new Set(slices.map((s) => s.number));
  const mergedByIssue = new Map();
  for (const pr of prs) {
    const m = pr.title.match(/\(#(\d+)\)\s*$/) || pr.title.match(/issue[\s#-]*(\d+)/i);
    if (m && pr.state === "MERGED") mergedByIssue.set(Number(m[1]), pr);
  }
  const iterations = history.iterations.map((it) => {
    let status = "unknown";
    if (mergedByIssue.has(it.issue)) status = "merged";
    else if (openIssueNums.has(it.issue)) status = "open";
    else status = "closed";
    return { ...it, status, prUrl: mergedByIssue.get(it.issue)?.url || null };
  });
  const currentIteration = getCurrentIteration();
  const currentPr = currentIteration ? await getCurrentPr(currentIteration.issue) : null;
  return {
    timestamp: new Date().toISOString(),
    loopRunning: procs.some((p) => p.cmd.includes("ralph.sh")),
    processes: procs,
    currentIteration,
    currentPr,
    cumulative: getCumulativeStats(prs),
    loopOutTail: getLoopOutTail(20),
    iterationHistory: { iterations, stats: history.stats },
    openSlices: slices,
    recentPrs: prs,
  };
}

// Spawn .ralph/launch.sh detached so the loop survives this extension/session.
async function startLoop() {
  const procs = await getLoopProcess();
  if (procs.some((p) => p.cmd.includes("ralph.sh"))) {
    return { ok: false, error: "Loop is already running.", processes: procs };
  }
  const launcher = join(REPO_ROOT, ".ralph", "launch.sh");
  if (!existsSync(launcher)) {
    return { ok: false, error: `launcher not found: ${launcher}` };
  }
  try {
    // Append stdout/stderr to loop.out and fully detach so the process
    // survives the extension lifecycle.
    const out = openSync(LOOP_LOG, "a");
    const child = spawn("bash", [launcher], {
      cwd: REPO_ROOT,
      detached: true,
      stdio: ["ignore", out, out],
      env: {
        ...process.env,
        PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || ""}`,
      },
    });
    child.unref();
    return { ok: true, pid: child.pid };
  } catch (err) {
    return { ok: false, error: String(err.message || err) };
  }
}

// Stop the loop by SIGTERMing every detected ralph.sh + copilot -p PID.
async function stopLoop() {
  const procs = await getLoopProcess();
  if (procs.length === 0) {
    return { ok: false, error: "No loop process running." };
  }
  const killed = [];
  const failed = [];
  for (const p of procs) {
    try {
      process.kill(p.pid, "SIGTERM");
      killed.push(p.pid);
    } catch (err) {
      failed.push({ pid: p.pid, error: String(err.message || err) });
    }
  }
  return { ok: killed.length > 0, killed, failed };
}

const webview = new CopilotWebview({
  extensionName: "ralph_dashboard",
  contentDir: join(import.meta.dirname, "content"),
  title: "Ralph Loop Dashboard",
  width: 1200,
  height: 900,
  callbacks: {
    getStatus,
    getPrDetail,
    getIssueDetail,
    startLoop,
    stopLoop,
    log: (msg, opts) => session.log(msg, opts),
  },
});

const session = await joinSession({
  tools: webview.tools,
  commands: [
    {
      name: "ralph",
      description: "Open the Ralph loop dashboard window.",
      handler: () => webview.show(),
    },
  ],
  hooks: { onSessionEnd: webview.close },
});
