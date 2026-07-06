# Git Commit Format — Examples & Origin Notes

On-demand detail for `~/.claude/rules/git-commit.md`. Read a section when the summary points here.


## deferred-stubs

## Deferred Stubs in PR Description

When a PR adds a public symbol (function, method, trait, type, FFI export) that has no in-tree caller because the consumer is intentionally deferred to a follow-up PR, add a `## Deferred` section to the PR description naming the stub and the follow-up. Without this, the diff looks like dead code to a reviewer or future reader, and the trail-off (e.g., "Swift side ships in a later PR") is invisible.

Format:

```
## Deferred
- `weave_ios_core::EdgeClient::publish_edge_status(wifi)` — public stub awaiting Swift `NEHotspotNetwork` reader + 10s timer in WeaveIos app repo
```

This applies even when the plan or commit body already mentions the deferral — the PR description is the durable artifact reviewers see. A `// TODO: Swift impl` source comment is NOT a substitute; reviewers don't grep new public symbols.

Origin: 2026-04-26 deferred-stub public symbol read as oversight.

## branch-cleanup-survey

## Branch Cleanup Survey

When the user asks to delete merged local branches (or asks "これはマージ済みか？" about lingering branches), survey BOTH sets before presenting the candidate list — never ask the AskUserQuestion until you have the complete set:

```bash
# Set A: squash-merged leftovers (commits NOT reachable from origin/main).
git branch --no-merged origin/main

# Set B: true-merge-commit leftovers (commits reachable, but the branch ref still exists locally).
git branch --merged origin/main | grep -v '^\*\| main$\| master$'
```

Present the union of A and B as a single candidate list, cross-reference each against `gh pr list --state closed --head <branch>` to confirm merged status, then ask once for destructive-op authorization. Do not ship the first-pass deletion and then surface "by the way, 2 more remain" — that forces a second user roundtrip.

Origin: 2026-04-24 weave — only `--no-merged` surveyed, missed true-merge-commit branches.

## pr-review-comment-fetch

## PR Review Comment Exhaustive Fetch

When acting on PR review comments ("レビューコメント反映", "review した", "コメントしたから確認"), do NOT rely on `gh api repos/<owner>/<repo>/pulls/<n>/comments` alone. That endpoint returns inline comments but they fan out across multiple `review` submissions — a reviewer who submits review A with 2 comments, then submits review B with 1 more comment, produces 3 inline comments total but they live in 2 separate review threads. Treating the visible-on-screen list as complete after one fetch silently drops the comments from later submissions.

**Required fetch + cross-reference**:

```bash
# Authoritative: review threads with resolution state
gh pr view <n> --json reviewThreads --jq '.reviewThreads[] | select(.isResolved == false) | {path, line, body: .comments[0].body}'

# Count unresolved threads — every one must be addressed before declaring done
gh pr view <n> --json reviewThreads --jq '[.reviewThreads[] | select(.isResolved == false)] | length'
```

`reviewThreads` is the canonical structure: each thread groups all comments on a single line/conversation, carries `isResolved`, and survives across review-submission boundaries. Use it as the source of truth, not `pulls/<n>/comments`.

**Verification gate before pushing the fix commit**: count unresolved threads, count comments you've addressed. If the numbers don't match, re-fetch — there is at least one comment from a review submission you didn't see.

Origin: 2026-05-07 — `pulls/<n>/comments` dropped a comment from a second review submission.

### Diff before acting on comments that reference content by name

When a review comment references content by name ("keep X", "restore Y", "don't remove Z", "X を日本語にしてほしい"), the reviewer is reacting to a specific diff state. Confirm what actually changed before applying a fix:

```bash
# vs the PR base — what this PR removed / added / renamed
git diff origin/main...HEAD -- <file> | grep -F '<content-phrase>'
# vs the previous commit on the branch
git diff HEAD~1 HEAD -- <file> | grep -F '<content-phrase>'
```

This tells you whether the named content was deleted, renamed, still present, or never existed. Apply only the minimum fix the diff actually requires.

Comments that look like single-axis style requests can in fact span two axes — e.g., "Bad/Good は日本語のままにしてほしい" parses simultaneously as (a) relabel `Bad/Good` → `悪い例/良い例` and (b) restore the example pairs that were deleted. The diff disambiguates: if the named tokens are absent from `HEAD` but present in the diff's `-` lines, the reviewer is asking for restoration AND relabel, not just relabel.

Origin: 2026-05-11 PR #341 review comment on a line my diff had deleted. Both interpretations happened to be correct; running `git diff origin/main...HEAD` first would have made that explicit rather than guessed.

## stacked-pr-merge-guard

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

Origin: 2026-04-26 iOS — `--delete-branch` auto-closed two stacked downstream PRs.

