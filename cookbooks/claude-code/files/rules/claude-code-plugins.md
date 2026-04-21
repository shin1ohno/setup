# Claude Code Plugin Integration

Official plugins from `claude-plugins-official` and `anthropic-agent-skills` are registered via the cookbook. Each plugin self-describes its triggers via skill/command frontmatter — Claude auto-invokes them when the user's request matches. The rules below codify integration points where an explicit default differs from the plugin's own suggestion, or where a workflow habit should change.

## Skill Creation

When the user asks to create a new skill (model-invocable behavior, not plain slash-command), **invoke the `skill-creator` skill** rather than hand-writing a `SKILL.md`. `skill-creator` runs evals, comparisons, and description-tuning — outputs higher-quality skills than a draft-then-commit loop.

Exception: this repo's skills are cookbook-managed. After `skill-creator` produces a validated skill directory, move the contents into `cookbooks/claude-code/files/skills/<name>/` and add `<name>` to the skills list in `cookbooks/claude-code/default.rb`.

## Plugin Development

When building a new Claude Code plugin (manifest + components), use the `plugin-dev` plugin's skills: `agent-development`, `command-development`, `hook-development`, `mcp-integration`, `plugin-settings`, `plugin-structure`, `skill-development`. These encode Anthropic's official structure and avoid the common mistake of placing `skills/` / `commands/` inside `.claude-plugin/`.

## Hook Generation

When the user asks to create a new Claude Code hook based on a conversation pattern ("whenever X happens, warn me"), use the `hookify` plugin. Hookify rules live in `.claude/hookify.{rule-name}.local.md` and are distinct from the Ruby hook scripts in `cookbooks/claude-code/files/hooks/` — the Ruby hooks enforce hard guards (pre-commit checks, co-authored-by blocking), hookify rules emit soft reminders.

Do NOT use hookify for scenarios that belong in a Ruby hook script. Ruby hooks are mandatory for: commit gating, tool-input mutation, whitespace/newline enforcement.

## MCP Server Development

When designing or building an MCP server, invoke `mcp-server-dev` skills. They cover deployment models (remote HTTP / MCPB / local stdio), tool design patterns, authentication flows, and interactive MCP apps. Use before writing server code, not after.

## Frontend / UI Work

For non-trivial UI implementation (new component, page redesign, visual system), invoke the `frontend-design` skill before writing CSS or component code. It guides away from generic AI-aesthetic output and toward production-grade design decisions.

For quick interactive HTML exploration (single-file playground with live controls), use the `playground` skill.

## Repository Onboarding

When entering an unfamiliar repository for the first time and the user asks for Claude Code setup guidance, invoke the `claude-automation-recommender` skill (from `claude-code-setup` plugin). It surveys the codebase and recommends 1-2 of each automation type (hooks, subagents, skills, plugins, MCP servers). Read-only; user implements the recommendations manually.

## CLAUDE.md Maintenance

For capturing session learnings into CLAUDE.md, the `claude-md-management` plugin provides `/revise-claude-md` (command) and `claude-md-improver` (skill). Use `claude-md-improver` for multi-CLAUDE.md audit across a repo; use `/revise-claude-md` for single-session additions.

In this repo, the source of truth for the global CLAUDE.md is `cookbooks/claude-code/files/CLAUDE.md`. When `claude-md-management` modifies `~/.claude/CLAUDE.md`, mirror the change to the cookbook source and `diff` to verify.

## Commit / Push / PR Workflow

The `commit-commands` plugin provides `/commit`, `/commit-push-pr`, `/clean_gone`. These are shortcuts — they do NOT follow the branch-hygiene rule in `@~/.claude/rules/git-commit.md` (branch check before first commit, PR-branch default, no direct push to `main`).

Default behavior: follow the manual workflow in `git-commit.md`. Use `/commit-commands:*` only when the user explicitly requests it OR when the current state already satisfies the branch-hygiene rule (descriptive branch name, diverged from `origin/main`, no scope bleed).

## Feature Development Workflow

The `feature-dev` plugin offers a 7-phase workflow with specialized agents. This is an ALTERNATIVE to the EnterPlanMode + AskUserQuestion workflow in the main CLAUDE.md.

Default: use EnterPlanMode for non-trivial tasks (per CLAUDE.md). Invoke `feature-dev` only when the user explicitly requests its structured flow OR when the task is greenfield and the user has no existing scope constraints.

## Code Review

- **`code-reviewer`** (from `pr-review-toolkit`): proactive review after writing code, before commit/PR. Confidence-scored findings
- **`code-simplifier`** (standalone + inside pr-review-toolkit): reduce complexity while preserving behavior. Invokable as `/simplify` via the existing cookbook skill, or via the plugin agent for deeper passes
- **`silent-failure-hunter`** (from `pr-review-toolkit`): specialized for error-handling audits. Invoke when the diff adds try/catch, fallback logic, or error callbacks
- **`security-review` skill** (cookbook): security-focused review via `code-reviewer` with OWASP-focused prompt (see the skill's Step 3)

The `code-simplifier` plugin agent and the `/simplify` cookbook skill coexist: the skill is the user-invoked entry point; the plugin agent is invoked as a subagent inside pr-review-toolkit's PR review flow.

## Security Guidance Hook

`security-guidance` installs a PreToolUse hook that warns on 9 pattern matches (command injection, XSS, unsafe eval, etc.) during file edits. This is ambient — no action required beyond reading the warnings. Complements but does NOT replace the on-demand `/security-review` skill.

## Document Skills (DOCX / PDF / PPTX / XLSX)

The `document-skills` from `anthropic-agent-skills` marketplace handle creation and editing of Office-format documents. Claude auto-invokes when the user asks for these formats. Note: the cookbook's `ingest-pdf` skill is separate — it handles PDF → Cognee ingestion with Vision API fallback, distinct from `document-skills`' PDF form-field manipulation.
