---
description: "Git commit message format rules — loaded when creating commits"
---

# Git Commit Format

## First Line (Summary)

- Start with `{component}: ` prefix when possible (shortened filename or directory)
- Prefer contextful verbs over generic "Change", "Add", "Fix", "Update"
- Explain the "why", not just the "what"

## Default to PR Branch; Do Not Push to main

When a commit needs to reach remote `main`, default to:

1. `git checkout -b <descriptive-branch>` from latest `origin/main`
2. Commit on the branch
3. `git push -u origin <branch>`
4. `gh pr create --base main` with a summary + test plan

Do **NOT** default to `git push origin main`. The harness blocks direct pushes to `main` (correct policy), and attempting it wastes a turn on a permission denial. Even without the gate, PR flow provides a review trail for future readers and lets CI run against the isolated branch before affecting main.

**Exceptions** where direct `git push origin main` is acceptable only with explicit user opt-in:

- User has already said "push directly to main" in the current conversation
- Single-developer repo with no CI and the user has said "skip PR for this one"

Absent an explicit opt-in, always go PR branch → `gh pr create`. If a commit was just made on a local `main` tracking branch, redirect before pushing: `git branch -m <branch>; git push -u origin <branch>; gh pr create`.

**Deny-list scope note**: The `Bash(git push:*)` deny entry matches commands that *start with* `git push`. A compound command `cd /repo && git push ...` bypasses the matcher. This is a known limitation. The behavioral rule (always present the blocked push as `! git push ...` and let the user run it) is the reliable enforcement mechanism — not the deny entry alone. Do not exploit the compound-form loophole to auto-push.

## Branch Check Before First Commit

Before writing any file or running `git add` in a repo that is part of the current task, run `git branch --show-current` and `git log --oneline -3`. If the current branch is not `main` and was not created for this task, stop and create a new branch from `origin/main`:

    git fetch origin
    git checkout -b fix/<topic> origin/main

Do NOT commit onto: merged PR branches still checked out locally, in-flight feature branches for unrelated work, or any branch whose `git log` shows commits unrelated to the current task. Scope-bleed discovered after the commit requires cherry-pick surgery that is easy to prevent with this 2-second check.

## GPG Signing Failures

If `git commit` fails with a GPG signing error or timeout, present the user with the full cache-refresh command:

```
! gpg-connect-agent reloadagent /bye && echo "test" | gpg --clearsign > /dev/null
```

The first part reloads the agent; the second forces a `gpg --clearsign` in the user's terminal, which triggers pinentry and caches the passphrase so the next `git commit` inside the Claude Code Bash sandbox signs silently without timing out again.

Do not use the shorter `gpg-connect-agent reloadagent /bye` alone — it reloads the agent but does not pre-cache the passphrase, so the very next commit can trigger a fresh pinentry that times out in the sandbox.

Do not bypass signing with `-c commit.gpgsign=false` unless the user explicitly requests it.
