// Extension: ralph-dashboard-canvas (repo-native)
// Renders the Ralph loop dashboard inside a Copilot canvas (side panel) instead
// of the native webview window. It reuses the repo-native status-data.mjs so the
// numbers match exactly, and serves its own loopback UI so it is independent of
// the native window's lifecycle. Read-only: it never starts/stops workers.
// Includes a Pipeline tab for viewing the orchestrator pipeline state.

import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile } from "node:fs/promises";
import { joinSession, createCanvas, CanvasError } from "@github/copilot-sdk/extension";
import { pageHtml } from "./renderer.mjs";
import { discoverRepos } from "./lib/repo-discovery.mjs";
import { computePipelineState } from "./lib/pipeline-data.mjs";

const pexec = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

// Augment PATH so `gh` resolves in the extension's (possibly minimal) env.
const ENV = {
  ...process.env,
  PATH: `${process.env.PATH || ""}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
};

// Import the repo-native status-data module
async function loadStatusReaderFactory() {
  const statusDataPath = join(REPO_ROOT, "extension", "lib", "status-data.mjs");
  if (!existsSync(statusDataPath)) {
    throw new Error(`status-data.mjs not found at ${statusDataPath}`);
  }
  const mod = await import(statusDataPath);
  if (typeof mod.createStatusReader !== "function") {
    throw new Error("createStatusReader export missing from status-data.mjs");
  }
  return mod.createStatusReader;
}

// gh helpers for pipeline data
class GhError extends Error {
  constructor(kind, message) {
    super(message);
    this.kind = kind;
  }
}

async function gh(args) {
  try {
    const { stdout } = await pexec("gh", args, { env: ENV, maxBuffer: 16 * 1024 * 1024, timeout: 25000 });
    return stdout;
  } catch (e) {
    const msg = String((e && (e.stderr || e.message)) || e);
    if (e && e.code === "ENOENT") throw new GhError("missing", "GitHub CLI (`gh`) not found on PATH.");
    if (/not logged|authentication|gh auth login|HTTP 401|Bad credentials/i.test(msg)) {
      throw new GhError("auth", "GitHub CLI is not authenticated. Run `gh auth login`.");
    }
    throw new GhError("other", msg.split("\n")[0] || "gh failed");
  }
}

async function ghJson(args) {
  const out = await gh(args);
  return JSON.parse(out || "[]");
}

async function deriveSlug(cwd) {
  if (!cwd) return null;
  try {
    const { stdout } = await pexec("git", ["-C", cwd, "remote", "get-url", "origin"], { env: ENV, timeout: 8000 });
    const m = stdout.trim().match(/[:/]([^/\s]+\/[^/\s]+?)(?:\.git)?$/);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

async function readJsonSafe(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return null;
  }
}

// Resolve the default repo: if RALPH_DASHBOARD_REPO is set, use it; otherwise
// discover orchestrated repos and use the most-recently-active one; fall back
// to this repo (REPO_ROOT) if no orchestrated repos found.
function getDefaultRepo() {
  if (process.env.RALPH_DASHBOARD_REPO) {
    return process.env.RALPH_DASHBOARD_REPO;
  }
  
  const discovered = discoverRepos();
  if (discovered.length > 0) {
    return discovered[0].mainCheckout;
  }
  
  return REPO_ROOT;
}

function resolveRepoRoot(input) {
  return (input && typeof input.repoRoot === "string" && input.repoRoot) || getDefaultRepo();
}

// Build a status reader fresh each call so live edits to .ralph/config.json
// (e.g. issueSearch) are reflected without an extension reload
async function getReader(repoRoot) {
  const createStatusReader = await loadStatusReaderFactory();
  if (!existsSync(join(repoRoot, ".ralph"))) {
    throw new Error(`no .ralph/ directory in ${repoRoot}`);
  }
  return createStatusReader({ repoRoot, env: process.env });
}

async function statusJson(repoRoot) {
  try {
    const reader = await getReader(repoRoot);
    return await reader.buildStatusPayload({ withPrs: true });
  } catch (err) {
    return { error: String(err && err.message ? err.message : err), repoRoot };
  }
}

// Compute pipeline state for a repo
async function pipelineStateJson(repoRoot) {
  try {
    const slug = await deriveSlug(repoRoot);
    if (!slug) {
      return { error: { kind: "other", message: "Could not determine repo slug from git remote" }, repoRoot };
    }

    let openPrs = [];
    const [openIssues, closedIssues] = await Promise.all([
      ghJson(["issue", "list", "--repo", slug, "--state", "open", "--limit", "200", "--json", "number,title,labels,assignees,body,url,createdAt,updatedAt"]),
      ghJson(["issue", "list", "--repo", slug, "--state", "closed", "--limit", "40", "--json", "number,title,labels,url,closedAt"]),
    ]);
    
    try {
      openPrs = await ghJson(["pr", "list", "--repo", slug, "--state", "open", "--limit", "100", "--json", "number,title,url,headRefName,closingIssuesReferences"]);
    } catch (prErr) {
      // PR fetch failure: fail closed by keeping openPrs empty and flagging in response
      // This prevents issues with open PRs from incorrectly appearing in next-run
      return {
        error: { kind: "pr-fetch-failed", message: "Could not fetch PRs: " + (prErr.message || prErr) },
        repoSlug: slug,
        repoRoot,
        generatedAt: new Date().toISOString(),
      };
    }

    const claims = (await readJsonSafe(join(repoRoot, ".ralph", "state.json")))?.claims || {};
    const ledger = await readJsonSafe(join(repoRoot, ".ralph", "orchestrator", "ledger.json"));

    const pipeline = computePipelineState({
      issues: openIssues,
      closedIssues,
      claims,
      openPrs,
    });

    let lastTick = null;
    if (ledger) {
      const blockers = Array.isArray(ledger.blockers) ? ledger.blockers : [];
      const phase = ledger.phase || null;
      const outcome = ledger.noReadyWork
        ? "no ready work"
        : blockers.length
          ? "blocked"
          : phase || "ok";
      const b0 = blockers[0];
      lastTick = {
        phase,
        outcome,
        blockerCount: blockers.length,
        blocker: b0 ? (b0.kind || b0.type || "") + (b0.detail ? ": " + b0.detail : "") : null,
        runId: ledger.run?.runId || null,
        queuedIssues: (ledger.queuedIssues || []).map((q) => q.number),
        updatedAt: ledger.updatedAt || ledger.lastSuccessfulAutomatedStart || null,
      };
    }

    return {
      repoSlug: slug,
      repoRoot,
      generatedAt: new Date().toISOString(),
      ...pipeline,
      lastTick,
    };
  } catch (err) {
    const kind = err instanceof GhError ? err.kind : "other";
    return { error: { kind, message: String(err && err.message ? err.message : err) }, repoRoot };
  }
}


// One loopback server per open canvas instance
const servers = new Map(); // instanceId -> { server, url, repoRoot }

async function startServer(instanceId, repoRoot) {
  const server = createServer(async (req, res) => {
    const path = (req.url || "/").split("?")[0];
    if (path === "/status") {
      const data = await statusJson(repoRoot);
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      res.end(JSON.stringify(data));
      return;
    }
    if (path === "/pipeline-state") {
      const data = await pipelineStateJson(repoRoot);
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      res.end(JSON.stringify(data));
      return;
    }
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    res.end(pageHtml());
  });
  server.on("clientError", (_e, sock) => { try { sock.destroy(); } catch {} });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  return { server, url: `http://127.0.0.1:${port}/`, repoRoot };
}

