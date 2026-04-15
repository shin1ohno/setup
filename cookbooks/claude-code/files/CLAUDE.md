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

**Examples:**

```
❌ Bad: "以下の3点が問題です。[分析結果]。実装を進めます。"
✓ Good: "以下の3点が問題です。[分析結果]。" → AskUserQuestion("どの方針で進めますか？")

❌ Bad: "調査結果をまとめました。[7項目のリスト]"
✓ Good: "調査結果をまとめました。" → AskUserQuestion("どれを採用しますか？", multiSelect)
```

**When AskUserQuestion is not needed**: when instructions are clear, only one implementation path exists, and all operations are reversible. Same applies during execution of an approved plan — steps included in the plan do not require individual confirmation.

## Critical Rules — General

- Communicate in Japanese
- Git commit messages, source code comments, and spec documentation must be in English
- **Non-trivial tasks**: ALWAYS enter plan mode before implementation. No exceptions. Non-trivial = any task touching 2+ files, any config change with deploy steps, any new agent/hook/skill creation
- **Every conversation**: launch background sub-agents to search Cognee and Mem0 at conversation start. Continue interacting with the user immediately — feed results back when agents complete. No exceptions except trivial edits, typo fixes, and git operations
- **Conversation first turn**: after launching background agents, if the user's initial request has any ambiguity, do NOT proceed with analysis — immediately use AskUserQuestion. Background agent launch does not substitute for clarifying intent
- **Every conclusion**: save findings to Cognee/Mem0 before moving on. Do not wait for the user to ask
- **Every meaningful unit of work**: create a git commit immediately upon completion. Do not wait for the user to ask. A unit = one feature, one bug fix, one refactor, or one logical change
- **This file is managed in two places**: source of truth is `~/ManagedProjects/setup/cookbooks/claude-code/files/CLAUDE.md`, deploy target is `~/.claude/CLAUDE.md`. When editing, always update both files and verify they match with `diff`

## Behavioral Principles

- Act, don't announce: if you can perform an action now, do it — do not narrate your intent to do it later. "I will create a plan" is wasted output; entering plan mode and drafting the plan is useful output
- No-regret items execute immediately: after completing a unit of work, if remaining items are reversible, clearly scoped, and within the approved plan, execute them — do not list them as "remaining tasks" and stop. The only valid reasons to list instead of execute: out of scope, destructive, ambiguous, or requires a decision. If an item requires sudo, immediately present the `! sudo` command to the user rather than deferring it
- Try-then-report: when comparing non-destructive alternatives (API methods, tool options, configurations), try all candidates silently and report only the results — do not ask which to try first or announce each attempt. The user wants outcomes, not play-by-play
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
| Unit of work committed, more items remain | Proceed to next item immediately |
| All plan items complete but plan mode still active | Exit plan mode immediately, do not re-enter |

### Research-to-Plan Pipeline

When a task requires research before planning, run research and planning in parallel — never sequentially:

1. Launch background research agents
2. **Immediately** enter plan mode and begin drafting the plan with available information
3. Incorporate research results into the plan as agents complete
4. Present the completed plan for user approval

**Anti-pattern**: launching research, then announcing "I'll plan when results arrive" and waiting. This is idle time that violates the planning rule.

## Sub-agent Design Principles

Core rules: 1 agent = 1 task, parallelize independent work, background-first for research.

See @~/.claude/rules/sub-agents.md for full guidelines including bulk research pattern and tool selection.

## Writing

See @~/.claude/rules/writing.md

## Session Retrospective

After 3 or more commits in a session, launch the `session-retrospective` agent in the background to analyze conversation patterns. Present any improvement proposals to the user. The user can also trigger this manually with `/retro`.

## Compaction

When compacting, always preserve: the current plan state, all modified file paths, test commands used, and any AskUserQuestion decisions made.

**Plan state preservation**: before compaction, write the active plan to the plan file with:
- Approved items (with checkmarks for completed ones)
- Current execution step
- Remaining tasks with file paths
- Any user decisions (AskUserQuestion results) that affect remaining work

On session resume, read the plan file first to restore context.

## Knowledge Persistence

See @~/.claude/docs/knowledge-persistence.md for persistence rules (Mem0 / Cognee / MEMORY.md).
