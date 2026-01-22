# Claude Code Personal Preferences

This file contains my personal preferences for Claude Code.

## Critical Rules

These rules must always be followed:

- Communicate in Japanese
- Git commit messages and source code comments must be in English
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
- Create a SESSION_PROGRESS.md document at the project root to record plans and achievements; split it appropriately to conserve tokens

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
