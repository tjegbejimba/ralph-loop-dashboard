// Extension: ralph-dashboard-canvas (repo-native)
// Renders the Ralph loop dashboard inside a Copilot canvas (side panel) instead
// of the native webview window. It reuses the repo-native status-data.mjs so the
// numbers match exactly, and serves its own loopback UI so it is independent of
// the native window's lifecycle. Read-only: it never starts/stops workers.

import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { joinSession, createCanvas, CanvasError } from "@github/copilot-sdk/extension";
import { pageHtml } from "./renderer.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

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

// Default repo to point at when the canvas is opened without an explicit repoRoot
const DEFAULT_REPO = process.env.RALPH_DASHBOARD_REPO || REPO_ROOT;

function resolveRepoRoot(input) {
  return (input && typeof input.repoRoot === "string" && input.repoRoot) || DEFAULT_REPO;
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
            description: "Absolute path to the repo whose .ralph loop to show. Defaults to this repo.",
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
