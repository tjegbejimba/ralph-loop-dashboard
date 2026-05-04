// Unit tests for user config persistence.
// Run via `node --test test/user-config.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadUserConfig, saveUserConfig, addRecentQuery, getPresets } from "../extension/lib/user-config.mjs";

function makeTempDir() {
  return mkdtempSync(join(tmpdir(), "ralph-test-"));
}

test("loadUserConfig — returns safe defaults when config file missing", () => {
  const tempDir = makeTempDir();
  
  try {
    const result = loadUserConfig({ configDir: tempDir });
    
    assert.equal(result.config.defaultRepoRoot, null);
    assert.equal(result.config.defaultIssueSearch, null);
    assert.equal(result.config.defaultModel, null);
    assert.equal(result.config.defaultParallelism, null);
    assert.deepEqual(result.config.recentQueries, []);
    assert.deepEqual(result.warnings, []);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("loadUserConfig — loads valid config from file", () => {
  const tempDir = makeTempDir();
  const configPath = join(tempDir, "config.json");
  
  const testConfig = {
    defaultRepoRoot: "/home/user/projects/repo",
    defaultIssueSearch: "is:open label:enhancement",
    defaultModel: "claude-sonnet-4.5",
    defaultParallelism: 2,
    recentQueries: ["is:open milestone:v1", "is:open author:@me"],
  };
  
  writeFileSync(configPath, JSON.stringify(testConfig, null, 2), "utf8");
  
  try {
    const result = loadUserConfig({ configDir: tempDir });
    
    assert.equal(result.config.defaultRepoRoot, "/home/user/projects/repo");
    assert.equal(result.config.defaultIssueSearch, "is:open label:enhancement");
    assert.equal(result.config.defaultModel, "claude-sonnet-4.5");
    assert.equal(result.config.defaultParallelism, 2);
    assert.deepEqual(result.config.recentQueries, [
      "is:open milestone:v1",
      "is:open author:@me",
    ]);
    assert.deepEqual(result.warnings, []);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("loadUserConfig — merges partial config with defaults", () => {
  const tempDir = makeTempDir();
  const configPath = join(tempDir, "config.json");
  
  // Only set some fields
  const partialConfig = {
    defaultModel: "gpt-5.4",
    recentQueries: ["is:open"],
  };
  
  writeFileSync(configPath, JSON.stringify(partialConfig, null, 2), "utf8");
  
  try {
    const result = loadUserConfig({ configDir: tempDir });
    
    // Explicitly set fields use loaded values
    assert.equal(result.config.defaultModel, "gpt-5.4");
    assert.deepEqual(result.config.recentQueries, ["is:open"]);
    
    // Missing fields use defaults
    assert.equal(result.config.defaultRepoRoot, null);
    assert.equal(result.config.defaultIssueSearch, null);
    assert.equal(result.config.defaultParallelism, null);
    
    assert.deepEqual(result.warnings, []);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("loadUserConfig — returns warnings for unknown fields (potential secrets)", () => {
  const tempDir = makeTempDir();
  const configPath = join(tempDir, "config.json");
  
  const configWithUnknown = {
    defaultModel: "gpt-5.4",
    githubToken: "ghp_secret123",
    apiKey: "sk-secret456",
  };
  
  writeFileSync(configPath, JSON.stringify(configWithUnknown, null, 2), "utf8");
  
  try {
    const result = loadUserConfig({ configDir: tempDir });
    
    // Valid field is loaded
    assert.equal(result.config.defaultModel, "gpt-5.4");
    
    // Unknown fields are NOT in config
    assert.equal(result.config.githubToken, undefined);
    assert.equal(result.config.apiKey, undefined);
    
    // Warnings are returned
    assert.equal(result.warnings.length, 2);
    assert.ok(result.warnings.some(w => w.field === "githubToken"));
    assert.ok(result.warnings.some(w => w.field === "apiKey"));
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("saveUserConfig — writes config atomically with temp file", async () => {
  const tempDir = makeTempDir();
  const configPath = join(tempDir, "config.json");
  
  const newConfig = {
    defaultRepoRoot: "/home/user/newrepo",
    defaultModel: "claude-opus-4.7",
    defaultParallelism: 4,
  };
  
  try {
    const result = await saveUserConfig(newConfig, { configDir: tempDir });
    
    assert.deepEqual(result.warnings, []);
    
    // Config file should exist
    assert.ok(existsSync(configPath));
    
    // Read it back and verify
    const saved = JSON.parse(readFileSync(configPath, "utf8"));
    assert.equal(saved.defaultRepoRoot, "/home/user/newrepo");
    assert.equal(saved.defaultModel, "claude-opus-4.7");
    assert.equal(saved.defaultParallelism, 4);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("saveUserConfig — creates config directory if missing", async () => {
  const tempRoot = makeTempDir();
  const configDir = join(tempRoot, "subdir", "config");
  const configPath = join(configDir, "config.json");
  
  const newConfig = { defaultModel: "gpt-5.5" };
  
  try {
    const result = await saveUserConfig(newConfig, { configDir });
    
    assert.deepEqual(result.warnings, []);
    assert.ok(existsSync(configPath));
    
    const saved = JSON.parse(readFileSync(configPath, "utf8"));
    assert.equal(saved.defaultModel, "gpt-5.5");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("saveUserConfig — rejects unknown fields with warnings", async () => {
  const tempDir = makeTempDir();
  
  const configWithSecrets = {
    defaultModel: "gpt-5.4",
    githubToken: "ghp_secret",
    password: "hunter2",
  };
  
  try {
    const result = await saveUserConfig(configWithSecrets, { configDir: tempDir });
    
    // Should have warnings for unknown fields
    assert.equal(result.warnings.length, 2);
    assert.ok(result.warnings.some(w => w.field === "githubToken"));
    assert.ok(result.warnings.some(w => w.field === "password"));
    
    // Config file should only contain valid field
    const configPath = join(tempDir, "config.json");
    const saved = JSON.parse(readFileSync(configPath, "utf8"));
    assert.equal(saved.defaultModel, "gpt-5.4");
    assert.equal(saved.githubToken, undefined);
    assert.equal(saved.password, undefined);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});


test("addRecentQuery — adds query to front of list", () => {
  const tempDir = makeTempDir();
  
  try {
    // Add first query
    addRecentQuery("is:open label:bug", { configDir: tempDir });
    
    // Add second query
    const result = addRecentQuery("is:open milestone:v1", { configDir: tempDir });
    
    // Second query should be at front
    assert.deepEqual(result.config.recentQueries, [
      "is:open milestone:v1",
      "is:open label:bug",
    ]);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("addRecentQuery — deduplicates existing queries", () => {
  const tempDir = makeTempDir();
  
  try {
    // Add three queries
    addRecentQuery("query A", { configDir: tempDir });
    addRecentQuery("query B", { configDir: tempDir });
    addRecentQuery("query C", { configDir: tempDir });
    
    // Re-add query B (should move to front, not duplicate)
    const result = addRecentQuery("query B", { configDir: tempDir });
    
    assert.deepEqual(result.config.recentQueries, [
      "query B",
      "query C",
      "query A",
    ]);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("addRecentQuery — limits to maxRecent", () => {
  const tempDir = makeTempDir();
  
  try {
    // Add 5 queries with limit of 3
    for (let i = 1; i <= 5; i++) {
      addRecentQuery(`query ${i}`, { configDir: tempDir, maxRecent: 3 });
    }
    
    const { config } = loadUserConfig({ configDir: tempDir });
    
    // Should only keep last 3
    assert.equal(config.recentQueries.length, 3);
    assert.deepEqual(config.recentQueries, ["query 5", "query 4", "query 3"]);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("getPresets — returns Slice N preset and recent queries", () => {
  const tempDir = makeTempDir();
  
  try {
    // Add some recent queries
    addRecentQuery("is:open author:@me", { configDir: tempDir });
    addRecentQuery("is:open label:bug", { configDir: tempDir });
    
    const { presets } = getPresets({ configDir: tempDir });
    
    // Should have Slice N + 2 recent
    assert.equal(presets.length, 3);
    
    // First preset is Slice N
    assert.equal(presets[0].label, "Slice N (numbered issues)");
    assert.ok(presets[0].query);
    
    // Then recent queries
    assert.equal(presets[1].label, "is:open label:bug");
    assert.equal(presets[1].query, "is:open label:bug");
    assert.equal(presets[2].label, "is:open author:@me");
    assert.equal(presets[2].query, "is:open author:@me");
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("getPresets — truncates long query labels", () => {
  const tempDir = makeTempDir();
  
  const longQuery = "is:open " + "label:enhancement ".repeat(10);
  
  try {
    addRecentQuery(longQuery, { configDir: tempDir });
    
    const { presets } = getPresets({ configDir: tempDir });
    
    // Recent query label should be truncated
    const recentPreset = presets.find(p => p.query === longQuery);
    assert.ok(recentPreset);
    assert.ok(recentPreset.label.length <= 50);
    assert.ok(recentPreset.label.endsWith("..."));
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});
