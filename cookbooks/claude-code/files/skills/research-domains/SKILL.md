---
name: research-domains
description: Periodically research best practices across software, management, investment, and hobbies. Proposes improvements to this repository.
user-invocable: true
argument-hint: "[domain or 'all']"
---

# Research Domains Skill

## Purpose

Systematically research best practices across multiple domains and propose concrete improvements to the repository's skills, agents, rules, and cookbooks.

## Argument Parsing

`$ARGUMENTS` specifies the domain(s) to research:
- `software` / `management` / `investment` / `hobbies` — single domain
- `all` or omitted — all domains

## Domain-Specific Research Priorities

### Management

In addition to general engineering management practices, prioritize organizational insights published by leading AI companies (Anthropic, OpenAI, DeepMind, etc.). These companies actively share practices on:
- Team structure and scaling (research ↔ engineering ↔ product)
- Decision-making frameworks at fast-scaling organizations
- Culture of writing and documentation (RFCs, design docs)
- Leadership principles and values frameworks

Launch a dedicated sub-agent for AI company organizational research alongside the general management researcher.

## Workflow

### Step 1: Launch Domain Research

Launch the `domain-researcher` agent in the background via the Agent tool:

- Pass the target domain(s) from `$ARGUMENTS`
- The agent will query Mem0 for user context, Cognee for existing knowledge, and the web for current best practices

### Step 2: Present Findings

When the agent returns, present findings in two sections:

**Section A: Domain Summaries** — key findings per domain, with source credibility tags

**Section B: Improvement Proposals** — numbered list of concrete changes to this repository. Each proposal includes:

1. **What**: the specific change (new skill, agent, rule, hook, or cookbook)
2. **Where**: target file path
3. **Why**: the best practice or gap that motivates the change
4. **Domain**: which domain this belongs to

### Step 3: User Selection

Use AskUserQuestion (multiSelect) to let the user choose which proposals to implement.

### Step 4: Plan and Implement

For each selected proposal:
1. Enter plan mode if the combined changes are non-trivial (2+ files)
2. Implement following existing patterns (skills in `cookbooks/claude-code/files/skills/`, agents in `agents/`, etc.)
3. Run `./bin/mitamae local linux.rb --dry-run` to verify
4. Commit with descriptive message
