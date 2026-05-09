import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const PRD_REF_PATTERN = /<!--\s*RALPH_PRD_REF:\s*(#\d+)\s*-->/;

/**
 * Parses the PRD reference from .ralph/RALPH.md.
 * Returns a string like "#7" or null if not found or still a placeholder.
 */
export function parsePrdReference(repoRoot) {
  if (!repoRoot) return null;
  const ralphMdPath = join(repoRoot, ".ralph", "RALPH.md");
  if (!existsSync(ralphMdPath)) return null;
  try {
    const content = readFileSync(ralphMdPath, "utf-8");
    const match = content.match(PRD_REF_PATTERN);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

/**
 * Extracts the owner/repo slug from an issueSearch string.
 * e.g. "repo:tjegbejimba/ralph-loop-dashboard is:issue is:open" → "tjegbejimba/ralph-loop-dashboard"
 */
export function extractRepo(issueSearch) {
  if (!issueSearch) return null;
  const match = issueSearch.match(/\brepo:([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\b/);
  return match ? match[1] : null;
}

/**
 * Builds the dashboard header text from available context.
 * Priority:
 *   1. prdReference + prdTitle  → "Ralph Loop — PRD #N: <title>"
 *   2. prdReference             → "Ralph Loop — PRD #N"
 *   3. repo                     → "Ralph Loop — owner/repo"
 *   4. bare                     → "Ralph Loop"
 */
export function buildHeaderText({ repo = null, prdReference = null, prdTitle = null } = {}) {
  if (prdReference) {
    if (prdTitle) return `Ralph Loop — PRD ${prdReference}: ${prdTitle}`;
    return `Ralph Loop — PRD ${prdReference}`;
  }
  if (repo) return `Ralph Loop — ${repo}`;
  return "Ralph Loop";
}

// Session-scoped cache. Keys: "<repo>#<num>" or "null#<num>".
// Both successes (string) and failures (null) are cached to avoid hammering gh.
const _cache = new Map();

/**
 * Fetches the PRD issue title from GitHub via gh CLI.
 * @param {string|null} repo - "owner/repo"
 * @param {string|null} prdReference - "#N"
 * @param {{ ghJsonFn: Function }} options
 */
export async function fetchPrdTitle(repo, prdReference, { ghJsonFn } = {}) {
  if (!prdReference) return null;
  const prdNum = prdReference.replace(/^#/, "");
  if (!prdNum) return null;

  const cacheKey = `${repo || "null"}#${prdNum}`;
  if (_cache.has(cacheKey)) return _cache.get(cacheKey);

  let title = null;
  if (repo && typeof ghJsonFn === "function") {
    const result = await ghJsonFn(["issue", "view", prdNum, "--repo", repo, "--json", "title"]);
    if (result && typeof result.title === "string") {
      title = result.title;
    }
  }

  if (title !== null) _cache.set(cacheKey, title);
  return title;
}

/** Clears the PRD title cache. Used in tests only. */
export function clearPrdTitleCache() {
  _cache.clear();
}