## tag-release-downstream-lib

## Tag a release immediately when fixing auth/security on a downstream-consumed library

When a fix lands on a library's `main` branch that changes auth, signature verification, audience/issuer/scope checking, secret handling, token validation, or any other security-relevant behavior — AND that library is consumed by a sibling repo via a pinned git tag (cookbook, deploy compose, dependent crate using `tag = "..."`) — cut a new release tag in the **same merge turn**, before moving to other work. Then in the consuming repo, bump the pin in a follow-up commit.

The trap: a fix sits unreleased on `main` for days while every consumer of the prior tag continues to ship the broken behavior. The fix is invisible to anyone who doesn't read the merged-but-untagged commit log. When the bug eventually surfaces in production, the diagnostic arc costs more than the original fix did — the consumer searches the released tags, finds nothing, assumes upstream hasn't fixed it, and starts independent debugging.

**Trigger** — apply when ALL of:

1. The merged change touches auth / signing / verification / secret / scope / audience / issuer logic
2. The library is consumed via a pinned tag in at least one cookbook or deploy spec (find with `git grep -rE '<library>.*#v[0-9]'` in sibling repos)
3. The pinned consumer would observably misbehave without the fix

**Workflow**:

1. Merge the fix PR
2. `git tag -a v<next> -m "<changelog including the fix line>"` from the post-merge `main`
3. `git push origin v<next>`
4. In the consuming repo, bump the pin in a separate commit: cookbook `VERSION = "..."` or `Cargo.toml` `tag = "v..."`
5. Apply / deploy the consumer to validate

Don't defer step 2-3 to a "release later" pile. The five seconds of tag-cutting closes the gap; the multi-day gap is what makes the fix invisible.

Origin: 2026-05-02 roon-rs `f6b5491` fixed JWT audience validation but cut no tag; `lxc-roon-mcp` stayed pinned to `v0.5.3` and 401'd every claude.ai token (`AuthError::WrongAudience`) for 3 days until a `v0.5.3..main` diff surfaced the untagged fix.

## working-dir-git-check

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

**Why this fires reliably**: this `setup` repo is intentionally dual-located — `~/ManagedProjects/setup/` is the git-tracked source, `~/setup-main/` (or similar tarball-extracted directory) is the deploy copy that mitamae operates on. Any pull-and-extract delivery model hits the same trap.

Origin: 2026-05-03 LXC bootstrap — edited 14 files in `~/setup-main/` (no `.git`) before the dual-location surfaced.

## deny-list-nongithub-remote

## Default to PR Branch; Do Not Push to main — deny-list scope + non-GitHub remotes

**Deny-list scope note**: The `Bash(git push:*)` deny entry matches commands that *start with* `git push`. A compound command `cd /repo && git push ...` bypasses the matcher. This is a known limitation. The behavioral rule (always present the blocked push as `! git push ...` and let the user run it) is the reliable enforcement mechanism — not the deny entry alone. Do not exploit the compound-form loophole to auto-push.

**CodeCommit (and other non-`origin` remote URL forms) also bypass the deny entry**: when the remote URL is `codecommit::ap-northeast-1://<profile>@<repo>` instead of `origin → github.com:...`, the command shape `git push origin <branch>` for that repo translates into the codecommit transport at the remote-helper layer — but in some sessions the deny matcher did NOT intercept the push and it ran inline as a regular Bash call (the 2026-05-06 retro session pushed a recovery branch directly to a CodeCommit remote without `!` confirmation). The orphaned-commit recovery accidentally became auto-execute. The fix is behavioral, not a regex change: **for any push to a non-GitHub remote — CodeCommit, GitLab via custom remote, internal Gitea — apply the same `! git push <remote> <branch>` user-authorization rule manually.** Treat the deny entry as a backstop that catches GitHub-flavored pushes, not a complete safety net. When the URL form is exotic, the rule lives in the assistant's behavior, not the deny config.

## merge-execution-default

## Merge Execution Default — self-execute, plan-scoped authorization

