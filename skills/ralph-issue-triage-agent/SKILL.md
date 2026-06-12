---
name: ralph-issue-triage-agent
description: "Dry-run-only advisory triage for frozen GitHub issue evidence snapshots in Ralph Loop and CLI-vs-agent triage experiments. Use this whenever an unattended or manual agent needs to inspect issue details, comments, labels, linked PR evidence, or repo context and produce Recommendation/Priority/Automation-safety opinions without mutating GitHub. Do not use for live issue editing, commenting, PRD creation, issue slicing, Ralph enqueueing, or implementation planning."
---

# Ralph Issue Triage Agent

Use this skill to turn a bounded, frozen GitHub issue evidence bundle into an advisory triage opinion. The skill owns the durable policy and playbook; the caller owns the run envelope. Do not bake repo names, search queries, issue caps, schedules, or output paths into your reasoning unless the caller supplied them for this run.

The purpose is dry-run triage, not execution. The output should help TJ or a maintainer decide what to do next, and should be stable enough for a later dry-run CLI-vs-agent bake-off.

## Non-negotiable dry-run boundary

During triage runs, perform zero mutations.

Do not:

- Comment on, edit, close, reopen, label, assign, milestone, lock, transfer, or otherwise mutate GitHub issues or PRs.
- Run `gh issue comment`, `gh issue edit`, `gh issue close`, `gh issue reopen`, `gh pr edit`, GraphQL mutations, REST write calls, GitHub issue mutation tools, or scripts that do those writes.
- Invoke `to-prd`, `to-issues`, `to-ralph`, create PRD/slice issues, or enqueue anything into Ralph.
- Start Ralph workers or call any Ralph enqueue path.
- Print exact apply commands or mutation plans. Taxonomy changes may be suggested only as advisory classifications.
- Edit code, run live services, inspect secrets, or broaden the task into implementation design.

Local/session artifacts and chat/report text are allowed. If a future live path is approved, the agent should produce a validated comment artifact only; a constrained deterministic writer/CLI should perform idempotent bot-owned create/update. A scheduled agent should still not directly invoke `gh issue comment` or GraphQL mutations.

## Evidence scope

Work from the frozen snapshot or evidence bundle supplied by the caller. Treat it as the source of truth for the experiment.

In scope:

- Frozen issue title, body, comments, labels, assignees, state, author, dates, reactions, and timeline events supplied by the caller.
- URL-first evidence references in artifacts: issue URL first, linked PR URLs next, then local artifact paths.
- TJ/owner/maintainer comments. When clear, their comments are authoritative over weaker signals.
- Linked PR evidence included in the bundle, or linked PR URLs as evidence that a PR is associated with the issue. If PR details are not frozen in the bundle, say that rather than fetching broad internet context.
- Repo context docs that the caller preloaded once.
- At most three narrow repo searches/file reads per issue when the frozen evidence points to a specific file, symbol, config, doc, or test. Cite each file path used.

Out of scope:

- Internet research, unrelated repositories, secrets, live production services, broad architectural exploration, implementation design, code edits, and all mutations.

If the caller gives only a live issue URL and no frozen evidence, explain that the triage run needs a frozen snapshot. Do not fill the gap with live writes or broad browsing.

## Triage pass

1. **Inventory evidence.** List the issue URL or snapshot ID first, then comments, labels, linked PRs, and local paths. Use owner comments as the highest-signal source when they directly answer priority, scope, or disposition.
2. **Issue detail pass.** Read the frozen title/body/state/dates/labels/assignees/comments before judging. Do not infer from the title alone.
3. **Fit/Risk/Proof/Blocker/Next.**
   - Fit: Is this worth shaping or prioritizing for the repo?
   - Risk: What could go wrong if automated work proceeds later?
   - Proof: What evidence would show the issue is solved or correctly classified?
   - Blocker: What missing fact prevents a stronger recommendation?
   - Next: What is the single best human action?
4. **Optional trust signal.** For non-TJ/non-maintainer issues only, author/opener history can be weak supporting context. Never let it override issue evidence or owner comments, and cite the author/date or snapshot field when used.
5. **Score conservatively.** Favor `Uncertain` for conflicting or weak evidence, and `Needs info` when all variants agree a specific fact is missing.

## Scoring semantics

Use qualitative bands; do not compute a numeric score unless the caller explicitly provides one.

- **Value:** user impact, maintainer impact, repo health, or strategic relevance.
- **Urgency:** active breakage, security/data-loss risk, release blocking, or time sensitivity.
- **Leverage:** small fix with broad payoff, reusable automation, or repeated pain.
- **Clarity:** concrete repro, acceptance evidence, linked proof, and bounded scope.
- **Automation safety:** how safely a later Ralph/agent workflow could act after human prep.

Map the bands conservatively:

- **Recommendation**
  - `Pursue`: worth shaping or prioritizing. This does not mean ready for Ralph.
  - `Refine`: likely worthwhile, but needs scope, acceptance criteria, decomposition, or taxonomy cleanup.
  - `Needs info`: blocked by a missing fact/question that the evidence identifies.
  - `Defer`: valid but low urgency, poor timing, or lower leverage than competing work.
  - `Close`: only with explicit duplicate, obsolete, already-fixed, invalid, or out-of-scope evidence.
  - `Uncertain`: evidence is weak, conflicting, stale, or unstable across runs.
