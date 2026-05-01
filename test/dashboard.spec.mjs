// Minimal harness: serve extension/content/ over a localhost HTTP server,
// inject a stub `window.copilot` so main.js can drive the UI without the
// real webview bridge, and assert against the rendered DOM.

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
    // Stub the webview bridge — page expects /__bridge.js to define `copilot`.
    // Tests inject their own via addInitScript, so just return empty JS.
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

// Inject a stub `window.copilot` that returns the given status object.
async function loadDashboard(page, status) {
  await page.addInitScript((statusJson) => {
    const status = JSON.parse(statusJson);
    window.copilot = {
      getStatus: () => Promise.resolve(status),
      startLoop: () => Promise.resolve({ ok: true }),
      stopLoop: () => Promise.resolve({ ok: true }),
      getPrDetail: () => Promise.resolve(null),
      getIssueDetail: () => Promise.resolve(null),
    };
  }, JSON.stringify(status));
  await page.goto(baseUrl);
  // main.js fires refresh() on load asynchronously; wait for it to settle.
  await page.waitForFunction(
    () => document.getElementById("last-updated").textContent !== "—",
  );
}

function makeWorker({ workerId, issue, logFile, stage = "starting" }) {
  return {
    issue,
    workerId,
    startedAt: new Date(Date.now() - 60_000).toISOString(),
    logFile,
    tail: `[stage] ${stage}\nworking on #${issue}`,
    stage: { stage, label: stage, icon: "○" },
    reviewStats: null,
    tokens: null,
    lastWriteAt: new Date(Date.now() - 5_000).toISOString(),
    ageSec: 5,
    stuck: false,
    currentPr: null,
  };
}

const baseStatus = {
  timestamp: new Date().toISOString(),
  loopRunning: true,
  workers: [],
  currentIteration: null,
  currentPr: null,
  recentPrs: [],
  iterationHistory: { iterations: [], stats: null },
  queue: [],
  cumulative: null,
};

test("renders 'no active workers' placeholder when workers[] is empty", async ({
  page,
}) => {
  await loadDashboard(page, { ...baseStatus, workers: [] });
  const container = page.locator("#workers-container");
  await expect(container).toContainText("no active workers");
  await expect(page.locator("#workers-count")).toHaveText("—");
  await expect(page.locator(".worker-card")).toHaveCount(0);
});

test("renders one worker card in single-worker mode", async ({ page }) => {
  const w = makeWorker({
    workerId: 1,
    issue: 125,
    logFile: "iter-20260426-140000-w1-issue-125.log",
    stage: "reviewing",
  });
  await loadDashboard(page, {
    ...baseStatus,
    workers: [w],
    currentIteration: w,
  });
  await expect(page.locator(".worker-card")).toHaveCount(1);
  await expect(page.locator("#workers-count")).toHaveText("1 active");
  await expect(page.locator(".worker-card")).toContainText("#125");
  await expect(page.locator(".worker-card .worker-pill")).toHaveText(
    /worker 1/,
  );
  // Single-worker mode should NOT switch to grid layout.
  await expect(page.locator("#workers-container")).not.toHaveClass(/multi/);
});

test("renders two worker cards in parallel mode and uses grid layout", async ({
  page,
}) => {
  const w1 = makeWorker({
    workerId: 1,
    issue: 125,
    logFile: "iter-20260426-140000-w1-issue-125.log",
    stage: "reviewing",
  });
  const w2 = makeWorker({
    workerId: 2,
    issue: 127,
    logFile: "iter-20260426-140100-w2-issue-127.log",
    stage: "writing tests",
  });
  await loadDashboard(page, {
    ...baseStatus,
    workers: [w1, w2],
    currentIteration: w1,
  });
  const cards = page.locator(".worker-card");
  await expect(cards).toHaveCount(2);
  await expect(page.locator("#workers-count")).toHaveText("2 active");
  await expect(cards.nth(0)).toContainText("#125");
  await expect(cards.nth(0)).toContainText("worker 1");
  await expect(cards.nth(1)).toContainText("#127");
  await expect(cards.nth(1)).toContainText("worker 2");
  // Grid layout class applied when 2+ workers active.
  await expect(page.locator("#workers-container")).toHaveClass(/multi/);
});

