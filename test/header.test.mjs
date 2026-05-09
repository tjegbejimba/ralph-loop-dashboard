import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  parsePrdReference,
  extractRepo,
  buildHeaderText,
  fetchPrdTitle,
  clearPrdTitleCache,
} from "../extension/lib/header.mjs";

// ─── parsePrdReference ────────────────────────────────────────────────────────

test("parsePrdReference returns null when repoRoot is falsy", () => {
  assert.equal(parsePrdReference(null), null);
  assert.equal(parsePrdReference(""), null);
  assert.equal(parsePrdReference(undefined), null);
});

test("parsePrdReference returns null when .ralph/RALPH.md does not exist", () => {
  const tmp = mkdtempSync(join(tmpdir(), "ralph-header-"));
  try {
    assert.equal(parsePrdReference(tmp), null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("parsePrdReference parses PRD reference from marker", () => {
  const tmp = mkdtempSync(join(tmpdir(), "ralph-header-"));
  try {
    mkdirSync(join(tmp, ".ralph"), { recursive: true });
    writeFileSync(
      join(tmp, ".ralph", "RALPH.md"),
      "<!-- RALPH_PRD_REF: #7 -->\n# Prompt\n",
    );
    assert.equal(parsePrdReference(tmp), "#7");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("parsePrdReference returns null for unset {{PRD_REFERENCE}} placeholder", () => {
  const tmp = mkdtempSync(join(tmpdir(), "ralph-header-"));
  try {
    mkdirSync(join(tmp, ".ralph"), { recursive: true });
    writeFileSync(
      join(tmp, ".ralph", "RALPH.md"),
      "<!-- RALPH_PRD_REF: {{PRD_REFERENCE}} -->\n# Prompt\n",
    );
    assert.equal(parsePrdReference(tmp), null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("parsePrdReference tolerates extra whitespace in marker", () => {
  const tmp = mkdtempSync(join(tmpdir(), "ralph-header-"));
  try {
    mkdirSync(join(tmp, ".ralph"), { recursive: true });
    writeFileSync(
      join(tmp, ".ralph", "RALPH.md"),
      "<!--  RALPH_PRD_REF:  #42  -->\n",
    );
    assert.equal(parsePrdReference(tmp), "#42");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

// ─── extractRepo ─────────────────────────────────────────────────────────────

test("extractRepo returns null for falsy input", () => {
  assert.equal(extractRepo(null), null);
  assert.equal(extractRepo(""), null);
  assert.equal(extractRepo(undefined), null);
});

test("extractRepo parses owner/repo from issueSearch", () => {
  assert.equal(
    extractRepo("repo:tjegbejimba/ralph-loop-dashboard is:issue is:open"),
    "tjegbejimba/ralph-loop-dashboard",
  );
});

test("extractRepo returns null when no repo: prefix", () => {
  assert.equal(extractRepo("is:issue is:open Slice in:title"), null);
});

// ─── buildHeaderText ─────────────────────────────────────────────────────────

test("buildHeaderText returns bare title when neither prdReference nor repo", () => {
  assert.equal(buildHeaderText({}), "Ralph Loop");
  assert.equal(buildHeaderText({ repo: null, prdReference: null, prdTitle: null }), "Ralph Loop");
});

test("buildHeaderText returns repo line when no prdReference", () => {
  assert.equal(
    buildHeaderText({ repo: "owner/repo", prdReference: null }),
    "Ralph Loop — owner/repo",
  );
});

test("buildHeaderText returns PRD line without title on fetch failure", () => {
  assert.equal(
    buildHeaderText({ repo: "owner/repo", prdReference: "#7", prdTitle: null }),
    "Ralph Loop — PRD #7",
  );
});

test("buildHeaderText returns full PRD line with title", () => {
  assert.equal(
    buildHeaderText({ repo: "owner/repo", prdReference: "#7", prdTitle: "My PRD" }),
    "Ralph Loop — PRD #7: My PRD",
  );
});

test("buildHeaderText shows PRD even when repo is absent", () => {
  assert.equal(
    buildHeaderText({ repo: null, prdReference: "#7", prdTitle: null }),
    "Ralph Loop — PRD #7",
  );
});

// ─── fetchPrdTitle ────────────────────────────────────────────────────────────

test("fetchPrdTitle returns title from ghJsonFn on success", async () => {
  clearPrdTitleCache();
  const stub = async (_args) => ({ title: "Awesome PRD" });
  const result = await fetchPrdTitle("owner/repo", "#7", { ghJsonFn: stub });
  assert.equal(result, "Awesome PRD");
});

test("fetchPrdTitle returns null when ghJsonFn fails", async () => {
  clearPrdTitleCache();
  const stub = async (_args) => ({ error: "not found" });
  const result = await fetchPrdTitle("owner/repo", "#99", { ghJsonFn: stub });
  assert.equal(result, null);
});

test("fetchPrdTitle caches success results", async () => {
  clearPrdTitleCache();
  let callCount = 0;
  const stub = async (_args) => { callCount++; return { title: "Cached Title" }; };
  await fetchPrdTitle("owner/repo", "#5", { ghJsonFn: stub });
  await fetchPrdTitle("owner/repo", "#5", { ghJsonFn: stub });
  assert.equal(callCount, 1, "gh should only be called once");
});

test("fetchPrdTitle caches null (failure) results to avoid repeated calls", async () => {
  clearPrdTitleCache();
  let callCount = 0;
  const stub = async (_args) => { callCount++; return { error: "boom" }; };
  await fetchPrdTitle("owner/repo", "#6", { ghJsonFn: stub });
  await fetchPrdTitle("owner/repo", "#6", { ghJsonFn: stub });
  assert.equal(callCount, 1, "failing gh call should only happen once");
});

test("fetchPrdTitle returns null when prdReference is falsy", async () => {
  clearPrdTitleCache();
  const stub = async (_args) => ({ title: "Unreachable" });
  assert.equal(await fetchPrdTitle("owner/repo", null, { ghJsonFn: stub }), null);
  assert.equal(await fetchPrdTitle("owner/repo", "", { ghJsonFn: stub }), null);
});

test("fetchPrdTitle skips gh call when repo is absent and returns null", async () => {
  clearPrdTitleCache();
  let called = false;
  const stub = async (_args) => { called = true; return { title: "X" }; };
  const result = await fetchPrdTitle(null, "#7", { ghJsonFn: stub });
  assert.equal(result, null);
  assert.equal(called, false, "gh should not be called without a repo");
});
