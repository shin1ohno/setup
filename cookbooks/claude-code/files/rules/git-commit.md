---
description: "Git commit message format rules — loaded when creating commits"
---

# Git Commit Format

## First Line (Summary)

- Start with `{component}: ` prefix when possible (shortened filename or directory)
- Prefer contextful verbs over generic "Change", "Add", "Fix", "Update"
- Explain the "why", not just the "what"

## Deferred Stubs in PR Description

When a PR adds a public symbol (function, method, trait, type, FFI export) that has no in-tree caller because the consumer is intentionally deferred to a follow-up PR, add a `## Deferred` section to the PR description naming the stub and the follow-up. Without this, the diff looks like dead code to a reviewer or future reader, and the trail-off (e.g., "Swift side ships in a later PR") is invisible.

Format:

```
## Deferred
- `weave_ios_core::EdgeClient::publish_edge_status(wifi)` — public stub awaiting Swift `NEHotspotNetwork` reader + 10s timer in WeaveIos app repo
```

This applies even when the plan or commit body already mentions the deferral — the PR description is the durable artifact reviewers see, and the section is where reviewers expect "what's intentionally not finished here." A `// TODO: Swift impl` source comment is NOT a substitute; reviewers don't grep new public symbols.

This rule exists because the 2026-04-26 weave session shipped `EdgeClient::publish_edge_status` as a stub for a deferred iOS Swift side, mentioned it in the commit body, but the PR description had no Deferred section — the unused public symbol could read as oversight rather than scope decision.

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

### Cherry-pick is a commit operation — branch check applies

`git cherry-pick` does not involve `git add`, so the "check before git add" trigger above is not reached. Before any `git cherry-pick`, run `git branch --show-current` and confirm the target is the intended branch — typically a fresh branch created from `origin/main` for this specific task, not whatever branch happens to be checked out.

The standard pattern for moving an existing commit onto its own clean branch:

    git fetch origin
    git checkout -b fix/<topic> origin/main
    git cherry-pick <hash>

Never cherry-pick onto an existing feature branch unless that branch is the cherry-pick's intended destination. The "branch is not main" heuristic is insufficient — the branch may be another in-flight feature (the user's WIP, a sibling task) that has nothing to do with the commit you're moving.

