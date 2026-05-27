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
//   help | --help                        Print usage.
//
// Repo resolution: $RALPH_REPO_ROOT → walk up from cwd looking for .ralph/.
// We don't import extension/lib/repo-resolver.mjs here so the CLI keeps
// working in repos that don't yet have a full .ralph install.

import { existsSync, statSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { join, resolve, dirname } from "node:path";
import { createStatusReader } from "./lib/status-data.mjs";
import { renderStatus, renderLocalStatus, shouldUseColor } from "./lib/terminal-render.mjs";

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
  const flags = { color: undefined, withPrs: false, interval: 2, worker: null };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--no-color") flags.color = false;
    else if (a === "--color") flags.color = true;
    else if (a === "--with-prs") flags.withPrs = true;
    else if (a === "--interval") {
      const n = Number(args[++i]);
      if (Number.isFinite(n) && n > 0) flags.interval = n;
    } else if (a === "--worker") {
      const n = Number(args[++i]);
      if (Number.isFinite(n)) flags.worker = n;
    } else if (/^-?\d+(\.\d+)?$/.test(a) && flags._numericPos == null) {
      // Positional numeric arg — used by `watch <SEC>` and `follow <N>`.
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
  node cli.mjs help

Reads .ralph/ from cwd (or RALPH_REPO_ROOT). Shows current workers, queue
progress, and loop.out tail. Designed for terminal users who can't load the
Ralph dashboard extension.
`);
}

async function cmdStatus(reader, flags) {
  const payload = await reader.buildStatusPayload({ withPrs: flags.withPrs });
  process.stdout.write(renderStatus(payload, { color: flags.color, withPrs: flags.withPrs }) + "\n");
}

async function cmdWatch(reader, flags) {
  const interval = flags._numericPos || flags.interval;
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

  let child = null;
  let stopping = false;
  const startTail = (logFile, issue) => {
    const logPath = join(reader.paths.LOGS_DIR, logFile);
    process.stdout.write(`── following w${current.workerId} #${issue} · ${logFile} ──\n`);
    // Use tail -F when available (handles rotation/recreation); fall back to -f.
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

  startTail(current.logFile, current.issue);

  // Poll state.json every 2s. If the followed worker's logFile changes,
  // print a separator and re-tail. If the worker disappears, exit cleanly.
  while (!stopping) {
    await new Promise((r) => setTimeout(r, 2000));
    const next = pickWorkerLog(reader, current.workerId);
    if (next.error) {
      process.stdout.write(`\n── ${next.error} ──\n`);
      stopTail();
      process.exit(0);
    }
    if (next.logFile !== current.logFile) {
      stopTail();
      process.stdout.write(`\n── worker rolled to new iteration: #${next.issue} ──\n`);
      current = next;
      startTail(current.logFile, current.issue);
    }
  }
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd || cmd === "help" || cmd === "--help" || cmd === "-h") {
    printUsage();
    process.exit(0);
  }
  const flags = parseFlags(rest);
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
