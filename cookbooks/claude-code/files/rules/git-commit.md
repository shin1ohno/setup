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

**Deny-list scope note**: The `Bash(git push:*)` deny entry matches commands that *start with* `git push`. A compound command `cd /repo && git push ...` bypasses the matcher. This is a known limitation. The behavioral rule (always present the blocked push as `! git push ...` and let the user run it) is the reliable enforcement mechanism — not the deny entry alone. Do not exploit the compound-form loophole to auto-push.

**CodeCommit (and other non-`origin` remote URL forms) also bypass the deny entry**: when the remote URL is `codecommit::ap-northeast-1://<profile>@<repo>` instead of `origin → github.com:...`, the command shape `git push origin <branch>` for that repo translates into the codecommit transport at the remote-helper layer — but in some sessions the deny matcher did NOT intercept the push and it ran inline as a regular Bash call (the 2026-05-06 retro session pushed a recovery branch directly to a CodeCommit remote without `!` confirmation). The orphaned-commit recovery accidentally became auto-execute. The fix is behavioral, not a regex change: **for any push to a non-GitHub remote — CodeCommit, GitLab via custom remote, internal Gitea — apply the same `! git push <remote> <branch>` user-authorization rule manually.** Treat the deny entry as a backstop that catches GitHub-flavored pushes, not a complete safety net. When the URL form is exotic, the rule lives in the assistant's behavior, not the deny config.

## Merge Execution Default — self-execute, plan-scoped authorization

When a PR you created has all required checks green, do NOT present `! gh pr merge …` for the user to run — `Bash(gh pr …)` is allow-listed, so the `!` prefix is not a permission gate. If the approved plan already names the merge, self-execute it (`gh pr merge`, sandbox-disabled). If the plan does not cover the merge, take approval once via AskUserQuestion — an explicit chat instruction ("merge 624" / "632 をマージして" / "許可するからマージして進めて") also counts as approval — then self-execute.

**Plan-scoped authorization**: once merge approval is granted during an approved multi-PR plan, it extends to every subsequent green-CI PR in the *same plan, same repo, plan-internal branch* — re-confirmation is not required per PR. This is the merge-specific form of "Steps inside an approved plan don't need individual confirmation"; a plan-internal merge is NOT a "Before destructive operations → pause" case.

**Invariant guards, kept every time**: (a) confirm all required checks green via `gh pr checks`; (b) run the Stacked PR Merge Guard (`gh pr list --base <head>` for downstreams) before `--delete-branch`; (c) probe merge state immediately before merging (`gh pr view <n> --json state,mergeStateStatus`). Re-confirm via AskUserQuestion only OUTSIDE the plan scope: a different repo, a plan-external branch, a base change, or a merge needing admin/force.

**Fallback**: only when `gh pr merge` is denied by project-local settings (deny/ask) do you revert to presenting `! gh pr merge <n> --squash --delete-branch` for the user.

