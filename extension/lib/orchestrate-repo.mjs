// orchestrate-repo — headless repo-maintain runner.
//
// Runs Ralph's `ralph-orchestrator` repo-maintain logic from a repo's MAIN
// checkout (where the gitignored, local-only `.ralph/` lives) via a local
// scheduler (launchd/cron), instead of a Copilot scheduled workflow. Copilot
// workflows run in throwaway git worktrees that never contain `.ralph/`, so
// repo-maintain can never discover or launch from there. This CLI runner is the
// headless equivalent of the agent-session skill: it discovers ready work
// read-only, builds a bounded queue, and launches behind the EXISTING gated
// path (`orchestrateRun` — allowAgentLaunch + preflight). It never calls
// `launch.sh --start` directly and never invents a second launch mechanism.
//
// Behavior matches skills/ralph-orchestrator/modes/repo-maintain.md and
// references/policy.md (the authoritative spec). This module is pure of process
// I/O where possible: gh / git / orchestrateRun / active-run detection are all
// injectable so the logic can be unit-tested without the network or real
// workers.

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

import { orchestrateRun as orchestrateRalphRun, resolveOrchestrateRepoRoot } from "./loop-launch-controller.mjs";
import { resolveActiveRun } from "./status-data.mjs";
import { queryIssues } from "./issue-query.mjs";
import { classifyIssue, RALPH_STATES, CANONICAL_LABELS } from "./label-taxonomy.mjs";

export const LEDGER_SCHEMA_VERSION = "ralph-orchestrator/v1";

// The extension's own repo root (where this code is installed). Used as the
// trusted default when validating an operator-supplied --repo-root against the
// orchestrateAllowedRepoRoots allowlist: a --repo-root that differs from this is
// an OVERRIDE and must be allowlisted (PR #97 posture). Derived from this
// module's location (extension/lib/), never from operator-controlled cwd/env, so
// it can't be redirected to disable the allowlist on this headless entry point.
const DEFAULT_TRUSTED_REPO_ROOT = resolve(import.meta.dirname, "..", "..");

// V1 repo-maintain parameters (repo-maintain.md "V1 parameters"): at most 3
// issues and 1 worker per new run, run until the bounded queue drains.
export const REPO_MAINTAIN_DEFAULTS = Object.freeze({
  maxIssues: 3,
  parallelism: 1,
  runMode: "until-empty",
});

// The canonical ralph:* state labels a repo must have before repo-maintain will
// touch it. Missing any of these is a one-time owner-brief skip, never an
// autonomous label migration.
export const REQUIRED_CANONICAL_LABELS = Object.freeze([...RALPH_STATES]);

const SLUG_RE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;

function isDirectory(path) {
  try {
    return existsSync(path);
  } catch {
    return false;
  }
}

/**
 * Resolve the GitHub owner/name for a repo. Prefers `.ralph/config.json` `repo`
 * (the same field preflight trusts), then falls back to the `origin` remote.
 *
 * @returns {{ owner: string, name: string, slug: string } | null}
 */
export function resolveRepoSlug({ repoRoot, config, execGit } = {}) {
  const fromConfig = typeof config?.repo === "string" ? config.repo.trim() : "";
  if (SLUG_RE.test(fromConfig)) {
    const [owner, name] = fromConfig.split("/");
    return { owner, name, slug: `${owner}/${name}` };
  }

  let remote = "";
  try {
    remote = String(
      typeof execGit === "function"
        ? execGit(["-C", repoRoot, "remote", "get-url", "origin"])
        : defaultExecGit(["-C", repoRoot, "remote", "get-url", "origin"]),
    ).trim();
  } catch {
    remote = "";
  }
  const parsed = parseGitHubRemote(remote);
  return parsed;
}

