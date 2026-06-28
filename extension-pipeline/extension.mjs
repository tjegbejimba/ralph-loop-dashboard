// Extension: ralph-pipeline
// Read-only side-panel canvas for Ralph orchestrator state across repos.

import { joinSession, createCanvas } from "@github/copilot-sdk/extension";
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile } from "node:fs/promises";
import { watch, readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";

import { computePipelineState, discoverFailedRunItems } from "./lib/pipeline-state.mjs";
import { renderHtml } from "./renderer.mjs";

const pexec = promisify(execFile);
const STATE_TTL_MS = 4000;
const ENV = {
  ...process.env,
  PATH: `${process.env.PATH || ""}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
};

const servers = new Map();
let SESSION;
let WORKSPACE;

function logSafe(message, level = "info") {
  try {
    SESSION?.log?.(message, { level, ephemeral: true });
  } catch {
    // Logging is best-effort; never break the read-only panel.
  }
}

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
  } catch (error) {
    const message = String((error && (error.stderr || error.message)) || error);
    if (error && error.code === "ENOENT") throw new GhError("missing", "GitHub CLI (`gh`) not found on PATH.");
    if (/not logged|authentication|gh auth login|HTTP 401|Bad credentials/i.test(message)) {
      throw new GhError("auth", "GitHub CLI is not authenticated. Run `gh auth login`.");
    }
    throw new GhError("other", message.split("\n")[0] || "gh failed");
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
    const match = stdout.trim().match(/[:/]([^/\s]+\/[^/\s]+?)(?:\.git)?$/);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

function repoActivity(checkout) {
  let activity = 0;
  for (const path of [
    join(checkout, ".ralph", "state.json"),
    join(checkout, ".ralph", "orchestrator", "ledger.json"),
    join(checkout, ".ralph", "runs"),
  ]) {
    try {
      activity = Math.max(activity, statSync(path).mtimeMs);
    } catch {
      // Missing Ralph runtime state is expected for quiet repos.
    }
  }
  return activity;
}

function discoverRepos() {
  const found = new Map();
  for (const root of [join(homedir(), "Code")]) {
    let entries = [];
    try {
      entries = readdirSync(root, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const checkout = join(root, entry.name);
      const cfgPath = join(checkout, ".ralph", "config.json");
      const orchDir = join(checkout, ".ralph", "orchestrator");
      if (!existsSync(cfgPath) || !existsSync(orchDir)) continue;
      let slug = null;
      try {
        slug = JSON.parse(readFileSync(cfgPath, "utf8"))?.repo || null;
      } catch {
        continue;
      }
      if (!slug || typeof slug !== "string") continue;
      const repoName = slug.split("/")[1] || entry.name;
      const candidate = { slug, mainCheckout: checkout, label: repoName, activity: repoActivity(checkout) };
      const previous = found.get(slug);
      const isCanonical = entry.name === repoName;
      if (!previous || (isCanonical && basename(previous.mainCheckout) !== repoName)) found.set(slug, candidate);
    }
  }
  return [...found.values()].sort((a, b) => b.activity - a.activity || a.label.localeCompare(b.label));
}

async function guessCheckout(slug) {
  const name = slug.split("/")[1];
  if (!name) return null;
  const guess = join(homedir(), "Code", name);
  return existsSync(join(guess, ".ralph")) ? guess : null;
}

async function resolveRepos(input) {
  if (input?.repoSlug) {
    return [
      {
        slug: input.repoSlug,
        mainCheckout: input.mainCheckout || (await guessCheckout(input.repoSlug)) || WORKSPACE || process.cwd(),
        label: input.repoSlug.split("/")[1] || input.repoSlug,
        activity: 0,
      },
    ];
  }
  const discovered = discoverRepos();
  if (discovered.length === 0) {
    const wsSlug = await deriveSlug(WORKSPACE);
    if (wsSlug) {
      discovered.push({
        slug: wsSlug,
        mainCheckout: (await guessCheckout(wsSlug)) || WORKSPACE || process.cwd(),
        label: wsSlug.split("/")[1] || wsSlug,
        activity: 0,
      });
    }
  }
  return discovered;
}

async function readJsonSafe(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return null;
  }
}

async function computeState(repo) {
  const repoSlug = repo.slug;
  const mainCheckout = repo.mainCheckout;
  let error = null;
  let openIssues = [];
  let closedIssues = [];
  let openPrs = [];

  try {
    [openIssues, closedIssues, openPrs] = await Promise.all([
      ghJson(["issue", "list", "--repo", repoSlug, "--state", "open", "--limit", "200", "--json", "number,title,labels,assignees,body,url,createdAt,updatedAt"]),
      ghJson(["issue", "list", "--repo", repoSlug, "--state", "closed", "--limit", "40", "--json", "number,title,labels,url,closedAt,createdAt,updatedAt"]),
      ghJson(["pr", "list", "--repo", repoSlug, "--state", "open", "--limit", "100", "--json", "number,title,url,headRefName,closingIssuesReferences"]).catch(() => []),
    ]);
  } catch (err) {
    error = { kind: err instanceof GhError ? err.kind : "other", message: String(err && err.message ? err.message : err) };
  }

  const claims = (await readJsonSafe(join(mainCheckout, ".ralph", "state.json")))?.claims || {};
  const ledger = await readJsonSafe(join(mainCheckout, ".ralph", "orchestrator", "ledger.json"));
  const failedRunItems = discoverFailedRunItems(mainCheckout);
  const state = computePipelineState({
    repo,
    openIssues,
    closedIssues,
    claims,
    openPrs,
    failedRunItems,
    ledger,
  });
  return { ...state, error };
}

async function cachedState(entry, slug) {
  const repo = entry.repos.find((item) => item.slug === slug) || entry.repos[0];
  if (!repo) throw new Error("no repo configured");
  const hit = entry.cache.get(repo.slug);
  const now = Date.now();
  if (hit && now - hit.at < STATE_TTL_MS) return hit.state;
  const state = await computeState(repo);
  entry.cache.set(repo.slug, { at: now, state });
  return state;
}

function pushRefresh(entry) {
  for (const response of entry.clients) {
    try {
      response.write("data: refresh\n\n");
    } catch {
      // Dropped SSE clients are cleaned up by close handlers.
    }
  }
}

function watchPath(entry, path) {
  try {
    const watcher = watch(path, { persistent: false }, () => {
      entry.cache.clear();
      pushRefresh(entry);
    });
    watcher.on("error", () => {});
    entry.watchers.push(watcher);
  } catch {
    // Some repos will not have all runtime files yet.
  }
}

function setupWatchers(entry) {
  for (const repo of entry.repos) {
    watchPath(entry, join(repo.mainCheckout, ".ralph", "state.json"));
    watchPath(entry, join(repo.mainCheckout, ".ralph", "orchestrator", "ledger.json"));
    watchPath(entry, join(repo.mainCheckout, ".ralph", "runs"));
  }
}

async function startServer(repos) {
  const entry = { repos, cache: new Map(), clients: new Set(), watchers: [] };
  const server = createServer(async (req, res) => {
    const url = new URL(req.url || "/", "http://127.0.0.1");
    const slug = url.searchParams.get("repo") || repos[0]?.slug || "";

    if (url.pathname === "/repos") {
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify(entry.repos.map((repo) => ({ slug: repo.slug, label: repo.label }))));
      return;
    }

    if (url.pathname === "/state" || (url.pathname === "/refresh" && req.method === "POST")) {
      if (url.pathname === "/refresh") entry.cache.delete(slug);
      try {
        const state = await cachedState(entry, slug);
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(state));
      } catch (err) {
        res.statusCode = 500;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ error: { kind: "other", message: String(err && err.message ? err.message : err) } }));
      }
      return;
    }

    if (url.pathname === "/events") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
      res.write("retry: 5000\n\n");
      entry.clients.add(res);
      req.on("close", () => entry.clients.delete(res));
      return;
    }

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(renderHtml());
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  entry.server = server;
  entry.url = `http://127.0.0.1:${port}/`;
  setupWatchers(entry);
  return entry;
}

const session = await joinSession({
  canvases: [
    createCanvas({
      id: "ralph-pipeline",
      displayName: "Ralph Pipeline",
      description:
        "Live read-only view of the Ralph orchestrator pipeline across orchestrated repos: failed work needing attention, running workers, queue, deferred work, and recent results.",
      inputSchema: {
        type: "object",
        properties: {
          repoSlug: { type: "string", description: "owner/name; pins the panel to a single repo. Omit to auto-discover all orchestrated repos under ~/Code." },
          mainCheckout: { type: "string", description: "absolute path to the main checkout holding .ralph/ (only used with repoSlug)" },
        },
      },
      actions: [
        {
          name: "refresh",
          description: "Recompute and return the current Ralph pipeline state for a repo; also nudges the open panel to re-render.",
          inputSchema: {
            type: "object",
            properties: { repoSlug: { type: "string", description: "which repo to recompute; defaults to the primary repo" } },
          },
          handler: async (ctx) => {
            const entry = servers.get(ctx.instanceId);
            if (!entry) throw new Error("canvas instance not open");
            const slug = ctx.input?.repoSlug || entry.repos[0]?.slug || "";
            entry.cache.delete(slug);
            const state = await cachedState(entry, slug);
            pushRefresh(entry);
            return state;
          },
        },
      ],
      open: async (ctx) => {
        let entry = servers.get(ctx.instanceId);
        if (!entry) {
          const repos = await resolveRepos(ctx.input || {});
          if (!repos.length) logSafe("ralph-pipeline: no orchestrated repos resolved", "warn");
          entry = await startServer(repos);
          servers.set(ctx.instanceId, entry);
        }
        const primary = entry.repos[0];
        return {
          title: "Ralph Pipeline",
          url: entry.url,
          status: entry.repos.length > 1 ? `${entry.repos.length} repos` : primary ? primary.slug : "",
        };
      },
      onClose: async (ctx) => {
        const entry = servers.get(ctx.instanceId);
        if (!entry) return;
        servers.delete(ctx.instanceId);
        for (const watcher of entry.watchers) {
          try {
            watcher.close();
          } catch {}
        }
        for (const response of entry.clients) {
          try {
            response.end();
          } catch {}
        }
        await new Promise((resolve) => entry.server.close(() => resolve()));
      },
    }),
  ],
});

SESSION = session;
WORKSPACE = session.workspacePath;
