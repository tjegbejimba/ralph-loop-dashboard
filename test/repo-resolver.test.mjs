// Unit tests for repo resolution logic.
// Run via `node --test test/repo-resolver.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolveRepoState } from "../extension/lib/repo-resolver.mjs";

function makeTempDir() {
  return mkdtempSync(join(tmpdir(), "ralph-test-"));
}

test("resolveRepoState — RALPH_REPO_ROOT env var takes precedence", () => {
  const tempRoot = makeTempDir();
  mkdirSync(join(tempRoot, ".ralph"));
  
  try {
    const result = resolveRepoState({
      env: { RALPH_REPO_ROOT: tempRoot },
      cwd: "/some/other/path",
      searchStart: "/another/path",
    });
    
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.hasRalph, true);
    assert.equal(result.source, "env");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — env override without .ralph/ shows missing setup", () => {
  const tempRoot = makeTempDir();
  
  try {
    const result = resolveRepoState({
      env: { RALPH_REPO_ROOT: tempRoot },
      cwd: "/some/other/path",
      searchStart: "/another/path",
    });
    
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.hasRalph, false);
    assert.equal(result.source, "env");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — CWD upward search finds .ralph/", () => {
  const tempRoot = makeTempDir();
  const nested = join(tempRoot, "src", "deep");
  mkdirSync(join(tempRoot, ".ralph"));
  mkdirSync(nested, { recursive: true });
  
  try {
    const result = resolveRepoState({
      env: {},
      cwd: nested,
      searchStart: nested,
    });
    
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.hasRalph, true);
    assert.equal(result.source, "cwd-ralph");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — CWD upward search finds .git/ when .ralph/ missing", () => {
  const tempRoot = makeTempDir();
  const nested = join(tempRoot, "packages", "app");
  mkdirSync(join(tempRoot, ".git"));
  mkdirSync(nested, { recursive: true });
  
  try {
    const result = resolveRepoState({
      env: {},
      cwd: nested,
      searchStart: nested,
    });
    
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.hasRalph, false);
    assert.equal(result.source, "cwd-git");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — unresolved when no markers found", () => {
  const tempRoot = makeTempDir();
  const nested = join(tempRoot, "random");
  mkdirSync(nested, { recursive: true });
  
  try {
    const result = resolveRepoState({
      env: {},
      cwd: nested,
      searchStart: nested,
    });
    
    assert.equal(result.state, "unresolved");
    assert.equal(result.repoRoot, null);
    assert.equal(result.hasRalph, false);
    assert.equal(result.source, "none");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — legacy searchStart fallback", () => {
  const tempRoot = makeTempDir();
  const legacyPath = join(tempRoot, ".github", "extensions", "ralph-dashboard");
  mkdirSync(join(tempRoot, ".ralph"));
  mkdirSync(legacyPath, { recursive: true });
  
  try {
    const result = resolveRepoState({
      env: {},
      cwd: "/some/unrelated/path",
      searchStart: legacyPath,
    });
    
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.hasRalph, true);
    assert.equal(result.source, "legacy");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — invalid env override falls through to CWD search", () => {
  const tempRoot = makeTempDir();
  mkdirSync(join(tempRoot, ".ralph"));
  
  try {
    const result = resolveRepoState({
      env: { RALPH_REPO_ROOT: "/nonexistent/path/that/does/not/exist" },
      cwd: tempRoot,
      searchStart: tempRoot,
    });
    
    // Should fall through to cwd search
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.source, "cwd-ralph");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — RALPH_REPO_ROOT pointing to a file falls through", () => {
  const tempRoot = makeTempDir();
  const tempFile = join(tempRoot, "somefile.txt");
  writeFileSync(tempFile, "not a directory");
  mkdirSync(join(tempRoot, ".ralph"));
  
  try {
    const result = resolveRepoState({
      env: { RALPH_REPO_ROOT: tempFile },
      cwd: tempRoot,
      searchStart: tempRoot,
    });
    
    // Should fall through to cwd search, not treat file as repo root
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.source, "cwd-ralph");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — .ralph as file (not directory) is ignored", () => {
  const tempRoot = makeTempDir();
  const nested = join(tempRoot, "src");
  mkdirSync(nested, { recursive: true });
  writeFileSync(join(tempRoot, ".ralph"), "not a directory");
  mkdirSync(join(tempRoot, ".git"));
  
  try {
    const result = resolveRepoState({
      env: {},
      cwd: nested,
      searchStart: nested,
    });
    
    // Should skip file .ralph and find .git instead
    assert.equal(result.state, "resolved");
    assert.equal(result.repoRoot, tempRoot);
    assert.equal(result.hasRalph, false);
    assert.equal(result.source, "cwd-git");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("resolveRepoState — .git as file (not directory) is ignored", () => {
  const tempRoot = makeTempDir();
  const nested = join(tempRoot, "workspace");
  mkdirSync(nested, { recursive: true });
  writeFileSync(join(tempRoot, ".git"), "gitdir: ../main/.git/worktrees/workspace");
  
  try {
    const result = resolveRepoState({
      env: {},
      cwd: nested,
      searchStart: nested,
    });
    
    // Should skip file .git and show unresolved
    assert.equal(result.state, "unresolved");
    assert.equal(result.repoRoot, null);
    assert.equal(result.hasRalph, false);
    assert.equal(result.source, "none");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});
