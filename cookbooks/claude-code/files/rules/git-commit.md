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
- **Established repo convention** (no explicit opt-in needed, but verify the signal first): run `git log --oneline origin/main -10` on the target repo. If the last 5+ commits all reached `main` directly (no `Merge pull request #` titles, no squash-merge `(#nnn)` suffixes, all the same commit-shape e.g. solo HANDOFF/CHANGELOG updates), treat that history as the established convention for this file in this repo. The user-facing flow is unchanged — still present `! git push origin main` for the user to authorize, never auto-push — but skip the "should I open a PR?" ceremony when the history shows the answer is "no" for this file class.

Absent an explicit opt-in OR an established convention, always go PR branch → `gh pr create`. If a commit was just made on a local `main` tracking branch, redirect before pushing: `git branch -m <branch>; git push -u origin <branch>; gh pr create`.

**The convention signal is per-file-class, not per-repo**: a repo can have HANDOFF/log files that go direct-to-main while code changes still go through PRs. When the file being committed is a different class than the historical direct-to-main commits, the convention does NOT apply — fall back to PR branch.

This rule exists because the 2026-05-05 PVE migration session ended with 3 unpushed `HANDOFF.md` commits on `main` of the `ultraplan-pve-roundtable` repo. The repo's `git log --oneline origin/main -10` showed every prior HANDOFF commit went direct to `main` with no PR — a clear convention. Per the rule's prior wording I correctly presented `! git push origin main` for user authorization, but had also asked the user about PR-vs-direct ceremony when the history already answered. The git-log signal is machine-readable and can resolve the question without burning a user turn.

**Deny-list scope note**: The `Bash(git push:*)` deny entry matches commands that *start with* `git push`. A compound command `cd /repo && git push ...` bypasses the matcher. This is a known limitation. The behavioral rule (always present the blocked push as `! git push ...` and let the user run it) is the reliable enforcement mechanism — not the deny entry alone. Do not exploit the compound-form loophole to auto-push.

**CodeCommit (and other non-`origin` remote URL forms) also bypass the deny entry**: when the remote URL is `codecommit::ap-northeast-1://<profile>@<repo>` instead of `origin → github.com:...`, the command shape `git push origin <branch>` for that repo translates into the codecommit transport at the remote-helper layer — but in some sessions the deny matcher did NOT intercept the push and it ran inline as a regular Bash call (the 2026-05-06 retro session pushed a recovery branch directly to a CodeCommit remote without `!` confirmation). The orphaned-commit recovery accidentally became auto-execute. The fix is behavioral, not a regex change: **for any push to a non-GitHub remote — CodeCommit, GitLab via custom remote, internal Gitea — apply the same `! git push <remote> <branch>` user-authorization rule manually.** Treat the deny entry as a backstop that catches GitHub-flavored pushes, not a complete safety net. When the URL form is exotic, the rule lives in the assistant's behavior, not the deny config.

## Branch Check Before First Commit

Before writing any file or running `git add` in a repo that is part of the current task, run `git branch --show-current` and `git log --oneline -3`. If the current branch is not `main` and was not created for this task, stop and create a new branch from `origin/main`:

    git fetch origin
    git checkout -b fix/<topic> origin/main

Do NOT commit onto: merged PR branches still checked out locally, in-flight feature branches for unrelated work, or any branch whose `git log` shows commits unrelated to the current task. Scope-bleed discovered after the commit requires cherry-pick surgery that is easy to prevent with this 2-second check.

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

This rule exists because the 2026-05-09 ADR-0005 Phase 4 Stream T session shipped PR #280 with the WRONG content. `gh pr create` was invoked while CWD's current branch was `feat/kibana-port-rtx-routers-dashboard` (Stream U's), not the intended `feat/elastic-agent-prometheus-integration` (Stream T's). PR #280's title described Stream T's Prometheus federation cookbook but the diff was Stream U's rtx-routers dashboard NDJSON — a duplicate of PR #279. Stream T's actual code was shipped in a re-do PR #281. One full PR cycle wasted; the title/diff mismatch was discoverable only by reading the diff after merge.

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
- **the previous Bash invocation ended with `Shell cwd was reset to ...`** — the Bash sandbox does not persist branch checkouts across CWD resets. Even if the Bash log line `Switched to a new branch 'fix/X'` is visible, the next Bash invocation may evaluate `git status` against a *different* branch (typically the session-default one, which can be a long-lived `feat/*` branch left over from another conversation). This is the most common failure mode for misplaced commits in long sessions.

