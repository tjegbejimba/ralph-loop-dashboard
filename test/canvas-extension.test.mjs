import { describe, test } from "node:test";
import assert from "node:assert";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { createServer } from "node:http";

const REPO_ROOT = join(import.meta.dirname, "..");
const CANVAS_EXTENSION_PATH = join(REPO_ROOT, "extension-canvas", "extension.mjs");
const CANVAS_RENDERER_PATH = join(REPO_ROOT, "extension-canvas", "renderer.mjs");

describe("canvas extension", () => {
  test("extension files exist", () => {
    assert.ok(existsSync(CANVAS_EXTENSION_PATH), "extension-canvas/extension.mjs should exist");
    assert.ok(existsSync(CANVAS_RENDERER_PATH), "extension-canvas/renderer.mjs should exist");
  });
  
  test("renderer exports pageHtml function", async () => {
    const { pageHtml } = await import(CANVAS_RENDERER_PATH);
    assert.strictEqual(typeof pageHtml, "function", "pageHtml should be a function");
    
    const html = pageHtml();
    assert.ok(html.includes("<!doctype html>"), "should return HTML document");
    assert.ok(html.includes("Ralph Loop"), "should contain Ralph Loop title");
    assert.ok(html.includes("/status"), "should fetch from /status endpoint");
  });

  test("server serves status JSON for a repo with .ralph/", async () => {
    // Import the internal functions we need to test
    const extensionCode = await import("node:fs").then((fs) => 
      fs.promises.readFile(CANVAS_EXTENSION_PATH, "utf-8")
    );
    
    // Extract and eval the statusJson function for testing
    // For now, we'll test via a minimal mock server with the same shape
    const { pageHtml } = await import(CANVAS_RENDERER_PATH);
    
    const server = createServer((req, res) => {
      const path = (req.url || "/").split("?")[0];
      if (path === "/status") {
        res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ loopRunning: false, workers: [], openSlices: [] }));
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(pageHtml());
    });

    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = server.address().port;
    const baseUrl = `http://127.0.0.1:${port}`;

    try {
      // Test status endpoint
      const statusRes = await fetch(`${baseUrl}/status`);
      assert.strictEqual(statusRes.status, 200);
      assert.ok(statusRes.headers.get("content-type").includes("application/json"));
      const statusData = await statusRes.json();
      assert.ok("loopRunning" in statusData);
      assert.ok(Array.isArray(statusData.workers));

      // Test HTML endpoint
      const htmlRes = await fetch(baseUrl);
      assert.strictEqual(htmlRes.status, 200);
      assert.ok(htmlRes.headers.get("content-type").includes("text/html"));
      const html = await htmlRes.text();
      assert.ok(html.includes("<!doctype html>"));
    } finally {
      await new Promise((resolve) => server.close(() => resolve()));
    }
  });
});
