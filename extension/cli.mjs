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
//   promote-lanes [--dry-run|--live]     Apply lane routing decisions as guarded
//                                        state transitions.
//   promote-ready [--dry-run|--live]     Promote ralph:fast-lane issues to
//                                        ralph:ready (one-tap gate).
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
import { runPromoteLanes, runPromoteReady } from "./lib/lane-promotion.mjs";
import { loadUserConfig } from "./lib/user-config.mjs";
import { runOrchestrateRepo, renderPlan, renderSummary, resolveRepoSlug } from "./lib/orchestrate-repo.mjs";
import { resolveOrchestrateRepoRoot } from "./lib/loop-launch-controller.mjs";
import { runCloseCompletedPrds, renderCloseCompletedPrds } from "./lib/close-completed-prds.mjs";
import { runGithubPreflight } from "./lib/github-preflight.mjs";

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
    triageTaxonomyMode: "canonical",
    triageBotLogin: null,
    triageRepos: [],
    promoteLanesMode: "dry-run",
    promoteLanesQuery: null,
    promoteLanesRepos: [],
    promoteReadyMode: "dry-run",
    promoteReadyIssue: null,
    promoteReadyRepo: null,
    // orchestrate-repo flags
    dryRun: false,
    repoRoot: null,
    maxIssues: null,
    parallelism: null,
    runMode: null,
    closeCompletedPrds: false,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--help" || a === "-h") flags.help = true;
    else if (a === "--no-color") flags.color = false;
    else if (a === "--color") flags.color = true;
    else if (a === "--with-prs") flags.withPrs = true;
    else if (a === "--json") flags.json = true;
    else if (a === "--dry-run") {
      flags.triageMode = "dry-run";
      flags.promoteLanesMode = "dry-run";
      flags.promoteReadyMode = "dry-run";
      flags.dryRun = true;
    }
    else if (a === "--live") {
      flags.triageMode = "live";
      flags.promoteLanesMode = "live";
      flags.promoteReadyMode = "live";
    }
    else if (a === "--canonical-labels") flags.triageTaxonomyMode = "canonical";
    else if (a === "--query") {
      const val = args[++i] || null;
      flags.triageQuery = val;
      flags.promoteLanesQuery = val;
    }
    else if (a === "--bot-login") flags.triageBotLogin = args[++i] || null;
    else if (a === "--repo") {
      const val = args[++i];
      flags.triageRepos.push(val);
      flags.promoteLanesRepos.push(val);
      flags.promoteReadyRepo = val;
    }
    else if (a === "--issue") flags.promoteReadyIssue = parseInt(args[++i], 10) || null;
    else if (a === "--repo-root") flags.repoRoot = args[++i] || null;
    else if (a === "--run-mode") flags.runMode = args[++i] || null;
    else if (a === "--close-completed-prds") flags.closeCompletedPrds = true;
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
  node cli.mjs promote-lanes [--dry-run|--live] [--repo OWNER/NAME ...] [--query QUERY] [--json]
  node cli.mjs promote-ready [--dry-run|--live] [--issue N] [--repo OWNER/NAME] [--json]
  node cli.mjs orchestrate-repo [--repo-root PATH] [--dry-run] [--json] [--max-issues N] [--parallelism N] [--run-mode MODE]
  node cli.mjs orchestrate-repo --close-completed-prds [--repo-root PATH] [--dry-run] [--json]
  node cli.mjs help

Reads .ralph/ from cwd (or RALPH_REPO_ROOT). Shows current workers, queue
progress, and loop.out tail. Designed for terminal users who can't load the
Ralph dashboard extension.

triage runs comment-only advisory issue triage. It defaults to dry-run
calibration and prints exact comments without posting. Live mode only
posts/updates the bot-owned triage comment; no labels, closure, or Ralph
enqueue happens automatically.

promote-lanes applies lane routing decisions as guarded state transitions.
Defaults to dry-run; --live is required to write labels. Reads triaged issues
(default: label:ralph:needs-triage), evaluates each, routes to a lane, and
applies the target label while removing conflicting ralph:* state labels.

