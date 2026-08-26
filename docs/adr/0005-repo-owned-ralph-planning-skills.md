# Repo-owned Ralph planning skills

Ralph's PRD pipeline originally depended on two user-global skills,
`to-prd` and `to-issues`. Pull requests #47 and #91 documented those names as
pre-existing stages, and pull request #113 explicitly said their fixes lived
outside this repository. Neither skill was therefore installed or validated by
Ralph.

The upstream skill set later renamed `to-prd` to `to-spec` and merged
`to-issues` into `to-tickets`. The old slugs were deleted. Depending on those
user-global copies left the repository's advertised end-to-end workflow incomplete.

## Decision

Ralph owns adapted `to-spec` and `to-tickets` skills in `skills/`.

- `to-spec` publishes a Ralph PRD parent with `work:prd`,
  `ralph:evaluated`, and one priority label. The artifact remains a PRD in Ralph's
  domain and CLI even though the skill uses the current "spec" name.
- `to-tickets` authors Ralph child slices with the exact `Parent #N` marker and
  bulleted `- #N` entries under `## Blocked by`, then applies the filing-time
  born-ready rule.
- Both remain model-invoked because Ralph's skills compose them:
  `to-spec` can hand a new PRD to `ralph-orchestrator`, and the orchestrator invokes
  `to-tickets` during `prd-run`.
- `install.sh` continues to discover every repo-owned `skills/*/SKILL.md`
  directory. It symlinks them into `~/.agents/skills/` on POSIX/WSL and writes
  marked, refreshable managed copies in native Windows Git Bash.

The repository does not ship compatibility aliases for the deleted names. This
keeps one source of truth and prevents old and new planning skills from triggering
against the same request.

## Consequences

The repository now contains and validates every skill required by its documented
Ralph workflow. Existing global installations must rerun `install.sh --skills-only`
after this change lands. The installer refreshes its marked copies but deliberately
does not delete unmarked global skill directories; an operator should remove
deprecated or legacy unmarked copies manually after verifying their origin.
