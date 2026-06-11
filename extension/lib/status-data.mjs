// status-data.mjs — pure data layer for Ralph status payloads.
//
// Factored out of main.mjs so it can be consumed by both the dashboard webview
// (extension/main.mjs) and the terminal CLI (extension/cli.mjs). This module
// MUST NOT import @github/copilot-sdk/extension or anything that joins a
// Copilot session at import time — cli.mjs runs outside Copilot sessions.

import { execFile } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import { detectTokens } from "./tokens.mjs";
import { parsePrdReference, extractRepo, buildHeaderText, fetchPrdTitle } from "./header.mjs";
import { filterScopedRalphProcesses } from "./process-scope.mjs";
import { isAlive, readPidFile } from "./platform-shim.mjs";
import { classifyIssue, orderIssuesForQueue } from "./label-taxonomy.mjs";

const execFileAsync = promisify(execFile);
const IS_WINDOWS = process.platform === "win32";

// Iteration log filenames may include an optional worker-id segment:
//   iter-{YYYYMMDD}-{HHMMSS}-w{id}-issue-{N}.log   (parallel workers)
//   iter-{YYYYMMDD}-{HHMMSS}-issue-{N}.log         (legacy single worker)
export const ITER_LOG_REGEX = /^iter-(\d{8})-(\d{6})(?:-w(\d+))?-issue-(\d+)\.log$/;

