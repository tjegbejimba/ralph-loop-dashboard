// test/app-link-routing.test.mjs
// Unit tests for app-level GitHub link routing
import { describe, it } from "node:test";
import assert from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Extract parseGitHubUrl function from the dashboard client code
function loadClientFunction() {
  const mainJs = readFileSync(join(import.meta.dirname, "../extension/content/main.js"), "utf-8");
  
  // Extract the parseGitHubUrl function - handle multi-line definition
  const fnMatch = mainJs.match(/function parseGitHubUrl\(url\)\s*\{[\s\S]*?\n\}/);
  if (!fnMatch) {
    throw new Error("parseGitHubUrl function not found in main.js");
  }
  
  // Evaluate the function in an isolated context
  const fnCode = fnMatch[0];
  const fn = new Function(`return (${fnCode})`)();
  return fn;
}

describe("GitHub URL parsing", () => {
  let parseGitHubUrl;
  
  it("function exists in main.js", () => {
    parseGitHubUrl = loadClientFunction();
    assert.ok(typeof parseGitHubUrl === "function");
  });

  it("parses issue URLs correctly", () => {
    const result = parseGitHubUrl("https://github.com/owner/repo/issues/123");
    assert.deepStrictEqual(result, {
      owner: "owner",
      repo: "repo",
      type: "issue",
      number: 123,
    });
  });

  it("parses PR URLs correctly", () => {
    const result = parseGitHubUrl("https://github.com/tj/ralph-loop/pull/42");
    assert.deepStrictEqual(result, {
      owner: "tj",
      repo: "ralph-loop",
      type: "pr",
      number: 42,
    });
  });

  it("returns null for non-GitHub URLs", () => {
    const result = parseGitHubUrl("https://example.com/foo");
    assert.strictEqual(result, null);
  });

  it("returns null for malformed GitHub URLs", () => {
    const result = parseGitHubUrl("https://github.com/owner/repo/commits");
    assert.strictEqual(result, null);
  });

  it("handles http and https", () => {
    const http = parseGitHubUrl("http://github.com/o/r/issues/1");
    const https = parseGitHubUrl("https://github.com/o/r/issues/1");
    assert.deepStrictEqual(http, https);
  });
});
