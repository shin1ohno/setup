---
name: retro
description: Review the current session and propose improvements to CLAUDE.md, hooks, agents, and skills.
user-invocable: true
---

# Session Retrospective Skill

## Purpose

Analyze the current session's patterns and propose improvements to the Claude Code configuration (CLAUDE.md, hooks, agents, skills, rules).

## Workflow

### Step 0: Summarize Session Context

Before launching the agent, compile a session summary to pass as context:

1. List all commits made in this session (run `git log --oneline` for recent commits)
2. Identify key patterns: files modified, corrections made, repeated instructions, workflows executed
3. Note any rule violations or hook misfires observed

Format as a concise bullet list of session events.

### Step 1: Launch Retrospective Agent

Launch the `session-retrospective` agent in the background using the Agent tool:

- subagent_type: use the session-retrospective agent definition
- Include the session summary from Step 0 in the agent prompt as context
- Instruct: "Review the current conversation for patterns that could be codified into CLAUDE.md rules, hooks, agents, or skills."

### Step 2: Present Findings

When the agent returns, present its findings to the user as a numbered list of proposals. Each proposal should include:

1. **What**: the specific change (e.g., "add a hook that...", "add a rule that...")
2. **Where**: the target file (e.g., `~/.claude/rules/foo.md`, `settings.json`)
3. **Why**: the pattern observed in this session that motivates the change

### Step 3: User Selection

Use AskUserQuestion to let the user select which proposals to implement (multiSelect).

### Step 4: Implement

For each approved proposal, implement the change. Follow existing patterns:
- Hooks: Ruby scripts in `cookbooks/claude-code/files/hooks/`, registered in `settings.json`
- Rules: Markdown files in `cookbooks/claude-code/files/rules/` with appropriate frontmatter
- Agents: Markdown files in `cookbooks/claude-code/files/agents/`
- Skills: `SKILL.md` in `cookbooks/claude-code/files/skills/<name>/`
- CLAUDE.md: edit source of truth at `cookbooks/claude-code/files/CLAUDE.md`

After implementation, sync deploy targets and commit.
