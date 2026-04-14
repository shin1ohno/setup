# Claude Code Personal Preferences

This file contains my personal preferences for Claude Code.

## Critical Rules

These rules must always be followed:

- Communicate in Japanese
- Git commit messages, source code comments, and spec documentation must be in English
- Always ensure files end with a newline character (`\n`)
- Never include "Generated with Claude Code" or "Co-Authored-By: Claude" in git commits
- **Every conversation**: search Cognee and Mem0 before generating the first substantive response. No exceptions except trivial edits, typo fixes, and git operations
- **Every ambiguity**: use AskUserQuestion instead of guessing. Guessing wrong costs more than a 5-second pause
- **Every conclusion**: save findings to Cognee/Mem0 before moving on. Do not wait for the user to ask
- **This file is managed in two places**: source of truth is `~/ManagedProjects/setup/cookbooks/claude-code/files/CLAUDE.md`, deploy target is `~/.claude/CLAUDE.md`. When editing, always update both files and verify they match with `diff`

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
- Do not guess when unclear — ALWAYS use AskUserQuestion to confirm before proceeding. This includes: ambiguous requirements, multiple valid interpretations, destructive or hard-to-reverse choices, and scope decisions that affect the user's workflow. Guessing and proceeding is worse than pausing to ask

### When to AskUserQuestion

AskUserQuestion is quality control, not hesitation. **Pause** response generation and confirm with the user in these situations:

1. **Ambiguous requirements**: e.g., "improve this", "clean this up" — when the output direction has multiple valid interpretations
2. **Before destructive operations**: file deletion, git reset, database changes — anything irreversible
3. **Scope decisions**: when tempted to fix something "while you're at it" — do not expand scope unilaterally
4. **Technical choices**: when multiple equivalent options exist and the user's preference is unknown
5. **Uncertain assumptions**: when you catch yourself thinking "this is probably right"

**When AskUserQuestion is not needed**: when instructions are clear, only one implementation path exists, and all operations are reversible. Same applies during execution of an approved plan — steps included in the plan do not require individual confirmation.

## Planning and Execution Model

- Use `/plan` mode to create a thorough plan before starting any non-trivial task
- Get user confirmation on the plan before proceeding
- **After plan approval, execute the full implementation autonomously** — do not stop to ask permission at each step
- Produce a PR as the reviewable artifact: branch, implement, test, commit, then `gh pr create`
- The user reviews the PR, not the intermediate steps

### Autonomous Execution Boundary

| Situation | Action |
|-----------|--------|
| Plan approved, implementation straightforward | Proceed autonomously |
| Tests fail during implementation | Fix and retry, do not ask |
| Ambiguity discovered not covered by the plan | AskUserQuestion |
| Scope creep temptation | AskUserQuestion |
| Destructive operation not in the plan | AskUserQuestion |
| Implementation complete | Create PR, notify user |

## Sub-agent Design Principles

- 1 agent = 1 task: never give multiple roles to a single agent
- Run parallelizable tasks in parallel (Agent tool parallel calls)
- Review gate: always include a review step for important outputs
- Background first: any research task that does not block the next step must use `run_in_background: true`. This includes Cognee/Mem0 searches at conversation start, web research, and catalog lookups. The main conversation should never idle while waiting for research results — either launch background agents or continue interacting with the user

### Bulk Research Pattern

When collecting information from multiple sources (URLs, products, brands, categories), **proactively** apply this pattern (propose and execute before the user asks for parallelism):

1. **Split by independence**: divide targets so each agent's work is self-contained — 1 agent = 1 brand, category, or theme
2. **Launch all agents in background in parallel**: use `run_in_background: true` for all agents in a single message
3. **Each agent's responsibility**: WebFetch reviews → fetch specs from manufacturer sites → save to Cognee via cognify
4. **Progress reporting**: show a progress table with agent status (researching... / **done**) and update it as each agent completes

```
Example: "Save all reviews from this page" → launch sub-agents per category in background
Example: "Look up all reviews for this brand" → 1 agent per brand in background
Example: "Find bindings for this board" → 1 agent per brand group in background
```

### Tool Selection Guide

| Situation | Tool |
|-----------|------|
| One-off research / exploration | Agent tool (Explore) |
| Simple code search | Glob / Grep directly |
| 3+ step non-standard task | /plan → implement |
| 2+ independent research tasks | Background sub-agents (parallel) |
| Multi-brand/category survey | 1 agent per category (background) |

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

## Knowledge Persistence: Mem0 / Cognee / MEMORY.md

