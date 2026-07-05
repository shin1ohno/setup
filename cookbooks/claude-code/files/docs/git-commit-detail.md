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
