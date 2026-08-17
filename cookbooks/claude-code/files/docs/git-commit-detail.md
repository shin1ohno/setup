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

**Required fetch + cross-reference** — `gh pr view <n> --json reviewThreads` does NOT work: `reviewThreads` is not a `gh pr view --json` field (gh 2.95.0 → `Unknown JSON field: "reviewThreads"`, exit 1). Use the GraphQL API. The `query(...)` variable declarations plus `-F` passing are mandatory — inlining `$owner,$name,$number` without declaring them is a GraphQL validation error:

```bash
# Unresolved review threads (path / isResolved / first comment body)
gh api graphql -F owner=<owner> -F name=<repo> -F number=<n> -f query='
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100){
        nodes{isResolved path comments(first:10){nodes{body}}}
      }}}}' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)'

# Unresolved thread count — must reach 0 before declaring done (same query):
#   --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length'
```

`reviewThreads` (via GraphQL) is the canonical structure: each thread groups all comments on a single line/conversation, carries `isResolved`, and survives across review-submission boundaries. Use it as the source of truth, not `pulls/<n>/comments`.

- `statusCheckRollup` / `mergeStateStatus` and the rest ARE still valid `gh pr view --json` fields — only `reviewThreads` is rejected there. When one `gh pr view --json` call would need both, split `reviewThreads` out to the GraphQL query above and leave the other fields on `gh pr view`.
- In a headless environment where `gh api` is approval-gated, unresolved-thread state is unobtainable — do NOT guess it resolved; escalate with a needs-human label and stop (this ends the dead-probe-every-run loop).
- jq negation: use the `select(.isResolved | not)` form — `!=` / bare `!` break under interactive zsh history expansion (consistent with `rules/shell.md`).

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

Before running `gh pr merge --squash --delete-branch <n>`, check whether any *open* PR uses this PR's head branch as its base. GitHub auto-closes a PR when its base branch is deleted (it does NOT auto-retarget), and the closed PR is unrecoverable — `gh pr reopen` and `gh pr edit --base` both fail once the base ref is gone — so recovery means rebasing the orphaned branch onto main and opening a brand-NEW PR (new number, lost review context), 2-3 round-trips per dependent. The correct order is: retarget every open downstream to main FIRST (`gh pr edit <m> --base main`), then merge with `--delete-branch`. Reconfirmed 2026-07 setup #696/#697/#700 — the guard was skipped on the (wrong) auto-retarget assumption; #697 could not be reopened and was recreated as #700, while #699 survived the next merge because it was retargeted beforehand.

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