Origin: 2026-07 — 3 sessions / 2 repos (setup #624, #632; sage #11→#21) each re-presented `! gh pr merge` after the user had already authorized merging in chat, forcing a re-authorization round-trip; #13–#21 merged autonomously with no objection once the pattern was corrected.

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

The check above covers the start of a task. It does not cover mid-task branch drift. Re-run `git branch --show-current` before **every** `git add` / `git commit` when *any* of these happened since your last commit on this repo:

- a background Bash task ran (`run_in_background: true`) — `terraform apply/plan`, `cargo test`, `npm run build`, etc.
- a sub-agent (Explore / general-purpose / Plan) ran with write access to the repo, or executed Bash in it
- the conversation paused waiting on a user-run `!` command (`! git push`, `! sudo …`, the user is likely at a shell and may switch branches)
- the user sent a message that could plausibly include a `git checkout` on their side
- the conversation paused on an **AskUserQuestion round-trip**, or an interactive **credential retry** (GPG pinentry timeout, sudo password prompt, 2FA) — any wall-clock gap between two of your tool calls is a window a repo-sharing async process can act in, *even if you probed for it immediately before the gap opened*. A point-in-time "is the loop running?" check taken at task start does not cover the gaps that open later in the same task
- **the previous Bash invocation ended with `Shell cwd was reset to ...`** — the Bash sandbox does not persist branch checkouts across CWD resets. Even if the Bash log line `Switched to a new branch 'fix/X'` is visible, the next Bash invocation may evaluate `git status` against a *different* branch (typically the session-default one, which can be a long-lived `feat/*` branch left over from another conversation). This is the most common failure mode for misplaced commits in long sessions.
- **a daemon or autonomous loop also operates on this repo** (launchd job, cron, a `claude -p` watcher, a CI runner that shares the working tree) — the HEAD, index, and tracked files can change between your Bash invocations with NO trace in this conversation. Before the first `git add`, confirm the loop is paused (kill-switch file, `launchctl stop`, kill by PID) and re-probe `git status` twice for stability. Detection: `git branch --show-current` returns a branch you did not create, OR `git status` shows modifications that appear/vanish between two probes. When the shared working tree may be in concurrent use (the user editing in another terminal, or an unrelated feature branch checked out), do NOT `git checkout` it — that moves the shared HEAD out from under them. Use `git worktree add <path> -b <branch> origin/main` to work on an isolated checkout without touching the shared HEAD. **When a repo is KNOWN to host a recurring autonomous git loop that shares the working tree (a scheduled `claude -p` runner, a CI agent that commits, a self-healing apply loop), do not gate worktree-vs-shared-tree on a liveness probe at all — default to `git worktree add /private/tmp/<name>-wt <branch>` unconditionally for every manual git op in that repo.** The loop can seize the tree during any later wall-clock gap (an AskUserQuestion wait, a GPG retry, a slow build) even when it was absent at your first check; a passing point-in-time probe is not evidence the tree stays yours for the whole task. Symptom of getting this wrong: the shared tree ends up on a branch you did not create, with a stale `index.lock` and your staged change stranded on another task's branch.

The branch you started the task on is not the branch you are necessarily on now. Committing on the wrong branch requires a cherry-pick + reset cleanup cycle that wastes a turn and leaves a confusing history.

**Never use `cd` to set git context.** `cd` does not survive the CWD reset between Bash invocations, and a bare `cd <dir>` can additionally trigger a shell `chpwd` hook (e.g. an auto-`tree`/`ls`) that floods stdout and masks the `Shell cwd was reset to ...` line you need to see. Use `git -C /absolute/path` on **every** git call — branch check, add, and commit — never a leading `cd` to "enter" the repo first.

**Required pattern** when committing to a fix/feat branch: explicit branch verification + `git -C /absolute/path` in the SAME Bash call as the commit (no leading `cd`):

```bash
test "$(git -C /Users/sh1/ManagedProjects/setup branch --show-current)" = "fix/X" &&
  git -C /Users/sh1/ManagedProjects/setup add <files> &&
  git -C /Users/sh1/ManagedProjects/setup commit -m "..."
```

If the `branch --show-current` test fails the chain aborts before staging, surfacing the drift immediately rather than after the commit lands on the wrong branch. **Do NOT** split `git checkout -b` into a separate Bash invocation from the commit — branch context does not survive the CWD reset between calls.

Origin: 2026-04-22 commit on wrong branch after background `terraform apply`; strengthened 2026-05-06 after two misplaced commits where `git checkout -b` ran in a separate Bash call from `git commit` (recovery: cherry-pick + `git branch -f <branch> origin/main`); 2026-06-19 a bare `cd <dir>` used to "enter" the repo within one Bash call still drifted at the next CWD reset AND triggered a shell tree-hook that masked the reset line — using `git -C /absolute/path` on every git call (never a leading `cd`) eliminates the ambiguity.

### Cherry-pick is a commit operation — branch check applies

`git cherry-pick` does not involve `git add`, so the "check before git add" trigger above is not reached. Before any `git cherry-pick`, run `git branch --show-current` and confirm the target is the intended branch — typically a fresh branch created from `origin/main` for this specific task, not whatever branch happens to be checked out.

The standard pattern for moving an existing commit onto its own clean branch:

    git fetch origin
    git checkout -b fix/<topic> origin/main
    git cherry-pick <hash>

Never cherry-pick onto an existing feature branch unless that branch is the cherry-pick's intended destination. The "branch is not main" heuristic is insufficient — the branch may be another in-flight feature (the user's WIP, a sibling task) that has nothing to do with the commit you're moving.

