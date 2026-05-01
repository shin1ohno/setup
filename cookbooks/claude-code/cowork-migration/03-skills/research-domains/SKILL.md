---
name: research-domains
description: |
  Use this skill when the user wants periodic / quarterly / cross-domain research on best practices — triggers like "what should we adopt", "audit our setup against industry best practices", "research domain X", "AI company practices", or any "look at what's new in [software / management / investment / hobbies] and propose updates to our stuff" framing. Runs domain-specific web research informed by Mem0 user context, prioritizes Anthropic / Claude blog as primary source for AI-tooling updates, surfaces actionable repository / preference / skill changes. Distinct from `research` skill which targets a single topic; this skill spans multiple domains and produces an improvement proposal list.
---

# Research Domains Skill

Systematically research best practices across multiple domains and propose concrete improvements to user preferences, skills, project memory, or scheduled tasks.

## Argument Parsing

The user's message specifies the domain(s):

- `software` / `management` / `investment` / `hobbies` — single domain
- `all` or omitted — all four domains

## Domain-Specific Priorities

### Management

Beyond general engineering management, prioritize organizational insights from leading AI companies (Anthropic, OpenAI, DeepMind):

- Team structure and scaling (research ↔ engineering ↔ product)
- Decision-making frameworks at fast-scaling organizations
- Writing-first culture (RFCs, design docs, DVQ)
- Leadership principles and values frameworks

### Software (Claude / Anthropic Blog — MUST READ)

Always fetch and analyze `https://claude.com/blog` as a primary source. For each post:

1. Fetch full article via WebFetch
2. Extract: problem solved, use cases enabled, what changed
3. Map to user's setup: does this affect their preferences, skills, project memory, or workflows
4. Propose concrete changes

Posts about Agent Skills, MCP, hooks, context window, and memory are highest priority.

## Workflow

### Step 0: Load Prior Proposals

Before launching new research, search Cognee with `"Quarterly Audit Proposal"` (CHUNKS, top_k=10). Include any unreviewed prior proposals in Step 2's output. Skip silently if Cognee is not connected.

### Step 1: Launch Background Research

For each requested domain, launch a background sub-agent (Agent tool, `run_in_background: true`):

- Mem0 query for user context (skill preferences, possessions, hobbies)
- Cognee query for existing knowledge on the domain
- WebSearch + WebFetch for current best practices
- Source credibility tagging per finding

For the software domain, instruct the sub-agent to fetch `https://claude.com/blog` as a mandatory step.

### Step 2: Present Findings

Two sections per domain:

**Section A: Domain Summary** — key findings with source credibility tags.

**Section B: Improvement Proposals** — numbered. Each:

```
## Proposal N: [Title]

**What**: [specific change]
**Where**: [target — preferences / skill / project memory / scheduled task]
**Why**: [best practice or gap that motivates it]
**Domain**: [software / management / investment / hobby name]
```

### Step 3: User Selection

AskUserQuestion (multiSelect) to choose which proposals to implement.

### Step 4: Plan and Implement

For each selected proposal, follow the relevant skill (`writing` for written deliverables, `interview` for under-specified, manual edits for preferences). Save findings to Cognee before closing the session.

## When NOT to use

- Acute single-topic question (use `research`)
- The user wants strategic advice on one decision (use `roundtable` plugin if installed)
