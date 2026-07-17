import { test, expect } from "@playwright/test";
import { createServer } from "node:http";

import { renderHtml } from "../extension-pipeline/renderer.mjs";

function pipelineState(promoted) {
  const card = {
    number: 42,
    title: "Fix empty queue",
    url: "https://github.com/tj/repo/issues/42",
    repoSlug: "tj/repo",
    priority: "priority:P2",
    workType: "work:standalone",
    state: promoted ? "ralph:ready" : "ralph:fast-lane",
    lane: promoted ? "REFINE" : "AUTO",
    ageDays: 0,
  };
  return {
    repoSlug: "tj/repo",
    failed: [],
    recoverable: [],
    running: [],
    ready: promoted ? [{ ...card, queued: true }] : [],
    deferred: [],
    awaiting: promoted ? [] : [card],
    held: [],
    needsTriage: [],
    recent: [],
    nextQueue: promoted ? [42] : [],
    queueCap: 3,
    lastTick: null,
  };
}

test("one-tap promotes an awaiting issue into the ready queue", async ({ page }) => {
  let promoted = false;
  let promotionRequests = 0;
  const server = createServer((req, res) => {
    const url = new URL(req.url || "/", "http://127.0.0.1");
    res.setHeader("Cache-Control", "no-store");
    if (url.pathname === "/repos") {
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify([{ slug: "tj/repo", label: "repo" }]));
      return;
    }
    if (url.pathname === "/state") {
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify(pipelineState(promoted)));
      return;
    }
    if (url.pathname === "/promote-ready" && req.method === "POST") {
      promotionRequests += 1;
      promoted = true;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify({ promoted: true, issueNumber: 42 }));
      return;
    }
    if (url.pathname === "/events") {
      res.statusCode = 204;
      res.end();
      return;
    }
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(renderHtml());
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));

  try {
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.getByRole("button", { name: "one-tap" }).click();

    await expect(page.locator('section[data-k="ready"] .card')).toContainText("#42");
    await expect(page.locator('section[data-k="awaiting"] .card')).toHaveCount(0);
    expect(promotionRequests).toBe(1);
    expect(page.url()).toMatch(/^http:\/\/127\.0\.0\.1:/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
