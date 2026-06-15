# CLI-first hybrid issue triage

Issue triage sits before Ralph execution. It decides whether an issue is worth
shaping, whether its taxonomy/preflight is safe, and whether it should ever move
toward `ralph:ready`. That makes triage a control-plane signal, not worker work.

We considered two approaches:

1. Make an LLM triage agent the primary decision-maker.
2. Make the deterministic triage CLI the primary primitive, with an LLM agent as
   an advisory escalation path over frozen evidence.

We picked **CLI-first hybrid**.

## Decision

The deterministic Ralph triage CLI is the source-of-truth primitive for automated
triage. Future orchestrator flows should consume structured CLI output such as
`triage --json`, not spawn a triage agent as the default path.

The CLI owns:

- issue query and snapshot creation;
- canonical label taxonomy and preflight checks;
- baseline scoring and recommendation JSON;
- idempotent fingerprinting for advisory bot comments;
- any permitted comment create/update path, bounded to bot-owned triage comments;
- deterministic lane routing from `ralph:needs-triage` to guarded lane labels
  such as `ralph:fast-lane`, while stopping before `ralph:ready`.

The LLM triage skill is advisory only. It may inspect a **frozen CLI snapshot** to
add maintainer-facing nuance, citations, owner-signal interpretation,
Fit/Risk/Proof/Blocker/Next reasoning, and owner-decision briefs. It does not
discover live queues, mutate GitHub, enqueue Ralph, create PRDs or slices, or
launch workers.

The orchestrator owns the transition from triage to execution. It may consume
CLI output, optionally consume an approved agent advisory artifact, and then
build a run queue only when the issue is explicitly ready: `ralph:ready`,
passing preflight, dependencies satisfied, and no human-interaction blocker.

Ralph workers remain scoped to implementation: one issue under `RALPH.md`, tests,
review, PR, and merge verification.

## Escalation rule

Use the LLM triage skill only when deterministic output needs a maintainer-grade
second look:

- low confidence;
- conflicting taxonomy or preflight;
- suspicious `Close` or `Defer` recommendation;
- owner/TJ decision needed;
- issue body or comments contain nuanced sequencing, safety, or dependency
  signals that the CLI cannot represent well.

The LLM output can enrich or challenge the CLI result, but it is not the source
of truth for labels, queue construction, enqueue, or launch.

## Evidence

The dry-run bake-off found that the first LLM triage skill was too unstable:
aggregate agent output was forced to `Uncertain` for every issue. After
refactoring the skill toward URL-first maintainer triage cards and
Fit/Risk/Proof/Blocker/Next reasoning, stability improved materially:

- exact top-field enum stability: 4/9 issues;
- recommendation-path stability after `Pursue`/`Refine` normalization: 9/9;
- forced `Uncertain`: 0/9;
- representative agent outcomes: `Refine` 4, `Pursue` 4, `Defer` 1;
- deterministic CLI outcomes: `Pursue` 8, `Close` 1.

That result supports the hybrid boundary: the agent is valuable for nuance and
catching questionable CLI calls, but probabilistic output should not drive
labels, queue state, or launch decisions.

## Consequences

- Scheduled automation and the dashboard can share the same deterministic
  `triage --json` primitive.
- The future Ralph orchestrator can keep a compact repo-scoped ledger from
  structured triage output instead of raw `gh` dumps.
- Agent reasoning remains available where it adds value, but it is fenced behind
  frozen snapshots and no-mutation rules.
- Live commenting and lane routing, if enabled, should be performed by the
  deterministic writers (`triage --live` and `promote-lanes --live`), not
  directly by a scheduled LLM agent.
- A suspicious deterministic result should trigger agent review, not automatic
  `ralph:ready` promotion, enqueue, or launch.