- **Confidence**
  - `high`: direct, consistent frozen evidence supports the top-line call.
  - `medium`: enough evidence to advise, but some inference or missing proof remains.
  - `low`: weak/conflicting evidence; use `Uncertain` unless a narrow `Needs info` question is obvious.
- **Priority** is advisory only.
  - `P0`: active outage, data loss, security exposure, severe regression, or hard blocker with direct evidence.
  - `P1`: important user/maintainer blocker, high-value fix, or time-sensitive issue.
  - `P2`: useful planned work, solid value, not urgent.
  - `P3`: cleanup, nice-to-have, speculative, stale, or low leverage.
- **Automation safety**
  - `safe after prep`: a later agent could work safely once a human has accepted the triage and prepared normal issue metadata.
  - `needs prep`: needs clearer scope, tests, reproduction, acceptance criteria, labels, or decomposition before automation.
  - `hitl-required`: needs human judgment, product decision, credentials/live-service access, risky migration, sensitive data, or owner conflict resolution.

## Citation rules

Every factual or evidence claim must cite the frozen snapshot. If you cannot cite it, mark it as an inference or omit it.

Good citation forms:

- `[issue body: "quoted span"]`
- `[comment @author, YYYY-MM-DD: "quoted span"]`
- `[labels: bug, priority:P1, ralph:needs-triage]`
- `[assignees: @owner]`
- `[state/date: open, updated YYYY-MM-DD]`
- `[linked PR: https://github.com/OWNER/REPO/pull/123]`
- `[file: docs/path.md]`
- `[snapshot: artifacts/issue-123.json]`

Prefer short quoted spans over paraphrases when the claim matters. For repo context, cite the file path and the narrow fact used.

## Output contract

Start with this shared top section. Choose exactly one allowed value for each top field; do not print a range or the full allowed-value list in the actual answer.

Allowed values:

- Recommendation: Pursue / Refine / Needs info / Defer / Close / Uncertain
- Confidence: high / medium / low plus reason
- Priority: P0 / P1 / P2 / P3 advisory only
- Automation safety: safe after prep / needs prep / hitl-required

```markdown
Recommendation: one allowed Recommendation value
Confidence: one allowed Confidence value - reason
Priority: one allowed Priority value advisory only
Automation safety: one allowed Automation safety value
Preflight list:
- ...
Why:
- ...
Next action: One human-action sentence.
```

Then include the richer agent section:

```markdown
Evidence inspected:
- ...

Fit/Risk/Proof/Blocker:
- Fit: ...
- Risk: ...
- Proof: ...
- Blocker: ...

TJ/owner signal:
- ...

Optional trust:
- ...

Suggested next human question:
- ...
```

Rules for the output:

- The `Preflight list` is a checklist of missing facts/prep gates only; it is not an apply plan.
- `Why` bullets must be cited.
- `Next action` must be exactly one human-action sentence.
- `Optional trust` should be `N/A` when the issue comes from TJ/a maintainer or when the frozen snapshot does not support a non-maintainer trust signal.
- Do not include exact `gh`, GraphQL, issue mutation, PRD, slice, or Ralph enqueue commands.

## Harness-consumable shape

If the caller asks for JSON or a local artifact, use a shape compatible with later bake-off aggregation. Write only to the caller-approved local/session artifact path.

```json
{
  "schema_version": "ralph-issue-triage-agent/v1",
  "run_metadata": {
    "provided_by_caller": true
  },
  "frozen_evidence_refs": [],
  "top_fields": {
    "recommendation": "Pursue",
    "confidence": {"level": "medium", "reason": ""},
    "priority": "P2",
    "automation_safety": "needs prep"
  },
  "preflight": [],
  "why": [],
  "evidence_inspected": [],
  "fit_risk_proof_blocker": {
    "fit": "",
    "risk": "",
    "proof": "",
    "blocker": ""
  },
  "tj_owner_signal": [],
  "optional_trust": [],
  "suggested_next_human_question": "",
  "citations": []
}
```

Do not invent run metadata. Copy only what the caller supplied, such as snapshot ID, issue URL, issue number, repo, run index, model, timestamp, or artifact labels.

For the later bake-off, expect artifacts to include: labeled JSON snapshot with run metadata, frozen evidence, labeled CLI output, labeled agent outputs, stability results, deltas, source mapping, and a blinded randomized A/B Markdown report. This skill defines the agent output; it does not implement the harness.

## Stability protocol for repeated runs

The caller may run the agent three times per issue on the same frozen snapshot.

- Treat flips in `Recommendation`, `Priority`, `Automation safety`, or `Confidence` as instability.
- If all top fields are stable, the representative output is run 1.
- If unstable, display a warning and force the aggregate/default recommendation to `Uncertain`.
- Use `Needs info` instead of `Uncertain` only when all variants agree the facts are missing and the missing fact is specific.
- Include an appendix with all runs and the top-field deltas.

Never resolve instability by silently picking the most favorable output.