Choose the system based on the nature of the data. When in doubt, save to both — the cost of duplication is lower than the cost of missing information.

| Destination | Target | Examples |
|-------------|--------|----------|
| **Mem0** | User attributes, preferences, possessions | Body measurements, owned gear, taste preferences, workflow style |
| **Cognee** | Domain knowledge, external documents, analysis results | Product specs, technical insights, comparison reviews, error solutions |
| **MEMORY.md** | Project-specific working context | Codebase quirks, build process caveats |

**Decision rule**: tied to "who" → Mem0. Tied to "what" → Cognee. Scoped to this project → MEMORY.md.

Skip operations for any system whose MCP is not connected in the current session.

## Mem0

Cross-project memory for user attributes, preferences, and possessions.
Available via MCP tools: `add_memories`, `search_memory`, `list_memories`.

### When to Search

Run search_memory in parallel with Cognee at conversation start. Always search when the topic relates to user attributes (possessions, preferences, body measurements).

### When to Save

Save immediately when user attributes are revealed during conversation — do not wait to be asked. Targets: body measurements, owned devices/gear, food preferences, riding style, workflow preferences, relationships/roles.

## Cognee Knowledge Graph

Cross-project knowledge store for technical knowledge, product reviews, business insights, and reference documents.
Available via MCP tools: `search`, `cognify`, `save_interaction`, `list_data`.
If Cognee MCP is not connected in this session, skip all Cognee operations silently.

### When to Search (READ)

Run a Cognee search **before** generating a response to the first message in a conversation.

When to search:
1. **Conversation start**: the first message involving a non-trivial task
2. **Before decisions**: past decisions, reviews, or evaluations on the same topic/product/technology
3. **Product or tool discussions**: existing reviews, comparisons, recommendations
4. **On errors**: error messages or patterns — may have been solved before
5. **Investment or business questions**: past analyses, market data, recommendations on similar topics

**No search needed**: trivial edits, typo fixes, and git operations only.

**Search type selection:**

| Need | search_type |
|------|-------------|
| Recommendations, relationships, why-questions | GRAPH_COMPLETION |
| Specific facts, error solutions, product specs | CHUNKS |
| Overview of a topic, product category summary | SUMMARIES |

Use `top_k=5` for focused queries, `top_k=15` for broad exploration.

### When to Save (WRITE)

When a research, review, or analysis task reaches a conclusion (summary or comparison table produced), save immediately **before** moving to the next task. Do not wait for the user to ask.

**Always save (use `cognify`):**
- Product reviews, evaluations, and comparison results
- Recommended product/tool combinations with rationale
- Root cause of a non-obvious bug and its fix
- Architectural decisions and their rationale
- Surprising API behavior, gotchas, or workarounds
- Infrastructure/deployment patterns
- Investment or business analysis results
- Cross-project patterns or conventions
- User attributes, possessions, and preferences (body measurements, owned gear/devices, taste preferences, etc.) — save proactively whenever revealed in conversation, without waiting for the user to ask

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
| PDF/document | `/ingest-pdf` skill | When user provides a file |
| Large batch (10+ files) | `bulk_ingest.py` via docker | One-time imports |

### PDF and Document Ingestion

Use the `/ingest-pdf` skill. Manual procedure if needed:

1. Attempt text extraction with PyPDF2. If extracted characters < pages × 100, classify as image-based PDF
2. Image-based PDF: render each page as an image with PyMuPDF (DPI=200) → extract text via Claude's vision
3. Upload with a unique filename via REST API `POST /api/v1/add` (use `datasetName` parameter to create a dedicated dataset)
4. `POST /api/v1/cognify` (specify target with `datasets` parameter)
5. Verify ingestion with MCP `search` (`GRAPH_COMPLETION`)

**Watcher (`~/ingest/drop/`) is deprecated**: it ingests files mid-write and causes data_id collisions on duplicate filenames. Use the REST API for uploads instead.

### Cognee Operational Notes

- **Filename uniqueness**: `/api/v1/add` generates data_id deterministically from the filename. Duplicate filenames are treated as the same record — use unique names like `<category>_<name>_<detail>_text.txt`
- **Dataset isolation**: prefer per-domain datasets (e.g., `snowboard_<brand>`) over aggregating into main_dataset. Enables independent rebuilds on container failure
- **Container restart risk**: restarts can lose internal `text_<hash>.txt` files. If cognify returns 409, this is the cause. Fix by re-uploading data and re-running cognify
- **API info**: Base URL `http://localhost:8001`, auth via `POST /api/v1/auth/login` (form: `username=default_user@example.com&password=default_password`)
