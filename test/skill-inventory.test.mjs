import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(TEST_DIR, "..");
const SKILLS_ROOT = join(REPO_ROOT, "skills");
const REQUIRED_SKILLS = [
  "to-spec",
  "to-tickets",
  "to-ralph",
  "ralph-orchestrator",
  "ralph-issue-triage-agent",
];

async function markdownFiles(root) {
  const entries = await readdir(root, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const path = join(root, entry.name);
      if (entry.isDirectory()) return markdownFiles(path);
      return entry.isFile() && entry.name.endsWith(".md") ? [path] : [];
    }),
  );
  return nested.flat();
}

function frontmatterValue(content, key) {
  const frontmatter = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  assert.ok(frontmatter, "SKILL.md must start with YAML frontmatter");
  const value = frontmatter[1].match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
  return value?.[1]?.replace(/^["']|["']$/g, "");
}

test("repository bundles the complete Ralph skill workflow", async () => {
  const installed = new Set(
    (await readdir(SKILLS_ROOT, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name),
  );

  for (const skill of REQUIRED_SKILLS) {
    assert.ok(installed.has(skill), `missing required repo-owned skill: ${skill}`);
    const content = await readFile(join(SKILLS_ROOT, skill, "SKILL.md"), "utf8");
    assert.equal(frontmatterValue(content, "name"), skill);
    assert.ok(frontmatterValue(content, "description"), `${skill} needs a description`);
  }
});

test("installer help names every repo-owned skill", async () => {
  const install = await readFile(join(REPO_ROOT, "install.sh"), "utf8");
  const skillDirs = (await readdir(SKILLS_ROOT, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);

  for (const skill of skillDirs) {
    assert.match(install, new RegExp(`\\b${skill}\\b`), `install help omits ${skill}`);
  }
});

test("live workflow docs use the supported planning skill names", async () => {
  const files = [
    join(REPO_ROOT, "README.md"),
    join(REPO_ROOT, "install.sh"),
    ...(await markdownFiles(SKILLS_ROOT)),
  ];

  for (const path of files) {
    const content = await readFile(path, "utf8");
    assert.doesNotMatch(content, /\bto-prd\b|\bto-issues\b|\bgrill-me\b/, path);
  }
});

test("skill references resolve to repo-owned skills", async () => {
  const files = await markdownFiles(SKILLS_ROOT);
  const referenced = new Set();

  for (const path of files) {
    const content = await readFile(path, "utf8");
    for (const match of content.matchAll(/`(to-[a-z0-9-]+|ralph-(?:orchestrator|issue-triage-agent))`/g)) {
      referenced.add(match[1]);
    }
  }

  for (const skill of referenced) {
    const content = await readFile(join(SKILLS_ROOT, skill, "SKILL.md"), "utf8");
    assert.equal(frontmatterValue(content, "name"), skill);
  }
});

test("relative Markdown links in skill docs resolve", async () => {
  const files = await markdownFiles(SKILLS_ROOT);

  for (const path of files) {
    const content = await readFile(path, "utf8");
    for (const match of content.matchAll(/\[[^\]]*]\(([^)]+\.md(?:#[^)]+)?)\)/g)) {
      const target = match[1].split("#", 1)[0];
      if (/^[a-z]+:/i.test(target)) continue;
      await readFile(resolve(dirname(path), target), "utf8");
    }
  }
});

