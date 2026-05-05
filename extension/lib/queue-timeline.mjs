// Queue timeline presenter — transforms run state into timeline rows for dashboard display

/**
 * Build queue timeline from run state
 * 
 * Transforms the selected queue and run status into timeline rows with issue links,
 * PR links, log files, and current state for each queue item.
 * 
 * @param {Object} options
 * @param {Array} options.queue - Selected issue queue from queue.json
 * @param {Object} options.status - Run status from status.json
 * @param {string} options.repoOwner - GitHub repository owner
 * @param {string} options.repoName - GitHub repository name
 * @returns {Array<Object>} Timeline rows
 * @returns {number} [].issueNumber - Issue number
 * @returns {string} [].title - Issue title
 * @returns {string} [].state - Current state (queued|claimed|running|pr-opened|merged|failed|skipped)
 * @returns {string} [].issueUrl - GitHub issue URL
 * @returns {string|null} [].prUrl - GitHub PR URL (if PR exists)
 * @returns {number|null} [].prNumber - PR number (if PR exists)
 * @returns {string|null} [].logFile - Worker log filename (if claimed/running/completed)
 * @returns {number|null} [].workerId - Worker ID (if claimed/running/completed)
 * @returns {string|null} [].startedAt - ISO timestamp when work started (if running/completed)
 * @returns {string|null} [].error - Error message (if failed/skipped)
 */
export function buildQueueTimeline({ queue, status, repoOwner, repoName }) {
  // Validate required parameters
  if (!Array.isArray(queue)) {
    throw new TypeError("queue is required and must be an array");
  }
  if (!status || typeof status !== "object" || !status.items) {
    throw new TypeError("status is required and must have items property");
  }
  if (!repoOwner || typeof repoOwner !== "string") {
    throw new TypeError("repoOwner is required and must be a string");
  }
  if (!repoName || typeof repoName !== "string") {
    throw new TypeError("repoName is required and must be a string");
  }
  
  return queue.map(issue => {
    const issueNumber = issue.number;
    const itemStatus = status.items[String(issueNumber)];
    
    // Build base row with issue metadata
    const row = {
      issueNumber,
      title: issue.title,
      state: itemStatus?.status || "queued",
      issueUrl: `https://github.com/${repoOwner}/${repoName}/issues/${issueNumber}`,
      prUrl: null,
      prNumber: null,
      logFile: null,
      workerId: null,
      startedAt: null,
      error: null,
    };
    
    // Add runtime state if item has status
    if (itemStatus) {
      row.workerId = itemStatus.workerId ?? null;
      row.logFile = itemStatus.logFile ?? null;
      row.startedAt = itemStatus.startedAt ?? null;
      row.error = itemStatus.error ?? null;
      
      // Add PR URL if PR was opened
      if (itemStatus.prNumber) {
        row.prNumber = itemStatus.prNumber;
        row.prUrl = `https://github.com/${repoOwner}/${repoName}/pull/${itemStatus.prNumber}`;
      }
    }
    
    return row;
  });
}