promote-ready promotes ralph:fast-lane issues to ralph:ready (one-tap gate).
Defaults to dry-run; --live is required to apply mutations. With --issue N,
promotes a single issue. Without --issue, batches all eligible fast-lane issues.

orchestrate-repo runs the ralph-orchestrator repo-maintain sweep from a repo's
MAIN checkout (where the local-only .ralph/ lives) for a local scheduler. It
discovers ready work read-only and launches a bounded run only through the
gated orchestrateRun path (allowAgentLaunch + preflight). Use --dry-run first.
The default sweep is read-only/launch-only and closes nothing.

With --close-completed-prds it instead reconciles open work:prd parents,
closing (as completed) only those whose every child slice is closed via a
merged PR. OFF by default; honors --dry-run for a zero-mutation preview.
`);
}

function printTriageUsage() {
  process.stdout.write(`Usage:
  node cli.mjs triage [--dry-run|--live] [--canonical-labels] [--repo OWNER/NAME] [--query QUERY] [--json]

Runs comment-only advisory issue triage for configured repositories.
Default repo: tjegbejimba/ralph-loop-dashboard
Default query: label:ralph:needs-triage

--dry-run           Print exact comments; do not post anything. Default.
--live              Post/update only the bot-owned triage comment.
--canonical-labels  Use label:ralph:needs-triage (now the default; kept for
                    backward compatibility).
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

// Emit a fail-loud GitHub preflight failure and mark a non-zero exit. Shared by
// triage and promote-lanes so a broken sandbox aborts before any per-issue work
// instead of silently no-op'ing (issue #149).
function emitPreflightFailure(flags, preflight, phase) {
  if (flags.json) {
    process.stdout.write(
      `${JSON.stringify({ ok: false, phase, error: preflight.error, checks: preflight.checks }, null, 2)}\n`,
    );
  }
  process.stderr.write(`${preflight.error}\n`);
  process.exitCode = 1;
}

// Classify a triage run so the scheduler can tell apart a genuine success, a
// run with nothing eligible, and a run that failed wholly or partially.
function classifyTriageRun(result) {
  const errors = [];
  let processed = 0;
  let skipped = 0;
  let posted = 0;
  let systemic = false;
  for (const repoResult of result.repos) {
    processed += repoResult.processed.length;
    skipped += repoResult.skipped.length;
    posted += repoResult.processed.filter((item) => item.posted).length;
    for (const error of repoResult.errors) {
      errors.push({ repo: repoResult.repo, ...error });
      if (error.type === "fetch_issues_failed") systemic = true;
    }
  }
  let outcome;
  if (systemic) outcome = "systemic_failure";
  else if (errors.length > 0) outcome = "partial_failure";
  else if (processed === 0 && skipped === 0) outcome = "success_no_eligible_work";
  else outcome = "success";
  return {
    outcome,
    errors,
    errorCount: errors.length,
    repoCount: result.repos.length,
    counts: { processed, skipped, posted },
  };
}

function isFailedTriageOutcome(outcome) {
  return outcome === "systemic_failure" || outcome === "partial_failure";
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

  // Fail-loud GitHub preflight (issue #149): abort before any per-issue work if
  // auth/reachability is broken in the (possibly sandboxed) environment.
  const preflight = runGithubPreflight({ repos });
  if (!preflight.ok) {
    emitPreflightFailure(flags, preflight, "github-preflight");
    return;
  }

  const result = await runIssueTriage({
    mode: flags.triageMode,
    config: {
      repos,
      botLogin: flags.triageBotLogin || preflight.login || currentGithubLogin(),
    },
  });

  const summary = classifyTriageRun(result);

  if (flags.json) {
    process.stdout.write(
      `${JSON.stringify({ ...result, outcome: summary.outcome, counts: summary.counts }, null, 2)}\n`,
    );
  } else {
    process.stdout.write(`${renderTriageRun(result)}\n`);
    const c = summary.counts;
    process.stdout.write(
      `\nOutcome: ${summary.outcome} ` +
        `(processed=${c.processed}, skipped=${c.skipped}, posted=${c.posted}, errors=${summary.errorCount})\n`,
    );
  }

  if (isFailedTriageOutcome(summary.outcome)) {
    process.stderr.write(
      `triage ${summary.outcome}: ${summary.errorCount} error(s) across ${summary.repoCount} repo(s).\n`,
    );
    for (const error of summary.errors) {
      const where = error.issueNumber ? `${error.repo} #${error.issueNumber}` : error.repo;
      process.stderr.write(`  - ${where} ${error.type}: ${error.message}\n`);
    }
    process.exitCode = 1;
  }
}

