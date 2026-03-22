# Claude Code Personal Preferences

This file contains my personal preferences for Claude Code.

## Critical Rules

These rules must always be followed:

- Communicate in Japanese
- Git commit messages, source code comments, and spec documentation must be in English
- Always ensure files end with a newline character (`\n`)
- Never include "Generated with Claude Code" or "Co-Authored-By: Claude" in git commits

## Code Quality Standards

- Throw errors instead of silently ignoring them (unless explicitly instructed otherwise)
- Do not leave empty lines containing only whitespace
- Write clean, readable code that follows language conventions
- Use consistent indentation and formatting
- Do not use mock data in production code
- When using passwords in test data or documentation, use obviously fake values (e.g., `example!PASS123`)

## General Preferences

- Follow existing code conventions and patterns in each project
- Prefer editing existing files over creating new ones

## Behavioral Principles

- Simple first: try the simplest solution first
- Do not guess when unclear — ask (use AskUserQuestion)

## Planning Before Implementation

- Use `/plan` mode to create a thorough plan before starting any non-trivial task
- Always get user confirmation on the plan before proceeding with implementation
- Break down complex tasks into clear, actionable steps

## Sub-agent Design Principles

- 1 agent = 1 task: never give multiple roles to a single agent
- Run parallelizable tasks in parallel (Agent tool parallel calls)
- Review gate: always include a review step for important outputs
- Use TAKT pieces for reusable, multi-step workflows

### Tool Selection Guide

| Situation | Tool |
|-----------|------|
| One-off research / exploration | Agent tool (Explore) |
| Multi-step repeatable workflow | /takt {piece} |
| Simple code search | Glob / Grep directly |
| 3+ step non-standard task | /plan → implement |

## Spec Workflow

When spec-workflow MCP is available, use it for feature development:

- Run tasks in parallel whenever possible to maximize efficiency
- Complete one task at a time, then commit changes before moving to the next
- Each task completion should result in a git commit

## Using o3 MCP

Three o3 MCPs are available with different reasoning levels:

| MCP | Use Case |
|-----|----------|
| `o3-high` | Complex architectural decisions, difficult debugging |
| `o3` | General reasoning, moderate complexity tasks |
| `o3-low` | Quick lookups, simple questions |

Use o3 when:
- Searching or fetching information from the web
- Need external knowledge beyond training data
- Want a second opinion on complex problems

## Writing Principles

Core objective: maximize the utility of what is communicated while minimizing the cost of reading.

### Structure: Pyramid Principle

- Lead with the conclusion (BLUF: Bottom Line Up Front)
- Support with key arguments, then details
- Each level answers "why?" or "how?" from the level above
- Group related arguments using MECE (Mutually Exclusive, Collectively Exhaustive)

### Style

- Default to narrative prose; use bullet points only when they genuinely aid comprehension
- Replace adjectives and adverbs with concrete numbers and specific facts (e.g., "significantly improved" → "improved by 40%")
- Amazon-style narrative memo format; body max 6 pages for long-form documents

### Editing Lens: Marginal Utility

Every sentence must earn its place. Apply the marginal utility test:

- When adding: does this sentence increase the document's total value more than the reading cost it adds?
- When reviewing: if I remove this sentence, does the document lose value?
- A shorter document that conveys the same information is always better
- When marginal utility of the next sentence approaches zero, stop writing

## Git Commit Format

### First Line (Summary)

- Keep under 50 characters
- Start with `{component}: ` prefix when possible (shortened filename or directory)
- Use imperative mood (e.g., "Add feature" not "Added feature")
- Prefer contextful verbs over generic "Change", "Add", "Fix", "Update"
- Explain the "why", not just the "what"

### Body (Optional)

- Leave second line empty
- Add detailed explanation, background, or reasoning
- Include context that helps reviewers understand the change