function parseGitHubRemote(remote) {
  if (!remote) return null;
  // git@github.com:owner/name(.git) | ssh://git@github.com/owner/name(.git)
  // https://github.com/owner/name(.git)
  const cleaned = remote.replace(/\.git$/i, "");
  const m =
    cleaned.match(/[:/]([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)$/) || null;
  if (!m) return null;
  const owner = m[1];
  const name = m[2];
  if (!owner || !name) return null;
  return { owner, name, slug: `${owner}/${name}` };
}

function defaultExecGit(args) {
  const result = spawnSync("git", args, { encoding: "utf8", maxBuffer: 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || "git command failed");
  return result.stdout;
}

function defaultListLabels(slug) {
  const result = spawnSync(
    "gh",
    ["label", "list", "--repo", slug, "--limit", "200", "--json", "name"],
    { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || "gh label list failed");
  const parsed = JSON.parse(result.stdout || "[]");
  return parsed.map((entry) => entry?.name).filter(Boolean);
}

// Read the repo's currently-claimed issue numbers from `.ralph/state.json`
// (canonical for live workers). These feed both active-run detection and
// discovery so a locally-claimed issue is never re-queued before its run's
// status.json catches up.
function defaultReadLocalClaims(repoRoot) {
  try {
    const parsed = JSON.parse(readFileSync(join(repoRoot, ".ralph", "state.json"), "utf8"));
    const claims = parsed?.claims && typeof parsed.claims === "object" ? parsed.claims : {};
    return Object.keys(claims)
      .map((key) => Number(key))
      .filter((n) => Number.isFinite(n));
  } catch {
    return [];
  }
}

/**
 * Return the canonical ralph:* state labels missing from a repo's label set.
 * Empty array means the precondition is satisfied.
 */
export function findMissingCanonicalLabels(repoLabelNames = []) {
  const present = new Set(repoLabelNames);
  return REQUIRED_CANONICAL_LABELS.filter((label) => !present.has(label));
}

/**
 * Bound a discovered, eligible issue set to the per-run cap, lowest issue
 * number first (repo-maintain.md step 5). Does not mutate the input.
 */
export function buildBoundedQueue(issues = [], { maxIssues = REPO_MAINTAIN_DEFAULTS.maxIssues } = {}) {
  return [...issues]
    .sort((a, b) => Number(a.number) - Number(b.number))
    .slice(0, Math.max(0, maxIssues));
}

function priorityShort(priorityLabel) {
  return typeof priorityLabel === "string" ? priorityLabel.replace(/^priority:/, "") : null;
}

// Owner-brief text for the canonical label-creation commands. Mirrors
// docs/labels.md; the orchestrator never runs these itself.
function labelCreationBrief(slug) {
  const lines = CANONICAL_LABELS.map(
    (label) =>
      `gh label create ${label.name} --repo ${slug} --color ${label.color} ` +
      `--description ${JSON.stringify(label.description)}`,
  );
  return (
    `Repo ${slug} is missing the canonical ralph:* labels, so repo-maintain is ` +
    `skipping it. Create them once, then re-run:\n\n${lines.join("\n")}`
  );
}

function emptyLedger({ slug, now }) {
  return {
    schemaVersion: LEDGER_SCHEMA_VERSION,
    mode: "repo-maintain",
    target: { repo: slug || null, prd: null, prdUrl: null },
    phase: "preflight",
    queuedIssues: [],
    run: { runId: null, workerIds: [], runDir: null },
    blockers: [],
    lastOwnerDecision: null,
    ownerBriefsSent: {},
    concurrency: { activeRunDetected: false, deferred: false },
    updatedAt: now().toISOString(),
  };
}

function writeLedger(repoRoot, ledger) {
  const dir = join(repoRoot, ".ralph", "orchestrator");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "ledger.json"), JSON.stringify(ledger, null, 2) + "\n", "utf8");
}

function hardStop({ repoRoot, ledger, outcome = "hard-stop", ownerBrief, extra = {}, dryRun }) {
  const ledgerWritten = ledger != null && !dryRun;
  if (ledgerWritten) writeLedger(repoRoot, ledger);
  return {
    ok: false,
    outcome,
    exitCode: 1,
    dryRun: Boolean(dryRun),
    repoRoot,
    ownerBrief: ownerBrief || null,
    ledger: ledger || null,
    ledgerWritten,
    ...extra,
  };
}

/**
 * Run the headless repo-maintain sweep for a single repo's main checkout.
 *
 * Steps (repo-maintain.md): resolve + require `.ralph/`, read `issueSearch`
 * exactly, resolve owner/name, concurrency defer, label precondition,
 * read-only discovery, bounded queue, gated launch via orchestrateRun, ledger.
 *
 * All side-effecting collaborators are injectable for testing.
 */
export async function runOrchestrateRepo(options = {}) {
  const {
    repoRoot: requestedRepoRoot = process.cwd(),
    dryRun = false,
    maxIssues = REPO_MAINTAIN_DEFAULTS.maxIssues,
    parallelism = REPO_MAINTAIN_DEFAULTS.parallelism,
    runMode = REPO_MAINTAIN_DEFAULTS.runMode,
    userConfig = {},
    now = () => new Date(),
    // The extension's trusted repo root. An operator-supplied repoRoot that
    // differs from this is an allowlist OVERRIDE (must be in
    // orchestrateAllowedRepoRoots). Defaults to this module's install location.
    trustedRepoRoot = DEFAULT_TRUSTED_REPO_ROOT,
    // Injectable collaborators:
    resolveActiveRunFn = resolveActiveRun,
    resolveRepoRootFn = resolveOrchestrateRepoRoot,
    readLocalClaimsFn = defaultReadLocalClaims,
    listLabels = defaultListLabels,
    execIssueList, // execCommand for queryIssues (returns gh stdout JSON string)
    queryIssuesFn = queryIssues,
    execGit,
    orchestrateRunFn = orchestrateRalphRun,
    getLoopProcessForRepo,
  } = options;

  const repoRoot = resolve(requestedRepoRoot);

  // Step 1: require a real `.ralph/` install. Do NOT install or repair.
  const configPath = join(repoRoot, ".ralph", "config.json");
  const ralphMdPath = join(repoRoot, ".ralph", "RALPH.md");
  if (!isDirectory(join(repoRoot, ".ralph")) || !existsSync(configPath)) {
    return hardStop({
      repoRoot,
      dryRun,
      outcome: "hard-stop",
      ownerBrief:
        `No .ralph/config.json found at ${repoRoot}. repo-maintain runs from a ` +
        `repo's MAIN checkout where the local-only .ralph/ lives — it will not ` +
        `install or repair Ralph. Run install.sh for this repo first.`,
    });
  }
  if (!existsSync(ralphMdPath)) {
    return hardStop({
      repoRoot,
      dryRun,
      outcome: "hard-stop",
      ownerBrief:
        `No .ralph/RALPH.md found at ${repoRoot}. The worker prompt is missing; ` +
        `repo-maintain will not repair it. Run install.sh for this repo first.`,
    });
  }

  // Step 2: read issue.issueSearch EXACTLY — never rewrite or reconstruct it.
  let config = {};
  try {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  } catch (err) {
    return hardStop({
      repoRoot,
      dryRun,
      outcome: "hard-stop",
      ownerBrief: `Could not parse .ralph/config.json: ${String(err.message || err)}`,
    });
  }
  const issueSearch =
    typeof config?.issue?.issueSearch === "string" ? config.issue.issueSearch : null;

  // Step 3: resolve owner/name from config.repo or origin remote.
  const slugInfo = resolveRepoSlug({ repoRoot, config, execGit });
  if (!slugInfo) {
    return hardStop({
      repoRoot,
      dryRun,
      outcome: "hard-stop",
      ownerBrief:
        `Could not resolve the GitHub owner/name for ${repoRoot}. Set "repo" in ` +
        `.ralph/config.json or add an origin remote.`,
    });
  }
  const slug = slugInfo.slug;

  if (!issueSearch) {
    return hardStop({
      repoRoot,
      dryRun,
      outcome: "hard-stop",
      ownerBrief:
        `.ralph/config.json for ${slug} has no issue.issueSearch. repo-maintain ` +
        `reads this query verbatim and will not invent one.`,
    });
  }

  const ledger = emptyLedger({ slug, now });
  const result = {
    ok: true,
    outcome: null,
    exitCode: 0,
    dryRun,
    repoRoot,
    repo: slug,
    issueSearch,
    concurrency: { activeRunDetected: false, deferred: false, activeRunId: null },
    labelPrecondition: { ok: true, missing: [] },
    discovered: [],
    skipped: [],
    queue: [],
    gate: null,
    launch: null,
    ledger,
    ledgerWritten: false,
    ownerBrief: null,
  };

  // Local live claims (state.json) feed both active-run detection and discovery
  // so a locally-claimed Ralph duplicate is deferred/skipped, never re-queued.
  let localClaims = [];
  try {
    localClaims = readLocalClaimsFn(repoRoot) || [];
  } catch {
    localClaims = [];
  }

  // Step 4: concurrency — one active run per repo. Defer if a run is live.
  let activeRun = null;
  try {
    activeRun = resolveActiveRunFn(repoRoot, { liveIssues: localClaims });
  } catch {
    activeRun = null;
  }
  if (activeRun && activeRun.isActive) {
    result.concurrency = {
      activeRunDetected: true,
      deferred: true,
      activeRunId: activeRun.runId || null,
    };
    ledger.phase = "monitoring";
    ledger.concurrency = { activeRunDetected: true, deferred: true };
    ledger.run = { runId: activeRun.runId || null, workerIds: [], runDir: activeRun.runDir || null };
    ledger.updatedAt = now().toISOString();
    result.outcome = "deferred";
    if (!dryRun) {
      writeLedger(repoRoot, ledger);
      result.ledgerWritten = true;
    }
    return result;
  }

  // Step 5: label precondition. Missing canonical ralph:* labels → skip +
  // one-time owner brief. Never migrate labels autonomously.
  let repoLabels = [];
  try {
    repoLabels = await listLabels(slug);
  } catch (err) {
    return hardStop({
      repoRoot,
      dryRun,
      ledger: { ...ledger, phase: "paused", blockers: [{ kind: "access", ref: slug, detail: `gh label list failed: ${String(err.message || err)}` }], updatedAt: now().toISOString() },
      ownerBrief: `Could not list labels for ${slug}: ${String(err.message || err)}. Check gh auth and repo access.`,
      extra: { repo: slug, issueSearch },
    });
  }
  const missingLabels = findMissingCanonicalLabels(repoLabels);
  if (missingLabels.length > 0) {
    result.labelPrecondition = { ok: false, missing: missingLabels };
    result.outcome = "skipped-labels";
    result.ownerBrief = labelCreationBrief(slug);
    ledger.phase = "paused";
    ledger.blockers = [
      { kind: "product", ref: slug, detail: `Missing canonical labels: ${missingLabels.join(", ")}` },
    ];
    ledger.ownerBriefsSent = { [`${slug}:labels`]: true };
    ledger.updatedAt = now().toISOString();
    if (!dryRun) {
      writeLedger(repoRoot, ledger);
      result.ledgerWritten = true;
    }
    return result;
  }

  // Step 6: discover ready work READ-ONLY via the existing query helper.
  const discovery = queryIssuesFn({
    repoOwner: slugInfo.owner,
    repoName: slugInfo.name,
    searchQuery: issueSearch,
    execCommand: execIssueList,
    claimedIssues: localClaims,
  });
  if (discovery.error) {
    return hardStop({
      repoRoot,
      dryRun,
      ledger: { ...ledger, phase: "paused", blockers: [{ kind: "access", ref: slug, detail: `discovery failed: ${discovery.error.message}` }], updatedAt: now().toISOString() },
      ownerBrief: `Issue discovery failed for ${slug}: ${discovery.error.message}. Check gh auth and the issueSearch query.`,
      extra: { repo: slug, issueSearch },
    });
  }

  const linkedPr = new Set(
    discovery.warnings.filter((w) => w.type === "linked_pr").map((w) => w.issueNumber),
  );
  const alreadyClaimed = new Set(
    discovery.warnings.filter((w) => w.type === "already_claimed").map((w) => w.issueNumber),
  );
  const unresolvedBlocker = new Set(
    discovery.warnings.filter((w) => w.type === "unresolved_blocker").map((w) => w.issueNumber),
  );

  const eligible = [];
  const skipped = [];
  for (const issue of discovery.issues || []) {
    const tx = issue.taxonomy || {};
    // V1: only ralph:ready + runnable work types qualify (conservative; blocked
    // states stay out until a human moves them).
    if (tx.state !== "ralph:ready" || tx.runnable !== true) {
      skipped.push({ number: issue.number, reason: "not canonical ralph:ready runnable work" });
      continue;
    }
    if (linkedPr.has(issue.number)) {
      skipped.push({ number: issue.number, reason: "open linked PR" });
      continue;
    }
    if (alreadyClaimed.has(issue.number)) {
      skipped.push({ number: issue.number, reason: "already claimed by an active Ralph run" });
      continue;
    }
    if (unresolvedBlocker.has(issue.number)) {
      skipped.push({ number: issue.number, reason: "unresolved blocker" });
      continue;
    }
    eligible.push({
      number: issue.number,
      title: issue.title,
      url: issue.url,
      priority: priorityShort(tx.priority),
    });
  }
  result.discovered = eligible;
  result.skipped = skipped;

  // Step 7: bounded queue (≤ maxIssues, lowest number first).
  const queue = buildBoundedQueue(eligible, { maxIssues });
  result.queue = queue;

  const allowLaunch = userConfig?.allowAgentLaunch === true;
  // Validate the operator-supplied repoRoot as an OVERRIDE against the trusted
  // default. A repoRoot equal to the trusted default is allowed; anything else
  // must be in orchestrateAllowedRepoRoots. This is the same gate orchestrateRun
  // enforces — we evaluate it up front so a non-allowlisted target hard-stops
  // with a clear owner brief and never reaches a launch.
  const repoRootDecision = resolveRepoRootFn({
    requested: repoRoot,
    defaultRepoRoot: trustedRepoRoot,
    userConfig,
  });
  const repoRootAllowed = repoRootDecision?.ok === true;
  const gateOk = allowLaunch && repoRootAllowed;
  let gateReason = null;
  if (!allowLaunch) {
    gateReason = "allowAgentLaunch is not enabled in ~/.ralph-dashboard/config.json";
  } else if (!repoRootAllowed) {
    gateReason = repoRootDecision?.error
      || `repoRoot ${repoRoot} is not listed in orchestrateAllowedRepoRoots.`;
  }
  result.gate = {
    allowAgentLaunch: allowLaunch,
    repoRootAllowed,
    status: gateOk ? "LAUNCH" : "HARD STOP",
    reason: gateReason,
  };

  ledger.queuedIssues = queue.map((issue) => ({
    number: issue.number,
    url: issue.url || null,
    priority: issue.priority || null,
  }));

  // No ready work → record and stop cleanly.
  if (queue.length === 0) {
    result.outcome = "no-ready-work";
    ledger.phase = "done";
    ledger.updatedAt = now().toISOString();
    if (!dryRun) {
      writeLedger(repoRoot, ledger);
      result.ledgerWritten = true;
    }
    return result;
  }

  // Step 10: dry-run stops before any launch / ledger write — plan only.
  if (dryRun) {
    result.outcome = "dry-run";
    ledger.phase = gateOk ? "launching" : "paused";
    ledger.updatedAt = now().toISOString();
    return result;
  }

  // Gate hard stop — refuse to launch and surface an owner brief. We never
  // bypass the gate or call launch.sh; orchestrateRun re-enforces this too.
  if (!gateOk) {
    const issueNumbers = queue.map((issue) => issue.number);
    const kind = !allowLaunch ? "allowAgentLaunch" : "allowlist";
    ledger.phase = "paused";
    ledger.blockers = [{ kind, ref: slug, detail: gateReason }];
    ledger.lastOwnerDecision = null;
    ledger.updatedAt = now().toISOString();
    writeLedger(repoRoot, ledger);
    return {
      ...result,
      ok: false,
      outcome: "hard-stop",
      exitCode: 1,
      ownerBrief: gateHardStopBrief({ slug, kind, repoRoot, issueNumbers }),
      ledgerWritten: true,
    };
  }

  // Step 8: launch behind the gate. orchestrateRun enforces allowAgentLaunch +
  // the allowlist + preflight against the TRUSTED default; we never bypass it or
  // call launch.sh --start directly.
  const issueNumbers = queue.map((issue) => issue.number);
  const launch = await orchestrateRunFn({
    repoRoot,
    defaultRepoRoot: trustedRepoRoot,
    issueNumbers,
    runOptions: { parallelism, runMode },
    userConfig,
    verify: false,
    getLoopProcessForRepo,
  });
  result.launch = launch;

  if (!launch || launch.ok !== true) {
    const kind = classifyLaunchFailure(launch);
    const detail = launch?.error || "orchestrateRun failed";
    ledger.phase = "paused";
    ledger.blockers = [{ kind, ref: slug, detail }];
    ledger.lastOwnerDecision = null;
    ledger.updatedAt = now().toISOString();
    writeLedger(repoRoot, ledger);
    return {
      ...result,
      ok: false,
      outcome: "hard-stop",
      exitCode: 1,
      ownerBrief: launchHardStopBrief({ slug, kind, detail, issueNumbers }),
      ledgerWritten: true,
    };
  }

  // Step 9: record the gated launch.
  result.outcome = "launched";
  ledger.phase = "monitoring";
  ledger.run = {
    runId: launch.runId || null,
    workerIds: [],
    runDir: launch.runDir || null,
  };
  ledger.updatedAt = now().toISOString();
  writeLedger(repoRoot, ledger);
  result.ledgerWritten = true;
  return result;
}

function classifyLaunchFailure(launch) {
  if (launch?.preflight) return "preflight";
  const error = String(launch?.error || "");
  if (/orchestrateAllowedRepoRoots|not listed in/i.test(error)) return "allowlist";
  if (/allowAgentLaunch/i.test(error)) return "allowAgentLaunch";
  if (/already running/i.test(error)) return "worker-stall";
  return "access";
}

// Owner brief for an up-front gate hard stop (gate evaluated before launch).
function gateHardStopBrief({ slug, kind, repoRoot, issueNumbers }) {
  const queued = issueNumbers.map((n) => `#${n}`).join(", ");
  const count = issueNumbers.length;
  if (kind === "allowlist") {
    return (
      `repo-maintain found ${count} ready issue(s) for ${slug} (${queued}) but its ` +
      `checkout ${repoRoot} is not allowlisted. Add its absolute path to ` +
      `"orchestrateAllowedRepoRoots" in ~/.ralph-dashboard/config.json, then re-run.`
    );
  }
  return (
    `repo-maintain has ${count} ready issue(s) for ${slug} (${queued}) but agent ` +
    `launch is gated off. Set "allowAgentLaunch": true in ` +
    `~/.ralph-dashboard/config.json to let the runner launch, then re-run.`
  );
}

function launchHardStopBrief({ slug, kind, detail, issueNumbers }) {
  const queued = issueNumbers.map((n) => `#${n}`).join(", ");
  if (kind === "allowAgentLaunch") {
    return (
      `repo-maintain has ${issueNumbers.length} ready issue(s) for ${slug} ` +
      `(${queued}) but agent launch is gated off. Set "allowAgentLaunch": true in ` +
      `~/.ralph-dashboard/config.json to let the runner launch, then re-run.`
    );
  }
  if (kind === "preflight") {
    return (
      `repo-maintain could not launch ${slug} (${queued}) — preflight blocked the run. ` +
      `Resolve the preflight blockers (clean tree, gh auth, canonical labels) and re-run. ` +
      `Detail: ${detail}`
    );
  }
  return `repo-maintain could not launch ${slug} (${queued}): ${detail}`;
}

/**
 * Render the dry-run / plan text (zero-mutation plan output).
 *
 * A hard-stop result (e.g. missing .ralph) carries only partial fields, so this
 * defers to renderSummary for those rather than dereferencing absent sections.
 */
export function renderPlan(result) {
  if (result?.ok === false || result?.outcome === "hard-stop") {
    return renderSummary(result);
  }
  const concurrency = result.concurrency || { activeRunDetected: false, activeRunId: null };
  const labelPrecondition = result.labelPrecondition || { ok: true, missing: [] };
  const discovered = result.discovered || [];
  const skipped = result.skipped || [];
  const queue = result.queue || [];
  const lines = [];
  lines.push(`Ralph repo-maintain — plan (dry-run)`);
  lines.push(`  repo:          ${result.repo}`);
  lines.push(`  repoRoot:      ${result.repoRoot}`);
  lines.push(`  issueSearch:   ${result.issueSearch}`);
  lines.push(
    `  concurrency:   ${concurrency.activeRunDetected ? `active run ${concurrency.activeRunId || ""} — would DEFER` : "no active run"}`,
  );
  lines.push(
    `  labels:        ${labelPrecondition.ok ? "canonical ralph:* present" : `MISSING ${labelPrecondition.missing.join(", ")} — would SKIP`}`,
  );
  lines.push(`  discovered:    ${discovered.length} eligible`);
  for (const issue of discovered) {
    lines.push(`    #${issue.number} [${issue.priority || "?"}] ${issue.title}`);
  }
  if (skipped.length > 0) {
    lines.push(`  skipped:`);
    for (const s of skipped) lines.push(`    #${s.number} — ${s.reason}`);
  }
  lines.push(`  bounded queue: ${queue.map((i) => `#${i.number}`).join(", ") || "(none)"}`);
  if (result.gate) {
    lines.push(`  gate:          ${result.gate.status}${result.gate.reason ? ` — ${result.gate.reason}` : ""}`);
  }
  if (result.ownerBrief) {
    lines.push("", "Owner brief:", result.ownerBrief);
  }
  lines.push("", "Would-be ledger:", JSON.stringify(result.ledger, null, 2));
  return lines.join("\n");
}

/**
 * Render a concise human summary for a non-dry-run.
 */
export function renderSummary(result) {
  const lines = [];
  const head = `Ralph repo-maintain — ${result.repo || result.repoRoot}`;
  switch (result.outcome) {
    case "launched":
      lines.push(`${head}: LAUNCHED ${result.queue.map((i) => `#${i.number}`).join(", ")} (run ${result.ledger?.run?.runId || "?"})`);
      break;
    case "deferred":
      lines.push(`${head}: DEFERRED — active run ${result.concurrency.activeRunId || ""} already in flight`);
      break;
    case "skipped-labels":
      lines.push(`${head}: SKIPPED — missing canonical labels ${result.labelPrecondition.missing.join(", ")}`);
      break;
    case "no-ready-work":
      lines.push(`${head}: no ready work`);
      break;
    case "hard-stop":
      lines.push(`${head}: HARD STOP`);
      break;
    default:
      lines.push(`${head}: ${result.outcome}`);
  }
  if (result.ownerBrief) lines.push("", result.ownerBrief);
  return lines.join("\n");
}