async function cmdPromoteLanes(flags) {
  if (flags.help) {
    process.stdout.write(`Usage:
  node cli.mjs promote-lanes [--dry-run|--live] [--repo OWNER/NAME ...] [--query QUERY] [--json]

Applies lane routing decisions as guarded state transitions.
Default repo: tjegbejimba/ralph-loop-dashboard
Default query: label:ralph:needs-triage

--dry-run           Print planned mutations; do not apply. Default.
--live              Apply the label mutations via gh.
--repo OWNER/NAME   Promote lanes in this repo instead of the default. Repeat
                    to triage several repos in one run.
--query QUERY       Override the issue search query.
--json              Emit the structured run summary.

Promotion is guarded: refuses to promote issues with taxonomy conflicts,
open linked PRs, assignees, unresolved blockers (except HOLD lane), missing
Parent markers for work:slice, or open questions/TBD evidence.
`);
    return;
  }

  const query = flags.promoteLanesQuery || "label:ralph:needs-triage";
  const live = flags.promoteLanesMode === "live";
  let repos;
  try {
    repos = flags.promoteLanesRepos.length > 0
      ? flags.promoteLanesRepos.map(parseRepoSpec)
      : [{ owner: "tjegbejimba", name: "ralph-loop-dashboard" }];
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exitCode = 2;
    return;
  }

  // Fail-loud GitHub preflight (issue #149): abort before any per-issue work if
  // auth/reachability is broken in the (possibly sandboxed) environment.
  const preflight = runGithubPreflight({ repos });
  if (!preflight.ok) {
    emitPreflightFailure(flags, preflight, "github-preflight");
    return;
  }

  const repoResults = [];

  for (const repo of repos) {
    const repoResult = promoteLanesForRepo({ repo, query, live });
    if (!repoResult) return;
    repoResults.push(repoResult);
  }

  const output = repoResults.length === 1
    ? repoResults[0]
    : {
        repos: repoResults,
        summary: aggregatePromotionSummary(repoResults),
      };

  if (flags.json) {
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  } else {
    process.stdout.write(renderPromoteLanesRun({ repoResults, live, query }));
  }

  // Surface enrichment failures that may have silently degraded routing/safety
  // decisions (author association → NONE, missing PR state). In live mode this
  // is a hard non-zero so the scheduler never reports a misleading success.
  const enrichmentErrors = repoResults.flatMap((r) =>
    (r.enrichmentErrors || []).map((e) => ({ repo: r.repo, ...e })),
  );
  if (enrichmentErrors.length > 0) {
    const severity = live ? "error" : "warning";
    process.stderr.write(
      `promote-lanes enrichment ${severity}: ${enrichmentErrors.length} GitHub enrichment ` +
        `call(s) failed; routing/safety decisions may be based on incomplete data.\n`,
    );
    for (const error of enrichmentErrors) {
      process.stderr.write(`  - ${error.repo} #${error.issueNumber} ${error.type}: ${error.message}\n`);
    }
    if (live) process.exitCode = 1;
  }
}

