---
name: to-ralph
description: Load a PRD issue into the Ralph TDD loop and surface preflight status. Use when the user wants to queue a PRD for Ralph after completing to-issues, or when they say "enqueue for Ralph", "send to Ralph", or "start the Ralph loop".
---

# To Ralph

Close the planning loop by enqueueing a PRD's issues into Ralph and surfacing any blockers before the human launches workers.

```
grill-me → to-prd → to-issues → to-ralph → ./.ralph/launch.sh
```

**You must never run `.ralph/launch.sh` without one of the permitted flags (`--enqueue` or `--status`). Launching workers is a human decision. Do not run `launch.sh` with `--start`, `--foreground`, or any flag that starts workers.**

## Steps

1. **Identify the PRD issue number.** Take it from conversation context, or ask the user if it is not clear.

2. **Enqueue the issues.** Run `./.ralph/launch.sh --enqueue <N>` (where `<N>` is the PRD issue number or the individual child issue numbers) in the target repo to write the issue numbers into `.ralph/config.json`. This sets up the queue without starting any workers.

3. **Check preflight status.** Run `./.ralph/launch.sh --status` and capture the output. This surfaces `needs_triage`, `not_ready_for_agent`, and `unresolved_blocker` preflight warnings from the issue tracker.

4. **Evaluate blockers.** Parse the status output for any warnings:
   - `needs_triage` — issues not yet labeled `ready-for-agent`.
   - `not_ready_for_agent` — issues missing the required label.
   - `unresolved_blocker` — open blocking issues that are not yet closed.

5. **Print a summary.** Output either:
   - ✅ **Ready to launch** — all issues are queued and preflight is clean. Remind the user to run `.ralph/launch.sh` (without flags) or start from the dashboard when they are ready.
   - ⚠️ **Blockers found** — list each preflight warning with an actionable hint (e.g., "apply `ready-for-agent` label to issue #N").

## Constraints

- **Never** run `./.ralph/launch.sh` without `--enqueue` or `--status` in this skill.
- **Never** run `./.ralph/launch.sh --start`, `--foreground`, or any variant that spawns workers.
- Do not modify `.ralph/config.json` directly — always go through `--enqueue`.
- Do not close or modify any issues.
- If the target repo does not have `.ralph/launch.sh`, surface that as a blocker and suggest running `install.sh /path/to/repo`.

## Release-branch loops

If the PRD targets a non-default base branch (e.g. `multi-user`, `next`, `v2`), surface this to the user before launch. The Ralph verifier supports it via two opt-in env vars:

- `RALPH_RELEASE_BRANCH` — name of the release branch.
- `RALPH_BRANCH_PREFIX` — optional per-issue branch prefix (e.g. `mu-`).

These must be exported in the operator's shell (or set in the launcher wrapper) before running `.ralph/launch.sh`. They are not configured via `.ralph/config.json` and are not set by this skill. Note in your summary that the operator needs to export them, and link to `docs/release-branch.md` in the ralph-loop-dashboard repo for the full design.
