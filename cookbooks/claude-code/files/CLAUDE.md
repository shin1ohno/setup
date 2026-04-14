# Claude Code Personal Preferences

This file contains my personal preferences for Claude Code.

## Critical Rules

These rules must always be followed:

- Communicate in Japanese
- Git commit messages, source code comments, and spec documentation must be in English
- Always ensure files end with a newline character (`\n`)
- Never include "Generated with Claude Code" or "Co-Authored-By: Claude" in git commits
- **Non-trivial tasks**: ALWAYS enter plan mode before implementation. No exceptions
- **Every ambiguity**: use AskUserQuestion instead of guessing — never present analysis as implicit proposal. Guessing wrong costs more than a 5-second pause
- **Every conversation**: search Cognee and Mem0 before generating the first substantive response. No exceptions except trivial edits, typo fixes, and git operations
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

Core rules: 1 agent = 1 task, parallelize independent work, background-first for research.

See @~/.claude/rules/sub-agents.md for full guidelines including bulk research pattern and tool selection.

## Writing

See @~/.claude/rules/writing.md

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

See @~/.claude/docs/knowledge-persistence.md for search/save rules, formats, and operational notes.
