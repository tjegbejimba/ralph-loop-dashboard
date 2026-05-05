import { execFile, spawn } from "node:child_process";
import { existsSync, openSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { joinSession } from "@github/copilot-sdk/extension";
import { CopilotWebview } from "./lib/copilot-webview.js";
import { detectTokens, parseTokenUnit } from "./lib/tokens.mjs";
import { resolveRepoState } from "./lib/repo-resolver.mjs";
import { initializeRalph } from "./lib/ralph-init.mjs";
import { loadUserConfig } from "./lib/user-config.mjs";
import {
  retryFailedIssue,
  skipFailedIssue,
  removeQueuedIssue,
  reorderQueuedIssue,
} from "./lib/run-store.mjs";

const execFileAsync = promisify(execFile);

// Resolve repo state at extension load time
const REPO_STATE = resolveRepoState({
  env: process.env,
  cwd: process.cwd(),
  searchStart: import.meta.dirname,
});

// For backward compatibility, export REPO_ROOT (or fallback to cwd if unresolved)
const REPO_ROOT = REPO_STATE.repoRoot || process.cwd();
const LOOP_LOG = join(REPO_ROOT, ".ralph", "loop.out");
const LOGS_DIR = join(REPO_ROOT, ".ralph", "logs");
const STATE_FILE = join(REPO_ROOT, ".ralph", "state.json");
const CONFIG_FILE = join(REPO_ROOT, ".ralph", "config.json");

// Iteration log filenames may include an optional worker-id segment:
//   iter-{YYYYMMDD}-{HHMMSS}-w{id}-issue-{N}.log   (parallel workers)
//   iter-{YYYYMMDD}-{HHMMSS}-issue-{N}.log         (legacy single worker)
const ITER_LOG_REGEX = /^iter-(\d{8})-(\d{6})(?:-w(\d+))?-issue-(\d+)\.log$/;

const DEFAULT_CONFIG = {
  profile: "generic",
  issue: {
    titleRegex: "^Slice [0-9]+:",
    titleNumRegex: "^Slice ([0-9]+):",
    issueSearch: "Slice in:title",
  },
  validation: {
    commands: [{ name: "Project checks", command: "Run the relevant checks documented by this repo." }],
  },
  stages: [
    { id: "merging", label: "merging", icon: "✓", patterns: ["gh pr merge\\b"] },
    { id: "ci-wait", label: "waiting on CI", icon: "⏱", patterns: ["gh pr checks\\b"] },
    { id: "review", label: "code review", icon: "🔍", patterns: ["Code-review\\("] },
    { id: "pr-open", label: "PR opened", icon: "↑", patterns: ["gh pr create\\b"] },
    { id: "planning", label: "planning critique", icon: "🦆", patterns: ["Rubber-duck\\("] },
    { id: "testing", label: "running tests", icon: "🧪", patterns: ["\\bbun test\\b"] },
    { id: "implementing", label: "committing", icon: "✎", patterns: ["\\bgit (commit|push)\\b"] },
  ],
};

function readRalphConfig() {
  const warnings = [];
  let userConfig = {};
  if (existsSync(CONFIG_FILE)) {
    try {
      userConfig = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
    } catch (err) {
      warnings.push(`Could not parse .ralph/config.json: ${err.message || err}`);
    }
  }
  const config = {
    ...DEFAULT_CONFIG,
    ...userConfig,
    issue: { ...DEFAULT_CONFIG.issue, ...(userConfig.issue || {}) },
    validation: { ...DEFAULT_CONFIG.validation, ...(userConfig.validation || {}) },
    stages: Array.isArray(userConfig.stages) ? userConfig.stages : DEFAULT_CONFIG.stages,
  };
  if (!Array.isArray(config.validation.commands)) {
    warnings.push("Invalid validation.commands; using an empty command list.");
    config.validation.commands = [];
  }
  if (userConfig.stages !== undefined && !Array.isArray(userConfig.stages)) {
    warnings.push("Invalid stages; using default stage patterns.");
    config.stages = DEFAULT_CONFIG.stages;
  }
  return { config, warnings };
}

function compileRegex(source, fallback, warnings, label, flags = "") {
  const chosen = source || fallback;
  try {
    return { source: chosen, regex: new RegExp(chosen, flags) };
  } catch {
    warnings.push(`Invalid ${label} regex "${chosen}"; using "${fallback}".`);
    return { source: fallback, regex: new RegExp(fallback, flags) };
  }
}

function compileStages(config, warnings) {
  const compiled = [];
  for (const stage of config.stages) {
    if (!stage || typeof stage !== "object") continue;
    const regexes = [];
    for (const pattern of Array.isArray(stage.patterns) ? stage.patterns : []) {
      try {
        regexes.push(new RegExp(pattern, "i"));
      } catch {
        warnings.push(`Invalid stage regex "${pattern}" for stage "${stage.id || "unknown"}"; ignoring.`);
      }
    }
    if (regexes.length === 0) continue;
    compiled.push({
      stage: String(stage.id || "working"),
      label: String(stage.label || stage.id || "working"),
      icon: String(stage.icon || "○"),
      regexes,
    });
  }
  if (compiled.length > 0) return compiled;
  return DEFAULT_CONFIG.stages.map((stage) => ({
    stage: stage.id,
    label: stage.label,
    icon: stage.icon,
    regexes: stage.patterns.map((pattern) => new RegExp(pattern, "i")),
  }));
}

const { config: RALPH_CONFIG, warnings: CONFIG_WARNINGS } = readRalphConfig();
const titleRegex = compileRegex(
  process.env.RALPH_TITLE_REGEX || RALPH_CONFIG.issue.titleRegex,
  DEFAULT_CONFIG.issue.titleRegex,
  CONFIG_WARNINGS,
  "issue.titleRegex",
);
const titleNumRegex = compileRegex(
  process.env.RALPH_TITLE_NUM_REGEX || RALPH_CONFIG.issue.titleNumRegex,
  DEFAULT_CONFIG.issue.titleNumRegex,
  CONFIG_WARNINGS,
  "issue.titleNumRegex",
);
const TITLE_REGEX_SOURCE = titleRegex.source;
const TITLE_REGEX = titleRegex.regex;
const TITLE_NUM_RE = titleNumRegex.regex;
// gh search query — see https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests
const ISSUE_SEARCH =
  process.env.RALPH_ISSUE_SEARCH || RALPH_CONFIG.issue.issueSearch || DEFAULT_CONFIG.issue.issueSearch;
const STAGE_MATCHERS = compileStages(RALPH_CONFIG, CONFIG_WARNINGS);

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
    for (const stage of STAGE_MATCHERS) {
      if (stage.regexes.some((re) => re.test(l))) {
        return { stage: stage.stage, label: stage.label, icon: stage.icon };
      }
    }
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

// Parse Copilot CLI's compact token unit: "8.9m" → 8_900_000, "59.5k" → 59_500,
// "934" → 934. Returns null on garbage input. Case-insensitive on the suffix
// because the renderer displays them in lower-case but other producers may
// uppercase.
// (parseTokenUnit + detectTokens live in ./lib/tokens.mjs — pure helpers,
// imported above so they can be unit-tested without joinSession side effects.)

// Per-worker cumulative token totals — sum of every completed iteration log
// for that worker. Cached by (file, mtime) so a tick doesn't re-read N
// gigabytes of logs every refresh.
const _cumulativeCache = new Map(); // logFile -> { mtimeMs, tokens }
function tokensForLogFile(name) {
  const fullPath = join(LOGS_DIR, name);
  let mtimeMs;
  try {
    mtimeMs = statSync(fullPath).mtimeMs;
  } catch {
    return null;
  }
  const cached = _cumulativeCache.get(name);
  if (cached && cached.mtimeMs === mtimeMs) return cached.tokens;
  let body;
  try {
    body = readFileSync(fullPath, "utf8");
  } catch {
    return null;
  }
  const tokens = detectTokens(body);
  _cumulativeCache.set(name, { mtimeMs, tokens });
  return tokens;
}

// Sum tokens across every iter-*-w<workerId>-issue-*.log for a worker.
// Includes the in-flight log if it already has a Tokens summary (rare but
// possible when copilot prints early). Returns a structured object even
// when no logs have any tokens yet (counts will be 0).
function getWorkerCumulativeTokens(workerId) {
  if (workerId == null || !existsSync(LOGS_DIR)) return null;
  const total = { input: 0, output: 0, cached: 0, reasoning: 0, iterations: 0 };
  let any = false;
  let files;
  try {
    files = readdirSync(LOGS_DIR);
  } catch {
    return null;
  }
  for (const f of files) {
    const m = f.match(ITER_LOG_REGEX);
    if (!m) continue;
    if (Number(m[3]) !== Number(workerId)) continue;
    const t = tokensForLogFile(f);
    if (!t) continue;
    any = true;
    total.input += t.input || 0;
    total.output += t.output || 0;
    total.cached += t.cached || 0;
    total.reasoning += t.reasoning || 0;
    total.iterations += 1;
  }
  if (!any) return { ...total, total: 0 };
  return { ...total, total: total.input + total.output };
}

// Caches the last successfully-parsed claim list so a transient mid-write
// read doesn't collapse the dashboard from N workers to legacy-fallback mode.
let _lastClaims = null;
let _stateFilePresent = false;

// Returns { claims, stateMissing } so callers can distinguish "no state.json"
// (legacy install -> use most-recent-log fallback) from "state.json unreadable"
// (transient parse failure -> reuse last good claims).
function readClaims() {
  if (!existsSync(STATE_FILE)) {
    _stateFilePresent = false;
    _lastClaims = null;
    return { claims: [], stateMissing: true };
  }
  _stateFilePresent = true;
  try {
    const raw = readFileSync(STATE_FILE, "utf8");
    const parsed = JSON.parse(raw);
    const claimsObj = parsed?.claims || {};
    const claims = Object.entries(claimsObj).map(([issue, c]) => ({
      issue: Number(issue),
      // Coerce workerId to a finite number or null. Defends against any
      // bad/malicious state.json injecting strings into the rendered HTML.
      workerId: Number.isFinite(Number(c?.workerId)) ? Number(c.workerId) : null,
      pid: Number.isFinite(Number(c?.pid)) ? Number(c.pid) : null,
      startedAt: typeof c?.startedAt === "string" ? c.startedAt : null,
      logFile: typeof c?.logFile === "string" ? c.logFile : null,
    }));
    _lastClaims = claims;
    return { claims, stateMissing: false };
  } catch {
    // File present but unreadable/corrupt — keep prior tick rather than
    // silently reverting to legacy-latest-log mode.
    return { claims: _lastClaims || [], stateMissing: false };
  }
}

function buildIteration(logFile) {
  if (!logFile) return null;
  const m = logFile.match(ITER_LOG_REGEX);
  if (!m) return null;
  const [, date, time, workerId, issue] = m;
  const startedAt = new Date(
    `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${time.slice(0, 2)}:${time.slice(2, 4)}:${time.slice(4, 6)}`,
  ).toISOString();
  let tail = "";
  let fullBody = "";
  let lastWriteMs = 0;
  const fullPath = join(LOGS_DIR, logFile);
  try {
    const stat = statSync(fullPath);
    lastWriteMs = stat.mtimeMs;
    fullBody = readFileSync(fullPath, "utf8");
    tail = fullBody.split("\n").slice(-40).join("\n");
  } catch {}
  const ageSec = lastWriteMs ? Math.floor((Date.now() - lastWriteMs) / 1000) : null;
  return {
    issue: Number(issue),
    workerId: workerId ? Number(workerId) : null,
    startedAt,
    logFile,
    tail,
    stage: detectStage(fullBody),
    reviewStats: detectReviewStats(fullBody),
    tokens: detectTokens(fullBody),
    lastWriteAt: lastWriteMs ? new Date(lastWriteMs).toISOString() : null,
    ageSec,
    stuck: ageSec !== null && ageSec > 300,
  };
}

// Returns one iteration object per active worker, derived from state.json.
// Falls back to "latest log file" mode when state.json doesn't exist (the
// loop hasn't been upgraded yet, or this is a single-worker legacy install).
function getCurrentIterations() {
  const { claims, stateMissing } = readClaims();
  if (claims.length > 0) {
    return claims
      .map((c) => {
        const it = buildIteration(c.logFile);
        if (!it) {
          // state.json claim with no resolvable log — surface what we know.
          // Compute ageSec from startedAt so a worker hung before its first
          // log byte still trips the stuck threshold (>300s).
          let ageSec = null;
          if (c.startedAt) {
            const t = Date.parse(c.startedAt);
            if (!Number.isNaN(t)) ageSec = Math.floor((Date.now() - t) / 1000);
          }
          return {
            issue: c.issue,
            workerId: c.workerId,
            startedAt: c.startedAt,
            logFile: c.logFile,
            tail: "",
            stage: { stage: "starting", label: "starting", icon: "○" },
            reviewStats: null,
            tokens: null,
            lastWriteAt: null,
            ageSec,
            stuck: ageSec !== null && ageSec > 300,
            pid: c.pid,
          };
        }
        return { ...it, workerId: c.workerId ?? it.workerId, pid: c.pid };
      })
      .sort((a, b) => (a.workerId ?? 0) - (b.workerId ?? 0));
  }
  // Legacy fallback — only when state.json is genuinely absent. If the file
  // is present but yielded zero claims (parse failure with no prior cache),
  // don't fabricate a worker from a stale log file.
  if (!stateMissing) return [];
  if (!existsSync(LOGS_DIR)) return [];
  try {
    const files = readdirSync(LOGS_DIR)
      .filter((f) => ITER_LOG_REGEX.test(f))
      .map((f) => ({ name: f, mtime: statSync(join(LOGS_DIR, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime);
    if (!files.length) return [];
    const it = buildIteration(files[0].name);
    return it ? [it] : [];
  } catch {
    return [];
  }
}

// Back-compat alias for callers that only need the most recent iteration.
function getCurrentIteration() {
  const all = getCurrentIterations();
  return all[0] || null;
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
      .filter((f) => ITER_LOG_REGEX.test(f))
      .map((f) => {
        const m = f.match(ITER_LOG_REGEX);
        const [, date, time, workerId, issue] = m;
        const startedAt = new Date(
          `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${time.slice(0, 2)}:${time.slice(2, 4)}:${time.slice(4, 6)}`,
        );
        const stat = statSync(join(LOGS_DIR, f));
        return {
          issue: Number(issue),
          workerId: workerId ? Number(workerId) : null,
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
    "number,title,url,labels",
  ]);
  if (!Array.isArray(data)) return [];
  return data
    .map((i) => {
      const m = i.title.match(TITLE_NUM_RE);
      return {
        ...i,
        labels: (i.labels || []).map((label) => label.name).filter(Boolean),
        slice: m ? Number(m.groups?.x ?? m[1]) : 999,
      };
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

function getConfigSummary() {
  return {
    profile: RALPH_CONFIG.profile || "generic",
    issue: {
      titleRegex: TITLE_REGEX_SOURCE,
      titleNumRegex: titleNumRegex.source,
      issueSearch: ISSUE_SEARCH,
    },
    validation: {
      commands: RALPH_CONFIG.validation.commands
        .filter((cmd) => cmd && typeof cmd === "object")
        .map((cmd) => ({
          name: String(cmd.name || "Check"),
          command: String(cmd.command || ""),
        })),
    },
    warnings: CONFIG_WARNINGS,
    repoState: {
      state: REPO_STATE.state,
      repoRoot: REPO_STATE.repoRoot,
      hasRalph: REPO_STATE.hasRalph,
      source: REPO_STATE.source,
    },
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
  // One iteration object per active worker (parallel-safe). Each gets its
  // own PR lookup in parallel — keeps the dashboard reactive when a worker
  // count grows beyond 1.
  const currentIterations = getCurrentIterations();
  const workerPanels = await Promise.all(
    currentIterations.map(async (it) => ({
      ...it,
      cumulativeTokens: getWorkerCumulativeTokens(it.workerId),
      currentPr: it.issue ? await getCurrentPr(it.issue) : null,
    })),
  );
  return {
    timestamp: new Date().toISOString(),
    loopRunning: procs.some((p) => p.cmd.includes("ralph.sh")),
    processes: procs,
    workers: workerPanels,
    // Back-compat singletons — first worker is "current". Older content/
    // bundles still reading these continue to work.
    currentIteration: workerPanels[0] || null,
    currentPr: workerPanels[0]?.currentPr || null,
    cumulative: getCumulativeStats(prs),
    loopOutTail: getLoopOutTail(20),
    iterationHistory: { iterations, stats: history.stats },
    openSlices: slices,
    recentPrs: prs,
    config: getConfigSummary(),
  };
}

// Spawn .ralph/launch.sh detached so the loop survives this extension/session.
async function startLoop({ runOptions } = {}) {
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
    
    // Build environment with run options
    const env = {
      ...process.env,
      PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || ""}`,
    };
    if (runOptions?.parallelism) {
      env.RALPH_PARALLELISM = String(runOptions.parallelism);
    }
    if (runOptions?.model) {
      env.RALPH_MODEL = runOptions.model;
    }
    
    // Build args - add --once flag for one-pass mode
    const args = [launcher];
    if (runOptions?.runMode === "one-pass") {
      args.push("--once");
    }
    
    const child = spawn("bash", args, {
      cwd: REPO_ROOT,
      detached: true,
      stdio: ["ignore", out, out],
      env,
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

// Initialize Ralph in the resolved repository root.
async function initRalph() {
  if (REPO_STATE.state === "unresolved") {
    return { ok: false, error: "No repository root resolved. Cannot initialize." };
  }
  if (!REPO_STATE.repoRoot) {
    return { ok: false, error: "Repository root is null. Cannot initialize." };
  }
  if (REPO_STATE.hasRalph) {
    return { ok: false, error: ".ralph/ already exists. Initialization not needed." };
  }
  
  const result = initializeRalph(REPO_STATE.repoRoot);
  
  if (result.success) {
    return {
      ok: true,
      message: "Ralph initialized successfully.",
      created: result.created,
      skipped: result.skipped,
      repoRoot: REPO_STATE.repoRoot,
    };
  } else {
    return {
      ok: false,
      error: result.error || "Initialization failed.",
      created: result.created,
      skipped: result.skipped,
    };
  }
}

// Run preflight checks
async function runPreflight({ queue, runOptions }) {
  // Import the preflight module
  const { runPreflight: runPreflightChecks } = await import("./lib/preflight.mjs");
  
  const result = await runPreflightChecks({
    repoRoot: REPO_ROOT,
    queue,
    runOptions,
  });
  
  return result;
}

// Get user config with defaults
async function getUserConfig() {
  const { config } = loadUserConfig();
  return config;
}

// Retry a failed issue
async function retryIssue({ runId, issueNumber }) {
  return retryFailedIssue({ repoRoot: REPO_ROOT, runId, issueNumber });
}

// Skip a failed issue
async function skipIssue({ runId, issueNumber }) {
  return skipFailedIssue({ repoRoot: REPO_ROOT, runId, issueNumber });
}

// Remove a queued issue
async function removeIssue({ runId, issueNumber }) {
  return removeQueuedIssue({ repoRoot: REPO_ROOT, runId, issueNumber });
}

// Reorder a queued issue
async function reorderIssue({ runId, issueNumber, newIndex }) {
  return reorderQueuedIssue({ repoRoot: REPO_ROOT, runId, issueNumber, newIndex });
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
    initRalph,
    runPreflight,
    getUserConfig,
    retryIssue,
    skipIssue,
    removeIssue,
    reorderIssue,
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
