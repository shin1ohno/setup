---
description: "Git commit message format rules — loaded when creating commits"
---

# Git Commit Format

Start the summary with a `{component}: ` prefix; explain the "why", not just the "what".

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/git-commit-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

## Deferred Stubs in PR Description

Detail: see `~/.claude/docs/git-commit-detail.md#deferred-stubs`.

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
- **Established repo convention** (no explicit opt-in needed, but verify the signal first): run `git log --oneline origin/main -10` on the target repo. If the last 5+ commits all reached `main` directly (no `Merge pull request #` titles, no squash-merge `(#nnn)` suffixes, all the same commit-shape e.g. solo HANDOFF/CHANGELOG updates), treat that history as the established convention for this file in this repo. The user-facing flow is unchanged — still present `! git push origin main` for the user to authorize, never auto-push — but skip the "should I open a PR?" ceremony when the history shows the answer is "no" for this file class.

Absent an explicit opt-in OR an established convention, always go PR branch → `gh pr create`. If a commit was just made on a local `main` tracking branch, redirect before pushing: `git branch -m <branch>; git push -u origin <branch>; gh pr create`.

**The convention signal is per-file-class, not per-repo**: a repo can have HANDOFF/log files that go direct-to-main while code changes still go through PRs. When the file being committed is a different class than the historical direct-to-main commits, the convention does NOT apply — fall back to PR branch.

Origin: 2026-05-05 PVE migration — asked PR-vs-direct ceremony when git-log already answered.

**Deny-list scope note**: The `Bash(git push:*)` deny entry only matches commands that *start with* `git push` — a compound `cd /repo && git push ...`, or a non-GitHub remote whose URL form is exotic (CodeCommit `codecommit::...`, GitLab via custom remote, internal Gitea), can bypass the matcher. The behavioral rule is the reliable enforcement, not the deny entry: always present a blocked push as `! git push <remote> <branch>` and let the user run it, and apply the same `!` user-authorization rule manually for any push to a non-GitHub remote. Do not exploit the compound-form loophole to auto-push; treat the deny entry as a backstop, not a complete safety net.

Detail (deny-matcher mechanics + CodeCommit bypass narrative + origin): see `~/.claude/docs/git-commit-detail.md#deny-list-nongithub-remote`.

## Merge Execution Default — self-execute, plan-scoped authorization

When a PR you created has all required checks green, do NOT present `! gh pr merge …` for the user to run — `Bash(gh pr …)` is allow-listed, so the `!` prefix is not a permission gate. If the approved plan already names the merge, self-execute it (`gh pr merge`, sandbox-disabled). If the plan does not cover the merge, take approval once via AskUserQuestion — an explicit chat instruction ("merge 624" / "632 をマージして" / "許可するからマージして進めて") also counts as approval — then self-execute.

**Plan-scoped authorization**: once merge approval is granted during an approved multi-PR plan, it extends to every subsequent green-CI PR in the *same plan, same repo, plan-internal branch* — re-confirmation is not required per PR. This is the merge-specific form of "Steps inside an approved plan don't need individual confirmation"; a plan-internal merge is NOT a "Before destructive operations → pause" case.

**Invariant guards, kept every time**: (a) confirm all required checks green via `gh pr checks`; (b) run the Stacked PR Merge Guard (`gh pr list --base <head>` for downstreams) before `--delete-branch` — GitHub does NOT auto-retarget downstream PRs when their base branch is deleted, and a PR closed this way CANNOT be reopened (`gh pr reopen` / `gh pr edit --base` both fail once the base ref is gone); skipping this guard costs a full PR recreation, not a quick reopen; (c) probe merge state immediately before merging (`gh pr view <n> --json state,mergeStateStatus`). Re-confirm via AskUserQuestion only OUTSIDE the plan scope: a different repo, a plan-external branch, a base change, or a merge needing admin/force.

**Fallback**: only when `gh pr merge` is denied by project-local settings (deny/ask) do you revert to presenting `! gh pr merge <n> --squash --delete-branch` for the user.