function promoteLanesForRepo({ repo, query, live }) {
  const repoName = `${repo.owner}/${repo.name}`;
  const ghResult = spawnSync(
    "gh",
    [
      "issue",
      "list",
      "--repo",
      repoName,
      "--search",
      query,
      "--state",
      "open",
      "--json",
      "number,title,body,labels,author,assignees,closedByPullRequestsReferences",
      "--limit",
      "100",
    ],
    { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 }
  );

  if (ghResult.error) {
    process.stderr.write(`gh error: ${ghResult.error.message}\n`);
    process.exitCode = 1;
    return null;
  }

  if (ghResult.status !== 0) {
    process.stderr.write(`gh failed: ${ghResult.stderr}\n`);
    process.exitCode = ghResult.status;
    return null;
  }

  const issues = JSON.parse(ghResult.stdout);
  const enrichmentErrors = [];

  // Enrich authorAssociation: gh issue list doesn't return it, so fetch via gh api
  // for each issue to get accurate OWNER/MEMBER/COLLABORATOR associations.
  for (const issue of issues) {
    const apiResult = spawnSync(
      "gh",
      ["api", `repos/${repo.owner}/${repo.name}/issues/${issue.number}`, "--jq", ".author_association"],
      { encoding: "utf8" }
    );
    if (apiResult.status === 0 && apiResult.stdout.trim()) {
      issue.authorAssociation = apiResult.stdout.trim();
    } else {
      // Fallback: assume NONE if we can't determine it. Record the failure so a
      // degraded routing decision is surfaced rather than silently trusted.
      issue.authorAssociation = "NONE";
      enrichmentErrors.push({
        issueNumber: issue.number,
        type: "author_association_failed",
        message: (apiResult.stderr || apiResult.error?.message || "gh api issue failed").trim(),
      });
    }
  }

  // Enrich PR state: gh issue list doesn't return PR state in closedByPullRequestsReferences.
  // Fetch state for each linked PR to enable the open-PR guard.
  for (const issue of issues) {
    const linkedPrs = issue.closedByPullRequestsReferences || [];
    for (const pr of linkedPrs) {
      if (!pr.number) continue;
      const prResult = spawnSync(
        "gh",
        ["pr", "view", String(pr.number), "--repo", `${repo.owner}/${repo.name}`, "--json", "state", "--jq", ".state"],
        { encoding: "utf8" }
      );
      if (prResult.status === 0 && prResult.stdout.trim()) {
        pr.state = prResult.stdout.trim();
      } else {
        // A missing PR state silently disables the open-PR guard. Record it so
        // the run can surface (and, in live mode, fail on) the gap.
        enrichmentErrors.push({
          issueNumber: issue.number,
          type: "pr_state_failed",
          prNumber: pr.number,
          message: (prResult.stderr || prResult.error?.message || "gh pr view failed").trim(),
        });
      }
    }
  }

  // Run lane promotion
  const result = runPromoteLanes({ issues, live });

  // Apply mutations if live, tracking what actually landed vs what failed so the
  // summary can't claim "promoted" when the gh edit never applied.
  const appliedMutations = [];
  const failedMutations = [];
  if (live) {
    for (const promotion of result.promotions) {
      if (promotion.skipped) continue;
      if (promotion.labelsAdded.length === 0 && promotion.labelsRemoved.length === 0) continue;

      const addArgs = promotion.labelsAdded.length > 0
        ? ["--add-label", promotion.labelsAdded.join(",")]
        : [];
      const removeArgs = promotion.labelsRemoved.length > 0
        ? ["--remove-label", promotion.labelsRemoved.join(",")]
        : [];

      const labelResult = spawnSync(
        "gh",
        [
          "issue",
          "edit",
          String(promotion.issueNumber),
          "--repo",
          repoName,
          ...addArgs,
          ...removeArgs,
        ],
        { encoding: "utf8" }
      );

      if (labelResult.status !== 0) {
        process.stderr.write(`Failed to update #${promotion.issueNumber}: ${labelResult.stderr}\n`);
        failedMutations.push({
          issueNumber: promotion.issueNumber,
          message: (labelResult.stderr || labelResult.error?.message || "gh issue edit failed").trim(),
        });
        process.exitCode = 1;
      } else {
        appliedMutations.push(promotion.issueNumber);
      }
    }
  }

  return {
    repo: repoName,
    query,
    ...result,
    enrichmentErrors,
    appliedMutations,
    failedMutations,
  };
}

