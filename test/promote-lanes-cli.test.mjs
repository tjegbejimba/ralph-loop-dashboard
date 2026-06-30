import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, mkdirSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { runPromoteLanes } from "../extension/lib/lane-promotion.mjs";

const CLI = join(import.meta.dirname, "..", "extension", "cli.mjs");

function writePromoteLanesGh(root, { issuesByRepo = {}, authStatusExit = 0, authorAssocExit = 0 } = {}) {
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  const log = join(root, "gh-repos.log");
  const editLog = join(root, "gh-edits.log");
  const gh = join(bin, "gh");
  writeFileSync(gh, `#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
const issuesByRepo = ${JSON.stringify(issuesByRepo)};
if (args[0] === "auth" && args[1] === "status") {
  if (${authStatusExit} !== 0) { process.stderr.write("not authenticated"); process.exit(${authStatusExit}); }
  process.stdout.write("Logged in to github.com");
} else if (args[0] === "api" && args[1] === "user") {
  process.stdout.write("octocat\\n");
} else if (args[0] === "api" && args[1] === "graphql") {
  process.stdout.write(JSON.stringify({ data: { viewer: { login: "octocat" }, rateLimit: { remaining: 5000 } } }));
} else if (args[0] === "issue" && args[1] === "list") {
  const repoIdx = args.indexOf("--repo");
  const repo = repoIdx >= 0 ? args[repoIdx + 1] : "?";
  const limitIdx = args.indexOf("--limit");
  const isProbe = limitIdx >= 0 && args[limitIdx + 1] === "1";
  if (!isProbe) fs.appendFileSync(${JSON.stringify(log)}, repo + "\\n");
  process.stdout.write(JSON.stringify(issuesByRepo[repo] || []));
} else if (args[0] === "api" && /^repos\\/.+\\/.+\\/issues\\/\\d+$/.test(args[1])) {
  if (${authorAssocExit} !== 0) { process.stderr.write("dial tcp: connection refused"); process.exit(${authorAssocExit}); }
  process.stdout.write("OWNER\\n");
} else if (args[0] === "issue" && args[1] === "edit") {
  fs.appendFileSync(${JSON.stringify(editLog)}, args.join(" ") + "\\n");
  process.stdout.write("");
} else {
  process.stderr.write("unexpected gh args: " + JSON.stringify(args));
  process.exit(1);
}
`);
  chmodSync(gh, 0o755);
  return { bin, log, editLog };
}

