// Repo discovery for Ralph Loop canvas — finds orchestrated repos by scanning
// ~/Code/*/.ralph for orchestrator dirs and config.json with repo slugs.
// Dedupes by slug (prefers canonical checkout) and orders by most-recent activity.

import { readdirSync, readFileSync, existsSync, statSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";

/**
 * Discover orchestrated repos by scanning directories for .ralph/orchestrator/
 * and .ralph/config.json with a repo slug.
 * 
 * @param {Object} options
 * @param {string[]} options.scanRoots - Directories to scan (default: ~/Code)
 * @returns {Array<{slug: string, mainCheckout: string, label: string, activity: number}>}
 */
export function discoverRepos(options = {}) {
  const scanRoots = options.scanRoots || [join(homedir(), "Code")];
  const found = new Map(); // slug -> { slug, mainCheckout, label, activity }
  
  for (const root of scanRoots) {
    let entries = [];
    try {
      entries = readdirSync(root, { withFileTypes: true });
    } catch {
      // Root doesn't exist or not readable
      continue;
    }
    
    for (const ent of entries) {
      if (!ent.isDirectory()) continue;
      
      const checkout = join(root, ent.name);
      const cfgPath = join(checkout, ".ralph", "config.json");
      const orchDir = join(checkout, ".ralph", "orchestrator");
      
      // Must have both orchestrator dir and config.json
      if (!existsSync(cfgPath) || !existsSync(orchDir)) continue;
      
      // Read slug from config
      let slug = null;
      try {
        const config = JSON.parse(readFileSync(cfgPath, "utf8"));
        slug = config?.repo || null;
      } catch {
        // Invalid JSON or missing repo field
        continue;
      }
      
      if (!slug || typeof slug !== "string") continue;
      
      const repoName = slug.split("/")[1] || ent.name;
      const candidate = {
        slug,
        mainCheckout: checkout,
        label: repoName,
        activity: repoActivity(checkout),
      };
      
      const prev = found.get(slug);
      const isCanonical = ent.name === repoName;
      
      // Prefer canonical checkout (basename matches repo name) over worktrees
      if (!prev || (isCanonical && basename(prev.mainCheckout) !== repoName)) {
        found.set(slug, candidate);
      }
    }
  }
  
  // Sort by most-recently-active first, then alphabetically by label
  return [...found.values()].sort(
    (a, b) => b.activity - a.activity || a.label.localeCompare(b.label)
  );
}

/**
 * Get the last activity timestamp for a repo checkout.
 * Returns the newest mtime of state.json or orchestrator/ledger.json.
 * 
 * @param {string} checkout - Absolute path to repo checkout
 * @returns {number} - Timestamp in milliseconds, or 0 if no activity files exist
 */
export function repoActivity(checkout) {
  let maxTime = 0;
  
  const statePath = join(checkout, ".ralph", "state.json");
  const ledgerPath = join(checkout, ".ralph", "orchestrator", "ledger.json");
  
  for (const path of [statePath, ledgerPath]) {
    try {
      const stats = statSync(path);
      maxTime = Math.max(maxTime, stats.mtimeMs);
    } catch {
      // File doesn't exist or not readable
    }
  }
  
  return maxTime;
}
