# Domain Docs

How engineering skills should consume this repository's domain documentation
when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repository root, when it exists.
- Relevant ADRs under [`docs/adr/`](../adr/).

If `CONTEXT.md` does not exist, proceed silently. Do not propose creating it
upfront. The `domain-modeling` skill creates it lazily when domain terms or
decisions are actually resolved.

## File structure

This is a single-context repository:

```text
/
|-- CONTEXT.md
|-- docs/
|   `-- adr/
`-- extension/, ralph/, skills/, test/
```

`docs/adr/` holds system-wide architectural decisions. Do not create
context-scoped ADR directories unless the repository is deliberately split
into independently modeled contexts.

## Use the glossary's vocabulary

When output names a domain concept in an issue title, proposal, hypothesis, or
test, use the term defined in `CONTEXT.md`. Avoid synonyms that the glossary
explicitly rejects.

If a needed concept is absent, first reconsider whether it is established
repository language. If the gap is real, note it for the `domain-modeling`
skill rather than inventing competing terminology.

## Flag ADR conflicts

If proposed work contradicts an existing ADR, surface the conflict explicitly
instead of silently overriding the decision. Cite the ADR and explain why it
may need to be revisited.
