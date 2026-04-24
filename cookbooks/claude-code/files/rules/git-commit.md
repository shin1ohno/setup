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

### Multi-repo tasks

When a task spans 2+ repositories (e.g., CWD is `weave`, edits land in `edge-agent`), run the branch check **per repository** before the first `git add` in each repo:

    git -C /absolute/path/to/other-repo branch --show-current
    git -C /absolute/path/to/other-repo log --oneline -3

Tool-side CWD resets (Bash sandbox reverts to the primary working directory on each invocation) mean a cd-based branch check only describes the primary repo; a CWD-based check is insufficient when edits reach into a sibling repo via absolute paths. Run the check per-repo, explicitly naming the path with `git -C`.

This rule exists because the 2026-04-23 iOS session edited `~/ManagedProjects/edge-agent` from a `~/ManagedProjects/weave` primary CWD. The check happened to succeed (edge-agent was on `main` and I cut a fresh branch), but the default `git branch --show-current` in that session was describing the weave repo, not the repo being edited.

### Cross-repo propagation: enumerate first

When a task propagates a value (hostname, SSH key, config entry, API endpoint, env var) across multiple repos, grep all likely-affected repos BEFORE writing any file. Create branches and PRs for every affected repo in one planning round — do not discover repos sequentially as edits progress.

```
# Example: adding a new host `neo` — grep for existing hosts to find all touchpoints
grep -rln '"air"\|"pro"' ~/ManagedProjects/*/ 2>/dev/null
```

If the grep surfaces K repos, the plan should list K branch/PR pairs up front. Do not start the first repo's PR and discover the second repo's need mid-flight — the user sees sequential round-trips where one coordinated planning step would have sufficed.

This rule exists because the 2026-04-25 session added `neo` to `setup` first, then separately discovered `home-monitor/ssh-devices.tf` also needed the entry, producing two sequential PR flows where one planning step would have scoped both.

### Re-check after any long-running background operation

The check above covers the start of a task. It does not cover mid-task branch drift. Re-run `git branch --show-current` before **every** `git add` / `git commit` when *any* of these happened since your last commit on this repo:

- a background Bash task ran (`run_in_background: true`) — `terraform apply/plan`, `cargo test`, `npm run build`, etc.
- a sub-agent (Explore / general-purpose / Plan) ran with write access to the repo, or executed Bash in it
- the conversation paused waiting on a user-run `!` command (`! git push`, `! sudo …`, the user is likely at a shell and may switch branches)
- the user sent a message that could plausibly include a `git checkout` on their side

The branch you started the task on is not the branch you are necessarily on now. Committing on the wrong branch requires a cherry-pick + reset cleanup cycle that wastes a turn and leaves a confusing history.

This rule exists because the 2026-04-22 session landed a `rtx-hnd: block DHCP ...` commit on `fix/hydra-upstream` instead of `main` — the user had switched branches while a long `terraform apply` was running in the background. Fixed afterward via FF-merge, but only after the user spotted it.

## Branch Cleanup Survey

When the user asks to delete merged local branches (or asks "これはマージ済みか？" about lingering branches), survey BOTH sets before presenting the candidate list — never ask the AskUserQuestion until you have the complete set:

```bash
# Set A: squash-merged leftovers (commits NOT reachable from origin/main).
git branch --no-merged origin/main

# Set B: true-merge-commit leftovers (commits reachable, but the branch ref still exists locally).
git branch --merged origin/main | grep -v '^\*\| main$\| master$'
```

Present the union of A and B as a single candidate list, cross-reference each against `gh pr list --state closed --head <branch>` to confirm merged status, then ask once for destructive-op authorization. Do not ship the first-pass deletion and then surface "by the way, 2 more remain" — that forces a second user roundtrip.

This rule exists because the 2026-04-24 weave session ran only `git branch --no-merged origin/main` in the first pass (detected 3 squash-merged branches) and missed 2 true-merge-commit branches (`docs/operational-assumptions`, `feat/connections-first-ui`). The user had to reply "消してください" a second time after the remaining candidates were surfaced post-deletion.

## GPG Signing Failures

If `git commit` fails with a GPG signing error or timeout, present the user with the full cache-refresh command:

```
! gpg-connect-agent reloadagent /bye && echo "test" | gpg --clearsign > /dev/null
```

The first part reloads the agent; the second forces a `gpg --clearsign` in the user's terminal, which triggers pinentry and caches the passphrase so the next `git commit` inside the Claude Code Bash sandbox signs silently without timing out again.

Do not use the shorter `gpg-connect-agent reloadagent /bye` alone — it reloads the agent but does not pre-cache the passphrase, so the very next commit can trigger a fresh pinentry that times out in the sandbox.

Do not bypass signing with `-c commit.gpgsign=false` unless the user explicitly requests it.