**kouzoh org exception**: the auto-mode classifier structurally denies self-merging into `kouzoh/*` repos — even in an interactive session, even with plan-scoped approval and policy-bot green (observed 2026-07-08, zp-SHIN #73). For kouzoh-org PRs, skip the self-merge attempt and present `! gh -R kouzoh/<repo> pr merge <n> --merge --delete-branch` directly (zp convention: merge commit). Consistent with the denial-as-probe rule: this exception is recorded WITH its rationale, so no per-run re-attempt is needed; if a future attempt succeeds anyway, update this line in the same run.

Origin: 2026-07 — re-presented `! gh pr merge` after the user had already authorized merging, forcing a re-authorization round-trip. Detail: see `~/.claude/docs/git-commit-detail.md#merge-execution-default`.

## Branch Check Before First Commit

Before writing any file or running `git add` in a repo that is part of the current task, run `git branch --show-current` and `git log --oneline -3`. If the current branch is not `main` and was not created for this task, stop and create a new branch from `origin/main`:

    git fetch origin
    git checkout -b fix/<topic> origin/main

Do NOT commit onto: merged PR branches still checked out locally, in-flight feature branches for unrelated work, or any branch whose `git log` shows commits unrelated to the current task. Scope-bleed discovered after the commit requires cherry-pick surgery that is easy to prevent with this 2-second check.

### Config-editing tasks — branch check at first Write, not first commit

For tasks whose primary output is edits to `CLAUDE.md`, `~/.claude/rules/*.md`, or any rules/docs file that accumulates many Write calls before any `git add`, run the branch check **before the FIRST Write tool call** — not just before `git add`. By the time you reach `git add`, you may have applied 5+ Writes across multiple turns to the wrong branch; the cherry-pick (or stash → branch → pop) recovery cost dwarfs the 2-second check.

```
git -C /path/to/repo branch --show-current  # before the first Write
```

If the current branch is not the intended one (typically: not `main`, not a branch created for this task), cut a fresh branch from `origin/main` BEFORE editing. The "Before writing any file" wording is easily missed when the editing session spans many turns and never touches `git add` until late.

Origin: 2026-05-11 CLAUDE.md trim — 5+ Writes on an unrelated open PR's branch.

### Branch check immediately before `gh pr create`

The branch check at first commit time is necessary but not sufficient. In multi-stream worktree sessions where multiple branches coexist, the current branch can change between commit and PR-create — a parallel agent finishes, you switch context, and `gh pr create` runs against the NEW current branch. The PR's title and body describe one set of changes, but the diff contains a different stream's content.

Before `gh pr create`, assert the current branch matches the intended branch in the same Bash invocation:

```bash
test "$(git -C . branch --show-current)" = "feat/my-branch" && \
  cat /tmp/pr-body.md | gh pr create --base main --title "..." --body-file -
```

Or, more explicit, pass `--head <branch>` to gh:

```bash
cat /tmp/pr-body.md | gh pr create --base main --head feat/my-branch --title "..." --body-file -
```

The `--head` form is the safest — gh uses the explicit branch regardless of CWD's current branch state.

Origin: 2026-05-09 multi-stream worktree — PR shipped with wrong stream's diff (current branch drifted between commit and PR-create).

### Multi-repo tasks

When a task spans 2+ repositories (e.g., CWD is `weave`, edits land in `edge-agent`), run the branch check **per repository** before the first `git add` in each repo:

    git -C /absolute/path/to/other-repo branch --show-current
    git -C /absolute/path/to/other-repo log --oneline -3

Tool-side CWD resets (Bash sandbox reverts to the primary working directory on each invocation) mean a cd-based branch check only describes the primary repo; a CWD-based check is insufficient when edits reach into a sibling repo via absolute paths. Run the check per-repo, explicitly naming the path with `git -C`.

Origin: 2026-04-23 iOS — bare branch check described primary CWD, not the sibling repo edited.

### Cross-repo propagation: enumerate first

When a task propagates a value (hostname, SSH key, config entry, API endpoint, env var) across multiple repos, grep all likely-affected repos BEFORE writing any file. Create branches and PRs for every affected repo in one planning round — do not discover repos sequentially as edits progress.

```
# Example: adding a new host `neo` — grep for existing hosts to find all touchpoints
grep -rln '"air"\|"pro"' ~/ManagedProjects/*/ 2>/dev/null
```

If the grep surfaces K repos, the plan should list K branch/PR pairs up front. Do not start the first repo's PR and discover the second repo's need mid-flight — the user sees sequential round-trips where one coordinated planning step would have sufficed.

Origin: 2026-04-25 `neo` host add — `home-monitor/ssh-devices.tf` discovered as a second sequential PR.

### Re-check after any long-running background operation

The check above covers the start of a task. It does not cover mid-task branch drift. Re-run `git branch --show-current` before **every** `git add` / `git commit` when *any* long-running or async operation happened since your last commit on this repo — a background Bash task (`run_in_background: true`), a repo-writing sub-agent, a user-run `!` pause, an AskUserQuestion / credential-retry gap, a `Shell cwd was reset to ...` line between invocations, or a daemon / autonomous loop sharing the working tree. Any wall-clock gap between two of your tool calls is a window a repo-sharing async process can act in, even if you probed immediately before the gap opened. For a repo KNOWN to host a recurring autonomous git loop sharing the working tree, default to a worktree unconditionally (prefer the repo-internal `.claude/worktrees/` location via EnterWorktree — `/private/tmp/<name>-wt` can be denied by the sandbox write allowlist) — do not gate worktree-vs-shared-tree on a liveness probe.

Detail (full per-case trigger list + daemon/worktree mechanics + origins): see `~/.claude/docs/git-commit-detail.md#recheck-after-background-op`.

The branch you started the task on is not the branch you are necessarily on now. Committing on the wrong branch requires a cherry-pick + reset cleanup cycle that wastes a turn and leaves a confusing history.

**Never use `cd` to set git context.** `cd` does not survive the CWD reset between Bash invocations, and a bare `cd <dir>` can additionally trigger a shell `chpwd` hook (e.g. an auto-`tree`/`ls`) that floods stdout and masks the `Shell cwd was reset to ...` line you need to see. Use `git -C /absolute/path` on **every** git call — branch check, add, and commit — never a leading `cd` to "enter" the repo first.

**Required pattern** when committing to a fix/feat branch: explicit branch verification + `git -C /absolute/path` in the SAME Bash call as the commit (no leading `cd`):

```bash
test "$(git -C /Users/sh1/ManagedProjects/setup branch --show-current)" = "fix/X" &&
  git -C /Users/sh1/ManagedProjects/setup add <files> &&
  git -C /Users/sh1/ManagedProjects/setup commit -m "..."
```

If the `branch --show-current` test fails the chain aborts before staging, surfacing the drift immediately rather than after the commit lands on the wrong branch. **Do NOT** split `git checkout -b` into a separate Bash invocation from the commit — branch context does not survive the CWD reset between calls.

### Cherry-pick is a commit operation — branch check applies

`git cherry-pick` does not involve `git add`, so the "check before git add" trigger above is not reached. Before any `git cherry-pick`, run `git branch --show-current` and confirm the target is the intended branch — typically a fresh branch created from `origin/main` for this specific task, not whatever branch happens to be checked out.

The standard pattern for moving an existing commit onto its own clean branch:

    git fetch origin
    git checkout -b fix/<topic> origin/main
    git cherry-pick <hash>

Never cherry-pick onto an existing feature branch unless that branch is the cherry-pick's intended destination. The "branch is not main" heuristic is insufficient — the branch may be another in-flight feature (the user's WIP, a sibling task) that has nothing to do with the commit you're moving.

