import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { QueueBuilder } from "../extension/lib/queue-builder.mjs";

describe("QueueBuilder", () => {
  describe("tracer bullet - select single issue", () => {
    it("adds selected issue to queue", () => {
      const qb = new QueueBuilder();
      const issue = {
        number: 5,
        title: "Add authentication",
        labels: ["feature"],
        milestone: "v1.0",
        url: "https://github.com/test/repo/issues/5",
      };

      qb.selectIssue(issue);
      const queue = qb.getQueue();

      assert.equal(queue.length, 1);
      assert.equal(queue[0].number, 5);
      assert.equal(queue[0].title, "Add authentication");
    });
  });

  describe("auto-sort by issue number", () => {
    it("sorts selected issues by number ascending", () => {
      const qb = new QueueBuilder();
      
      qb.selectIssue({ number: 10, title: "Third" });
      qb.selectIssue({ number: 3, title: "First" });
      qb.selectIssue({ number: 7, title: "Second" });
      
      const queue = qb.getQueue();
      
      assert.equal(queue.length, 3);
      assert.equal(queue[0].number, 3);
      assert.equal(queue[1].number, 7);
      assert.equal(queue[2].number, 10);
    });
  });

  describe("deselect issues", () => {
    it("removes issue from queue by number", () => {
      const qb = new QueueBuilder();
      
      qb.selectIssue({ number: 3, title: "First" });
      qb.selectIssue({ number: 7, title: "Second" });
      qb.selectIssue({ number: 10, title: "Third" });
      
      qb.deselectIssue(7);
      const queue = qb.getQueue();
      
      assert.equal(queue.length, 2);
      assert.equal(queue[0].number, 3);
      assert.equal(queue[1].number, 10);
    });
  });

  describe("duplicate prevention", () => {
    it("prevents duplicate issue entries", () => {
      const qb = new QueueBuilder();
      
      qb.selectIssue({ number: 5, title: "Feature" });
      qb.selectIssue({ number: 5, title: "Feature" });
      qb.selectIssue({ number: 5, title: "Feature (different title)" });
      
      const queue = qb.getQueue();
      
      assert.equal(queue.length, 1);
      assert.equal(queue[0].number, 5);
    });
  });

  describe("manual reorder", () => {
    it("moves issue to specified index", () => {
      const qb = new QueueBuilder();
      
      qb.selectIssue({ number: 3, title: "First" });
      qb.selectIssue({ number: 7, title: "Second" });
      qb.selectIssue({ number: 10, title: "Third" });
      
      // Move issue 3 to index 2 (last position)
      qb.reorderIssue(3, 2);
      const queue = qb.getQueue();
      
      assert.equal(queue.length, 3);
      assert.equal(queue[0].number, 7);
      assert.equal(queue[1].number, 10);
      assert.equal(queue[2].number, 3);
    });
    
    it("moves issue forward in queue", () => {
      const qb = new QueueBuilder();
      
      qb.selectIssue({ number: 1, title: "A" });
      qb.selectIssue({ number: 2, title: "B" });
      qb.selectIssue({ number: 3, title: "C" });
      
      // Move issue 3 to index 0 (first position)
      qb.reorderIssue(3, 0);
      const queue = qb.getQueue();
      
      assert.equal(queue[0].number, 3);
      assert.equal(queue[1].number, 1);
      assert.equal(queue[2].number, 2);
    });
  });

  describe("isSelected helper", () => {
    it("returns true if issue is in queue", () => {
      const qb = new QueueBuilder();
      
      qb.selectIssue({ number: 5, title: "Test" });
      
      assert.equal(qb.isSelected(5), true);
      assert.equal(qb.isSelected(10), false);
    });
  });

  describe("metadata preservation", () => {
    it("preserves labels, milestone, and url", () => {
      const qb = new QueueBuilder();
      
      qb.selectIssue({
        number: 5,
        title: "Add auth",
        labels: ["feature", "security"],
        milestone: "v1.0",
        url: "https://github.com/test/repo/issues/5",
      });
      
      const queue = qb.getQueue();
      const issue = queue[0];
      
      assert.deepEqual(issue.labels, ["feature", "security"]);
      assert.equal(issue.milestone, "v1.0");
      assert.equal(issue.url, "https://github.com/test/repo/issues/5");
    });
  });
});