export const DEFAULT_CONFIG = {
  profile: "generic",
  issue: {
    titleRegex: "^Slice [0-9]+:",
    titleNumRegex: "^Slice ([0-9]+):",
    issueSearch: "is:open no:assignee label:ralph:ready (label:work:slice OR label:work:standalone)",
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

export function readRalphConfig(configFile) {
  const warnings = [];
  let userConfig = {};
  if (existsSync(configFile)) {
    try {
      userConfig = JSON.parse(readFileSync(configFile, "utf8"));
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

export function compileRegex(source, fallback, warnings, label, flags = "") {
  const chosen = source || fallback;
  try {
    return { source: chosen, regex: new RegExp(chosen, flags) };
  } catch {
    warnings.push(`Invalid ${label} regex "${chosen}"; using "${fallback}".`);
    return { source: fallback, regex: new RegExp(fallback, flags) };
  }
}

export function compileStages(config, warnings) {
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

// Walks backwards through a log body, returning the latest matching stage
// (most-recent activity wins). Mirrors the dashboard's detectStage.
export function detectStage(logBody, stageMatchers) {
  if (!logBody) return { stage: "starting", label: "starting", icon: "○" };
  const lines = logBody.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i];
    for (const stage of stageMatchers) {
      if (stage.regexes.some((re) => re.test(l))) {
        return { stage: stage.stage, label: stage.label, icon: stage.icon };
      }
    }
  }
  return { stage: "working", label: "working", icon: "⚙" };
}

export function detectReviewStats(logBody) {
  if (!logBody) return null;
  const gpt = (logBody.match(/Code-review\(gpt-5\.5\)/gi) || []).length;
  const opus = (logBody.match(/Code-review\(claude-opus-4\.7\)/gi) || []).length;
  if (gpt === 0 && opus === 0) return null;
  return { gpt, opus, total: gpt + opus };
}

// Resolve the "active run" inside .ralph/runs/. Prefers (in order):
//   1. A run whose status.json items overlap with the issues currently
//      claimed in state.json — state.json is canonical for live workers,
//      so if a worker is actively running an issue and that issue appears
//      in run X's status.json, run X is the active one even if its
//      status items have all been marked terminal (lifecycle lag).
//   2. A run whose status.json contains any non-terminal item
//      (running/claimed/queued).
//   3. Newest mtime as final tiebreak.
// Returns { runId, runDir, statusFile, statusData, isActive } or null.
export function resolveActiveRun(repoRoot, opts = {}) {
  const runsDir = join(repoRoot, ".ralph", "runs");
  if (!existsSync(runsDir)) return null;

  // Caller may pass currently-claimed issue numbers (typically derived from
  // state.json) so we can prefer the run that owns those live claims.
  const liveIssues = new Set((opts.liveIssues || []).map(Number));

  let entries;
  try {
    entries = readdirSync(runsDir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => {
        const runDir = join(runsDir, e.name);
        const statusFile = join(runDir, "status.json");
        let mtime = 0;
        try { mtime = statSync(runDir).mtimeMs; } catch {}
        let statusData = null;
        try {
          if (existsSync(statusFile)) {
            statusData = JSON.parse(readFileSync(statusFile, "utf8"));
            const stat = statSync(statusFile);
            mtime = Math.max(mtime, stat.mtimeMs);
          }
        } catch {}
        const items = statusData?.items || {};
        let hasNonTerminal = false;
        let containsLiveClaim = false;
        for (const [issueKey, v] of Object.entries(items)) {
          if (v && (v.status === "running" || v.status === "claimed" || v.status === "queued")) {
            hasNonTerminal = true;
          }
          if (liveIssues.has(Number(issueKey))) {
            containsLiveClaim = true;
          }
        }
        return { runId: e.name, runDir, statusFile, mtime, hasNonTerminal, containsLiveClaim, statusData };
      });
  } catch {
    return null;
  }
  if (entries.length === 0) return null;

  entries.sort((a, b) => {
    if (a.containsLiveClaim !== b.containsLiveClaim) return a.containsLiveClaim ? -1 : 1;
    if (a.hasNonTerminal !== b.hasNonTerminal) return a.hasNonTerminal ? -1 : 1;
    return b.mtime - a.mtime;
  });
  const chosen = entries[0];
  return {
    runId: chosen.runId,
    runDir: chosen.runDir,
    statusFile: chosen.statusFile,
    statusData: chosen.statusData,
    isActive: chosen.containsLiveClaim || chosen.hasNonTerminal,
  };
}

export function createStatusReader({ repoRoot, env = process.env, ghBin = "gh" } = {}) {
  const LOGS_DIR = join(repoRoot, ".ralph", "logs");
  const STATE_FILE = join(repoRoot, ".ralph", "state.json");
  const CONFIG_FILE = join(repoRoot, ".ralph", "config.json");
  const LOOP_LOG = join(repoRoot, ".ralph", "loop.out");
  const LAUNCHER_PID_FILE = join(repoRoot, ".ralph", "launcher.pid");

  const { config: ralphConfig, warnings: configWarnings } = readRalphConfig(CONFIG_FILE);

  const titleRegex = compileRegex(
    env.RALPH_TITLE_REGEX || ralphConfig.issue.titleRegex,
    DEFAULT_CONFIG.issue.titleRegex,
    configWarnings,
    "issue.titleRegex",
  );
  const titleNumRegex = compileRegex(
    env.RALPH_TITLE_NUM_REGEX || ralphConfig.issue.titleNumRegex,
    DEFAULT_CONFIG.issue.titleNumRegex,
    configWarnings,
    "issue.titleNumRegex",
  );
  const ISSUE_SEARCH =
    env.RALPH_ISSUE_SEARCH || ralphConfig.issue.issueSearch || DEFAULT_CONFIG.issue.issueSearch;
  const stageMatchers = compileStages(ralphConfig, configWarnings);

  const tokenCache = new Map();
  let lastClaims = null;
  let stateFilePresent = false;

  function tokensForLogFile(name) {
    const fullPath = join(LOGS_DIR, name);
    let mtimeMs;
    try { mtimeMs = statSync(fullPath).mtimeMs; } catch { return null; }
    const cached = tokenCache.get(name);
    if (cached && cached.mtimeMs === mtimeMs) return cached.tokens;
    let body;
    try { body = readFileSync(fullPath, "utf8"); } catch { return null; }
    const tokens = detectTokens(body);
    tokenCache.set(name, { mtimeMs, tokens });
    return tokens;
  }

  function getWorkerCumulativeTokens(workerId) {
    if (workerId == null || !existsSync(LOGS_DIR)) return null;
    const total = { input: 0, output: 0, cached: 0, reasoning: 0, iterations: 0 };
    let any = false;
    let files;
    try { files = readdirSync(LOGS_DIR); } catch { return null; }
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

  function readClaims() {
    if (!existsSync(STATE_FILE)) {
      stateFilePresent = false;
      lastClaims = null;
      return { claims: [], stateMissing: true };
    }
    stateFilePresent = true;
    try {
      const raw = readFileSync(STATE_FILE, "utf8");
      const parsed = JSON.parse(raw);
      const claimsObj = parsed?.claims || {};
      const claims = Object.entries(claimsObj).map(([issue, c]) => ({
        issue: Number(issue),
        workerId: Number.isFinite(Number(c?.workerId)) ? Number(c.workerId) : null,
        pid: Number.isFinite(Number(c?.pid)) ? Number(c.pid) : null,
        startedAt: typeof c?.startedAt === "string" ? c.startedAt : null,
        logFile: typeof c?.logFile === "string" ? c.logFile : null,
      }));
      lastClaims = claims;
      return { claims, stateMissing: false };
    } catch {
      return { claims: lastClaims || [], stateMissing: false };
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
      stage: detectStage(fullBody, stageMatchers),
      reviewStats: detectReviewStats(fullBody),
      tokens: detectTokens(fullBody),
      lastWriteAt: lastWriteMs ? new Date(lastWriteMs).toISOString() : null,
      ageSec,
      stuck: ageSec !== null && ageSec > 300,
    };
  }

  function getCurrentIterations() {
    const { claims, stateMissing } = readClaims();
    if (claims.length > 0) {
      return claims
        .map((c) => {
          const it = buildIteration(c.logFile);
          if (!it) {
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
              pidAlive: c.pid ? isAlive(c.pid) : null,
            };
          }
          return {
            ...it,
            workerId: c.workerId ?? it.workerId,
            pid: c.pid,
            pidAlive: c.pid ? isAlive(c.pid) : null,
          };
        })
        .sort((a, b) => (a.workerId ?? 0) - (b.workerId ?? 0));
    }
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

  function getCurrentIteration() {
    return getCurrentIterations()[0] || null;
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

  async function getLoopProcess() {
    if (IS_WINDOWS) {
      const pid = readPidFile(LAUNCHER_PID_FILE);
      if (pid && isAlive(pid)) {
        return [{ pid, cmd: "ralph launcher (windows)" }];
      }
      return [];
    }
    try {
      const { stdout } = await execFileAsync("ps", ["-axww", "-o", "pid=,ppid=,command="], {
        timeout: 3000,
      });
      return filterScopedRalphProcesses(stdout, repoRoot);
    } catch {
      return [];
    }
  }

  async function ghJson(args) {
    try {
      const envForGh = { ...env };
      if (!IS_WINDOWS) {
        envForGh.PATH = `/opt/homebrew/bin:/usr/local/bin:${env.PATH || ""}`;
      }
      const { stdout } = await execFileAsync(ghBin, args, {
        cwd: repoRoot,
        timeout: 10000,
        env: envForGh,
      });
      return JSON.parse(stdout);
    } catch (err) {
      return { error: String(err.message || err) };
    }
  }

  async function getOpenSlices() {
    const data = await ghJson([
      "issue", "list", "--state", "open", "--limit", "30",
      "--search", ISSUE_SEARCH,
      "--json", "number,title,body,state,url,labels,assignees",
    ]);
    if (!Array.isArray(data)) return [];
    const issues = data
      .map((i) => {
        const m = i.title.match(titleNumRegex.regex);
        const labels = (i.labels || []).map((label) => label.name).filter(Boolean);
        const taxonomy = classifyIssue({ ...i, labels });
        return {
          ...i,
          labels,
          taxonomy: {
            state: taxonomy.state,
            priority: taxonomy.priority,
            workType: taxonomy.workType,
            parentNumber: taxonomy.parentNumber,
            blockers: taxonomy.blockers,
            conflicts: taxonomy.conflicts,
            warnings: taxonomy.warnings,
            runnable: taxonomy.runnable,
            eligibleForQueue: taxonomy.runnable,
          },
          slice: m ? Number(m.groups?.x ?? m[1]) : 999,
        };
      })
      .filter((i) => titleRegex.regex.test(i.title));
    return orderIssuesForQueue(issues);
  }

  async function getRecentPrs() {
    const data = await ghJson([
      "pr", "list", "--state", "all", "--limit", "10",
      "--json", "number,title,state,mergedAt,url,additions,deletions,changedFiles",
    ]);
    if (!Array.isArray(data)) return [];
    return data;
  }

  async function getCurrentPr(issueNumber) {
    if (!issueNumber) return null;
    const list = await ghJson([
      "pr", "list", "--state", "open",
      "--search", `linked:issue ${issueNumber}`,
      "--json", "number,title,url,isDraft,headRefName",
      "--limit", "5",
    ]);
    let pr = Array.isArray(list) && list.length ? list[0] : null;
    if (!pr) {
      const issueData = await ghJson([
        "issue", "view", String(issueNumber),
        "--json", "closedByPullRequestsReferences",
      ]);
      const ref = issueData?.closedByPullRequestsReferences?.find?.((p) => p.state === "OPEN");
      if (ref)
        pr = { number: ref.number, title: ref.title, url: ref.url, isDraft: false, headRefName: "" };
    }
    if (!pr) return null;
    const detail = await ghJson([
      "pr", "view", String(pr.number),
      "--json", "number,title,url,isDraft,state,statusCheckRollup,reviewDecision,additions,deletions,changedFiles,commits",
    ]);
    if (detail?.error) return { ...pr, error: detail.error };
    const checks = detail.statusCheckRollup || [];
    const summary = { total: checks.length, pass: 0, fail: 0, pending: 0 };
    for (const c of checks) {
      const concl = (c.conclusion || c.status || "").toUpperCase();
      if (["SUCCESS", "NEUTRAL", "SKIPPED"].includes(concl)) summary.pass++;
      else if (["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"].includes(concl)) summary.fail++;
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

  function getConfigSummary(repoState) {
    return {
      profile: ralphConfig.profile || "generic",
      repo: extractRepo(ISSUE_SEARCH),
      prdReference: parsePrdReference(repoRoot),
      issue: {
        titleRegex: titleRegex.source,
        titleNumRegex: titleNumRegex.source,
        issueSearch: ISSUE_SEARCH,
      },
      taxonomy: {
        defaultState: "ralph:ready",
        runnableWorkTypes: ["work:slice", "work:standalone"],
        defaultPriority: "priority:P2",
      },
      validation: {
        commands: ralphConfig.validation.commands
          .filter((cmd) => cmd && typeof cmd === "object")
          .map((cmd) => ({
            name: String(cmd.name || "Check"),
            command: String(cmd.command || ""),
          })),
      },
      warnings: configWarnings,
      repoState: repoState || null,
    };
  }

  // Build a local-only payload: no gh calls, no PR enrichment. Used by
  // `cli.mjs watch` to keep refresh fast and free.
  function buildLocalPayload() {
    const iterations = getCurrentIterations();
    const workerPanels = iterations.map((it) => ({
      ...it,
      cumulativeTokens: getWorkerCumulativeTokens(it.workerId),
    }));
    // Pass live issue numbers from state.json claims so resolveActiveRun
    // can prefer the run that owns the currently-running work.
    const liveIssues = iterations.map((it) => it.issue).filter((n) => Number.isFinite(n));
    const activeRun = resolveActiveRun(repoRoot, { liveIssues });
    return {
      timestamp: new Date().toISOString(),
      repoRoot,
      workers: workerPanels,
      currentIteration: workerPanels[0] || null,
      loopOutTail: getLoopOutTail(15),
      activeRun,
      iterationHistory: getIterationHistory(10),
      configWarnings,
    };
  }

  // Build the full payload (matches the dashboard's getStatus shape). Pass
  // `withPrs: false` to skip the gh-backed enrichment (used when a caller
  // wants a fast snapshot but still needs the loop process list).
  async function buildStatusPayload({ withPrs = true, repoState } = {}) {
    const procs = await getLoopProcess();
    const local = buildLocalPayload();

    let slices = [];
    let prs = [];
    if (withPrs) {
      [slices, prs] = await Promise.all([getOpenSlices(), getRecentPrs()]);
    }

    const openIssueNums = new Set(slices.map((s) => s.number));
    const mergedByIssue = new Map();
    for (const pr of prs) {
      const m = pr.title.match(/\(#(\d+)\)\s*$/) || pr.title.match(/issue[\s#-]*(\d+)/i);
      if (m && pr.state === "MERGED") mergedByIssue.set(Number(m[1]), pr);
    }
    const iterations = local.iterationHistory.iterations.map((it) => {
      let status = "unknown";
      if (mergedByIssue.has(it.issue)) status = "merged";
      else if (openIssueNums.has(it.issue)) status = "open";
      else status = "closed";
      return { ...it, status, prUrl: mergedByIssue.get(it.issue)?.url || null };
    });

    let workerPanels = local.workers;
    if (withPrs) {
      workerPanels = await Promise.all(
        local.workers.map(async (w) => ({
          ...w,
          currentPr: w.issue ? await getCurrentPr(w.issue) : null,
        })),
      );
    }

    const config = getConfigSummary(repoState);
    const prdTitle = withPrs
      ? await fetchPrdTitle(config.repo, config.prdReference, { ghJsonFn: ghJson })
      : null;
    const headerText = buildHeaderText({
      repo: config.repo,
      prdReference: config.prdReference,
      prdTitle,
    });

    return {
      timestamp: new Date().toISOString(),
      // On POSIX, loopRunning is true when any scoped ralph.sh process is
      // visible to `ps`. On Windows we don't have a usable `ps` contract,
      // so we trust the pidfile entry getLoopProcess() returns. This makes
      // the Windows dashboard's loopRunning flag agree with startLoop()'s
      // "alreadyRunning" check, which already uses procs.length > 0 on
      // Windows — fixes a latent bug where the dashboard showed "idle"
      // even while a Windows loop was running.
      loopRunning: procs.some((p) => p.cmd.includes("ralph.sh")) || (IS_WINDOWS && procs.length > 0),
      processes: procs,
      workers: workerPanels,
      currentIteration: workerPanels[0] || null,
      currentPr: workerPanels[0]?.currentPr || null,
      cumulative: getCumulativeStats(prs),
      loopOutTail: local.loopOutTail,
      iterationHistory: { iterations, stats: local.iterationHistory.stats },
      openSlices: slices,
      recentPrs: prs,
      config,
      prdTitle,
      headerText,
      activeRun: local.activeRun,
    };
  }

  return {
    // Paths + config (handy for callers that need them)
    repoRoot,
    paths: { LOGS_DIR, STATE_FILE, CONFIG_FILE, LOOP_LOG, LAUNCHER_PID_FILE },
    config: ralphConfig,
    configWarnings,
    stageMatchers,
    titleRegex,
    titleNumRegex,
    ISSUE_SEARCH,
    // Functions
    readClaims,
    buildIteration,
    getCurrentIterations,
    getCurrentIteration,
    getLoopOutTail,
    getIterationHistory,
    getWorkerCumulativeTokens,
    tokensForLogFile,
    getLoopProcess,
    ghJson,
    getOpenSlices,
    getRecentPrs,
    getCurrentPr,
    getCumulativeStats,
    getConfigSummary,
    resolveActiveRun: (opts) => resolveActiveRun(repoRoot, opts),
    buildLocalPayload,
    buildStatusPayload,
  };
}
