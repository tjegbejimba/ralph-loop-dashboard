#!/usr/bin/env node
// cli.mjs — terminal entry for Ralph status.
//
// Subcommands:
//   status [--with-prs] [--no-color]     One-shot snapshot. Default omits gh
//                                        calls for speed; --with-prs adds the
//                                        recent-PRs section.
//   watch [--interval SEC] [--no-color]  Live local-only refresh (no gh).
//                                        Ctrl-C to exit. Default 2s.
//   follow [--worker N]                  Tail the active worker's iteration
//                                        log; re-tails on iter rollover.
//   triage [--dry-run|--live]            Comment-only advisory issue triage.
//   help | --help                        Print usage.
//
// Repo resolution: $RALPH_REPO_ROOT → walk up from cwd looking for .ralph/.
// We don't import extension/lib/repo-resolver.mjs here so the CLI keeps
// working in repos that don't yet have a full .ralph install. The triage
// subcommand is repo-allowlist based and does not require .ralph/.

import { existsSync, statSync, readFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { join, resolve, dirname } from "node:path";
import { createStatusReader } from "./lib/status-data.mjs";
import { renderStatus, renderLocalStatus, shouldUseColor } from "./lib/terminal-render.mjs";
import { DEFAULT_TRIAGE_CONFIG, runIssueTriage } from "./lib/issue-triage.mjs";
import { loadUserConfig } from "./lib/user-config.mjs";
import { runOrchestrateRepo, renderPlan, renderSummary } from "./lib/orchestrate-repo.mjs";

function findRepoRoot(start) {
  if (process.env.RALPH_REPO_ROOT) return process.env.RALPH_REPO_ROOT;
  let dir = resolve(start || process.cwd());
  while (true) {
    if (existsSync(join(dir, ".ralph"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

function parseFlags(args) {
  const flags = {
    color: undefined,
    withPrs: false,
    interval: 2,
    worker: null,
    help: false,
    json: false,
    triageMode: "dry-run",
    triageQuery: null,
    triageTaxonomyMode: "legacy",
    triageBotLogin: null,
    triageRepos: [],
    // orchestrate-repo flags
    dryRun: false,
    repoRoot: null,
    maxIssues: null,
    parallelism: null,
    runMode: null,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--help" || a === "-h") flags.help = true;
    else if (a === "--no-color") flags.color = false;
    else if (a === "--color") flags.color = true;
    else if (a === "--with-prs") flags.withPrs = true;
    else if (a === "--json") flags.json = true;
    else if (a === "--dry-run") { flags.triageMode = "dry-run"; flags.dryRun = true; }
    else if (a === "--live") flags.triageMode = "live";
    else if (a === "--canonical-labels") flags.triageTaxonomyMode = "canonical";
    else if (a === "--query") flags.triageQuery = args[++i] || null;
    else if (a === "--bot-login") flags.triageBotLogin = args[++i] || null;
    else if (a === "--repo") flags.triageRepos.push(args[++i]);
    else if (a === "--repo-root") flags.repoRoot = args[++i] || null;
    else if (a === "--run-mode") flags.runMode = args[++i] || null;
    else if (a === "--max-issues") {
      const n = Number(args[++i]);
      if (Number.isInteger(n) && n > 0) flags.maxIssues = n;
      else flags.maxIssues = NaN;
    } else if (a === "--parallelism") {
      const n = Number(args[++i]);
      if (Number.isInteger(n) && n > 0) flags.parallelism = n;
      else flags.parallelism = NaN;
    } else if (a === "--interval") {
      const n = Number(args[++i]);
      if (Number.isFinite(n) && n > 0) flags.interval = n;
    } else if (a === "--worker") {
      const n = Number(args[++i]);
      if (Number.isFinite(n)) flags.worker = n;
    } else if (/^\d+(\.\d+)?$/.test(a) && flags._numericPos == null) {
      // Positional numeric arg — used by `watch <SEC>` and `follow <N>`.
      // Only accepts non-negative; negative values fall through and are
      // surfaced as unknown args by the subcommand.
      flags._numericPos = Number(a);
    }
  }
  return flags;
}

function printUsage() {
  process.stdout.write(`Usage:
  node cli.mjs status [--with-prs] [--no-color]
  node cli.mjs watch [SEC|--interval SEC] [--no-color]
  node cli.mjs follow [N|--worker N]
  node cli.mjs triage [--dry-run|--live] [--canonical-labels] [--repo OWNER/NAME] [--query QUERY] [--json]
  node cli.mjs orchestrate-repo [--repo-root PATH] [--dry-run] [--json] [--max-issues N] [--parallelism N] [--run-mode MODE]
  node cli.mjs help

Reads .ralph/ from cwd (or RALPH_REPO_ROOT). Shows current workers, queue
progress, and loop.out tail. Designed for terminal users who can't load the
Ralph dashboard extension.

triage runs comment-only advisory issue triage. It defaults to dry-run
calibration and prints exact comments without posting. Live mode only
posts/updates the bot-owned triage comment; no labels, closure, or Ralph
enqueue happens automatically.

orchestrate-repo runs the ralph-orchestrator repo-maintain sweep from a repo's
MAIN checkout (where the local-only .ralph/ lives) for a local scheduler. It
discovers ready work read-only and launches a bounded run only through the
gated orchestrateRun path (allowAgentLaunch + preflight). Use --dry-run first.
`);
}

function printTriageUsage() {
  process.stdout.write(`Usage:
  node cli.mjs triage [--dry-run|--live] [--canonical-labels] [--repo OWNER/NAME] [--query QUERY] [--json]

Runs comment-only advisory issue triage for configured repositories.
Default repo: tjegbejimba/ralph-loop-dashboard
Default query: label:needs-triage

--dry-run           Print exact comments; do not post anything. Default.
--live              Post/update only the bot-owned triage comment.
--canonical-labels  Use label:ralph:needs-triage instead of the legacy query.
--repo OWNER/NAME   Triage this repo instead of the default. Repeatable to
                    triage several repos in one run.
--query QUERY       Override the triage issue search query.
--bot-login LOGIN   Override detected gh login for bot-owned comment matching.
--json              Emit the structured run summary.

No labels, closure, or Ralph enqueue happens automatically.
`);
}

async function cmdStatus(reader, flags) {
  const payload = await reader.buildStatusPayload({ withPrs: flags.withPrs });
  process.stdout.write(renderStatus(payload, { color: flags.color, withPrs: flags.withPrs }) + "\n");
}

async function cmdWatch(reader, flags) {
  const interval = flags._numericPos || flags.interval;
  if (!(Number.isFinite(interval) && interval > 0)) {
    process.stderr.write(`Invalid --watch interval: ${interval}. Must be > 0.\n`);
    process.exit(2);
  }
  const useColor = shouldUseColor(process.env, { color: flags.color });
  const canClear = useColor && process.stdout.isTTY && process.env.TERM !== "dumb";

  let stopping = false;
  const onSig = () => {
    stopping = true;
    process.stdout.write("\n");
    process.exit(0);
  };
  process.on("SIGINT", onSig);
  process.on("SIGTERM", onSig);

  while (!stopping) {
    const payload = reader.buildLocalPayload();
    if (canClear) process.stdout.write("\x1b[2J\x1b[H");
    process.stdout.write(renderLocalStatus(payload, { color: flags.color }) + "\n");
    if (!canClear) process.stdout.write("\n" + "─".repeat(60) + "\n");
    await new Promise((r) => setTimeout(r, interval * 1000));
  }
}

function pickWorkerLog(reader, workerArg) {
  const iters = reader.getCurrentIterations();
  if (iters.length === 0) return { error: "No active workers — nothing to follow." };
  const target = workerArg != null
    ? iters.find((i) => i.workerId === workerArg)
    : iters[0];
  if (!target) return { error: `No active worker with id ${workerArg}.` };
  if (!target.logFile) return { error: `Worker w${target.workerId ?? "?"} has no log file yet.` };
  return { workerId: target.workerId, logFile: target.logFile, issue: target.issue };
}

async function cmdFollow(reader, flags) {
  const workerArg = flags.worker ?? flags._numericPos ?? null;
  let current = pickWorkerLog(reader, workerArg);
  if (current.error) {
    process.stderr.write(`${current.error}\n`);
    process.exit(2);
  }
  // Once we've followed a worker, we don't exit when its claim briefly
  // disappears — that's the normal between-slices gap. The followed worker
  // (or the lowest-numbered active worker, when --worker isn't pinned) will
  // come back. Track the pinned workerId so we can re-acquire it after the
  // gap.
  const pinnedWorkerId = workerArg ?? current.workerId;

  let child = null;
  let stopping = false;
  let waiting = false;
  const startTail = (logFile, issue, workerId) => {
    const logPath = join(reader.paths.LOGS_DIR, logFile);
    process.stdout.write(`── following w${workerId} #${issue} · ${logFile} ──\n`);
    const args = ["-F", logPath];
    child = spawn("tail", args, { stdio: ["ignore", "inherit", "inherit"] });
    child.on("error", (err) => {
      process.stderr.write(`tail error: ${err.message}\n`);
      stopping = true;
    });
  };

  const stopTail = () => {
    if (child && !child.killed) {
      try { child.kill("SIGTERM"); } catch {}
    }
    child = null;
  };

  const onSig = () => {
    stopping = true;
    stopTail();
    process.exit(0);
  };
  process.on("SIGINT", onSig);
  process.on("SIGTERM", onSig);

  startTail(current.logFile, current.issue, current.workerId);

  // Poll state.json every 2s. Behaviour:
  //   - logFile changed → print separator + re-tail (slice rollover).
  //   - pinned worker disappeared → enter "waiting" mode; keep polling.
  //   - pinned worker reappears with a new logFile → re-tail.
  // The user must Ctrl-C to exit; follow never gives up on its own.
  while (!stopping) {
    await new Promise((r) => setTimeout(r, 2000));
    const next = pickWorkerLog(reader, pinnedWorkerId);
    if (next.error) {
      if (!waiting) {
        stopTail();
        process.stdout.write(`\n── worker w${pinnedWorkerId} idle; waiting for next claim (Ctrl-C to exit) ──\n`);
        waiting = true;
      }
      continue;
    }
    if (waiting || next.logFile !== current.logFile) {
      stopTail();
      if (waiting) {
        process.stdout.write(`\n── worker w${next.workerId} resumed: #${next.issue} ──\n`);
      } else {
        process.stdout.write(`\n── worker rolled to new iteration: #${next.issue} ──\n`);
      }
      waiting = false;
      current = next;
      startTail(current.logFile, current.issue, current.workerId);
    }
  }
}

function parseRepoSpec(value) {
  const trimmed = typeof value === "string" ? value.trim() : "";
  const segment = "[A-Za-z0-9._][A-Za-z0-9._-]*";
  const match = new RegExp(`^(${segment})\\/(${segment})$`).exec(trimmed);
  if (!match) {
    throw new Error(`Invalid --repo value: ${JSON.stringify(value)}. Expected owner/name.`);
  }
  return { owner: match[1], name: match[2] };
}

function triageReposFromFlags(flags) {
  const repoOverrides = {
    taxonomyMode: flags.triageTaxonomyMode,
  };
  if (flags.triageQuery) repoOverrides.query = flags.triageQuery;
  const baseRepos = flags.triageRepos.length > 0
    ? flags.triageRepos.map(parseRepoSpec)
    : DEFAULT_TRIAGE_CONFIG.repos;
  return baseRepos.map((repo) => ({ ...repo, ...repoOverrides }));
}

function currentGithubLogin() {
  const result = spawnSync("gh", ["api", "user", "--jq", ".login"], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr || "gh api user failed");
  }
  const login = result.stdout.trim();
  if (!login) throw new Error("Could not determine authenticated gh login");
  return login;
}

function renderTriageRun(result) {
  const lines = [`Ralph issue triage (${result.mode})`];
  for (const repoResult of result.repos) {
    lines.push("", `${repoResult.repo} — ${repoResult.query}`);
    for (const item of repoResult.processed) {
      lines.push("", `#${item.issueNumber} ${item.action}: ${item.recommendation}`);
      if (item.commentBody) lines.push(item.commentBody);
    }
    for (const item of repoResult.skipped) {
      lines.push(`#${item.issueNumber} skipped: ${item.reason}`);
    }
    for (const error of repoResult.errors) {
      const prefix = error.issueNumber ? `#${error.issueNumber}` : repoResult.repo;
      lines.push(`${prefix} error: ${error.message}`);
    }
  }
  return lines.join("\n");
}

async function cmdTriage(flags) {
  if (flags.help) {
    printTriageUsage();
    return;
  }
  let repos;
  try {
    repos = triageReposFromFlags(flags);
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exitCode = 2;
    return;
  }
  const result = await runIssueTriage({
    mode: flags.triageMode,
    config: {
      repos,
      botLogin: flags.triageBotLogin || currentGithubLogin(),
    },
  });
  if (flags.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`${renderTriageRun(result)}\n`);
  }
  if (result.repos.length > 0 && result.repos.every((repo) => repo.errors.length > 0 && repo.processed.length === 0)) {
    process.exitCode = 1;
  }
}

function printOrchestrateRepoUsage() {
  process.stdout.write(`Usage:
  node cli.mjs orchestrate-repo [--repo-root PATH] [--dry-run] [--json] [--max-issues N] [--parallelism N] [--run-mode MODE]

Runs the ralph-orchestrator repo-maintain sweep from a repo's MAIN checkout
(where the gitignored, local-only .ralph/ lives) for a local scheduler
(launchd/cron). Copilot scheduled workflows run in throwaway worktrees that
never contain .ralph/, so repo-maintain cannot run there — this is the headless
equivalent.

It resolves the repo, reads issue.issueSearch from .ralph/config.json verbatim,
defers when a run is already active, skips repos missing canonical ralph:*
labels, discovers ready work READ-ONLY, builds a bounded queue, and launches
ONLY through the gated orchestrateRun path (allowAgentLaunch + preflight). It
never calls launch.sh --start and never mutates GitHub during discovery.

--repo-root PATH   Repo MAIN checkout to operate on (default: cwd). Must contain
                   .ralph/config.json and .ralph/RALPH.md.
--dry-run          Read-only: print the plan + would-be ledger; no launch, no
                   ledger write, no mutations.
--json             Emit the structured run summary.
--max-issues N     Cap issues per run (default 3).
--parallelism N    Workers (default 1).
--run-mode MODE    one-pass | until-empty (default until-empty).

Launch is gated by allowAgentLaunch: true in ~/.ralph-dashboard/config.json
(default false) plus a passing preflight. On a hard stop it prints an owner
brief and exits non-zero.
`);
}

async function cmdOrchestrateRepo(flags) {
  if (flags.help) {
    printOrchestrateRepoUsage();
    return;
  }
  if (Number.isNaN(flags.maxIssues)) {
    process.stderr.write("Invalid --max-issues: must be a positive integer.\n");
    process.exitCode = 2;
    return;
  }
  if (Number.isNaN(flags.parallelism)) {
    process.stderr.write("Invalid --parallelism: must be a positive integer.\n");
    process.exitCode = 2;
    return;
  }
  if (flags.runMode != null && flags.runMode !== "one-pass" && flags.runMode !== "until-empty") {
    process.stderr.write(`Invalid --run-mode: ${JSON.stringify(flags.runMode)}. Expected one-pass or until-empty.\n`);
    process.exitCode = 2;
    return;
  }

  const repoRoot = flags.repoRoot ? resolve(flags.repoRoot) : process.cwd();
  const { config: userConfig } = loadUserConfig();

  const overrides = {};
  if (flags.maxIssues != null) overrides.maxIssues = flags.maxIssues;
  if (flags.parallelism != null) overrides.parallelism = flags.parallelism;
  if (flags.runMode != null) overrides.runMode = flags.runMode;

  let result;
  try {
    result = await runOrchestrateRepo({
      repoRoot,
      dryRun: flags.dryRun,
      userConfig,
      getLoopProcessForRepo: (targetRoot) =>
        createStatusReader({ repoRoot: targetRoot, env: process.env }).getLoopProcess,
      ...overrides,
    });
  } catch (err) {
    process.stderr.write(`orchestrate-repo error: ${String(err.message || err)}\n`);
    process.exitCode = 1;
    return;
  }

  if (flags.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else if (result.dryRun) {
    process.stdout.write(`${renderPlan(result)}\n`);
  } else {
    process.stdout.write(`${renderSummary(result)}\n`);
  }

  if (Number.isInteger(result.exitCode) && result.exitCode !== 0) {
    process.exitCode = result.exitCode;
  }
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd || cmd === "help" || cmd === "--help" || cmd === "-h") {
    printUsage();
    process.exit(0);
  }
  const flags = parseFlags(rest);
  if (cmd === "triage") {
    await cmdTriage(flags);
    return;
  }
  if (cmd === "orchestrate-repo") {
    await cmdOrchestrateRepo(flags);
    return;
  }
  const repoRoot = findRepoRoot();
  if (!repoRoot) {
    process.stderr.write(
      "Could not find .ralph/ in cwd or any parent. " +
      "Set RALPH_REPO_ROOT or cd into a Ralph-enabled repo.\n",
    );
    process.exit(2);
  }
  const reader = createStatusReader({ repoRoot, env: process.env });

  switch (cmd) {
    case "status": return cmdStatus(reader, flags);
    case "watch": return cmdWatch(reader, flags);
    case "follow": return cmdFollow(reader, flags);
    default:
      process.stderr.write(`Unknown command: ${cmd}\n\n`);
      printUsage();
      process.exit(2);
  }
}

main().catch((err) => {
  process.stderr.write(`cli error: ${err.stack || err.message || err}\n`);
  process.exit(1);
});