test("marks a stuck worker with the stuck class and warn pill", async ({
  page,
}) => {
  const stuckWorker = {
    ...makeWorker({
      workerId: 1,
      issue: 130,
      logFile: "iter-20260426-140000-w1-issue-130.log",
    }),
    stuck: true,
    ageSec: 600,
  };
  await loadDashboard(page, {
    ...baseStatus,
    workers: [stuckWorker],
    currentIteration: stuckWorker,
  });
  await expect(page.locator(".worker-card")).toHaveClass(/stuck/);
  await expect(page.locator(".worker-card .strip-item.warn")).toBeVisible();
});

test("history list shows worker pill (w1, w2) for parallel iterations", async ({
  page,
}) => {
  const status = {
    ...baseStatus,
    workers: [],
    iterationHistory: {
      iterations: [
        {
          issue: 125,
          workerId: 1,
          status: "merged",
          startedAt: new Date(Date.now() - 3_600_000).toISOString(),
          durationMs: 600_000,
          logFile: "iter-20260426-140000-w1-issue-125.log",
          prUrl: null,
        },
        {
          issue: 127,
          workerId: 2,
          status: "open",
          startedAt: new Date(Date.now() - 1_800_000).toISOString(),
          durationMs: 300_000,
          logFile: "iter-20260426-140100-w2-issue-127.log",
          prUrl: null,
        },
      ],
      stats: { last24h: 2, avgDurationMs: 450_000, total: 2 },
    },
  };
  await loadDashboard(page, status);
  const items = page.locator("#history-list li");
  await expect(items).toHaveCount(2);
  await expect(items.nth(0).locator(".worker-pill")).toHaveText("w1");
  await expect(items.nth(1).locator(".worker-pill")).toHaveText("w2");
});

test("escapes hostile worker fields (XSS defense)", async ({ page }) => {
  const hostile = {
    ...makeWorker({
      workerId: 1,
      issue: 999,
      logFile: "<script>alert(1)</script>.log",
    }),
    tail: '<img src=x onerror="alert(1)">',
    stage: { stage: "writing tests", label: "<b>danger</b>", icon: "<i>x</i>" },
  };
  let dialogFired = false;
  page.on("dialog", async (d) => {
    dialogFired = true;
    await d.dismiss();
  });
  await loadDashboard(page, {
    ...baseStatus,
    workers: [hostile],
    currentIteration: hostile,
  });
  // No JS executed via injected payloads.
  expect(dialogFired).toBe(false);
  // No raw <script>/<img> nodes injected from the hostile fields.
  const card = page.locator(".worker-card").first();
  await expect(card.locator("script")).toHaveCount(0);
  // Hostile log filename appears as text, not as markup.
  await expect(card.locator(".worker-card-log-meta")).toContainText(
    "<script>alert(1)</script>.log",
  );
  // Stage CSS class is slugified — "writing tests" -> "writing-tests".
  await expect(card.locator(".stage-badge")).toHaveClass(/stage-writing-tests/);
});

test("renders PR card inside worker card with check pills", async ({
  page,
}) => {
  const w = {
    ...makeWorker({
      workerId: 1,
      issue: 125,
      logFile: "iter-20260426-140000-w1-issue-125.log",
    }),
    currentPr: {
      number: 42,
      title: "Slice 38: fuzzy match",
      url: "https://github.com/x/y/pull/42",
      isDraft: false,
      additions: 120,
      deletions: 30,
      changedFiles: 5,
      commitCount: 3,
      reviewDecision: "APPROVED",
      checks: { total: 4, pass: 3, fail: 0, pending: 1 },
    },
  };
  await loadDashboard(page, {
    ...baseStatus,
    workers: [w],
    currentIteration: w,
    currentPr: w.currentPr,
  });
  const card = page.locator(".worker-card");
  await expect(card.locator(".pr-card-title")).toContainText("#42");
  await expect(card.locator(".pr-card-title")).toContainText(
    "Slice 38: fuzzy match",
  );
  await expect(card.locator(".pr-card-title")).toHaveAttribute(
    "rel",
    "noopener noreferrer",
  );
  await expect(card.locator(".check-pill.pending")).toContainText(
    "3✓ 0✗ 1○",
  );
  await expect(card.locator(".check-pill.pass")).toContainText("approved");
});

