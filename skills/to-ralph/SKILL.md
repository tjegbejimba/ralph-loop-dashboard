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

2. **Enqueue the issues.** Run `./.ralph/launch.sh --enqueue-prd <N>` for a PRD whose child slices are already labelled canonically (`ralph:ready`, `work:slice`, priority label, exact `Parent #N` marker), or `./.ralph/launch.sh --enqueue <N> [<N>...]` for explicit child issues. `launch.sh` runs a preflight pass automatically after the enqueue and prints a structured report to stdout — read that output, do not re-run `--status` if `--enqueue` already produced it.

3. **Read the preflight output.** It includes:
   - `Repo: clean | dirty (N files)` — workers abort on a dirty tree.
   - `RALPH.md: ref #N | placeholder {{PRD_REFERENCE}} | marker missing` — workers need a concrete PRD reference.
   - `Queue mode: direct-numbers (N issues) | issueSearch: <query>` — confirms which selection path workers will use.
   - Per-issue warnings/blockers: `missing_state`, `missing_work_type`, `state_conflict(...)`, `work_type_conflict(...)`, `not_runnable_state(ralph:hitl)`, `not_runnable_state(ralph:needs-triage)`, `closed`, `assigned`, `unresolved_blocker(#X)`, `missing_priority(default:priority:P2)`, `lookup_failed`.
   - `Verdict: ✅ Ready to launch | ⚠️ preflight blockers found` — final gate.

4. **Surface actionable next steps.** Translate every blocker into an exact dry-run plan first. Do **not** run these commands yourself — the agent must not mutate issues. Only print `gh issue edit` apply commands after the operator explicitly asks for apply commands. Examples:
   - `missing_state` / `not_runnable_state(ralph:needs-triage)` for `#N`:
     ```
     dry-run: #N add ralph:ready; remove ralph:needs-triage
     apply: gh issue edit N --repo OWNER/REPO --add-label ralph:ready --remove-label ralph:needs-triage
     ```
     Print only the `dry-run:` line by default. Print the `apply:` line only after explicit confirmation.
   - `missing_work_type` for `#N`:
     ```
     dry-run: #N add work:slice or work:standalone after confirming the issue shape
     apply: gh issue edit N --repo OWNER/REPO --add-label work:slice
     ```
   - `missing_priority(default:priority:P2)` for `#N`:
     ```
     dry-run: #N add priority:P2
     apply: gh issue edit N --repo OWNER/REPO --add-label priority:P2
     ```
   - `not_runnable_state(ralph:hitl)` for `#N` (only when the operator confirms the issue is autonomous-safe):
     ```
     dry-run: #N replace ralph:hitl with ralph:ready
     apply: gh issue edit N --repo OWNER/REPO --add-label ralph:ready --remove-label ralph:hitl
     ```
     Print only the `dry-run:` line by default. Print the `apply:` line only after explicit confirmation.
   - `unresolved_blocker(#X)` — note that the loop will skip the dependent slice until `#X` closes via a merged PR; surface this to the operator so they know which blocker to land first.
   - `Repo: dirty` — print a `git status --short` reminder and tell the operator to commit/stash before launching.
   - `RALPH.md: placeholder {{PRD_REFERENCE}}` — happens when `--enqueue <N>...` was used without `--enqueue-prd`. Suggest re-running with `--enqueue-prd <PRD>` so the marker auto-updates, or instruct the operator to edit `.ralph/RALPH.md` manually.

   Example apply command format, only after explicit apply confirmation:
     ```
     gh issue edit N --repo OWNER/REPO --add-label ralph:ready --remove-label ralph:needs-triage
     ```

5. **Confirm autonomous intent before recommending bulk label promotion.** If the PRD was published with `ralph:needs-triage` (the `to-issues` default) and the operator wants Ralph to run it, **ask** before printing bulk relabel commands. The conversation should make autonomous approval explicit; do not assume it.

6. **Print a summary.** Output either:
   - ✅ **Ready to launch** — preflight verdict is ✅. Remind the user to run `.ralph/launch.sh` (without flags) or start from the dashboard when they are ready.
   - ⚠️ **Blockers found** — list each warning with the actionable command, grouped by issue.

## Constraints

- **Never** run `./.ralph/launch.sh` without `--enqueue`, `--enqueue-prd`, or `--status` in this skill.
- **Never** run `./.ralph/launch.sh --start`, `--foreground`, or any variant that spawns workers.
- **Never** mutate GitHub issues yourself, whether via `gh`, REST/GraphQL calls, MCP tools, or scripts. The skill's job is to surface gaps and print dry-run-first commands for the operator; mutation is the operator's call.
- Do not modify `.ralph/config.json` directly — always go through `--enqueue` or `--enqueue-prd`.
- If the target repo does not have `.ralph/launch.sh`, surface that as a blocker and suggest running `install.sh /path/to/repo`.

## Release-branch loops

If the PRD targets a non-default base branch (e.g. `multi-user`, `next`, `v2`), surface this to the user before launch. The Ralph verifier supports it via two opt-in env vars:

- `RALPH_RELEASE_BRANCH` — name of the release branch.
- `RALPH_BRANCH_PREFIX` — optional per-issue branch prefix (e.g. `mu-`).

These must be exported in the operator's shell (or set in the launcher wrapper) before running `.ralph/launch.sh`. They are not configured via `.ralph/config.json` and are not set by this skill. Note in your summary that the operator needs to export them, and link to `docs/release-branch.md` in the ralph-loop-dashboard repo for the full design.
