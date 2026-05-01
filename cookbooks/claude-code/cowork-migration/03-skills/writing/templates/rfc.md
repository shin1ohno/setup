# RFC (Request for Comments) Template

A technical decision document that proposes a specific change and invites structured feedback before implementation.

## When to Use

- Architectural decisions affecting multiple teams or systems
- Technology choices with long-term implications
- Process changes that require buy-in from stakeholders
- Any decision where "we should have written this down" would be said later

## Structure

### Summary (3-5 sentences)

What is being proposed and why, in plain language. A reader should understand the core idea without reading further.

### Motivation

The problem or opportunity that motivates this proposal.
- What is the current state and why is it insufficient?
- What specific pain points or failures triggered this RFC?
- What happens if we do nothing?

### Proposal

The recommended solution in sufficient detail to implement.
- Technical design with key components and their interactions
- API or interface changes (if applicable)
- Data model changes (if applicable)
- Migration or rollout strategy

### Alternatives Considered

2-3 alternatives that were seriously evaluated.
For each:
- Brief description of the approach
- Why it was rejected (specific trade-off, not "it didn't feel right")

### Risks and Mitigations

Known risks of the proposed approach.
For each risk:
- Likelihood (low/medium/high)
- Impact (low/medium/high)
- Mitigation strategy or acceptance rationale

### Decision

To be filled after the review period.
- Decision: Accepted / Rejected / Deferred
- Decision date:
- Decider(s):
- Key conditions or modifications:

## Process

1. Author writes RFC and circulates for async review (target: 1 week)
2. Reviewers comment inline or in a dedicated thread
3. Author addresses comments and updates the document
4. DRI (Directly Responsible Individual) makes the final call
5. Decision section is filled in and the RFC is archived

## Writing Guidelines

- Target length: 2-4 pages for the core proposal (appendices as needed)
- Use diagrams for system interactions — text alone is insufficient for architecture
- Write for a reader who understands the domain but not the specific context
- Every "should" needs a "because"
