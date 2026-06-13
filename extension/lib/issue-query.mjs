// Issue query module — runs GitHub issue searches and generates preview warnings.

import { spawnSync } from "node:child_process";
import { classifyIssue } from "./label-taxonomy.mjs";

/**
 * Query GitHub issues and return metadata with warnings.
 * 
 * @param {Object} options
 * @param {string} options.repoOwner - Repository owner
 * @param {string} options.repoName - Repository name
 * @param {string} options.searchQuery - GitHub issue search query
 * @param {Function} [options.execCommand] - Command executor (for testing)
 * @param {Array<number>} [options.claimedIssues] - Issue numbers already claimed in active runs
 * @returns {Object} Result
 * @returns {Array<Object>|null} .issues - Array of issue metadata, or null on error
 * @returns {Array<Object>} .warnings - Nonblocking warnings
 * @returns {Object|null} .error - Error object if query failed
 */
export function queryIssues({ repoOwner, repoName, searchQuery, execCommand, claimedIssues = [], parsedDependencies = null, config = {} }) {
  try {
    // Validate claimedIssues is an array
    if (!Array.isArray(claimedIssues)) {
      return {
        issues: null,
        warnings: [],
        error: {
          type: "invalid_input",
          message: "claimedIssues must be an array",
        },
      };
    }
    
    // Execute gh CLI to search issues (or use test mock)
    const ghArgs = [
      "issue", "list",
      "--repo", `${repoOwner}/${repoName}`,
      "--search", searchQuery,
      "--json", "number,title,body,labels,milestone,url,closedByPullRequestsReferences",
      "--limit", "1000",
    ];
    const output = execCommand ? execCommand(ghArgs) : (() => {
      const result = spawnSync("gh", ghArgs, { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 });
      
      if (result.error) {
        throw result.error;
      }
      if (result.status !== 0) {
        throw new Error(result.stderr || "gh command failed");
      }
      return result.stdout;
    })();
    
    // Parse JSON output
    const rawIssues = JSON.parse(output);
    
    const warnings = [];
    const claimedSet = new Set(claimedIssues);
    const taxonomyConfig = config?.taxonomy ?? {};
    
    // Normalize to preview format
    const issues = rawIssues.map(issue => {
      // Normalize labels early so checks use plain strings
      const labels = Array.isArray(issue.labels)
        ? issue.labels.map(l => l?.name).filter(Boolean)
        : [];

      // Check for empty body
      if (!issue.body || issue.body.trim() === "") {
        warnings.push({
          issueNumber: issue.number,
          type: "empty_body",
          message: `Issue #${issue.number} has an empty issue body`,
        });
      }
      
      // Check for linked open PR
      const prRefs = Array.isArray(issue.closedByPullRequestsReferences) 
        ? issue.closedByPullRequestsReferences 
        : [];
      const openPRs = prRefs.filter(pr => pr && pr.state === "OPEN");
      
      if (openPRs.length > 0 && openPRs[0].url) {
        warnings.push({
          issueNumber: issue.number,
          type: "linked_pr",
          message: `Issue #${issue.number} already has an open PR`,
          prUrl: openPRs[0].url,
        });
      }
      
      // Check if issue is already claimed in an active run
      if (claimedSet.has(issue.number)) {
        warnings.push({
          issueNumber: issue.number,
          type: "already_claimed",
          message: `Issue #${issue.number} is already claimed in another active run`,
        });
      }

      const taxonomy = classifyIssue(
        { ...issue, labels },
        { compatibilityAliases: taxonomyConfig.compatibilityAliases === true },
      );
      for (const conflict of taxonomy.conflicts) {
        warnings.push({
          issueNumber: issue.number,
          type: "taxonomy_conflict",
          dimension: conflict.dimension,
          labels: conflict.labels,
          message: `Issue #${issue.number}: ${conflict.message}`,
          blocking: true,
        });
      }
      for (const warning of taxonomy.warnings.filter((warning) => warning.type === "legacy_alias")) {
        warnings.push({
          issueNumber: issue.number,
          type: "legacy_label_alias",
          legacy: warning.legacy ?? null,
          canonical: warning.canonical,
          message: `Issue #${issue.number}: ${warning.message}`,
          blocking: false,
        });
      }

      // Check unresolved blockers (graceful fallback when dep parser not available)
      const rawBlockers = parsedDependencies?.[issue.number];
      const blockers = Array.isArray(rawBlockers) ? rawBlockers : [];
      for (const blocker of blockers) {
        if (blocker && blocker.isOpen === true && Number.isInteger(blocker.number)) {
          warnings.push({
            issueNumber: issue.number,
            type: "unresolved_blocker",
            message: `Issue #${issue.number} is blocked by open issue #${blocker.number}`,
            blockerNumber: blocker.number,
            blocking: false,
          });
        }
      }
      
      return {
        number: issue.number,
        title: issue.title,
        body: issue.body,
        labels,
        taxonomy: {
          state: taxonomy.state,
          priority: taxonomy.priority,
          workType: taxonomy.workType,
          parentNumber: taxonomy.parentNumber,
          blockers: taxonomy.blockers,
          conflicts: taxonomy.conflicts,
          warnings: taxonomy.warnings,
          repoLabels: taxonomy.repoLabels,
          runnable: taxonomy.runnable,
          eligibleForQueue: taxonomy.runnable,
        },
        milestone: issue.milestone ? issue.milestone.title : null,
        url: issue.url,
      };
    });
    
    return {
      issues,
      warnings,
      error: null,
    };
  } catch (err) {
    // Sanitize error message to avoid exposing sensitive data
    let message = err.message;
    if (message && message.includes("--search")) {
      // Strip command details that might contain user input
      message = message.split("\n")[0] || "GitHub CLI command failed";
    }
    
    return {
      issues: null,
      warnings: [],
      error: {
        type: "query_failed",
        message,
      },
    };
  }
}
