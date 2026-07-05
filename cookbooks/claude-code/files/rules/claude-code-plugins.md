# Claude Code Plugin Integration

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/claude-code-plugins-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

Official plugins from `claude-plugins-official` and `anthropic-agent-skills` are registered via the cookbook. Each plugin self-describes its triggers via skill/command frontmatter — Claude auto-invokes them when the user's request matches. The rules below codify integration points where an explicit default differs from the plugin's own suggestion, or where a workflow habit should change.

## Skill Availability Check

Before invoking a plugin skill (e.g. `/roundtable:start`, `/feature-dev:feature-dev`, `/plugin-dev:create-plugin`), verify it is actually listed in the session's available-skills reminder. If the user requests a skill that is not present:

1. State the fact in one line: "`<skill>` は本セッションでは未登録です" (user-visible)
2. Propose a fallback via AskUserQuestion:
   - Option A: proceed with a manual/inline equivalent (e.g. run the roundtable deliberation format by hand)
   - Option B: pause so the user can install the plugin (`/plugin install …` or cookbook update) and retry

Do NOT silently fall back to a hand-rolled approximation — the user expects the plugin's structure (and may have trusted its output format for downstream work). Transparent substitution with consent is acceptable; opaque substitution is not.

Applies equally to commands and agents from plugins. Built-in Claude Code slash commands (`/help`, `/clear`, etc.) are not covered by this rule.

Applies equally to **MCP tools / tool-groups the user explicitly asked for** (e.g. a browser-operation request → `mcp__claude-in-chrome__*`). If a `ToolSearch` probe (see `~/.claude/rules/sub-agents.md`) also shows the tool absent, state the absence in one line, then AskUserQuestion offering: (a) proceed with a degraded substitute (e.g. `open <url>` — note click / form-input is unavailable), or (b) re-enable and do the intended operation (check `/mcp`, run the `mcp-auth` skill, reconnect the extension) before proceeding. Running a degraded substitute without consent is the same opaque-substitution violation. Origin: 2026-06 sage 635f5a9c — declared the tool absent, then ran an `open` substitute without consent and offered no re-enable path.

## Skill Creation

When the user asks to create a new skill (model-invocable behavior, not plain slash-command), **invoke the `skill-creator` skill** rather than hand-writing a `SKILL.md`. `skill-creator` runs evals, comparisons, and description-tuning — outputs higher-quality skills than a draft-then-commit loop.

Exception: this repo's skills are cookbook-managed. After `skill-creator` produces a validated skill directory, move the contents into `cookbooks/claude-code/files/skills/<name>/` and add `<name>` to the skills list in `cookbooks/claude-code/default.rb`.

## Plugin Development

When building a new Claude Code plugin (manifest + components), use the `plugin-dev` plugin's skills: `agent-development`, `command-development`, `hook-development`, `mcp-integration`, `plugin-settings`, `plugin-structure`, `skill-development`. These encode Anthropic's official structure and avoid the common mistake of placing `skills/` / `commands/` inside `.claude-plugin/`.

## Hook Generation

When the user asks to create a new Claude Code hook based on a conversation pattern ("whenever X happens, warn me"), use the `hookify` plugin. Hookify rules live in `.claude/hookify.{rule-name}.local.md` and are distinct from the Ruby hook scripts in `cookbooks/claude-code/files/hooks/` — the Ruby hooks enforce hard guards (pre-commit checks, co-authored-by blocking), hookify rules emit soft reminders.

Do NOT use hookify for scenarios that belong in a Ruby hook script. Ruby hooks are mandatory for: commit gating, tool-input mutation, whitespace/newline enforcement.

## Self-describing skill pointers

These plugins self-advertise their own triggers via frontmatter — Claude auto-invokes on match. Use:

- `mcp-server-dev` — building/designing an MCP server; invoke before writing server code
- `frontend-design` — non-trivial UI implementation; invoke before writing CSS/component code
- `playground` — single-file live-controls interactive HTML explorer
- `claude-automation-recommender` (`claude-code-setup`) — onboarding an unfamiliar repo for Claude Code setup recs (read-only)
- `document-skills` (`anthropic-agent-skills`) — create/edit DOCX/PDF/PPTX/XLSX (distinct from cookbook `ingest-pdf`)
- `/design-md:generate` — generate a `DESIGN.md` design-system rulebook (3+ AI-generated screens)
- `/roundtable:start` — structured multi-expert deliberation ("レビューして" / "議論して")
- `hookify` — soft-reminder hook from a conversation pattern (NOT hard guards — those stay Ruby hooks)
- `plugin-dev` skills — building a new Claude Code plugin

Detail (full per-plugin prose + triggers): see `~/.claude/docs/claude-code-plugins-detail.md#self-describing-skill-pointers`.

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
