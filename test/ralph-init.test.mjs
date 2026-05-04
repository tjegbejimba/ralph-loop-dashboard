// Unit tests for Ralph initialization service.
// Run via `node --test test/ralph-init.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, mkdirSync, existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { initializeRalph } from "../extension/lib/ralph-init.mjs";

function makeTempDir() {
  return mkdtempSync(join(tmpdir(), "ralph-init-test-"));
}

// Tracer bullet: creates .ralph/ directory
test("initializeRalph — creates .ralph/ directory when missing", () => {
  const tempRoot = makeTempDir();
  
  try {
    const result = initializeRalph(tempRoot);
    
    assert.equal(result.success, true);
    assert.equal(existsSync(join(tempRoot, ".ralph")), true);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("initializeRalph — creates RALPH.md from template", () => {
  const tempRoot = makeTempDir();
  
  try {
    const result = initializeRalph(tempRoot);
    
    assert.equal(result.success, true);
    assert.equal(existsSync(join(tempRoot, ".ralph", "RALPH.md")), true);
    
    const content = readFileSync(join(tempRoot, ".ralph", "RALPH.md"), "utf-8");
    assert.match(content, /# Ralph TDD Loop/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("initializeRalph — creates config.json with defaults", () => {
  const tempRoot = makeTempDir();
  
  try {
    const result = initializeRalph(tempRoot);
    
    assert.equal(result.success, true);
    assert.equal(existsSync(join(tempRoot, ".ralph", "config.json")), true);
    
    const config = JSON.parse(readFileSync(join(tempRoot, ".ralph", "config.json"), "utf-8"));
    assert.equal(config.profile, "generic");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("initializeRalph — copies shell scripts", () => {
  const tempRoot = makeTempDir();
  
  try {
    const result = initializeRalph(tempRoot);
    
    assert.equal(result.success, true);
    assert.equal(existsSync(join(tempRoot, ".ralph", "ralph.sh")), true);
    assert.equal(existsSync(join(tempRoot, ".ralph", "launch.sh")), true);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("initializeRalph — creates lib/ and profiles/ subdirectories", () => {
  const tempRoot = makeTempDir();
  
  try {
    const result = initializeRalph(tempRoot);
    
    assert.equal(result.success, true);
    assert.equal(existsSync(join(tempRoot, ".ralph", "lib")), true);
    assert.equal(existsSync(join(tempRoot, ".ralph", "profiles")), true);
    assert.equal(existsSync(join(tempRoot, ".ralph", "lib", "state.sh")), true);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("initializeRalph — adds .gitignore entries for runtime artifacts", () => {
  const tempRoot = makeTempDir();
  
  try {
    const result = initializeRalph(tempRoot);
    
    assert.equal(result.success, true);
    
    // Check .ralph/.gitignore exists
    const gitignorePath = join(tempRoot, ".ralph", ".gitignore");
    assert.equal(existsSync(gitignorePath), true);
    
    const gitignore = readFileSync(gitignorePath, "utf-8");
    assert.match(gitignore, /logs\//);
    assert.match(gitignore, /locks\//);
    assert.match(gitignore, /state\//);
    assert.match(gitignore, /runs\//);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("initializeRalph — does not overwrite existing files", () => {
  const tempRoot = makeTempDir();
  const ralphDir = join(tempRoot, ".ralph");
  mkdirSync(ralphDir, { recursive: true });
  
  // Pre-existing file
  const existingContent = "# Custom prompt";
  writeFileSync(join(ralphDir, "RALPH.md"), existingContent);
  
  try {
    const result = initializeRalph(tempRoot);
    
    assert.equal(result.success, true);
    assert.ok(result.skipped.includes(".ralph/RALPH.md"));
    
    // File should not be overwritten
    const content = readFileSync(join(ralphDir, "RALPH.md"), "utf-8");
    assert.equal(content, existingContent);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});
