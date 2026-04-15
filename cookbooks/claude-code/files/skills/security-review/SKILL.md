---
name: security-review
description: Complete a security review of the pending changes on the current branch
user-invocable: true
allowed-tools: ["Bash", "Agent", "Read", "Grep", "Glob", "AskUserQuestion"]
argument-hint: "[base_commit]"
---

# Security Review Skill

## Purpose

Review code changes for security vulnerabilities by diffing against a base commit and launching the security-reviewer agent.

## Argument Parsing

`$ARGUMENTS` is an optional base commit hash or ref. Examples:
- `/security-review` — auto-detect base
- `/security-review faee240` — diff from specific commit
- `/security-review main` — diff from branch
- `/security-review 今のコード全てを監査` — natural language; extract hash if present, otherwise auto-detect

## Workflow

### Step 1: Determine Base Commit

Try these in order until one succeeds:

1. **Argument provided**: if `$ARGUMENTS` looks like a commit hash (hex string) or branch name, use it directly as base
2. **merge-base**: run `git merge-base HEAD origin/$(git rev-parse --abbrev-ref HEAD 2>/dev/null) 2>/dev/null`
3. **Fallback**: show `git log --oneline -15` and use AskUserQuestion to ask the user which commit to diff from

### Step 2: Generate Diff

Run: `git diff <base>..HEAD -- . ':!*.bin' ':!*.sqlite3' ':!*.pickle' ':!*.png' ':!*.jpg'`

Also run `git diff <base>..HEAD --stat` for the summary.

If the diff is empty, inform the user and stop.

### Step 3: Launch Security Reviewer

Launch the `security-reviewer` agent (subagent_type: security-reviewer) with:

- The full diff output (excluding binary files)
- The diff stat summary
- Instructions to focus on changed lines but read surrounding context as needed

### Step 4: Present Results

When the agent returns, present findings organized by severity (Critical → High → Medium → Low → Info). Include:

- Total finding count by severity
- Each finding with file:line, attack vector, and remediation
- "No findings" sections explicitly listed
