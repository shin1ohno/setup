---
name: audit-claudemd
description: Audit CLAUDE.md and rules for redundancy with Claude Code defaults. Proposes deletions to reduce context bloat.
user-invocable: true
---

# Audit CLAUDE.md Skill

## Purpose

Detect rules in CLAUDE.md and `~/.claude/rules/` that duplicate Claude Code's default behavior. Reducing redundant instructions frees context window for user-specific guidance.

## Workflow

### Step 1: Collect Rules

Read all configuration files:

1. `~/.claude/CLAUDE.md` (global instructions)
2. All files in `~/.claude/rules/` directory
3. Project-level `CLAUDE.md` if present in the current working directory

Parse each file into individual rules or directives (one per bullet point, paragraph, or table row).

### Step 2: Research Defaults

Launch a background Agent (subagent_type: "claude-code-guide") to gather Claude Code's built-in behaviors:

- Query: "What are Claude Code's default behaviors for: code style, git operations, file editing, error handling, security, tool usage, communication style, and planning?"
- Focus on behaviors that are built-in and do not need explicit instruction

### Step 3: Classify

For each rule extracted in Step 1, classify it as:

| Classification | Meaning |
|---------------|---------|
| **Redundant** | Claude Code already does this by default without instruction |
| **Custom** | User-specific preference that overrides or extends defaults |
| **Uncertain** | Cannot determine without testing |

### Step 4: Present Results

Display a table with columns: Rule (abbreviated), Source File, Classification, Rationale.

Sort by classification: Redundant first, then Uncertain, then Custom.

### Step 5: User Selection

Use AskUserQuestion (multiSelect) to let the user choose which Redundant rules to remove.

### Step 6: Apply

For each selected rule:
1. Remove the rule from the source file (`cookbooks/claude-code/files/CLAUDE.md` or `cookbooks/claude-code/files/rules/*.md`)
2. Sync the deploy target (`~/.claude/CLAUDE.md` or `~/.claude/rules/*.md`)
3. Verify both files match with `diff`

Commit the changes with a descriptive message.
