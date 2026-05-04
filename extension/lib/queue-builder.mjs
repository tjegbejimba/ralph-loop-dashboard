// Queue builder module — manages issue selection, deselection, and ordering for run queue.

/**
 * QueueBuilder manages a run queue with selection, deselection, and reordering.
 */
export class QueueBuilder {
  constructor() {
    this.queue = [];
  }

  /**
   * Select an issue and add it to the queue.
   * Issues are automatically sorted by issue number ascending.
   * Duplicates are prevented - same issue number won't be added twice.
   * @param {Object} issue - Issue object with number, title, labels, milestone, url
   */
  selectIssue(issue) {
    // Prevent duplicates
    if (this.queue.some(item => item.number === issue.number)) {
      return;
    }
    
    // Deep copy to prevent external mutations affecting internal state
    this.queue.push(structuredClone(issue));
    this.queue.sort((a, b) => a.number - b.number);
  }

  /**
   * Deselect an issue and remove it from the queue.
   * @param {number} issueNumber - Issue number to remove
   */
  deselectIssue(issueNumber) {
    this.queue = this.queue.filter(issue => issue.number !== issueNumber);
  }

  /**
   * Reorder an issue to a new index in the queue.
   * @param {number} issueNumber - Issue number to move
   * @param {number} newIndex - New position (0-based index)
   */
  reorderIssue(issueNumber, newIndex) {
    const currentIndex = this.queue.findIndex(issue => issue.number === issueNumber);
    if (currentIndex === -1) return;
    
    // Validate newIndex is within bounds
    if (newIndex < 0 || newIndex >= this.queue.length) return;
    
    const [issue] = this.queue.splice(currentIndex, 1);
    this.queue.splice(newIndex, 0, issue);
  }

  /**
   * Get the current queue.
   * Returns a deep copy to prevent external mutations.
   * @returns {Array<Object>} Ordered array of selected issues
   */
  getQueue() {
    return this.queue.map(issue => structuredClone(issue));
  }

  /**
   * Check if an issue is selected.
   * @param {number} issueNumber - Issue number to check
   * @returns {boolean} True if issue is in queue
   */
  isSelected(issueNumber) {
    return this.queue.some(issue => issue.number === issueNumber);
  }
}
