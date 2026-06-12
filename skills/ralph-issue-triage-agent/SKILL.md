---
name: ralph-issue-triage-agent
description: "Dry-run-only advisory triage for frozen GitHub issue evidence snapshots in Ralph Loop and CLI-vs-agent triage experiments. Use whenever an unattended or manual agent must inspect frozen issue details, comments, labels, linked PR evidence, owner comments, or repo context and produce URL/snapshot-first Recommendation/Priority/Automation-safety item cards without mutating GitHub. Do not use for live queue discovery, issue editing, commenting, PRD creation, issue slicing, Ralph enqueueing, or implementation planning."
---

# Ralph Issue Triage Agent

Use this skill to turn a bounded, frozen GitHub issue evidence bundle into an advisory triage opinion. The skill owns the durable policy and playbook; the caller owns the run envelope. Do not bake repo names, search queries, issue caps, schedules, or output paths into your reasoning unless the caller supplied them for this run.

The purpose is dry-run triage, not execution. The output should help TJ or a maintainer decide what to do next, and should be stable enough for a later dry-run CLI-vs-agent bake-off. Triage output is maintainer-facing and URL/snapshot-first: every surfaced issue, PR, or snapshot item starts with its canonical URL or frozen snapshot ref, not an opaque issue number.

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

Default to the current supplied snapshot scope. Do not discover live queues, broaden to adjacent repos, fetch unrelated issues, or add new owners/orgs unless the caller explicitly supplied that broader frozen scope. If a batch snapshot contains multiple items, stay inside that batch and say what was not expanded.

In scope:

- Frozen issue title, body, comments, labels, assignees, state, author, dates, reactions, and timeline events supplied by the caller.
- URL-first evidence references in artifacts: issue URL first, linked PR URLs next, then local artifact paths.
- TJ/owner/maintainer comments. When clear, their comments are authoritative over weaker signals.
- Linked PR evidence included in the bundle, or linked PR URLs as evidence that a PR is associated with the issue. If PR details are not frozen in the bundle, say that rather than fetching broad internet context.
- Repo context docs that the caller preloaded once.
- At most three narrow repo searches/file reads per issue when the frozen evidence points to a specific file, symbol, config, doc, or test. Cite each file path used.

Out of scope:

- Internet research, unrelated repositories, secrets, live production services, broad architectural exploration, implementation design, code edits, and all mutations.

If the caller gives only a live issue URL and no frozen evidence, explain that the triage run needs a frozen snapshot. Do not fill the gap with live reads, live writes, queue discovery, broad browsing, or title-only inference.

## Triage pass

1. **Anchor the item.** Start each item card with the canonical issue URL, PR URL, or frozen snapshot ref. Never return only `#123`, queue positions, or other opaque references.
2. **Inventory evidence.** List the issue URL or snapshot ID first, linked PR URLs next, then comments, labels, assignees, dates, state, author, reactions/timeline events, and local paths. If linked PR details are frozen, read them before judging the issue; if only a PR URL is present, cite only that association.
3. **Issue detail pass before judgment.** Read the frozen title, body, state, dates, labels, assignees, comments, and linked PR evidence before classifying. Do not infer from the title, labels, or bot metadata alone.
4. **Owner authority pass.** Treat clear TJ/owner/maintainer comments as authoritative routing instructions for scope, priority, disposition, or next action. They override ordinary labels, bot inference, opener speculation, and weak trust signals. If there is no clear owner signal, say the call is based on the frozen evidence.
5. **Fit/Risk/Proof/Blocker/Next.**
   - Fit: Is this worth shaping or prioritizing for the repo?
   - Risk: What could go wrong if automated work proceeds later?
   - Proof: What evidence would show the issue is solved or correctly classified?
   - Blocker: What missing fact prevents a stronger recommendation?
   - Next: What is the single best human action?
6. **Assign a Ralph triage lane.** Use `Immediate / worth shaping` for clearly valuable work to shape or prioritize, `Needs TJ or owner judgment` for product/risk/access/disposition calls, and `Defer/close/supersede` for stale, duplicate, obsolete, invalid, out-of-scope, or lower-leverage items.
7. **Optional trust signal.** Use trust only for non-TJ/non-maintainer items. Keep it factual and weak: author/open date, repo/global activity if supplied, known/unknown/bot. Trust is never proof and never overrides owner comments or frozen issue evidence. If the snapshot lacks trust data, write `N/A`.
8. **Score conservatively.** Prefer useful `Pursue`/`Refine` when the substantive path is consistent, `Needs info` when a specific missing fact blocks the next action, and `Uncertain` only when evidence or repeated-run outputs materially conflict after deterministic tie-breaks.

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
  - `low`: weak/conflicting evidence; pair with `Uncertain` for unresolved material conflicts, or with `Needs info`/`Refine` when the missing fact or prep gate is specific.
- **Priority** is advisory only.
  - `P0`: active outage, data loss, security exposure, severe regression, or hard blocker with direct evidence.
  - `P1`: important user/maintainer blocker, high-value fix, or time-sensitive issue.
  - `P2`: useful planned work, solid value, not urgent.
  - `P3`: cleanup, nice-to-have, speculative, stale, or low leverage.