export const session = await joinSession({
  canvases: [
    createCanvas({
      id: "ralph-dashboard",
      displayName: "Ralph Loop",
      description: "Live read-only view of the Ralph loop: running state, active workers, queued slices, and recent PRs.",
      inputSchema: {
        type: "object",
        properties: {
          repoRoot: {
            type: "string",
            description: "Absolute path to the repo whose .ralph loop to show. Defaults to the most-recently-active orchestrated repo in ~/Code, or this repo if none found.",
          },
        },
        additionalProperties: false,
      },
      actions: [
        {
          name: "get_status",
          description: "Return the current Ralph loop status (loopRunning, workers, openSlices, recentPrs, cumulative) as JSON.",
          handler: async (ctx) => {
            const entry = servers.get(ctx.instanceId);
            const repoRoot = entry ? entry.repoRoot : resolveRepoRoot(ctx.input);
            const data = await statusJson(repoRoot);
            if (data && data.error) throw new CanvasError("status_unavailable", data.error);
            return {
              repoRoot,
              loopRunning: !!data.loopRunning,
              headerText: data.headerText || null,
              workers: (data.workers || []).map((w) => ({ issue: w.issue, stage: w.stageLabel || w.label || null })),
              openSlices: (data.openSlices || []).map((s) => ({ number: s.number, title: s.title, labels: s.labels })),
              recentPrs: (data.recentPrs || []).slice(0, 8).map((p) => ({ number: p.number, title: p.title, state: p.state })),
              cumulative: data.cumulative || null,
            };
          },
        },
      ],
      open: async (ctx) => {
        const repoRoot = resolveRepoRoot(ctx.input);
        let entry = servers.get(ctx.instanceId);
        if (!entry) {
          entry = await startServer(ctx.instanceId, repoRoot);
          servers.set(ctx.instanceId, entry);
        } else if (entry.repoRoot !== repoRoot) {
          await new Promise((r) => entry.server.close(() => r()));
          entry = await startServer(ctx.instanceId, repoRoot);
          servers.set(ctx.instanceId, entry);
        }
        return { title: "Ralph Loop", url: entry.url, status: repoRoot };
      },
      onClose: async (ctx) => {
        const entry = servers.get(ctx.instanceId);
        if (entry) {
          servers.delete(ctx.instanceId);
          await new Promise((resolve) => entry.server.close(() => resolve()));
        }
      },
    }),
  ],
});