function aggregatePromotionSummary(repoResults) {
  return repoResults.reduce(
    (summary, repoResult) => ({
      total: summary.total + repoResult.summary.total,
      promoted: summary.promoted + repoResult.summary.promoted,
      noOp: summary.noOp + repoResult.summary.noOp,
      skipped: summary.skipped + repoResult.summary.skipped,
    }),
    { total: 0, promoted: 0, noOp: 0, skipped: 0 },
  );
}

function renderPromoteLanesRun({ repoResults, live, query }) {
  const lines = [`Lane promotion (${live ? "live" : "dry-run"})\n`];
  if (repoResults.length > 1) {
    const summary = aggregatePromotionSummary(repoResults);
    lines.push(`Repos: ${repoResults.length}`);
    lines.push(`Query: ${query}`);
    lines.push(`Summary:`);
    lines.push(`  Total: ${summary.total}`);
    lines.push(`  Promoted: ${summary.promoted}`);
    lines.push(`  No-op (idempotent): ${summary.noOp}`);
    lines.push(`  Skipped (guards): ${summary.skipped}\n`);
  }

  for (const result of repoResults) {
    lines.push(`Repository: ${result.repo}`);
    lines.push(`Query: ${result.query}\n`);

    lines.push(`Summary:`);
    lines.push(`  Total: ${result.summary.total}`);
    lines.push(`  Promoted: ${result.summary.promoted}`);
    lines.push(`  No-op (idempotent): ${result.summary.noOp}`);
    lines.push(`  Skipped (guards): ${result.summary.skipped}`);
    if (live) {
      lines.push(`  Applied (live edits): ${result.appliedMutations?.length ?? 0}`);
      lines.push(`  Failed to apply: ${result.failedMutations?.length ?? 0}`);
    }
    lines.push("");

    for (const promotion of result.promotions) {
      if (promotion.skipped) {
        lines.push(`#${promotion.issueNumber} → SKIPPED: ${promotion.skipReason}`);
      } else if (promotion.labelsAdded.length === 0 && promotion.labelsRemoved.length === 0) {
        lines.push(`#${promotion.issueNumber} → ${promotion.lane} (no-op, already correct)`);
      } else {
        const added = promotion.labelsAdded.length > 0 ? `+${promotion.labelsAdded.join(", ")}` : "";
        const removed = promotion.labelsRemoved.length > 0 ? `-${promotion.labelsRemoved.join(", ")}` : "";
        const changes = [added, removed].filter(Boolean).join(" ");
        lines.push(`#${promotion.issueNumber} → ${promotion.lane}: ${changes}`);
      }
    }
    lines.push("");
  }

  return lines.join("\n").trimEnd() + "\n";
}