The branch you started the task on is not the branch you are necessarily on now. Committing on the wrong branch requires a cherry-pick + reset cleanup cycle that wastes a turn and leaves a confusing history.

**Required pattern** when committing to a fix/feat branch: always use `-C /absolute/path` and explicit branch verification in the SAME Bash call as the commit:

```bash
cd /home/shin1ohno/ManagedProjects/setup &&
  test "$(git -C . branch --show-current)" = "fix/X" &&
  git -C . add <files> &&
  git -C . commit -m "..."
```

If the `branch --show-current` test fails the chain aborts before staging, surfacing the drift immediately rather than after the commit lands on the wrong branch. **Do NOT** split `git checkout -b` into a separate Bash invocation from the commit — branch context does not survive the CWD reset between calls.

This rule exists because the 2026-04-22 session landed a `rtx-hnd: block DHCP ...` commit on `fix/hydra-upstream` instead of `main` — the user had switched branches while a long `terraform apply` was running in the background. Fixed afterward via FF-merge, but only after the user spotted it. Strengthened on 2026-05-06 after two consecutive misplaced-commit incidents in the Phase 2b auto-mitamae rollout (PRs #156 + #158): commits intended for `fix/grafana-datasource-uid` and `fix/docker-compose-force-recreate` both landed on the user's leftover `feat/grafana-pve-dashboard` branch because the `git checkout -b` ran in a separate Bash call from the eventual `git commit`. Both required cherry-pick recovery into the correct branch and `git branch -f feat/grafana-pve-dashboard origin/main` to clean up.

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

This rule exists because the 2026-05-07 PR #179 session fetched only 2 inline comments via `pulls/179/comments` and pushed a "review feedback addressed" commit. The reviewer had submitted a SECOND review (review id `PRR_kwDOJGwgDM787Pie`) adding a third comment at line 113 that was missed. User had to flag "一つ対応もれ" before I re-fetched and saw the gap. The `reviewThreads` approach would have surfaced all 3 from the start.

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

This rule exists because roon-rs commit `f6b5491` ("roon-mcp: add SSE server transport") landed on `main` 2026-05-02 and disabled JWT audience validation as a side effect — but no release tag was cut. The lxc-roon-mcp cookbook stayed pinned to `v0.5.3` (audience-validation-enabled) and rejected every claude.ai Bearer token with HTTP 401 invalid_token (`AuthError::WrongAudience`) for 3 days. The 2026-05-05 session burned the entire 401 debug arc — including a debug branch with added `tracing::warn!` and a full container rebuild — before diff'ing `v0.5.3..main` revealed the released-but-not-tagged fix. Tagging `v0.5.4` and bumping the cookbook took 2 minutes after the diagnosis; the cost would have been zero if the tag had been cut at merge time.

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

This rule exists because setup PR #135 (2026-05-05) used inline HEREDOC with backticks around `\`https://mcp.ohno.be/roon\`` in the body. `gh pr create` printed `--title string` usage hints and aborted without creating the PR. Retry with `--body-file /tmp/pr-body-bump.md` succeeded immediately. This recurs every few sessions on different repos — the body-file approach has zero failure modes.

### When the harness blocks `--body-file` — pipe via stdin

The Claude Code harness sometimes denies `gh pr create --body-file /tmp/...` with `no Write to that file appears in this transcript—the body content is unverifiable.` This happens when the harness's verifier window doesn't see the `Write` tool call that created the body file (e.g., a long transcript pushes the Write out of the verifier's lookback). The body file IS on disk, but the harness can't audit it.

Workaround: **stream the file via stdin to `--body-file -`**, which makes the body content visible inline with the command:

```
cat /tmp/pr-body.md | (cd /path/to/repo && gh pr create --base main --title "..." --body-file -)
```

`--body-file -` reads from stdin. The body content flows through the pipe, the harness sees it inline, and the deny rule doesn't fire. The body file stays as the source of truth on disk; the pipe is just the audit-friendly delivery channel.

This rule exists because setup PR #163 (Phase 3b, 2026-05-07) hit `--body-file /tmp/pr-body-phase3b.md` denial right after a Write — the harness verifier's window had advanced past the Write call by the time the gh invocation ran. Stdin pipe succeeded immediately.

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