This rule exists because the 2026-04-25 session cherry-picked an `ssh-keys: ...` commit onto `feat/roon-mcp-0.5.2-allowed-host` (the user's unrelated WIP branch). Recovery required `git branch -f <branch> origin/<branch>` to discard the misplaced commit and a fresh cherry-pick onto `fix/ssh-keys-host-pattern` from main.

### Branch overlap pre-flight: open PR file scope

Before cutting a feature branch from `origin/main` while another fix-PR is still open, check whether the fix touches files the feature plans to modify. A feature branched from `origin/main` does NOT inherit changes from an open sibling PR — when that sibling later merges, the feature's branch is silently regression-prone for the duration the user keeps deploying from it.

```
# List open PRs and the files they change.
gh pr list --state open --json number,headRefName,files \
  --jq '.[] | "#\(.number) \(.headRefName) — \(.files | map(.path) | join(", "))"'
```

Before `git checkout -b feat/<topic> origin/main`:

1. List your planned file edits (from the plan, or from the AskUserQuestion contract decisions)
2. Cross-reference against the open-PR file list
3. If overlap exists, choose explicitly via AskUserQuestion:
   - **(a) branch from the open fix-PR's HEAD** (`git checkout -b feat/<topic> origin/<fix-branch>`) — feature inherits the fix; rebase onto main after the fix merges
   - **(b) wait for the fix-PR to merge first**, then branch from updated `origin/main`
   - **(c) branch from main now and accept the cherry-pick later** (only when the fix-PR is unlikely to land before you ship)

Default to **(a)**. The cost of cherry-picking later is one extra round-trip the user must notice on their own; the cost of (a) is a routine post-merge rebase.

This rule exists because the 2026-04-25 weave session cut `feat/ios-edge-client` from `origin/main` while `fix/ios-ble-scan-no-filter` (PR #41) was still open and modifying `ios/WeaveIos/Core/BleBridge.swift`. PR #42 was then deployed to iPad without #41's fix, breaking BLE pairing on the redeploy. Recovery required cherry-picking the fix commit onto the feature branch — the user had to surface the regression by re-testing on hardware.

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

## Stacked PR Merge Guard — retarget downstream PRs before `--delete-branch`

Before running `gh pr merge --squash --delete-branch <n>`, check whether any *open* PR uses this PR's head branch as its base. GitHub auto-closes a PR when its base branch is deleted, so merging a stacked PR with `--delete-branch` silently kills its downstreams — recovery requires cherry-picking each closed PR's commits onto a fresh main-rooted branch and re-opening, which is 2-3 round-trips per dependent.

**Pre-merge check** — for the PR you're about to merge (call its head branch `$head`):

```
gh pr list --base "$head" --state open --json number,title,headRefName
```

If the result is non-empty, retarget each dependent to `main` first, then merge the bottom of the stack:

```
gh pr edit <downstream-pr-number> --base main
# repeat for each downstream
gh pr merge <bottom-pr> --squash --delete-branch
```

Once the downstream PR's base is `main`, GitHub computes the diff against the post-squash main commit (content-equivalent), so the diff stays clean.

**Workflow integration** — when running a PR-merge sequence (typical /retro session, multi-PR feature shipping), do the retarget pass *before* the first merge in the chain, not interleaved per-merge. Discovering a missed dependent after the parent PR has already been merged + branch deleted means GitHub has already auto-closed it.

This rule exists because the 2026-04-26 iOS session merged #45 with `--delete-branch`, which auto-closed stacked PRs #46 and #47. Recovery cost: cherry-pick → fresh branches → re-open as #48 / #50 → re-run CI. Two avoidable round-trips. The pre-merge `gh pr list --base` query takes one second.

## GPG Signing Failures

If `git commit` fails with a GPG signing error or timeout, present the user with the full cache-refresh command:

```
! gpg-connect-agent reloadagent /bye && echo "test" | gpg --clearsign > /dev/null
```

The first part reloads the agent; the second forces a `gpg --clearsign` in the user's terminal, which triggers pinentry and caches the passphrase so the next `git commit` inside the Claude Code Bash sandbox signs silently without timing out again.

Do not use the shorter `gpg-connect-agent reloadagent /bye` alone — it reloads the agent but does not pre-cache the passphrase, so the very next commit can trigger a fresh pinentry that times out in the sandbox.

Do not bypass signing with `-c commit.gpgsign=false` unless the user explicitly requests it.

**Output integrity**: present the full two-part chain as a single uninterrupted code line — never let a response truncation boundary split it. The user copy-pastes whatever you emit; if your output ends with `… echo "test" | gp` (truncated mid-word), the user runs `echo "test" | gpg` (no `--clearsign`), gpg returns "no command supplied" warning, and the pinentry cache is NOT primed. The very next commit then fails with the same "No passphrase given" error and the user has wasted a turn re-running.

Before emitting the GPG cache-refresh `!` line, scan the line you are about to write and verify both halves are intact. If you cannot fit the full command on a single line, emit it as a fenced code block (which preserves it as one logical unit) — never inline-formatted at the end of a sentence where the line wrap can swallow trailing tokens.

This rule exists because the 2026-05-04 retro session emitted `! gpg-connect-agent reloadagent /bye && echo "test" | gp` (truncated mid-word at line wrap), the user ran the truncated form, the pinentry cache stayed cold, and the next signed commit failed exactly the same way until the full command was re-emitted.

## Working directory `.git` check before first file write

Before writing any file inside a directory whose name suggests it is a deploy / extracted copy (`*-main`, `*-deploy`, `~/setup-main`, `~/deploy/*`), run a 1-second probe to confirm the directory is actually a git repository:

```
ls .git 2>/dev/null || echo "no .git here — likely a deploy copy"
```

If `.git` is absent, locate the tracked source-of-truth before editing:

```
find ~/ManagedProjects -maxdepth 4 -name "$(basename "$PWD" | sed 's/-main$//;s/-deploy$//')" -type d 2>/dev/null | head -3
```

Edit the tracked copy in `~/ManagedProjects/`, not the deploy copy. The deploy copy is regenerated on each `mitamae` apply (or equivalent), so changes there are silently discarded.

**Why this fires reliably**: this `setup` repo is intentionally dual-located — `~/ManagedProjects/setup/` is the git-tracked source, `~/setup-main/` (or similar tarball-extracted directory) is the deploy copy that mitamae operates on. Future bootstraps of this same pattern (any pull-and-extract delivery model) will hit the same trap.

This rule exists because the 2026-05-03 LXC bootstrap session edited 14 cookbook files in `~/setup-main/` (deploy copy, no `.git`) before the user asked `git status` and the dual-location issue surfaced. Recovery required syncing all 14 files into `~/ManagedProjects/setup/`, creating a branch there, and committing — work that would have been done in-place from the start with the up-front `.git` check.
