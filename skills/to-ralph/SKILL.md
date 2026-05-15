---
name: to-ralph
description: Load a PRD issue into the Ralph TDD loop and surface preflight status. Use when the user wants to queue a PRD for Ralph after completing to-issues, or when they say "enqueue for Ralph", "send to Ralph", or "start the Ralph loop".
---

# To Ralph

Close the planning loop by enqueueing a PRD's issues into Ralph and surfacing any blockers before the human launches workers.

```
grill-me → to-prd → to-issues → to-ralph → ./.ralph/launch.sh
```

**You must never run `.ralph/launch.sh` without one of the permitted flags (`--enqueue`, `--enqueue-prd`, or `--status`). Launching workers is a human decision. Do not run `launch.sh` with `--start`, `--foreground`, or any flag that starts workers.**

## Steps

1. **Identify the PRD issue number.** Take it from conversation context, or ask the user if it is not clear.

2. **Enqueue the issues.** Run `./.ralph/launch.sh --enqueue-prd <N>` for a PRD whose child slices are already labelled `ready-for-agent`, or `./.ralph/launch.sh --enqueue <N> [<N>...]` for explicit child issues. `launch.sh` now runs a preflight pass automatically after the enqueue and prints a structured report to stdout — read that output, do not re-run `--status` if `--enqueue` already produced it.

3. **Read the preflight output.** It includes:
   - `Repo: clean | dirty (N files)` — workers abort on a dirty tree.
   - `RALPH.md: ref #N | placeholder {{PRD_REFERENCE}} | marker missing` — workers need a concrete PRD reference.
   - `Queue mode: direct-numbers (N issues) | issueSearch: <query>` — confirms which selection path workers will use.
   - Per-issue warnings: `needs_triage`, `not_ready_for_agent`, `hitl`, `closed`, `unresolved_blocker(#X)`, `lookup_failed`.
   - `Verdict: ✅ Ready to launch | ⚠️ preflight blockers found` — final gate.

4. **Surface actionable next steps.** Translate every warning into an exact command the operator can copy-paste. Do **not** run these commands yourself — the agent must not mutate issues. Examples:
   - `needs_triage` / `not_ready_for_agent` for `#N`:
     ```
     gh issue edit N --repo OWNER/REPO --add-label ready-for-agent --remove-label needs-triage
     ```
   - `hitl` for `#N` (only when the operator confirms the issue is in fact AFK-safe):
     ```
     gh issue edit N --repo OWNER/REPO --remove-label hitl
     ```
   - `unresolved_blocker(#X)` — note that the loop will skip the dependent slice until `#X` closes via a merged PR; surface this to the operator so they know which blocker to land first.
   - `Repo: dirty` — print a `git status --short` reminder and tell the operator to commit/stash before launching.
   - `RALPH.md: placeholder {{PRD_REFERENCE}}` — happens when `--enqueue <N>...` was used without `--enqueue-prd`. Suggest re-running with `--enqueue-prd <PRD>` so the marker auto-updates, or instruct the operator to edit `.ralph/RALPH.md` manually.

5. **Confirm AFK intent before recommending bulk label promotion.** If the PRD was published with `needs-triage` (the `to-issues` default) and the operator wants AFK Ralph to run it, **ask** before printing the bulk relabel commands. The conversation should make AFK approval explicit; do not assume it.

6. **Print a summary.** Output either:
   - ✅ **Ready to launch** — preflight verdict is ✅. Remind the user to run `.ralph/launch.sh` (without flags) or start from the dashboard when they are ready.
   - ⚠️ **Blockers found** — list each warning with the actionable command, grouped by issue.

## Constraints

- **Never** run `./.ralph/launch.sh` without `--enqueue`, `--enqueue-prd`, or `--status` in this skill.
- **Never** run `./.ralph/launch.sh --start`, `--foreground`, or any variant that spawns workers.
- **Never** mutate GitHub issues yourself, whether via `gh`, REST/GraphQL calls, MCP tools, or scripts. The skill's job is to surface gaps and print commands for the operator; mutation is the operator's call.
- Do not modify `.ralph/config.json` directly — always go through `--enqueue` or `--enqueue-prd`.
- If the target repo does not have `.ralph/launch.sh`, surface that as a blocker and suggest running `install.sh /path/to/repo`.

## Release-branch loops

If the PRD targets a non-default base branch (e.g. `multi-user`, `next`, `v2`), surface this to the user before launch. The Ralph verifier supports it via two opt-in env vars:

- `RALPH_RELEASE_BRANCH` — name of the release branch.
- `RALPH_BRANCH_PREFIX` — optional per-issue branch prefix (e.g. `mu-`).

These must be exported in the operator's shell (or set in the launcher wrapper) before running `.ralph/launch.sh`. They are not configured via `.ralph/config.json` and are not set by this skill. Note in your summary that the operator needs to export them, and link to `docs/release-branch.md` in the ralph-loop-dashboard repo for the full design.
