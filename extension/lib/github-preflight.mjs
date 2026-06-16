// github-preflight.mjs — fail-loud GitHub readiness checks for CLI commands
// that mutate GitHub (triage, promote-lanes).
//
// The scheduled "Triage Needs-Triage Issues" workflow runs the triage and
// promote-lanes CLI commands inside a throwaway worktree. When that sandbox
// lacks gh/GH_TOKEN auth or outbound reachability to api.github.com, the
// underlying gh calls fail and the run silently no-ops (issue #149). These
// probes mirror the real call surface — REST + GraphQL + a per-repo read — so a
// broken environment is caught up front and reported as a hard, non-zero error
// instead of a quiet "success".

import { spawnSync } from "node:child_process";

/**
 * Default synchronous command runner. Returns a normalized result so callers
 * (and tests) never have to special-case spawnSync's shape.
 * @returns {{exitCode: number, stdout: string, stderr: string}}
 */
function defaultRunCommand(command, args = []) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
    timeout: 15000,
  });
  if (result.error) {
    return {
      exitCode: typeof result.status === "number" ? result.status : 1,
      stdout: "",
      stderr: result.error.message || String(result.error),
    };
  }
  return {
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: (result.stdout || "").trim(),
    stderr: (result.stderr || "").trim(),
  };
}

/**
 * Canonical "is gh authenticated" check. Exported so other modules
 * (e.g. preflight.mjs) share a single notion of gh-auth health.
 * @param {Function} [runCommand]
 * @returns {{exitCode: number, stdout: string, stderr: string}}
 */
export function checkGithubAuth(runCommand = defaultRunCommand) {
  return runCommand("gh", ["auth", "status"]);
}

function repoSlug(repo) {
  if (typeof repo === "string") return repo.trim();
  if (repo && repo.owner && repo.name) return `${repo.owner}/${repo.name}`;
  return null;
}

/**
 * Run GitHub readiness preflight for the given target repos.
 *
 * Probes (all must pass for ok === true):
 *   1. gh auth status                — auth presence (GH_TOKEN / gh login).
 *   2. gh api user                   — REST api.github.com reachability + identity.
 *   3. gh api graphql viewer/rateLimit — GraphQL reachability (the surface that
 *                                       produced the observed connection refused).
 *   4. gh issue list --repo R --limit 1 — per-repo read scope (perms/SSO).
 *
 * @param {Object} [options]
 * @param {Array<string|{owner:string,name:string}>} [options.repos] - target repos.
 * @param {Function} [options.runCommand] - injectable command runner (for tests).
 * @returns {{ok: boolean, login: string|null, checks: Array<Object>, error: string|null}}
 */
export function runGithubPreflight({ repos = [], runCommand = defaultRunCommand } = {}) {
  const checks = [];
  let login = null;

  // 1. gh auth status
  const auth = checkGithubAuth(runCommand);
  const authOk = auth.exitCode === 0;
  checks.push({
    id: "gh-auth-status",
    label: "gh auth status",
    ok: authOk,
    message: authOk
      ? "GitHub CLI authenticated"
      : `Not authenticated: ${auth.stderr || "gh auth status failed"}. Set GH_TOKEN or run 'gh auth login'.`,
  });

  // 2. REST identity / reachability
  const userRes = runCommand("gh", ["api", "user", "--jq", ".login"]);
  const userLogin = (userRes.stdout || "").trim();
  const userOk = userRes.exitCode === 0 && userLogin.length > 0;
  if (userOk) login = userLogin;
  checks.push({
    id: "rest-api",
    label: "REST api.github.com (gh api user)",
    ok: userOk,
    message: userOk
      ? `Reachable as @${login}`
      : `REST api.github.com unreachable or unauthorized: ${userRes.stderr || "gh api user failed"}`,
  });

  // 3. GraphQL reachability
  const gql = runCommand("gh", [
    "api",
    "graphql",
    "-f",
    "query={ viewer { login } rateLimit { remaining } }",
  ]);
  const gqlOk = gql.exitCode === 0;
  checks.push({
    id: "graphql-api",
    label: "GraphQL api.github.com",
    ok: gqlOk,
    message: gqlOk
      ? "GraphQL api.github.com reachable"
      : `GraphQL api.github.com unreachable: ${gql.stderr || "gh api graphql failed"}`,
  });

  // 4. Per-repo read probe
  for (const repo of repos) {
    const slug = repoSlug(repo);
    if (!slug) continue;
    const probe = runCommand("gh", [
      "issue",
      "list",
      "--repo",
      slug,
      "--limit",
      "1",
      "--json",
      "number",
    ]);
    const probeOk = probe.exitCode === 0;
    checks.push({
      id: `repo-read:${slug}`,
      label: `Read ${slug}`,
      ok: probeOk,
      message: probeOk
        ? `Can read ${slug}`
        : `Cannot read ${slug}: ${probe.stderr || "gh issue list failed"}`,
    });
  }

  const failed = checks.filter((check) => !check.ok);
  const ok = failed.length === 0;
  const error = ok
    ? null
    : `GitHub preflight failed (${failed.length} check${failed.length === 1 ? "" : "s"}):\n` +
      failed.map((check) => `  - ${check.label}: ${check.message}`).join("\n");

  return { ok, login, checks, error };
}
