// Repo resolution module — resolves target repo root from environment,
// current working directory, and active loop detection.

import { existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

// Check if path exists and is a directory
function isDirectory(path) {
  try {
    return existsSync(path) && statSync(path).isDirectory();
  } catch {
    return false;
  }
}

// Walk up from `start` looking for a directory containing any of `markers`.
// Returns the first match, or null. Markers must be directories, not files.
function findUpward(start, markers) {
  let dir = resolve(start);
  while (true) {
    for (const marker of markers) {
      const markerPath = join(dir, marker);
      if (isDirectory(markerPath)) return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/**
 * Resolve the target repo root and surface setup state.
 * 
 * @param {Object} options
 * @param {Object} options.env - Environment variables (e.g., { RALPH_REPO_ROOT: '/path' })
 * @param {string} options.cwd - Current working directory
 * @param {string} options.searchStart - Fallback search start path (e.g., import.meta.dirname)
 * @returns {Object} Resolution result
 * @returns {'resolved'|'unresolved'} .state - Resolution state
 * @returns {string|null} .repoRoot - Resolved repo root path, or null if unresolved
 * @returns {boolean} .hasRalph - Whether .ralph/ directory exists at repoRoot
 * @returns {'env'|'cwd-ralph'|'cwd-git'|'legacy'|'fallback'|'none'} .source - How repo was resolved
 */
export function resolveRepoState({ env, cwd, searchStart }) {
  // Precedence 1: RALPH_REPO_ROOT env var (explicit override)
  if (env.RALPH_REPO_ROOT) {
    const envRoot = resolve(env.RALPH_REPO_ROOT);
    if (isDirectory(envRoot)) {
      const hasRalph = isDirectory(join(envRoot, ".ralph"));
      return { state: "resolved", repoRoot: envRoot, hasRalph, source: "env" };
    }
    // Invalid env override (not a directory) — fall through to other methods
  }

  // Precedence 2: Walk up from cwd to find .ralph/
  const cwdRalph = findUpward(cwd, [".ralph"]);
  if (cwdRalph) {
    return { state: "resolved", repoRoot: cwdRalph, hasRalph: true, source: "cwd-ralph" };
  }

  // Precedence 3: Walk up from cwd to find .git/
  const cwdGit = findUpward(cwd, [".git"]);
  if (cwdGit) {
    const hasRalph = isDirectory(join(cwdGit, ".ralph"));
    return { state: "resolved", repoRoot: cwdGit, hasRalph, source: "cwd-git" };
  }

  // Precedence 4: Legacy in-repo install (walk up from searchStart)
  const legacyRalph = findUpward(searchStart, [".ralph"]);
  if (legacyRalph) {
    return { state: "resolved", repoRoot: legacyRalph, hasRalph: true, source: "legacy" };
  }

  // No repo root found
  return { state: "unresolved", repoRoot: null, hasRalph: false, source: "none" };
}
