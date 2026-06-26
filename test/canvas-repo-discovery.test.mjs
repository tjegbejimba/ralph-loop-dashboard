// Unit tests for canvas repo discovery.
// Run via `node --test test/canvas-repo-discovery.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, utimesSync } from "node:fs";
import { join } from "node:path";
import { tmpdir, homedir } from "node:os";
import { discoverRepos, repoActivity } from "../extension-canvas/lib/repo-discovery.mjs";

function makeTempDir() {
  return mkdtempSync(join(tmpdir(), "ralph-canvas-test-"));
}

function makeOrchRepo(root, name, slug, withActivity = false) {
  const checkout = join(root, name);
  const ralphDir = join(checkout, ".ralph");
  const orchDir = join(ralphDir, "orchestrator");
  const cfgPath = join(ralphDir, "config.json");
  
  mkdirSync(orchDir, { recursive: true });
  writeFileSync(cfgPath, JSON.stringify({ repo: slug }), "utf8");
  
  if (withActivity) {
    const statePath = join(ralphDir, "state.json");
    writeFileSync(statePath, "{}", "utf8");
    return { checkout, statePath };
  }
  
  return { checkout };
}

test("discoverRepos — finds orchestrated repos in ~/Code", () => {
  const tempRoot = makeTempDir();
  
  try {
    // Create two orchestrated repos
    makeOrchRepo(tempRoot, "ralph-loop-dashboard", "tjegbejimba/ralph-loop-dashboard");
    makeOrchRepo(tempRoot, "pwa-auth-bridge", "tjegbejimba/pwa-auth-bridge");
    
    const repos = discoverRepos({ scanRoots: [tempRoot] });
    
    assert.equal(repos.length, 2);
    assert.ok(repos.some(r => r.slug === "tjegbejimba/ralph-loop-dashboard"));
    assert.ok(repos.some(r => r.slug === "tjegbejimba/pwa-auth-bridge"));
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("discoverRepos — ignores dirs without .ralph/orchestrator", () => {
  const tempRoot = makeTempDir();
  
  try {
    // Create a valid orchestrated repo
    makeOrchRepo(tempRoot, "valid-repo", "user/valid-repo");
    
    // Create dirs without orchestrator
    const noOrch = join(tempRoot, "no-orch");
    mkdirSync(join(noOrch, ".ralph"), { recursive: true });
    writeFileSync(join(noOrch, ".ralph", "config.json"), JSON.stringify({ repo: "user/no-orch" }), "utf8");
    
    const noRalph = join(tempRoot, "no-ralph");
    mkdirSync(noRalph);
    
    const repos = discoverRepos({ scanRoots: [tempRoot] });
    
    assert.equal(repos.length, 1);
    assert.equal(repos[0].slug, "user/valid-repo");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("discoverRepos — ignores dirs without config.json", () => {
  const tempRoot = makeTempDir();
  
  try {
    // Create a valid orchestrated repo
    makeOrchRepo(tempRoot, "valid-repo", "user/valid-repo");
    
    // Create dir with orchestrator but no config
    const noConfig = join(tempRoot, "no-config");
    mkdirSync(join(noConfig, ".ralph", "orchestrator"), { recursive: true });
    
    const repos = discoverRepos({ scanRoots: [tempRoot] });
    
    assert.equal(repos.length, 1);
    assert.equal(repos[0].slug, "user/valid-repo");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("discoverRepos — orders by most recent activity", () => {
  const tempRoot = makeTempDir();
  
  try {
    // Create repos with different activity times
    const { checkout: old, statePath: oldState } = makeOrchRepo(
      tempRoot,
      "old-repo",
      "user/old-repo",
      true
    );
    const { checkout: recent, statePath: recentState } = makeOrchRepo(
      tempRoot,
      "recent-repo",
      "user/recent-repo",
      true
    );
    
    // Set old repo to 1 hour ago
    const oneHourAgo = Date.now() - 3600 * 1000;
    utimesSync(oldState, oneHourAgo / 1000, oneHourAgo / 1000);
    
    // Set recent repo to now (already done by writeFileSync)
    
    const repos = discoverRepos({ scanRoots: [tempRoot] });
    
    assert.equal(repos.length, 2);
    // Most recent should be first
    assert.equal(repos[0].slug, "user/recent-repo");
    assert.equal(repos[1].slug, "user/old-repo");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("discoverRepos — dedupes by slug, prefers canonical checkout", () => {
  const tempRoot = makeTempDir();
  
  try {
    // Create canonical checkout (basename = repo name)
    makeOrchRepo(tempRoot, "ralph-loop-dashboard", "tjegbejimba/ralph-loop-dashboard");
    
    // Create worktree (basename != repo name)
    makeOrchRepo(tempRoot, "ralph-loop-dashboard-ralph", "tjegbejimba/ralph-loop-dashboard");
    
    const repos = discoverRepos({ scanRoots: [tempRoot] });
    
    // Should only have one entry
    assert.equal(repos.length, 1);
    assert.equal(repos[0].slug, "tjegbejimba/ralph-loop-dashboard");
    
    // Should prefer canonical
    assert.ok(repos[0].mainCheckout.endsWith("ralph-loop-dashboard"));
    assert.ok(!repos[0].mainCheckout.endsWith("-ralph"));
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("repoActivity — returns newest mtime of state.json or ledger.json", () => {
  const tempRoot = makeTempDir();
  
  try {
    const checkout = join(tempRoot, "test-repo");
    const ralphDir = join(checkout, ".ralph");
    const orchDir = join(ralphDir, "orchestrator");
    
    mkdirSync(orchDir, { recursive: true });
    
    const statePath = join(ralphDir, "state.json");
    const ledgerPath = join(orchDir, "ledger.json");
    
    // Write state.json with older time
    writeFileSync(statePath, "{}", "utf8");
    const oldTime = Date.now() - 7200 * 1000; // 2 hours ago
    utimesSync(statePath, oldTime / 1000, oldTime / 1000);
    
    // Write ledger.json with newer time (now)
    writeFileSync(ledgerPath, "{}", "utf8");
    
    const activity = repoActivity(checkout);
    
    // Should return ledger.json mtime (newer)
    const ledgerMtime = Math.floor(Date.now() / 1000) * 1000; // Round to second
    assert.ok(activity >= ledgerMtime - 2000); // Within 2 seconds tolerance
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("repoActivity — returns 0 if neither file exists", () => {
  const tempRoot = makeTempDir();
  
  try {
    const checkout = join(tempRoot, "empty-repo");
    mkdirSync(checkout);
    
    const activity = repoActivity(checkout);
    
    assert.equal(activity, 0);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("discoverRepos — returns empty array if scan roots don't exist", () => {
  const repos = discoverRepos({ scanRoots: ["/nonexistent/path/12345"] });
  
  assert.deepEqual(repos, []);
});

test("discoverRepos — handles invalid config.json gracefully", () => {
  const tempRoot = makeTempDir();
  
  try {
    // Create valid repo
    makeOrchRepo(tempRoot, "valid-repo", "user/valid-repo");
    
    // Create repo with invalid JSON
    const invalidRepo = join(tempRoot, "invalid-config");
    mkdirSync(join(invalidRepo, ".ralph", "orchestrator"), { recursive: true });
    writeFileSync(join(invalidRepo, ".ralph", "config.json"), "not json", "utf8");
    
    const repos = discoverRepos({ scanRoots: [tempRoot] });
    
    // Should only return valid repo
    assert.equal(repos.length, 1);
    assert.equal(repos[0].slug, "user/valid-repo");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("discoverRepos — handles config.json without repo field", () => {
  const tempRoot = makeTempDir();
  
  try {
    // Create valid repo
    makeOrchRepo(tempRoot, "valid-repo", "user/valid-repo");
    
    // Create repo with config missing repo field
    const noSlug = join(tempRoot, "no-slug");
    mkdirSync(join(noSlug, ".ralph", "orchestrator"), { recursive: true });
    writeFileSync(join(noSlug, ".ralph", "config.json"), JSON.stringify({ other: "field" }), "utf8");
    
    const repos = discoverRepos({ scanRoots: [tempRoot] });
    
    // Should only return valid repo
    assert.equal(repos.length, 1);
    assert.equal(repos[0].slug, "user/valid-repo");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("discoverRepos — defaults to ~/Code when no scanRoots provided", () => {
  // This test just verifies the default behavior works without error
  // The actual ~/Code may or may not have Ralph repos
  const repos = discoverRepos();
  
  // Should return an array (may be empty if no repos in ~/Code)
  assert.ok(Array.isArray(repos));
});