test("renders worker card for claim with no log file yet (starting state)", async ({
  page,
}) => {
  // 10 minutes ago — exceeds 300s stuck threshold.
  const startedAt = new Date(Date.now() - 600_000).toISOString();
  const claimNoLog = {
    issue: 200,
    workerId: 3,
    startedAt,
    logFile: "iter-pending-w3-issue-200.log",
    tail: "",
    stage: { stage: "starting", label: "starting", icon: "○" },
    reviewStats: null,
    tokens: null,
    lastWriteAt: null,
    ageSec: 600,
    stuck: true,
    currentPr: null,
  };
  await loadDashboard(page, {
    ...baseStatus,
    workers: [claimNoLog],
    currentIteration: claimNoLog,
  });
  const card = page.locator(".worker-card");
  await expect(card).toHaveClass(/stuck/);
  await expect(card).toContainText("#200");
  await expect(card.locator(".worker-pill")).toHaveText(/worker 3/);
});

test("legacy single-worker mode (no workerId) hides worker pill", async ({
  page,
}) => {
  const legacy = {
    ...makeWorker({
      workerId: null,
      issue: 50,
      logFile: "iter-20260426-140000-issue-50.log",
    }),
  };
  legacy.workerId = null;
  await loadDashboard(page, {
    ...baseStatus,
    workers: [legacy],
    currentIteration: legacy,
  });
  await expect(page.locator(".worker-card")).toHaveCount(1);
  await expect(page.locator(".worker-card .worker-pill")).toHaveCount(0);
  await expect(page.locator("#workers-container")).not.toHaveClass(/multi/);
});

// Drives a loopRunning true → false transition through the stubbed
// getStatus() and verifies the appropriate Notification fires.
async function runLoopDoneTest(page, { remainingSlices, expectedTitle, expectedBodyMatch }) {
  await page.addInitScript(() => {
    // Stub Notification so the page treats permission as granted and we can
    // observe constructor calls without provoking the real OS layer.
    window.__notifications = [];
    class FakeNotification {
      constructor(title, opts) {
        window.__notifications.push({ title, body: opts?.body || "" });
      }
      static permission = "granted";
      static requestPermission() {
        return Promise.resolve("granted");
      }
    }
    window.Notification = FakeNotification;

    // Mutable status: starts running, no slices remaining configured by test.
    window.__status = {
      timestamp: new Date().toISOString(),
      loopRunning: true,
      workers: [],
      currentIteration: null,
      currentPr: null,
      recentPrs: [],
      iterationHistory: { iterations: [], stats: null },
      queue: [],
      openSlices: [],
      cumulative: null,
    };
    window.copilot = {
      getStatus: () => Promise.resolve(window.__status),
      startLoop: () => Promise.resolve({ ok: true }),
      stopLoop: () => Promise.resolve({ ok: true }),
      getPrDetail: () => Promise.resolve(null),
      getIssueDetail: () => Promise.resolve(null),
    };
  });
  await page.goto(baseUrl);
  await page.waitForFunction(
    () => document.getElementById("last-updated").textContent !== "—",
  );

  // First render saw loopRunning=true; flip to false and trigger another render.
  await page.evaluate((slices) => {
    window.__status = {
      ...window.__status,
      loopRunning: false,
      openSlices: slices,
      timestamp: new Date().toISOString(),
    };
  }, remainingSlices);
  await page.locator("#refresh-btn").click();

  await expect
    .poll(async () => await page.evaluate(() => window.__notifications.length))
    .toBeGreaterThan(0);
  const notes = await page.evaluate(() => window.__notifications);
  const found = notes.find((n) => n.title === expectedTitle);
  expect(found, `expected notification title "${expectedTitle}", got ${JSON.stringify(notes)}`).toBeTruthy();
  expect(found.body).toMatch(expectedBodyMatch);
}

test("notifies '🎉 all workers done' when loop finishes with empty queue", async ({ page }) => {
  await runLoopDoneTest(page, {
    remainingSlices: [],
    expectedTitle: "Ralph: all workers done 🎉",
    expectedBodyMatch: /every slice merged/i,
  });
});

test("notifies 'loop stopped' when loop finishes with slices still in queue", async ({ page }) => {
  await runLoopDoneTest(page, {
    remainingSlices: [
      { number: 200, title: "Slice 5: foo", url: "https://example/200" },
      { number: 201, title: "Slice 6: bar", url: "https://example/201" },
    ],
    expectedTitle: "Ralph: loop stopped",
    expectedBodyMatch: /2 slices still in queue/i,
  });
});
