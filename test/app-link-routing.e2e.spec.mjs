// test/app-link-routing.e2e.spec.mjs
// Playwright E2E test for app-level GitHub link routing
import { test, expect } from "@playwright/test";
import { createServer } from "node:http";
import { readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONTENT_DIR = resolve(__dirname, "..", "extension", "content");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
};

function startServer() {
  const server = createServer((req, res) => {
    if (req.url === "/__bridge.js") {
      res.writeHead(200, { "Content-Type": MIME[".js"] });
      res.end("// stubbed bridge\n");
      return;
    }
    const url = req.url === "/" ? "/index.html" : req.url.split("?")[0];
    const filePath = join(CONTENT_DIR, url);
    try {
      statSync(filePath);
      const ext = url.slice(url.lastIndexOf("."));
      res.writeHead(200, { "Content-Type": MIME[ext] || "text/plain" });
      res.end(readFileSync(filePath));
    } catch {
      res.writeHead(404);
      res.end("not found");
    }
  });
  return new Promise((resolveFn) => {
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      resolveFn({ server, baseUrl: `http://127.0.0.1:${port}` });
    });
  });
}

let baseUrl;
let server;

test.beforeAll(async () => {
  ({ server, baseUrl } = await startServer());
});

test.afterAll(async () => {
  await new Promise((r) => server.close(r));
});

// Load dashboard with a stub copilot bridge
async function loadDashboard(page, copilotMock = {}) {
  await page.addInitScript((mockJson) => {
    const mock = JSON.parse(mockJson);
    window.copilot = {
      getStatus: () =>
        Promise.resolve({
          timestamp: new Date().toISOString(),
          loopRunning: false,
          workers: [],
          queue: [],
          prs: [],
          iterationHistory: { iterations: [], stats: null },
          config: { repoState: { state: "resolved" } },
        }),
      ...mock,
    };
  }, JSON.stringify(copilotMock));
  await page.goto(baseUrl);
  await page.waitForFunction(
    () => document.getElementById("last-updated").textContent !== "—",
  );
}

test.describe("App-level GitHub link routing", () => {
  test("clicking GitHub PR link calls openGitHubResource", async ({ page }) => {
    await page.addInitScript(() => {
      window.copilot = {
        getStatus: () =>
          Promise.resolve({
            timestamp: new Date().toISOString(),
            loopRunning: false,
            workers: [],
            queue: [],
            prs: [],
            iterationHistory: { iterations: [], stats: null },
            config: { repoState: { state: "resolved" } },
          }),
        openGitHubResource: async (resource) => {
          window.__resourceCalls = window.__resourceCalls || [];
          window.__resourceCalls.push(resource);
          return { ok: true };
        },
      };
    });
    
    await page.goto(baseUrl);
    await page.waitForFunction(
      () => document.getElementById("last-updated").textContent !== "—",
    );
    
    // Inject a test link into the page
    await page.evaluate(() => {
      const link = document.createElement("a");
      link.href = "https://github.com/owner/repo/pull/42";
      link.id = "test-pr-link";
      link.textContent = "PR #42";
      document.body.appendChild(link);
    });
    
    // Click the PR link
    await page.click("#test-pr-link");
    
    // Wait for the async handler
    await page.waitForTimeout(300);
    
    // Verify openGitHubResource was called with correct parameters
    const calls = await page.evaluate(() => window.__resourceCalls || []);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual({
      owner: "owner",
      repo: "repo",
      type: "pr",
      number: 42,
    });
  });

  test("clicking GitHub issue link calls openGitHubResource", async ({ page }) => {
    await page.addInitScript(() => {
      window.copilot = {
        getStatus: () =>
          Promise.resolve({
            timestamp: new Date().toISOString(),
            loopRunning: false,
            workers: [],
            queue: [],
            prs: [],
            iterationHistory: { iterations: [], stats: null },
            config: { repoState: { state: "resolved" } },
          }),
        openGitHubResource: async (resource) => {
          window.__resourceCalls = window.__resourceCalls || [];
          window.__resourceCalls.push(resource);
          return { ok: true };
        },
      };
    });
    
    await page.goto(baseUrl);
    await page.waitForFunction(
      () => document.getElementById("last-updated").textContent !== "—",
    );
    
    await page.evaluate(() => {
      const link = document.createElement("a");
      link.href = "https://github.com/tj/ralph/issues/123";
      link.id = "test-issue-link";
      link.textContent = "Issue #123";
      document.body.appendChild(link);
    });
    
    await page.click("#test-issue-link");
    await page.waitForTimeout(300);
    
    const calls = await page.evaluate(() => window.__resourceCalls || []);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual({
      owner: "tj",
      repo: "ralph",
      type: "issue",
      number: 123,
    });
  });

  test("non-GitHub links are not intercepted", async ({ page }) => {
    await loadDashboard(page, {
      openGitHubResource: () => {
        window.__resourceCalls = window.__resourceCalls || [];
        window.__resourceCalls.push("should-not-be-called");
        return Promise.resolve({ ok: true });
      },
    });
    
    await page.evaluate(() => {
      const link = document.createElement("a");
      link.href = "https://example.com";
      link.id = "test-external-link";
      link.textContent = "Example";
      document.body.appendChild(link);
    });
    
    // This should not call openGitHubResource (non-GitHub URL)
    await page.click("#test-external-link");
    await page.waitForTimeout(300);
    
    const calls = await page.evaluate(() => window.__resourceCalls || []);
    expect(calls).toHaveLength(0);
  });

  test("fallback to window.open when copilot bridge unavailable", async ({ page }) => {
    // Load dashboard without openGitHubResource in the mock
    await loadDashboard(page, {});
    
    // Mock window.open
    await page.evaluate(() => {
      const originalOpen = window.open;
      window.open = (...args) => {
        window.__windowOpenCalled = true;
        window.__windowOpenArgs = args;
        return null;
      };
    });
    
    await page.evaluate(() => {
      const link = document.createElement("a");
      link.href = "https://github.com/owner/repo/pull/99";
      link.id = "test-fallback-link";
      link.textContent = "PR #99";
      document.body.appendChild(link);
    });
    
    await page.click("#test-fallback-link");
    await page.waitForTimeout(300);
    
    // Verify window.open was called with the GitHub URL
    const called = await page.evaluate(() => window.__windowOpenCalled);
    const args = await page.evaluate(() => window.__windowOpenArgs);
    
    expect(called).toBe(true);
    expect(args[0]).toBe("https://github.com/owner/repo/pull/99");
    expect(args[1]).toBe("_blank");
  });
});

