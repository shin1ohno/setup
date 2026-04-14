# Claude Code Personal Preferences

## Critical Rules — AskUserQuestion

IMPORTANT: AskUserQuestion is the highest-priority rule. When in doubt, ask.

- **Every ambiguity**: use AskUserQuestion instead of guessing — never present analysis as implicit proposal. Guessing wrong costs more than a 5-second pause
- **Analysis is NOT a proposal**: presenting findings without a question is a rule violation — always end with AskUserQuestion asking which direction to proceed
- Do not guess when unclear — ALWAYS use AskUserQuestion to confirm before proceeding. This includes: ambiguous requirements, multiple valid interpretations, destructive or hard-to-reverse choices, and scope decisions that affect the user's workflow

**Pause** response generation and confirm with the user in these situations:

1. **Ambiguous requirements**: e.g., "improve this", "clean this up" — when the output direction has multiple valid interpretations
2. **Before destructive operations**: file deletion, git reset, database changes — anything irreversible
3. **Scope decisions**: when tempted to fix something "while you're at it" — do not expand scope unilaterally
4. **Technical choices**: when multiple equivalent options exist and the user's preference is unknown
5. **Uncertain assumptions**: when you catch yourself thinking "this is probably right"

**When AskUserQuestion is not needed**: when instructions are clear, only one implementation path exists, and all operations are reversible. Same applies during execution of an approved plan — steps included in the plan do not require individual confirmation.

## Critical Rules — General

- Communicate in Japanese
- Git commit messages, source code comments, and spec documentation must be in English
- **Non-trivial tasks**: ALWAYS enter plan mode before implementation. No exceptions. Non-trivial = any task touching 2+ files, any config change with deploy steps, any new agent/hook/skill creation
- **Every conversation**: launch background sub-agents to search Cognee and Mem0 at conversation start. Continue interacting with the user immediately — feed results back when agents complete. No exceptions except trivial edits, typo fixes, and git operations
- **Every conclusion**: save findings to Cognee/Mem0 before moving on. Do not wait for the user to ask
- **Every meaningful unit of work**: create a git commit immediately upon completion. Do not wait for the user to ask. A unit = one feature, one bug fix, one refactor, or one logical change
- **This file is managed in two places**: source of truth is `~/ManagedProjects/setup/cookbooks/claude-code/files/CLAUDE.md`, deploy target is `~/.claude/CLAUDE.md`. When editing, always update both files and verify they match with `diff`

## Behavioral Principles

- Simple first: try the simplest solution first
- When codifying a production hotfix into the repository, do not default to placing it in the same file that was edited on the server. Evaluate change frequency and resource recreation impact, then place the fix in the appropriate layer

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

## Session Retrospective

After 3 or more commits in a session, launch the `session-retrospective` agent in the background to analyze conversation patterns. Present any improvement proposals to the user. The user can also trigger this manually with `/retro`.

## Compaction

When compacting, always preserve: the current plan state, all modified file paths, test commands used, and any AskUserQuestion decisions made.

## Knowledge Persistence

See @~/.claude/docs/knowledge-persistence.md for persistence rules (Mem0 / Cognee / MEMORY.md).
