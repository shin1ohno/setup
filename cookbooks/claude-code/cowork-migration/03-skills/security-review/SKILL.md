---
name: security-review
description: |
  Use this skill when the user wants a security review of recent code changes — triggers are "/security-review", "audit this branch for security issues", "OWASP review", "check for vulnerabilities", "is this code safe", or right before merging a PR with non-trivial changes. Diffs the current branch against a base commit, then runs a security-focused review covering OWASP Top 10 (injection, XSS, SSRF, auth flaws, crypto misuse, path traversal, unsafe deserialization), secret leakage, unsafe exec/eval, and untrusted input flowing to privileged sinks. Produces a severity-rated finding list. Requires a git repository in the workspace folder.
---

# Security Review Skill

Review code changes for security vulnerabilities by diffing against a base commit and running a security-focused review pass.

## Argument Parsing

The user's message may include a base commit, branch name, or just be a generic ask. Examples:

- `/security-review` — auto-detect base
- `/security-review faee240` — diff from specific commit
- `/security-review main` — diff from branch
- `audit current code` — auto-detect base

## Workflow

### Step 1: Determine Base Commit

Try in order until one succeeds:

1. **Argument provided**: if it looks like a commit hash or branch name, use it
2. **merge-base**: `git merge-base HEAD origin/$(git rev-parse --abbrev-ref HEAD 2>/dev/null) 2>/dev/null`
3. **Fallback**: show `git log --oneline -15` and use AskUserQuestion to pick the base

### Step 2: Generate Diff

```
git diff <base>..HEAD -- . ':!*.bin' ':!*.sqlite3' ':!*.pickle' ':!*.png' ':!*.jpg'
git diff <base>..HEAD --stat
```

If diff is empty, inform the user and stop.

### Step 3: Security-Focused Review

Launch a sub-agent (Agent tool, `general-purpose`) with this directive:

> Review the following git diff for security vulnerabilities. Focus on OWASP Top 10: injection (SQL, command, header), XSS, SSRF, authentication / session flaws, crypto misuse, path traversal, unsafe deserialization. Also flag: secret leakage, unsafe exec/eval, untrusted input flowing to privileged sinks (file system, network, DB, shell).
>
> For each finding:
> - File:line
> - Severity: Critical / High / Medium / Low / Info
> - Confidence: 0-100
> - Attack vector
> - Remediation
>
> Focus on changed lines but read surrounding context as needed.

Pass the diff and stat summary to the sub-agent.

### Step 4: Present Results

Group by severity (Critical → High → Medium → Low → Info):

- Total finding count by severity
- Each finding with file:line, attack vector, remediation
- Explicit "No findings" sections where applicable

End with a recommendation: which findings block the PR, which can be follow-ups.

## When NOT to use

- Pure documentation / config changes with no executable code paths
- Code that was already reviewed in a recent session
- The user wants a general code review (not security-specific) — use `code-reviewer` plugin instead
