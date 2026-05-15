// Filters `ps -axww -o pid=,ppid=,command=` output to processes scoped to a
// given repo. A Ralph worker (or its `copilot -p` child) from
// `/Users/x/foo/.ralph/ralph.sh` should not light up the dashboard for
// `/Users/x/bar` — see issue #64 follow-up #3.
//
// Strategy:
//   1. Find `ralph.sh` processes whose command line references the dashboard's
//      repo root (with a path-boundary check so `/foo/myrepo` does not match
//      `/foo/myrepo-experiment`).
//   2. Propagate scope to descendants via PPID linking. `copilot -p` children
//      inherit scope from their `ralph.sh` parent so they are not lost.
//   3. Emit `ralph.sh` and `copilot -p` rows that ended up in scope.
//
// Pure helper so it can be unit-tested without spawning ps.

/**
 * @param {string} psStdout  Raw stdout from `ps -axww -o pid=,ppid=,command=`.
 * @param {string} repoRoot  Absolute path to the dashboard's repo root.
 * @returns {Array<{pid: number, cmd: string}>}
 */
export function filterScopedRalphProcesses(psStdout, repoRoot) {
  if (!psStdout || !repoRoot) return [];

  // Normalize trailing slash so the script-path comparison is unambiguous.
  const root = repoRoot.replace(/[/\\]+$/, "");

  // Pass 1: parse every line into {pid, ppid, cmd}, skipping noise.
  const rows = [];
  for (const line of psStdout.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    // Drop the ps invocation itself (some ps versions include it).
    if (trimmed.includes("ps -axww")) continue;
    // Drop the dashboard's own processes (they reference "ralph_dashboard" /
    // "ralph-dashboard" in their cmdlines on macOS).
    if (trimmed.includes("ralph_dashboard") || trimmed.includes("ralph-dashboard")) continue;

    // ps -o pid=,ppid=,command= produces leading whitespace + columns. Parse
    // pid and ppid then take the rest as the command.
    const m = trimmed.match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (!m) continue;
    const pid = Number(m[1]);
    const ppid = Number(m[2]);
    const cmd = m[3];
    if (!Number.isFinite(pid)) continue;
    rows.push({ pid, ppid, cmd });
  }

  // Pass 2: seed scope from ralph.sh processes whose command line references
  // this repo's `.ralph/ralph.sh` path. Matching the concrete script path
  // (rather than `cmd.includes('ralph.sh') && isUnderRoot(cmd)`) avoids a
  // false positive when a process in another repo happens to mention this
  // repo's path as an argument.
  const ralphScriptPosix = `${root}/.ralph/ralph.sh`;
  const ralphScriptWin = `${root}\\.ralph\\ralph.sh`;
  const scoped = new Set();
  for (const r of rows) {
    if (r.cmd.includes(ralphScriptPosix) || r.cmd.includes(ralphScriptWin)) {
      scoped.add(r.pid);
    }
  }

  // Pass 3: propagate scope to descendants until fixpoint. A `copilot -p`
  // child of a scoped ralph.sh becomes scoped itself.
  let changed = true;
  while (changed) {
    changed = false;
    for (const r of rows) {
      if (scoped.has(r.pid)) continue;
      if (scoped.has(r.ppid)) {
        scoped.add(r.pid);
        changed = true;
      }
    }
  }

  // Pass 4: emit ralph.sh + copilot -p rows that are in scope.
  const matches = [];
  for (const r of rows) {
    if (!scoped.has(r.pid)) continue;
    if (!/ralph\.sh|copilot -p/.test(r.cmd)) continue;
    matches.push({ pid: r.pid, cmd: r.cmd });
  }
  return matches;
}
