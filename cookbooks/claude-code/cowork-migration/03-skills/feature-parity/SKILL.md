---
name: feature-parity
description: |
  Use this skill when the user wants to compare two implementations and find what's missing — triggers are "compare these two repos", "check parity with the reference SDK", "what features are missing vs X", "audit [my impl] against [reference]", or any port / rewrite / second-implementation context where one codebase should match another. Performs parallel exhaustive inventory of public APIs, methods, events, options, types in both implementations, produces a gap table grouped by priority (high / medium / low), and lets the user pick which gaps to address. Best run in a workspace folder containing both implementations.
---

# Feature Parity Audit Skill

Exhaustively compare a current implementation against a reference and produce a gap analysis.

## Workflow

### Step 1: Identify Reference

Use AskUserQuestion to confirm:

- Path to the reference implementation (must be readable from workspace folder or sandbox)
- Path to the current implementation (default: workspace folder root)

If both paths are not in the workspace, ask the user to add them via the workspace folder picker.

### Step 2: Parallel Exploration

Launch two Agent sub-agents in parallel:

**Agent 1 — Reference audit:**

- Read every source file in the reference
- Inventory every public API, method, event, callback, option, type
- Document behavioral details: error handling, edge cases, lifecycle

**Agent 2 — Current audit:**

- Read every source file in the current project
- Inventory every public type, method, trait, function
- Document test coverage and verified behaviors

### Step 3: Gap Analysis

Compare the two inventories. Produce a table:

| Feature | Reference | Current | Priority | Notes |
|---|---|---|---|---|
| ... | present/absent | present/absent | high/medium/low | ... |

### Step 4: Present Results

Group gaps by priority:

- **High** — required for SDK consumers (missing APIs, broken contracts)
- **Medium** — completeness improvements (missing services, edge cases)
- **Low** — nice-to-have (logging, browser support, convenience methods)

### Step 5: User Decision

AskUserQuestion (multiSelect) to choose which gaps to address.

### Step 6: Plan

For selected gaps, draft an implementation plan and present for approval. If the user has the `interview` skill or the Cowork plan workflow, defer to those for the actual specing.

## When NOT to use

- Two implementations in different languages where API shapes don't compare 1:1 (need a custom audit)
- Implementations whose public surface is undefined (no separation between public API and internal code)