describe("promote-lanes CLI integration", () => {
  it("processes every --repo value in one CLI run", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-promote-lanes-multi-"));
    const { bin, log } = writePromoteLanesGh(root);
    try {
      const result = spawnSync("node", [
        CLI,
        "promote-lanes",
        "--dry-run",
        "--json",
        "--repo",
        "octocat/hello-world",
        "--repo",
        "tjegbejimba/kindleflow",
      ], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
        encoding: "utf8",
        timeout: 10_000,
      });

      assert.equal(result.status, 0, `stderr: ${result.stderr}`);
      const output = JSON.parse(result.stdout);
      assert.deepEqual(output.repos.map((entry) => entry.repo), [
        "octocat/hello-world",
        "tjegbejimba/kindleflow",
      ]);
      assert.deepEqual(readFileSync(log, "utf8").trim().split("\n"), [
        "octocat/hello-world",
        "tjegbejimba/kindleflow",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("applies live label edits to every requested repo", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-promote-lanes-live-multi-"));
    const issue = (number) => ({
      number,
      title: "Prevent unsafe launches",
      body: [
        "Ralph can waste quota.",
        "",
        "Acceptance criteria:",
        "- preflight blocks unsafe launches",
      ].join("\n"),
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      assignees: [],
      closedByPullRequestsReferences: [],
    });
    const { bin, editLog } = writePromoteLanesGh(root, {
      issuesByRepo: {
        "octocat/hello-world": [issue(101)],
        "tjegbejimba/kindleflow": [issue(202)],
      },
    });
    try {
      const result = spawnSync("node", [
        CLI,
        "promote-lanes",
        "--live",
        "--json",
        "--repo",
        "octocat/hello-world",
        "--repo",
        "tjegbejimba/kindleflow",
      ], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
        encoding: "utf8",
        timeout: 10_000,
      });

      assert.equal(result.status, 0, `stderr: ${result.stderr}`);
      const edits = readFileSync(editLog, "utf8").trim().split("\n");
      assert.match(edits[0], /issue edit 101 --repo octocat\/hello-world/);
      assert.match(edits[0], /--add-label ralph:fast-lane/);
      assert.match(edits[0], /--remove-label ralph:needs-triage/);
      assert.match(edits[1], /issue edit 202 --repo tjegbejimba\/kindleflow/);
      assert.match(edits[1], /--add-label ralph:fast-lane/);
      assert.match(edits[1], /--remove-label ralph:needs-triage/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("aborts non-zero with no edits when gh auth fails preflight", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-promote-lanes-authfail-"));
    const { bin, editLog } = writePromoteLanesGh(root, {
      issuesByRepo: { "octocat/hello-world": [] },
      authStatusExit: 1,
    });
    try {
      const result = spawnSync("node", [
        CLI,
        "promote-lanes",
        "--live",
        "--repo",
        "octocat/hello-world",
      ], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
        encoding: "utf8",
        timeout: 10_000,
      });
      assert.equal(result.status, 1, `stdout: ${result.stdout}`);
      assert.match(result.stderr, /GitHub preflight failed/);
      assert.equal(existsSync(editLog), false, "no label edits should happen");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("emits a structured preflight failure with --json", () => {
    const root = mkdtempSync(join(tmpdir(), "ralph-promote-lanes-json-fail-"));
    const { bin } = writePromoteLanesGh(root, {
      issuesByRepo: { "octocat/hello-world": [] },
      authStatusExit: 1,
    });
    try {
      const result = spawnSync("node", [
        CLI,
        "promote-lanes",
        "--live",
        "--json",
        "--repo",
        "octocat/hello-world",
      ], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
        encoding: "utf8",
        timeout: 10_000,
      });
      assert.equal(result.status, 1);
      const payload = JSON.parse(result.stdout);
      assert.equal(payload.ok, false);
      assert.equal(payload.phase, "github-preflight");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("exits non-zero in --live when enrichment calls fail", () => {
    const issue = {
      number: 101,
      title: "Prevent unsafe launches",
      body: "Ralph can waste quota.\n\nAcceptance criteria:\n- preflight blocks unsafe launches",
      labels: [{ name: "ralph:needs-triage" }],
      author: { login: "tjegbejimba" },
      assignees: [],
      closedByPullRequestsReferences: [],
    };
    const root = mkdtempSync(join(tmpdir(), "ralph-promote-lanes-enrich-fail-"));
    const { bin } = writePromoteLanesGh(root, {
      issuesByRepo: { "octocat/hello-world": [issue] },
      authorAssocExit: 1,
    });
    try {
      const result = spawnSync("node", [
        CLI,
        "promote-lanes",
        "--live",
        "--repo",
        "octocat/hello-world",
      ], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
        encoding: "utf8",
        timeout: 10_000,
      });
      assert.equal(result.status, 1, `stdout: ${result.stdout}`);
      assert.match(result.stderr, /enrichment error/);
      assert.match(result.stderr, /author_association_failed/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("processes issues and returns promotion results", () => {
    const issues = [
      {
        number: 101,
        title: "Prevent unsafe launches",
        body: [
          "Ralph can waste quota.",
          "",
          "Acceptance criteria:",
          "- preflight blocks unsafe launches",
        ].join("\n"),
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
    ];

    const result = runPromoteLanes({ issues, live: false });

    assert.equal(result.promotions.length, 1);
    assert.equal(result.promotions[0].issueNumber, 101);
    assert.equal(result.promotions[0].lane, "AUTO");
    // Now expects computed priority label as well as lane label
    assert.deepEqual(result.promotions[0].labelsAdded, ["ralph:fast-lane", "priority:P1"]);
    assert.deepEqual(result.promotions[0].labelsRemoved, ["ralph:needs-triage"]);
  });

  it("skips issues that fail guards", () => {
    const issues = [
      {
        number: 102,
        title: "Conflicted issue",
        body: "Test issue",
        labels: [
          { name: "ralph:needs-triage" },
          { name: "priority:P1" },
          { name: "priority:P2" },
        ],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
    ];

    const result = runPromoteLanes({ issues, live: false });

    assert.equal(result.promotions.length, 1);
    assert.equal(result.promotions[0].skipped, true);
    assert.match(result.promotions[0].skipReason, /taxonomy conflict/i);
  });

  it("reports summary stats", () => {
    const issues = [
      {
        number: 101,
        title: "Good issue",
        body: [
          "Ralph can waste quota.",
          "",
          "Acceptance criteria:",
          "- preflight blocks",
        ].join("\n"),
        labels: [{ name: "ralph:needs-triage" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
      {
        number: 102,
        title: "Already correct",
        body: [
          "Ralph can waste quota.",
          "",
          "Acceptance criteria:",
          "- preflight blocks",
        ].join("\n"),
        // Include priority label to prevent auto-addition and maintain no-op status
        labels: [{ name: "ralph:fast-lane" }, { name: "work:standalone" }, { name: "priority:P2" }],
        author: { login: "tjegbejimba" },
        authorAssociation: "OWNER",
      },
    ];

    const result = runPromoteLanes({ issues, live: false });

    assert.equal(result.summary.total, 2);
    assert.equal(result.summary.promoted, 1);
    assert.equal(result.summary.noOp, 1);
    assert.equal(result.summary.skipped, 0);
  });
});
