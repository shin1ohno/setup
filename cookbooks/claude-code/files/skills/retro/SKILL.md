---
name: retro
description: Review the current session and propose improvements to CLAUDE.md, hooks, agents, and skills.
user-invocable: true
---

# Session Retrospective Skill

## Purpose

Analyze the current session's patterns and propose improvements to the Claude Code configuration (CLAUDE.md, hooks, agents, skills, rules). Every retrospective is persisted in full to the session's memory MCP (Step 2) — regardless of adoption; only user-approved proposals are implemented into the configuration (Step 5), and the adoption decisions are written back onto the saved notes (Step 6).

## Workflow

### Step 0: Summarize Session Context

Before launching the agent, compile a session summary to pass as context:

1. List all commits made in this session (run `git log --oneline` for recent commits)
2. Identify key patterns: files modified, corrections made, repeated instructions, workflows executed
3. Note any rule violations or hook misfires observed

Format as a concise bullet list of session events.

### Step 0: Collect Session Metrics

Before launching the agent, gather quantitative metrics:

1. `git log --oneline` — count commits in this session
2. Count AskUserQuestion invocations in the conversation
3. Count tool permission denials
4. Count plan revisions

Include these metrics in the agent prompt as structured data.

### Step 0: Recall Past Retro Records

Fetch prior retrospectives from the session's memory MCP (whichever memory connector this host registers):

1. `browse(filters: {tags: ["retro-proposal"]}, limit: 30, sort: "written_at:desc")` — recent proposal notes with their adoption `Status`; fall back to `recall` on the session's main topics if `browse` filtering is unavailable
2. Include the results in the agent prompt so the dedup guard can exclude adopted proposals and avoid re-proposing rejected ones

If the memory connector is unavailable (auth expired, not registered), write "past retro records unavailable" into the agent prompt and continue — do not block the retrospective.

### Step 0: Sweep Deflected / Dropped Review Findings

Before launching the agent, sweep the session for review findings that were surfaced but never acted on, so they are not silently lost:

1. `security-guidance` PreToolUse warnings that were acknowledged but not fixed (the edit went through anyway)
2. `code-reviewer` / `silent-failure-hunter` / `security-review` findings marked out-of-scope, deferred, or "later"
3. `ReportFindings` items the user deferred, and any "I'll note this for follow-up" the session made but never wrote down

For each surviving finding, capture it into the project's `TODO.md` (no project context → route per `~/.claude/docs/todo-management.md`: memory `remember(tags:["todo"])` with a close condition) with: what the finding was, which reviewer/hook surfaced it, why it was deflected, and a concrete first step to close it. Include these captured items in the agent prompt so the retrospective can decide whether any warrant a rule/hook change.

If the sweep finds nothing, note "no deflected findings this session" and continue.

### Step 1: Launch Retrospective Agent

Launch the `session-retrospective` agent in the background using the Agent tool:

- subagent_type: use the session-retrospective agent definition
- Include the session summary, metrics, past retro records, and swept findings from Step 0 in the agent prompt as context
- Instruct: "Review the current conversation for patterns that could be codified into CLAUDE.md rules, hooks, agents, or skills."

### Step 2: Persist the Full Retrospective to Memory

When the agent returns, save the complete retrospective to the session's memory MCP BEFORE presenting it — every retro is persisted, independent of which proposals the user later approves:

1. Build the retro-key: `retro-<YYYYMMDD>-<project dirname>-<first 8 chars of the session UUID>` (no UUID available → use `<HHMM>`)
2. Session hub note — `remember(type='episode', tags: ["retro", "<retro-key>"])`: date, project, host, session metrics, Section A (Patterns to Reinforce) in full, and the title list of all proposals
3. One note per proposal — `remember(type='knowledge', tags: ["retro", "<retro-key>", "retro-proposal"])`: the proposal verbatim (Type / Target file / Pattern observed / Proposed change / Priority), `Status: proposed`, and the retro-key in the body
4. Record the memory id returned by each `remember` call — Step 6 revises them
5. Echo a one-line receipt: `retro persisted: <N> proposals + hub → <retro-key>`

If the memory write fails (connector auth expired, server down), still present the findings and state the failed persistence explicitly so the save can be re-run after re-auth — never silently drop the retro.

### Step 3: Present Findings

Present the agent's findings in two sections:

**Section A: Patterns to Reinforce** — workflows, rules, or agent invocations that worked well this session. These should be preserved and not accidentally removed in future config changes.

**Section B: Improvement Proposals** — numbered list where each proposal includes:

1. **What**: the specific change (e.g., "add a hook that...", "add a rule that...")
2. **Where**: the target file (e.g., `~/.claude/rules/foo.md`, `settings.json`)
3. **Why**: the pattern observed in this session that motivates the change

### Step 4: User Selection

Use AskUserQuestion to let the user select which proposals to implement (multiSelect).

### Step 5: Implement

For each approved proposal, implement the change. Follow existing patterns:
- Hooks: Ruby scripts in `cookbooks/claude-code/files/hooks/`, registered in `settings.json`
- Rules: Markdown files in `cookbooks/claude-code/files/rules/` with appropriate frontmatter
- Agents: Markdown files in `cookbooks/claude-code/files/agents/`
- Skills: `SKILL.md` in `cookbooks/claude-code/files/skills/<name>/`
- CLAUDE.md: edit source of truth at `cookbooks/claude-code/files/CLAUDE.md`

After implementation, sync deploy targets and commit.

### Step 6: Write Back Adoption Decisions

After Step 5 completes (or the user declines every proposal), update each saved proposal note via `revise(id, content)` — same content with the `Status:` line changed:

- `Status: adopted (commit <hash> / PR #<n>)` for implemented proposals
- `Status: rejected (<user's stated reason, if any>)` for declined proposals
- Leave `Status: proposed` untouched when the user defers the decision (e.g. a background retro whose selection has not happened yet)

Also revise the hub note with a one-line adoption summary (`adopted X / rejected Y / deferred Z`), and echo a receipt line.
