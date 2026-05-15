// Unit tests for the repo-scoped process filter (issue #64 follow-up #3).
// ps fixtures use `pid ppid command` ordering — matching the `-o pid=,ppid=,command=`
// format the dashboard requests at runtime.

import { test } from "node:test";
import assert from "node:assert/strict";
import { filterScopedRalphProcesses } from "../extension/lib/process-scope.mjs";

const PS_OUTPUT = `
12345     1 /bin/bash /Users/dev/Code/myrepo/.ralph/ralph.sh
12346 12345 /Users/dev/.local/bin/copilot -p some-prompt
22222     1 /bin/bash /Users/dev/Code/otherrepo/.ralph/ralph.sh
22223 22222 /Users/dev/.local/bin/copilot -p other-prompt
33333     1 /usr/bin/vim some-file.txt
44444     1 node /Users/dev/Code/myrepo/extension/main.mjs ralph_dashboard
55555     1 ps -axww -o pid=,ppid=,command=
`.trim();

test("filterScopedRalphProcesses — keeps workers under repoRoot", () => {
  const matches = filterScopedRalphProcesses(PS_OUTPUT, "/Users/dev/Code/myrepo");
  const pids = matches.map(m => m.pid).sort();
  assert.deepEqual(pids, [12345, 12346]);
});

test("filterScopedRalphProcesses — copilot -p child inherits scope from ralph.sh parent", () => {
  const matches = filterScopedRalphProcesses(PS_OUTPUT, "/Users/dev/Code/myrepo");
  assert.ok(matches.some(m => m.pid === 12346),
    "copilot -p child of in-scope ralph.sh must be retained");
});

test("filterScopedRalphProcesses — copilot -p child of out-of-scope ralph.sh is dropped", () => {
  const matches = filterScopedRalphProcesses(PS_OUTPUT, "/Users/dev/Code/myrepo");
  assert.ok(!matches.some(m => m.pid === 22223),
    "copilot -p child of a different repo's ralph.sh must NOT be retained");
});

test("filterScopedRalphProcesses — drops workers from another repo", () => {
  const matches = filterScopedRalphProcesses(PS_OUTPUT, "/Users/dev/Code/myrepo");
  assert.ok(matches.every(m => !m.cmd.includes("/otherrepo/")),
    "cross-repo ralph workers must be filtered out");
});

test("filterScopedRalphProcesses — drops the dashboard process itself", () => {
  const matches = filterScopedRalphProcesses(PS_OUTPUT, "/Users/dev/Code/myrepo");
  assert.ok(matches.every(m => !m.cmd.includes("ralph_dashboard")),
    "dashboard process must be filtered out");
});

test("filterScopedRalphProcesses — drops the ps invocation itself", () => {
  const matches = filterScopedRalphProcesses(PS_OUTPUT, "/Users/dev/Code/myrepo");
  assert.ok(matches.every(m => !m.cmd.includes("ps -axww")),
    "ps query line must be filtered out");
});

test("filterScopedRalphProcesses — handles empty input", () => {
  assert.deepEqual(filterScopedRalphProcesses("", "/Users/dev/Code/myrepo"), []);
});

test("filterScopedRalphProcesses — handles missing repoRoot", () => {
  assert.deepEqual(filterScopedRalphProcesses(PS_OUTPUT, ""), []);
});

test("filterScopedRalphProcesses — normalizes trailing slash on repoRoot", () => {
  const matches = filterScopedRalphProcesses(PS_OUTPUT, "/Users/dev/Code/myrepo/");
  const pids = matches.map(m => m.pid).sort();
  assert.deepEqual(pids, [12345, 12346], "trailing slash on repoRoot must not block matching");
});

test("filterScopedRalphProcesses — sibling repo with shared prefix is rejected", () => {
  // `/Users/dev/Code/myrepo-experiment` shares a prefix with `/Users/dev/Code/myrepo`
  // but is a distinct repo. The script-path check requires the exact
  // `<repoRoot>/.ralph/ralph.sh`, so the sibling does not match.
  const psWithSibling = `
12345     1 /bin/bash /Users/dev/Code/myrepo/.ralph/ralph.sh
99999     1 /bin/bash /Users/dev/Code/myrepo-experiment/.ralph/ralph.sh
`.trim();
  const matches = filterScopedRalphProcesses(psWithSibling, "/Users/dev/Code/myrepo");
  const pids = matches.map(m => m.pid).sort();
  assert.deepEqual(pids, [12345], "sibling repo with shared prefix must not match");
});

test("filterScopedRalphProcesses — process that merely mentions repoRoot as arg is rejected", () => {
  // A process from another repo that happens to reference this repo's path
  // in its argv (e.g. a grep or an editor) must NOT be scoped — only
  // processes running THIS repo's `.ralph/ralph.sh` count.
  const psNoise = `
12345     1 /bin/bash /Users/dev/Code/myrepo/.ralph/ralph.sh
77777     1 /usr/bin/grep -r ralph.sh /Users/dev/Code/myrepo
`.trim();
  const matches = filterScopedRalphProcesses(psNoise, "/Users/dev/Code/myrepo");
  const pids = matches.map(m => m.pid).sort();
  assert.deepEqual(pids, [12345],
    "argv mentioning repoRoot must not light up a non-ralph.sh process");
});
