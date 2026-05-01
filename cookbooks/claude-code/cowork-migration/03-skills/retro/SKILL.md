---
name: retro
description: |
  Use this skill when the user wants to retrospect on a session, conversation, or recent stretch of work — triggers are "/retro", "let's do a retro", "review this session", "what could we have done better", "any patterns we should codify", or any moment when 3+ commits have been made or the user signals a natural pause point. Analyzes the conversation for repeated corrections, missed AskUserQuestion opportunities, recurring workflows, and effective patterns; proposes concrete updates to user preferences, skills, project memory, or scheduled tasks. Also fires reflexively when the user is "blocked on a manual action" (reading, deciding, restarting) so retrospective work happens during idle time.
---

# Session Retrospective Skill

Analyze the current session and propose improvements to the Cowork configuration (preferences, skills, project memory, scheduled tasks).

## Workflow

### Step 0: Compile Session Context

Before analysis, gather:

1. **Commits in this session** (if a git repo is in scope): `git log --oneline -<N>` since session start
2. **Conversation events**: corrections made, repeated instructions, workflows executed, AskUserQuestion invocations, tool permission denials, plan revisions
3. **Outputs produced**: files in workspace folder created/modified

Format as a concise bullet list. Keep this in your context for Step 1.

### Step 1: Analyze for Patterns

Look for these in the conversation:

1. **Repeated Corrections** → preference candidate (the same mistake corrected 2+ times means it should be codified)
2. **Repeated Explanations** → preference or project memory candidate (context Claude could have inferred)
3. **Repeated Workflows** → skill candidate (multi-step processes executed manually 2+ times)
4. **Repeated Sub-agent Patterns** → skill candidate
5. **Effective Patterns** → preserve list (workflows that worked, agents that produced clean outputs)
6. **Existing Config Issues** → modification candidate (rules ignored, skills mis-fitting)

### Step 2: Deduplication Guard

If this session has already produced commits, edits to preferences, or skill creations, exclude proposals that map to those changes. Mark them "Already codified in [hash / edit]".

### Step 3: Present Findings

Two sections:

**Section A: Patterns to Reinforce** — what worked. Preserve these in future config edits.

**Section B: Improvement Proposals** — numbered list. Each:

```
## Proposal N: [Short title]

**Type**: preference / skill / project-memory / scheduled-task
**Target**: [where it should go]
**Pattern observed**: [what happened in this session — concrete example]
**Proposed change**: [exact text to add or behavior to codify]
**Priority**: high / medium / low
```

### Step 4: User Selection

Use AskUserQuestion (multiSelect) to let the user pick which proposals to implement.

### Step 5: Implement

For each approved proposal:

- **Preference**: surface the exact text the user should paste into Cowork User preferences (Cowork preferences are user-managed; Claude cannot edit them programmatically)
- **Skill**: draft a `SKILL.md` and supporting files in the workspace folder
- **Project memory**: write to the relevant project memory file (Cognee `cognify` if connected, or a CLAUDE.md/AGENTS.md in the project repo)
- **Scheduled task**: use the `schedule` skill

After implementation, present `computer://` links for any new files.

## When NOT to use

- Sessions with < 3 meaningful interactions (nothing to retrospect)
- The user has explicitly declined retro work in this session
- The session is mid-task and not at a natural pause