Guard (c)/(d) origins: 2026-07 55206b98 — `mergeStateStatus: CLEAN` was read as "reviews resolved" and a PR with unresolved review threads was declared merge-ready (CLEAN only means no-conflict + required-checks-pass); 2026-07 65589d06 — the immediately-before-merge probe returned `UNKNOWN` (GitHub's async mergeability computation) and a re-poll a few seconds later resolved it, confirming re-poll (not BLOCKED-skip) as the correct handling.

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

Five loop-repo git-discipline addenda for that same bullet:

- **worktree placement**: prefer the repo-internal `.claude/worktrees/` location (EnterWorktree's default — sandbox-writable). `/private/tmp/<name>-wt` can be denied by the sandbox write allowlist (observed 2026-06-27); if it is denied, try EnterWorktree or a repo-internal path BEFORE degrading to `stash`+`checkout`, and if you do fall back to `stash`+`checkout`, confirm the loop is stopped in the same turn.
- **the worktree path you WRITE to must be the one `worktree add` created**: `git -C <repo> worktree add .claude/worktrees/<name>` resolves the relative path against `<repo>`, so the worktree lands at `<repo>/.claude/worktrees/<name>` — NOT under whatever subdirectory you were conceptually working in. Writing to `<repo>/<subproject>/.claude/worktrees/<name>/...` instead creates a stray nested tree inside the real working tree: the file is untracked in the wrong place, `git status` in the worktree shows nothing, and (on a loop-shared repo) the stray file is exposed to the loop's `git add -A`. Confirm the path before the first Write with `git -C <repo> worktree list`, and use its printed absolute path verbatim. Origin: 2026-08-01 — a cookbook was written to `zp-SHIN/projects/mercari-setup/.claude/worktrees/<name>/projects/mercari-setup/cookbooks/...` while the real worktree was at `zp-SHIN/.claude/worktrees/<name>/`; caught only when `mercari.rb` "did not exist" in the worktree, then required copying the file across and removing the stray tree.
- **unexpected staged files**: if a file you did not stage lands in the commit, run `git reflog -10` to look for a concurrent writer's trace (reset/checkout/commit interleaved with your own commands) BEFORE suspecting a hook or your own operation.
- **follow-up push to a self-authored PR branch**: on a repo running an autonomous merge loop, probe `gh pr view <n> --json state` before a follow-up push. A `[new branch]` line in the push output — a push to an *existing* PR branch reported as newly created — is the anomaly signal for "already merged + branch deleted, then orphan-recreated"; abandon that branch and switch to a new branch + new PR cut from the updated `origin/main`.
- **file writes belong in the worktree too**: the worktree default is not commit-only — do NOT leave uncommitted session artifacts (analysis docs, generated files) untracked on a loop-shared main tree. The loop's `git add -A` sweeps them into ITS commits, and its HEAD switches can orphan or delete them (observed 2026-07-21: two untracked analysis docs left on the shared tree became the trigger of a commit collision). `sub-agents.md`'s $TMPDIR scratch-file discipline covers sub-agents only; this addendum covers the main session's own artifacts.
- **contamination diagnosis is read-only**: after detecting unexpected staged/dirty files, stay read-only (`git status` / `git reflog` / `git diff`) until EVERY dirty file's owner is identified — a `git add` issued mid-diagnosis mixes your files with the loop's WIP into one unsplittable index (observed 2026-06-27).

Hook-dismissal anti-pattern (origin of the rules-side sentence): 2026-07-08 — the shared-tree warning hook fired 11× and was dismissed each time because the warning named the cwd repo (zp-SHIN) while the command's real target was `git -C ~/ManagedProjects/setup`; the hook cannot resolve `-C "$VAR"` shell variables and falls back to cwd, so a repo-name mismatch is a resolution artifact, not evidence of a false positive. The dismissals ended with HEAD switched twice by a concurrent actor. Recurred 13 days later (07-21) when a loop's `git add -A` absorbed a shared-tree commit.

Origin: 2026-04-22 commit on wrong branch after background `terraform apply`; strengthened 2026-05-06 after two misplaced commits where `git checkout -b` ran in a separate Bash call from `git commit` (recovery: cherry-pick + `git branch -f <branch> origin/main`); 2026-06-19 a bare `cd <dir>` used to "enter" the repo within one Bash call still drifted at the next CWD reset AND triggered a shell tree-hook that masked the reset line — using `git -C /absolute/path` on every git call (never a leading `cd`) eliminates the ambiguity.

## worktree-isolated-serialization

## Worktree-isolated session refuses compound git commands — serialize

When the session is inside an EnterWorktree worktree, a harness-level check (not one of the repo hooks) enforces that git operations stay inside the worktree. Two rejection shapes, both observed:

- **`git -C <shared-checkout> …` is refused** ("a worktree-isolated session's git operations must target its own worktree").
- **Any compound command containing git is refused as "too complex to verify"** — `&&`-chains (including the Required-pattern `test … && git add … && git commit`), and even a single git call with an output redirect (`git show HEAD:<path> > "$TMPDIR/x"`).

Remedy: run plain single-purpose git calls from the worktree cwd — `git add <files>`, then `git commit -m …`, as separate Bash invocations, and replace redirect-based verification with exit-code evidence or a plain `git status --porcelain`. The Required-pattern chain and this refusal are both correct in their own contexts: the chain guards against CWD-reset branch drift on a multi-branch shared checkout; a worktree session has exactly one branch checked out and no drift risk, so serialization loses nothing.

Origin: 2026-08-17 zp-SHIN PR #151 — four refusals in one session (one `git -C <shared>` chain, two "too complex" compound chains, one bare `git show` with an output redirect), each re-issued as serialized plain commands.

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

## index-lock-triage

## `index.lock` — 3-point triage before removal

When a git operation fails with `fatal: Unable to create '<repo>/.git/index.lock': File exists`, neither of the reflex reactions is correct: deleting the lock immediately can corrupt an in-flight write, and diagnosing a permanent fault chases the wrong cause. Run the 3-point probe.

```bash
# (a) transient? — re-probe after a few seconds; if it's gone, an editor/poller held it, just retry
sleep 3; ls -l .git/index.lock 2>/dev/null && echo "still present" || echo "gone — retry"

# (b) 0 bytes AND mtime minutes old and unchanging (not a live write mid-flight)
stat -f '%z bytes, mtime %Sm' -t '%H:%M:%S' .git/index.lock   # macOS BSD stat
#   Linux: stat -c '%s bytes, mtime %y' .git/index.lock

# (c) no writing git process holds it
pgrep -fl git
```

Remove the lock and retry ONCE only when (a)(b)(c) all hold (`rm -f .git/index.lock`); if any fails, wait or move work to a `git worktree`.

**Suspect ordering** — when the failure has all three of "multiple repos / frequent / cause unknown", the first suspect is a high-frequency poller running in the session's cwd (an IDE's git integration, the shell prompt, the statusline), NOT an autonomous loop. A loop-caused stale lock comes bundled with the other symptoms in the `Re-check after any long-running background operation` daemon guidance (a branch you did not create, staged files that appear/vanish between probes). The pre-diet rule text blamed loops only and mis-steered the diagnosis — poller-first is the correction.

**New periodic git-calling scripts** — when you WRITE a new script that calls git on a schedule (statusline / hook / monitoring loop / shell prompt), set `export GIT_OPTIONAL_LOCKS=0` in it. That stops `git status` from taking the optional `index.lock` (the index stat-cache write-back) — the standard VS Code / p10k / starship practice. Note: the coralline statusline was already fixed in setup#663 (2026-07-06) — no re-fix needed; this convention applies to newly written scripts.

**Why the triage protocol is permanently needed**: even after the statusline fix, the git polling of IDEs like Cursor / Zed is out of our control, so `index.lock` contention keeps happening — the triage above is the durable response, the `GIT_OPTIONAL_LOCKS=0` convention only covers scripts we write.

Origin: 2026-06-19〜07-06 — 18 real-error sessions across 3 repos (setup / zp-SHIN / orca). 96eb691b (a 1-second statusline poll was the root cause → #663); 0791ced1 (Cursor-IDE-origin stale lock ×2); 41598c5a (Zed-polling-origin transient → moved to a worktree).