async function cmdPromoteReady(flags) {
  if (flags.help) {
    process.stdout.write(`Usage:
  node cli.mjs promote-ready [--dry-run|--live] [--issue N] [--repo OWNER/NAME] [--json]

Promotes ralph:fast-lane issues to ralph:ready (one-tap gate).
Default repo: tjegbejimba/ralph-loop-dashboard

--dry-run           Print planned mutations; do not apply. Default.
--live              Apply the label mutations via gh.
--issue N           Promote a single issue by number. Omit to batch all fast-lane.
--repo OWNER/NAME   Use this repo instead of the default.
--json              Emit the structured run summary.

Promotion is guarded: refuses to promote issues with ralph:hitl, ralph:blocked,
non-runnable work types, missing priority, taxonomy conflicts, open linked PRs,
assignees, unresolved blockers, or open questions/TBD evidence.
`);
    return;
  }

  const live = flags.promoteReadyMode === "live";
  let repo;
  try {
    repo = flags.promoteReadyRepo
      ? parseRepoSpec(flags.promoteReadyRepo)
      : { owner: "tjegbejimba", name: "ralph-loop-dashboard" };
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exitCode = 2;
    return;
  }

  const repoSlug = `${repo.owner}/${repo.name}`;

  // Fail-loud GitHub preflight
  const preflight = runGithubPreflight({ repos: [repo] });
  if (!preflight.ok) {
    emitPreflightFailure(flags, preflight, "github-preflight");
    return;
  }

  const issueNumbers = flags.promoteReadyIssue != null ? [flags.promoteReadyIssue] : [];

  const result = await runPromoteReady({
    repo: repoSlug,
    issueNumbers,
    live,
    fetchIssue: async (repoSlug, issueNumber) => {
      const result = spawnSync(
        "gh",
        ["issue", "view", String(issueNumber), "--repo", repoSlug, "--json", "number,title,body,labels,state,assignees,closedByPullRequestsReferences"],
        { stdio: ["ignore", "pipe", "pipe"], encoding: "utf-8" },
      );
      if (result.status !== 0) return null;
      try {
        return JSON.parse(result.stdout);
      } catch {
        return null;
      }
    },
    fetchFastLaneIssues: async (repoSlug) => {
      const result = spawnSync(
        "gh",
        ["issue", "list", "--repo", repoSlug, "--label", "ralph:fast-lane", "--state", "open", "--json", "number,title,body,labels,state,assignees,closedByPullRequestsReferences", "--limit", "100"],
        { stdio: ["ignore", "pipe", "pipe"], encoding: "utf-8" },
      );
      if (result.status !== 0) return [];
      try {
        return JSON.parse(result.stdout);
      } catch {
        return [];
      }
    },
  });

  if (flags.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    const mode = live ? "live" : "dry-run";
    process.stdout.write(`\nPromote-ready (${mode})\n`);
    process.stdout.write(`Repository: ${repoSlug}\n`);
    process.stdout.write(`Mode: ${issueNumbers.length > 0 ? `single issue #${issueNumbers[0]}` : "batch all fast-lane"}\n\n`);
    
    process.stdout.write(`Summary:\n`);
    process.stdout.write(`  Total: ${result.summary.total}\n`);
    process.stdout.write(`  Promoted: ${result.summary.promoted}\n`);
    process.stdout.write(`  Skipped: ${result.summary.skipped}\n\n`);
    
    for (const promotion of result.promotions) {
      if (promotion.promoted) {
        const changes = [`+${promotion.labelsAdded.join(", ")}`, `-${promotion.labelsRemoved.join(", ")}`]
          .filter((s) => s.length > 1)
          .join(" ");
        process.stdout.write(`#${promotion.issueNumber} → PROMOTED: ${changes}\n`);
      } else {
        process.stdout.write(`#${promotion.issueNumber} → SKIPPED: ${promotion.skipReason}\n`);
      }
    }
  }

  process.exitCode = 0;
}

function printOrchestrateRepoUsage() {
  process.stdout.write(`Usage:
  node cli.mjs orchestrate-repo [--repo-root PATH] [--dry-run] [--json] [--max-issues N] [--parallelism N] [--run-mode MODE]
  node cli.mjs orchestrate-repo --close-completed-prds [--repo-root PATH] [--dry-run] [--json]

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

--repo-root PATH         Repo MAIN checkout to operate on (default: cwd). Must
                         contain .ralph/config.json and .ralph/RALPH.md.
--dry-run                Read-only: print the plan + would-be ledger; no launch,
                         no ledger write, no mutations.
--json                   Emit the structured run summary.
--max-issues N           Cap issues per run (default 10).
--parallelism N          Workers (default 1).
--run-mode MODE          one-pass | until-empty (default until-empty).
--close-completed-prds   OPT-IN reconcile: instead of the launch sweep, close
                         (as completed) every OPEN work:prd parent whose every
                         child slice is closed via a merged PR. Cross-links the
                         delivered children + their merge PRs in a close comment.
                         OFF by default. Combine with --dry-run to preview which
                         parents WOULD close (and why others are skipped) with
                         ZERO mutations. Closes nothing else: never a work:slice
                         / work:standalone, never a parent with any open or zero
                         children, never with --admin.

Launch is gated by allowAgentLaunch: true in ~/.ralph-dashboard/config.json
(default false) plus a passing preflight. On a hard stop it prints an owner
brief and exits non-zero.
`);
}

async function cmdCloseCompletedPrds(flags) {
  const requestedRepoRoot = flags.repoRoot ? resolve(flags.repoRoot) : process.cwd();
  const { config: userConfig } = loadUserConfig();

  // Enforce the SAME orchestrateAllowedRepoRoots allowlist the launch path uses
  // (PR #97/#98 posture). A --repo-root that differs from the extension's own
  // trusted repo root is an OVERRIDE and must be allowlisted — otherwise an
  // operator could redirect destructive closes to an arbitrary checkout. The
  // trusted root is derived from this module's location (the dashboard repo
  // root, mirroring orchestrate-repo.mjs DEFAULT_TRUSTED_REPO_ROOT), never from
  // operator cwd/env.
  const trustedRepoRoot = resolve(import.meta.dirname, "..");
  const repoRootDecision = resolveOrchestrateRepoRoot({
    requested: requestedRepoRoot,
    defaultRepoRoot: trustedRepoRoot,
    userConfig,
  });
  if (!repoRootDecision.ok) {
    process.stderr.write(`${repoRootDecision.error}\n`);
    process.exitCode = 1;
    return;
  }
  const repoRoot = repoRootDecision.repoRoot;

  const configPath = join(repoRoot, ".ralph", "config.json");
  if (!existsSync(configPath)) {
    process.stderr.write(
      `No .ralph/config.json found at ${repoRoot}. ` +
        "--close-completed-prds runs from a repo's MAIN checkout where .ralph/ lives.\n",
    );
    process.exitCode = 2;
    return;
  }
  let config = {};
  try {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  } catch (err) {
    process.stderr.write(`Could not parse .ralph/config.json: ${String(err.message || err)}\n`);
    process.exitCode = 2;
    return;
  }
  const slugInfo = resolveRepoSlug({ repoRoot, config });
  if (!slugInfo) {
    process.stderr.write(
      `Could not resolve the GitHub owner/name for ${repoRoot}. Set "repo" in ` +
        ".ralph/config.json or add an origin remote.\n",
    );
    process.exitCode = 2;
    return;
  }

  let result;
  try {
    result = await runCloseCompletedPrds({ slug: slugInfo.slug, dryRun: flags.dryRun });
  } catch (err) {
    process.stderr.write(`close-completed-prds error: ${String(err.message || err)}\n`);
    process.exitCode = 1;
    return;
  }

  if (flags.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`${renderCloseCompletedPrds(result)}\n`);
  }

  if (result.errors.length > 0) process.exitCode = 1;
}

async function cmdOrchestrateRepo(flags) {
  if (flags.help) {
    printOrchestrateRepoUsage();
    return;
  }
  if (flags.closeCompletedPrds) {
    await cmdCloseCompletedPrds(flags);
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

  // The extension's own repo root (cli.mjs lives in extension/). An operator
  // --repo-root that differs from this is an allowlist override enforced by
  // orchestrateRun against orchestrateAllowedRepoRoots.
  const trustedRepoRoot = resolve(import.meta.dirname, "..");

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
      trustedRepoRoot,
      getLoopProcessForRepo: (targetRoot) =>
        createStatusReader({ repoRoot: targetRoot, env: process.env }).getLoopProcess,
      ...overrides,
    });
  } catch (err) {
    process.stderr.write(`orchestrate-repo error: ${String(err.message || err)}\n`);
    process.exitCode = 1;
    return;
  }

  const isHardStop = result.ok === false || result.outcome === "hard-stop";
  if (flags.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else if (result.dryRun && !isHardStop) {
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
  if (cmd === "promote-lanes") {
    await cmdPromoteLanes(flags);
    return;
  }
  if (cmd === "promote-ready") {
    await cmdPromoteReady(flags);
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