Origin: 2026-04-25 cherry-picked onto the user's unrelated WIP branch.

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

Origin: 2026-04-25 weave — feature branch cut from main lacked an open sibling fix, regressing BLE pairing on redeploy.

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

The Write tool and ordinary Bash commands run in the Claude Code command sandbox, where `$TMPDIR` is remapped to a sandbox-private directory. Network commands (`gh pr create/edit`, see the next section) must run with `dangerouslyDisableSandbox: true`, where `$TMPDIR` resolves to the REAL OS temp dir (`/var/folders/.../T` on macOS) — a different path. A `cat "$TMPDIR/body.md"` inside the sandbox-disabled invocation then returns 0 bytes with NO error, and the PR is created with a silently empty body.

Rule: never reference a `$TMPDIR`-relative path in a `dangerouslyDisableSandbox` invocation when the file was written under the normal command sandbox. Construct the body inline via heredoc piped to `--body-file -` in the same sandbox-disabled invocation — no file reference:

```
gh pr create --base main --title "..." --body-file - <<'EOF'
## Summary
- ...
## Test plan
- `cmd1` … `cmd2` …
EOF
```

This sidesteps all three `--body-file` failure modes at once (backtick mis-parse, harness verifier window, cross-sandbox TMPDIR). Detection signal: the PR body is blank even though you "wrote" it and no command errored.

Origin: 2026-06-26 PR #556 — body written to the command-sandbox TMPDIR, `gh pr create` ran sandbox-disabled with the real TMPDIR → `cat "$TMPDIR/body.md"` returned empty → blank PR body, no error surfaced.

**User-run `!` commands are outside the isolation boundary too**: the scratchpad (`/private/tmp/claude-501/...`) and the command-sandbox `$TMPDIR` are invisible from the user's terminal. The moment you write one of those paths into a `!` command you present for the user to run — `git commit -F <path>`, an `scp`/`rsync` copy source, any command taking `-f`/`-F`/`--file` — it is a composition bug: the user's run fails with `fatal: could not read log file <path>: No such file or directory`. Fix, in order:

1. **Inline it** — if the content is short, use no file: write `git commit -F - <<'EOF' … EOF` (or `gh pr create --body-file - <<'EOF' … EOF`) directly in the `!` block, same heredoc solution as above.
2. **Put it on a user-visible path** — for long multi-line content, `Write` it under the target repo's `.git/` (e.g. `.git/<topic>-commit-msg.txt`, the same convention as `COMMIT_EDITMSG`), then present the relative-path form `! git commit -F .git/<topic>-commit-msg.txt` (the user `cd`s into the repo first). `.git/` is not tracked, so it does not dirty `git status`; do NOT use a bare tmp file inside the repo tree — that adds untracked noise and mis-commit risk.

Pre-emit check: before writing out any `!` block, scan it for a `/private/tmp/claude-501` or sandbox-`$TMPDIR` path. If one is present, do not present it — switch to option 1 or 2.

Origin: 2026-07 session 031f3049 — a `git commit -F <scratchpad path>` presented for the user (GPG signing) failed with `could not read log file`; recovered by moving the message under `.git/`.

## gh CLI network access requires `dangerouslyDisableSandbox`

Every `gh pr create / edit / merge / checks / view`, `gh api`, and `git push` over **HTTPS** fails inside the Claude Code command sandbox — the TLS root store and outbound egress are blocked (`tls: failed to verify certificate`, GraphQL POST blocked). Run these with `dangerouslyDisableSandbox: true`.

`git push` over an **SSH** remote works in-sandbox (SSH egress is allowed); only HTTPS pushes and `gh` CLI calls need sandbox-disabled.

When a post-commit block is planned (`push → gh pr create → gh pr checks`), run the network steps sandbox-disabled from the start rather than discovering it one failed command at a time. This is a sandbox-config fact, not a one-off — treat a `tls: failed to verify certificate` / blocked-egress error from any `gh`/HTTPS call as expected-in-sandbox and retry sandbox-disabled, per the Bash tool's sandbox-failure guidance.

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
