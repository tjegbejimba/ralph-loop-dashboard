// Issue query module — runs GitHub issue searches and generates preview warnings.

import { execSync } from "node:child_process";

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
export function queryIssues({ repoOwner, repoName, searchQuery, execCommand, claimedIssues = [] }) {
  try {
    // Execute gh CLI to search issues (or use test mock)
    const output = execCommand ? execCommand() : execSync(
      `gh issue list --repo ${repoOwner}/${repoName} --search "${searchQuery}" --json number,title,body,labels,milestone,url,closingPullRequestsReferences --limit 1000`,
      { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 }
    );
    
    // Parse JSON output
    const rawIssues = JSON.parse(output);
    
    const warnings = [];
    const claimedSet = new Set(claimedIssues);
    
    // Normalize to preview format
    const issues = rawIssues.map(issue => {
      // Check for empty body
      if (!issue.body || issue.body.trim() === "") {
        warnings.push({
          issueNumber: issue.number,
          type: "empty_body",
          message: `Issue #${issue.number} has an empty issue body`,
        });
      }
      
      // Check for linked open PR
      const openPRs = (issue.closingPullRequestsReferences || []).filter(
        pr => pr.state === "OPEN"
      );
      if (openPRs.length > 0) {
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
      
      return {
        number: issue.number,
        title: issue.title,
        body: issue.body,
        labels: issue.labels ? issue.labels.map(l => l.name) : [],
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
    return {
      issues: null,
      warnings: [],
      error: {
        type: "query_failed",
        message: err.message,
      },
    };
  }
}