Origin: 2026-07 — 3 sessions / 2 repos (setup #624, #632; sage #11→#21) each re-presented `! gh pr merge` after the user had already authorized merging in chat, forcing a re-authorization round-trip; #13–#21 merged autonomously with no objection once the pattern was corrected.

## recheck-after-background-op

## Re-check after any long-running background operation

Full trigger list — re-run `git branch --show-current` before **every** `git add` / `git commit` when *any* of these happened since your last commit on this repo:

- a background Bash task ran (`run_in_background: true`) — `terraform apply/plan`, `cargo test`, `npm run build`, etc.
- a sub-agent (Explore / general-purpose / Plan) ran with write access to the repo, or executed Bash in it
- the conversation paused waiting on a user-run `!` command (`! git push`, `! sudo …`, the user is likely at a shell and may switch branches)
- the user sent a message that could plausibly include a `git checkout` on their side
- the conversation paused on an **AskUserQuestion round-trip**, or an interactive **credential retry** (GPG pinentry timeout, sudo password prompt, 2FA) — any wall-clock gap between two of your tool calls is a window a repo-sharing async process can act in, *even if you probed for it immediately before the gap opened*. A point-in-time "is the loop running?" check taken at task start does not cover the gaps that open later in the same task
- **the previous Bash invocation ended with `Shell cwd was reset to ...`** — the Bash sandbox does not persist branch checkouts across CWD resets. Even if the Bash log line `Switched to a new branch 'fix/X'` is visible, the next Bash invocation may evaluate `git status` against a *different* branch (typically the session-default one, which can be a long-lived `feat/*` branch left over from another conversation). This is the most common failure mode for misplaced commits in long sessions.
- **a daemon or autonomous loop also operates on this repo** (launchd job, cron, a `claude -p` watcher, a CI runner that shares the working tree) — the HEAD, index, and tracked files can change between your Bash invocations with NO trace in this conversation. Before the first `git add`, confirm the loop is paused (kill-switch file, `launchctl stop`, kill by PID) and re-probe `git status` twice for stability. Detection: `git branch --show-current` returns a branch you did not create, OR `git status` shows modifications that appear/vanish between two probes. When the shared working tree may be in concurrent use (the user editing in another terminal, or an unrelated feature branch checked out), do NOT `git checkout` it — that moves the shared HEAD out from under them. Use `git worktree add <path> -b <branch> origin/main` to work on an isolated checkout without touching the shared HEAD. **When a repo is KNOWN to host a recurring autonomous git loop that shares the working tree (a scheduled `claude -p` runner, a CI agent that commits, a self-healing apply loop), do not gate worktree-vs-shared-tree on a liveness probe at all — default to `git worktree add /private/tmp/<name>-wt <branch>` unconditionally for every manual git op in that repo.** The loop can seize the tree during any later wall-clock gap (an AskUserQuestion wait, a GPG retry, a slow build) even when it was absent at your first check; a passing point-in-time probe is not evidence the tree stays yours for the whole task. Symptom of getting this wrong: the shared tree ends up on a branch you did not create, with a stale `index.lock` and your staged change stranded on another task's branch.

Origin: 2026-04-22 commit on wrong branch after background `terraform apply`; strengthened 2026-05-06 after two misplaced commits where `git checkout -b` ran in a separate Bash call from `git commit` (recovery: cherry-pick + `git branch -f <branch> origin/main`); 2026-06-19 a bare `cd <dir>` used to "enter" the repo within one Bash call still drifted at the next CWD reset AND triggered a shell tree-hook that masked the reset line — using `git -C /absolute/path` on every git call (never a leading `cd`) eliminates the ambiguity.

## branch-overlap-preflight

## Branch overlap pre-flight: open PR file scope

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

## cross-sandbox-tmpdir

## Cross-sandbox TMPDIR isolation — never reference a `$TMPDIR` file across sandbox modes

The Write tool and ordinary Bash commands run in the Claude Code command sandbox, where `$TMPDIR` is remapped to a sandbox-private directory. Network commands (`gh pr create/edit`, see the next section) must run with `dangerouslyDisableSandbox: true`, where `$TMPDIR` resolves to the REAL OS temp dir (`/var/folders/.../T` on macOS) — a different path. A `cat "$TMPDIR/body.md"` inside the sandbox-disabled invocation then returns 0 bytes with NO error, and the PR is created with a silently empty body.

Origin: 2026-06-26 PR #556 — body written to the command-sandbox TMPDIR, `gh pr create` ran sandbox-disabled with the real TMPDIR → `cat "$TMPDIR/body.md"` returned empty → blank PR body, no error surfaced.

**User-run `!` command remediation, in order**:

1. **Inline it** — if the content is short, use no file: write `git commit -F - <<'EOF' … EOF` (or `gh pr create --body-file - <<'EOF' … EOF`) directly in the `!` block, same heredoc solution as above.
2. **Put it on a user-visible path** — for long multi-line content, `Write` it under the target repo's `.git/` (e.g. `.git/<topic>-commit-msg.txt`, the same convention as `COMMIT_EDITMSG`), then present the relative-path form `! git commit -F .git/<topic>-commit-msg.txt` (the user `cd`s into the repo first). `.git/` is not tracked, so it does not dirty `git status`; do NOT use a bare tmp file inside the repo tree — that adds untracked noise and mis-commit risk.

Origin: 2026-07 session 031f3049 — a `git commit -F <scratchpad path>` presented for the user (GPG signing) failed with `could not read log file`; recovered by moving the message under `.git/`.
