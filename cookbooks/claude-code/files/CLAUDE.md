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
- Do not guess when unclear — ALWAYS use AskUserQuestion to confirm before proceeding. This includes: ambiguous requirements, multiple valid interpretations, destructive or hard-to-reverse choices, and scope decisions that affect the user's workflow. Guessing and proceeding is worse than pausing to ask.

## Planning Before Implementation

- Use `/plan` mode to create a thorough plan before starting any non-trivial task
- Always get user confirmation on the plan before proceeding with implementation
- Break down complex tasks into clear, actionable steps

## Sub-agent Design Principles

- 1 agent = 1 task: never give multiple roles to a single agent
- Run parallelizable tasks in parallel (Agent tool parallel calls)
- Review gate: always include a review step for important outputs

### Tool Selection Guide

| Situation | Tool |
|-----------|------|
| One-off research / exploration | Agent tool (Explore) |
| Simple code search | Glob / Grep directly |
| 3+ step non-standard task | /plan → implement |


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

## Cognee Knowledge Graph

Cross-project knowledge store for technical knowledge, product reviews, business insights, and reference documents.
Available via MCP tools: `search`, `cognify`, `save_interaction`, `list_data`.
If Cognee MCP is not connected in this session, skip all Cognee operations silently.

### When to Search (READ)

Search Cognee proactively — do NOT wait for the user to ask:

1. **Conversation start**: When the first message involves a non-trivial task, search for relevant prior knowledge
2. **Before decisions**: Search for past decisions, reviews, or evaluations on the same topic/product/technology
3. **Product/tool discussions**: Search for existing reviews, comparisons, or recommendations before giving advice
4. **When encountering errors**: Search for the error message or pattern — it may have been solved before
5. **Investment/business questions**: Search for prior analysis, market data, or past recommendations on similar topics
6. **Unfamiliar project/tool**: Search before asking the user questions that Cognee might already answer

Do NOT search for: trivial edits, typo fixes, git operations, or tasks where you already have full context.

**Search type selection:**

| Need | search_type |
|------|-------------|
| Recommendations, relationships, why-questions | GRAPH_COMPLETION |
| Specific facts, error solutions, product specs | CHUNKS |
| Overview of a topic, product category summary | SUMMARIES |

Use `top_k=5` for focused queries, `top_k=15` for broad exploration.

### When to Save (WRITE)

Save proactively — do NOT wait for the user to ask. When a research, review, or analysis task reaches a natural conclusion (e.g., you output a summary or comparison table), save immediately before moving on. This applies to ALL topics, not just software engineering.

**Always save (use `cognify`):**
- Product reviews, evaluations, and comparison results
- Recommended product/tool combinations with rationale
- Root cause of a non-obvious bug and its fix
- Architectural decisions and their rationale
- Surprising API behavior, gotchas, or workarounds
- Infrastructure/deployment patterns
- Investment or business analysis results
- Cross-project patterns or conventions

**Save lightly (use `save_interaction`):**
- Troubleshooting steps that led to a resolution
- Quick product impressions or initial evaluations
- Project-specific setup steps

**Never save:**
- Routine code changes (rename, formatting, simple refactor)
- Information already in project README or docs
- Temporary state (current branch, WIP status)
- Secrets, credentials, tokens, passwords

### Save Format

When calling `cognify`, structure the data as a self-contained knowledge note:

For technical knowledge:
```
## [Topic]: [Specific Subject]
Context: [project name, tech stack]
Problem: [what happened]
Solution: [what worked]
Why: [root cause or rationale]
```

For product reviews and evaluations:
```
## Review: [Product Name] ([Category])
Rating: [1-5 or qualitative]
Use case: [what it's good for]
Pros: [strengths]
Cons: [weaknesses]
Compared to: [alternatives considered]
Verdict: [recommendation and context]
```

For business/investment insights:
```
## Analysis: [Subject]
Context: [market, timing, constraints]
Key findings: [main points]
Recommendation: [action items]
Risk factors: [caveats]
```

### Ingestion Method Selection

| Data | Method | When |
|------|--------|------|
| Single insight (< 500 words) | `cognify` MCP tool | During conversation |
| Interaction log | `save_interaction` MCP tool | End of meaningful exchange |
| File from user (path/URL) | Copy to `~/ingest/drop/` | User provides file to ingest |
| Large batch (10+ files) | `bulk_ingest.py` via docker | One-time imports |

### PDF and Document Ingestion

When the user provides a PDF/document (path or URL) for ingestion:
1. Copy the file to `~/ingest/drop/` (watcher will auto-ingest)
2. Wait ~60 seconds for watcher to process and cognify
3. **Verify indexing**: Run `list_data` to confirm the document appears, then `search` with a specific fact from the document to verify graph quality
4. **If verification fails**: Try re-ingesting with `cognify` using extracted text, or report the issue to the user
5. For URLs: download the file first with `curl`/`wget` to `~/ingest/drop/`

### Relationship to MEMORY.md

- **MEMORY.md**: project-scoped, conversation-scoped facts (file paths, current architecture state)
- **Cognee**: cross-project knowledge with lasting value (patterns, decisions, reviews, recommendations)
- Do not duplicate between the two systems