Origin: 2026-04-25 cherry-picked onto the user's unrelated WIP branch.

### Branch overlap pre-flight: open PR file scope

Before cutting a feature branch from `origin/main` while another fix-PR is still open, check whether the fix touches files the feature plans to modify. A feature branched from `origin/main` does NOT inherit changes from an open sibling PR — when that sibling later merges, the feature's branch is silently regression-prone for the duration the user keeps deploying from it. Cross-reference your planned file edits against the open-PR file list; if they overlap, choose explicitly via AskUserQuestion and **default to branching from the open fix-PR's HEAD** (`git checkout -b feat/<topic> origin/<fix-branch>`), rebasing onto `main` after the fix merges.

Detail (`gh pr list` file-scope query + full 3-option choice + origin): see `~/.claude/docs/git-commit-detail.md#branch-overlap-preflight`.

## `index.lock` — 3-point triage before removal

When a git operation fails with `index.lock exists`, do NOT immediately delete it and do NOT diagnose it as a permanent fault. Run a 3-point probe: (a) re-probe after a few seconds — if it vanished it was transient (an editor / statusline / IDE poller), just retry; (b) it is 0 bytes AND its mtime is minutes old and unchanging; (c) `pgrep -fl git` shows no writing git process. Remove the lock and retry ONCE only when (a)(b)(c) all hold; if any fails, wait or move to a worktree. Suspect ordering: when the failure has all three of "multiple repos / frequent / cause unknown", the first suspect is a high-frequency poller running in the cwd (an IDE's git integration / shell prompt / statusline), NOT an autonomous loop — a loop-caused stale lock comes with the other symptoms in the `Re-check after any long-running background operation` daemon guidance above (cross-reference). Detail: see `~/.claude/docs/git-commit-detail.md#index-lock-triage`.

## Branch Cleanup Survey

Detail: see `~/.claude/docs/git-commit-detail.md#branch-cleanup-survey`.

## PR Review Comment Exhaustive Fetch

Detail: see `~/.claude/docs/git-commit-detail.md#pr-review-comment-fetch`.

## Stacked PR Merge Guard — retarget downstream PRs before `--delete-branch`

Detail: see `~/.claude/docs/git-commit-detail.md#stacked-pr-merge-guard`.

## Tag a release immediately when fixing auth/security on a downstream-consumed library

Detail: see `~/.claude/docs/git-commit-detail.md#tag-release-downstream-lib`.

## `gh pr create` body containing code → use `--body-file`

When the PR description contains backticks, fenced code blocks, or inline command examples, do NOT pass the body via inline HEREDOC to `gh pr create --body "$(cat <<'EOF' ... EOF)"`. The shell or `gh` CLI mis-parses the embedded backticks / dollar signs / pipes and the command aborts with a usage-error blurb that hides the actual parsing failure.

**Always**:

```
cat > /tmp/pr-body.md <<'EOF'
## Summary
- ...
## Test plan
- `cmd1` … `cmd2` …
EOF
gh pr create --base main --title "..." --body-file /tmp/pr-body.md
```

The body file is plain Markdown — no escaping, no quoting concerns, no parser ambiguity. Apply unconditionally when the PR body has any of: backticks, code fences, `$()`, `${...}`, single quotes inside double quotes, or multi-paragraph structure.

Origin: 2026-05-05 — inline HEREDOC with backticks made `gh pr create` print `--title string` usage hints and abort.

### When the harness blocks `--body-file` — pipe via stdin

The Claude Code harness sometimes denies `gh pr create --body-file /tmp/...` with `no Write to that file appears in this transcript—the body content is unverifiable.` This happens when the harness's verifier window doesn't see the `Write` tool call that created the body file (e.g., a long transcript pushes the Write out of the verifier's lookback). The body file IS on disk, but the harness can't audit it.

Workaround: **stream the file via stdin to `--body-file -`**, which makes the body content visible inline with the command:

```
cat /tmp/pr-body.md | (cd /path/to/repo && gh pr create --base main --title "..." --body-file -)
```

`--body-file -` reads from stdin. The body content flows through the pipe, the harness sees it inline, and the deny rule doesn't fire. The body file stays as the source of truth on disk; the pipe is just the audit-friendly delivery channel.

Origin: 2026-05-07 — `--body-file /tmp/...` denied right after a Write the verifier window had advanced past.

### Cross-sandbox TMPDIR isolation — never reference a `$TMPDIR` file across sandbox modes

Rule: never reference a `$TMPDIR`-relative path in a `dangerouslyDisableSandbox` invocation when the file was written under the normal command sandbox — the sandbox `$TMPDIR` and the real-OS `$TMPDIR` a sandbox-disabled `gh pr create/edit` sees are different paths, so `cat "$TMPDIR/body.md"` returns 0 bytes with NO error and the PR ships a blank body. Construct the body inline via heredoc piped to `--body-file -` in the same sandbox-disabled invocation — no file reference:

```
gh pr create --base main --title "..." --body-file - <<'EOF'
## Summary
- ...
## Test plan
- `cmd1` … `cmd2` …
EOF
```

This sidesteps all three `--body-file` failure modes at once (backtick mis-parse, harness verifier window, cross-sandbox TMPDIR). Detection signal: the PR body is blank even though you "wrote" it and no command errored.

**User-run `!` commands are outside the isolation boundary too**: the scratchpad (`/private/tmp/claude-501/...`) and the command-sandbox `$TMPDIR` are invisible from the user's terminal. Writing one of those paths into a `!` command you present for the user to run — `git commit -F <path>`, an `scp`/`rsync` source, any command taking `-f`/`-F`/`--file` — is a composition bug: the user's run fails with `fatal: could not read log file <path>: No such file or directory`. Fix by inlining via heredoc (`git commit -F - <<'EOF' … EOF`) or writing the content to a user-visible path under the target repo's `.git/`.

Pre-emit check: before writing out any `!` block, scan it for a `/private/tmp/claude-501` or sandbox-`$TMPDIR` path. If one is present, do not present it — switch to the inline heredoc or `.git/`-path form.

Detail (mechanism + 2-option remediation + origins): see `~/.claude/docs/git-commit-detail.md#cross-sandbox-tmpdir`.

## gh CLI network access requires `dangerouslyDisableSandbox`

Every `gh pr create / edit / merge / checks / view`, `gh api`, and `git push` over **HTTPS** fails inside the Claude Code command sandbox — the TLS root store and outbound egress are blocked (`tls: failed to verify certificate`, GraphQL POST blocked). Run these with `dangerouslyDisableSandbox: true`.

`git push` over an **SSH** remote works in-sandbox (SSH egress is allowed); only HTTPS pushes and `gh` CLI calls need sandbox-disabled.

When a post-commit block is planned (`push → gh pr create → gh pr checks`), run the network steps sandbox-disabled from the start rather than discovering it one failed command at a time. This is a sandbox-config fact, not a one-off — treat a `tls: failed to verify certificate` / blocked-egress error from any `gh`/HTTPS call as expected-in-sandbox and retry sandbox-disabled, per the Bash tool's sandbox-failure guidance.

**Intermittent HTTPS timeouts are transient too**: when an already-sandbox-disabled `gh` call (`pr create` / `merge` / `view` / `api`) fails with `dial tcp …:443: i/o timeout`, treat it like the `pr checks --watch` transient rule — retry up to 3 times (immediately → 5s → 15s) before diagnosing. An SSH `git push` succeeding while HTTPS times out confirms the degradation is network-layer, not repo-side. A merge that timed out may or may not have landed: probe `gh pr view <n> --json state` before re-issuing. Origin: 2026-07-08 — ~10 intermittent 443 timeouts across one session; every operation succeeded on retry while SSH pushes worked throughout.

Origin: 2026-06-26 — every gh/HTTPS call across PR #556/#563/#564 required a sandbox-disabled retry; SSH push succeeded in-sandbox.

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

Origin: 2026-05-04 retro — emitted `... echo "test" | gp` truncated mid-word; cold pinentry cache failed the next commit.

## Working directory `.git` check before first file write

Detail: see `~/.claude/docs/git-commit-detail.md#working-dir-git-check`.