- **Automation safety**
  - `safe after prep`: a later agent could work safely once a human has accepted the triage and prepared normal issue metadata.
  - `needs prep`: needs clearer scope, tests, reproduction, acceptance criteria, labels, or decomposition before automation.
  - `hitl-required`: needs human judgment, product decision, credentials/live-service access, risky migration, sensitive data, or owner conflict resolution.

`Pursue` and `Refine` are maintainer-facing priority/shaping opinions only. They never mean "ready for Ralph" and never authorize issue slicing, PRD creation, queue mutation, or worker launch.

PRD #86 taxonomy awareness is advisory only: `ralph:*`, `priority:P0`-`priority:P3`, and `work:prd|slice|standalone` are classification/preflight language, not label-edit commands or mutation instructions.

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

Start every surfaced issue/PR/snapshot item with this shared item card. Choose exactly one allowed value for each locked top field; do not print a range or the full allowed-value list in the actual answer.

Allowed values:

- Recommendation: Pursue / Refine / Needs info / Defer / Close / Uncertain
- Confidence: high / medium / low plus reason
- Priority: P0 / P1 / P2 / P3 advisory only
- Automation safety: safe after prep / needs prep / hitl-required

```markdown
Frozen ref: canonical issue URL, canonical PR URL, or frozen snapshot ref
Recommendation: one allowed Recommendation value
Confidence: one allowed Confidence value - reason
Priority: one allowed Priority value advisory only
Automation safety: one allowed Automation safety value
Preflight list:
- ...
Why:
- ...
Next action: One human-action sentence.
Triage lane: Immediate / worth shaping OR Needs TJ or owner judgment OR Defer/close/supersede
```

Then include the richer agent section:

```markdown
Evidence inspected:
- ...

Fit/Risk/Proof/Blocker/Next:
- Fit: ...
- Risk: ...
- Proof: ...
- Blocker: ...
- Next: ...

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
- `Triage lane` is a maintainer review bucket, not an execution state.
- `Optional trust` should be `N/A` when the issue comes from TJ/a maintainer or when the frozen snapshot does not support a non-maintainer trust signal.
- Do not include exact `gh`, GraphQL, issue mutation, PRD, slice, or Ralph enqueue commands.
- For batch output, group item cards under `Immediate / worth shaping`, `Needs TJ or owner judgment`, and `Defer/close/supersede`; still start each item card with its URL or snapshot ref.

## Harness-consumable shape

If the caller asks for JSON or a local artifact, use a shape compatible with later bake-off aggregation. Write only to the caller-approved local/session artifact path.

```json
{
  "schema_version": "ralph-issue-triage-agent/v1",
  "run_metadata": {
    "provided_by_caller": true
  },
  "primary_ref": "https://github.com/OWNER/REPO/issues/123 or artifacts/issue-123.json",
  "frozen_evidence_refs": [],
  "top_fields": {
    "recommendation": "Pursue",
    "confidence": {"level": "medium", "reason": ""},
    "priority": "P2",
    "automation_safety": "needs prep"
  },
  "triage_lane": "Immediate / worth shaping",
  "preflight": [],
  "why": [],
  "evidence_inspected": [],
  "fit_risk_proof_blocker": {
    "fit": "",
    "risk": "",
    "proof": "",
    "blocker": "",
    "next": ""
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

- Normalize before comparing. Enum values are material; minor confidence rationale wording, citation phrasing, or equivalent next-action wording is not material unless it changes the required human decision.
- If all material top fields are stable, the representative output is run 1.
- Treat `Pursue` and `Refine` as the same worth-shaping path when the frozen evidence and next action agree. Tie-break to `Refine` when scope, acceptance criteria, proof, taxonomy cleanup, or decomposition still needs human prep; tie-break to `Pursue` only when the item is already bounded and proof/prep is clear.
- Use `Needs info` when a specific missing fact blocks choosing between action paths. Do not downgrade a useful `Pursue`/`Refine` path to `Needs info` when the missing work is ordinary prep already captured by `Refine` or preflight.
- Use `Close` only with explicit duplicate, obsolete, already-fixed, invalid, or out-of-scope evidence, preferably owner-confirmed or stable across runs. A single close outlier is not enough.
- Use `Defer` for low leverage, stale timing, or competing-priority evidence. Do not use `Defer` merely because confidence wording differs.
- Use `Uncertain` only for material path conflict after the above rules, such as close-vs-pursue without owner resolution, defer-vs-P0 urgency conflict, contradictory owner comments, or incompatible blockers.
- Priority tie-break: keep `P0` only with direct outage/data-loss/security/hard-blocker evidence; otherwise choose the majority priority, and for adjacent unresolved ties choose the less urgent value.
- Automation-safety tie-break: choose the stricter value only when the stricter run names a concrete human-risk blocker; otherwise choose the majority value.
- Confidence tie-break: choose the lower confidence level when top-field variance remains, and explain the variance in the reason. Do not force `Uncertain` just because confidence level or wording differs.
- Include an appendix with all runs, top-field deltas, which deltas were material, and the deterministic tie-break used.

Never resolve instability by silently picking the most favorable output. Make the tie-break visible so a maintainer can audit it.
