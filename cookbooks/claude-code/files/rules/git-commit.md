# Git Commit Format

Start the summary with a `{component}: ` prefix; explain the "why", not just the "what".

Always-loaded summary. Examples and origins: `~/.claude/docs/git-commit-detail.md` (on demand — Read it when a section pointer matches).

## Deferred Stubs in PR Description

Detail: see `~/.claude/docs/git-commit-detail.md#deferred-stubs`.

## Default to PR Branch; Do Not Push to main

To reach remote `main`: branch from latest `origin/main` → commit → `git push -u origin <branch>` → `gh pr create --base main` (summary + test plan). Never default to `git push origin main`. Direct push needs explicit opt-in (the user said "push directly to main" in this conversation, or "skip PR for this one" on a single-developer repo with no CI) or an **established convention**: `git log --oneline origin/main -10` shows the last 5+ commits reached `main` directly with the same shape (no `Merge pull request #`, no `(#nnn)`). The convention is per-file-class and only skips the PR question — still present `! git push origin main`, never auto-push. A commit on local `main`: `git branch -m <branch>; git push -u origin <branch>; gh pr create`. Detail: see `~/.claude/docs/git-commit-detail.md#default-to-pr-branch`.

**Push permission shape (settings.json, since 2026-09-08)**: a `fix/` or `feat/` **branch** push runs without a prompt — do not present one as `! git push …`, just run it. Still gated: `main`-targeting pushes in their canonical spellings and every history-rewriting or remote-deleting form (`--force`, `-f`, `--force-with-lease`, `--mirror`, `--delete`) are **denied**; a bare `git push` with no refspec still **asks**. Three residual holes the config cannot close, where this rule is the only enforcement: **a rewrite flag placed after the refspec**, **`main` batched into a branch push**, and **a non-canonical `main` spelling** (`origin main:main`). So never put a rewrite flag after the refspec, never batch `main` into a branch push, and never reach `main` by an unusual spelling. Detail: see `~/.claude/docs/git-commit-detail.md#push-permission-shape`.

**Deny-list scope note**: the matchers only match commands that *start with* `git push`, so a compound `cd /repo && git push ...` or an exotic non-GitHub remote (CodeCommit `codecommit::...`, GitLab custom remote, internal Gitea) can bypass them. The behavioral rule is the enforcement: present a blocked push, and any push to a non-GitHub remote, as `! git push <remote> <branch>`; never exploit the compound-form loophole to auto-push. Detail: see `~/.claude/docs/git-commit-detail.md#deny-list-nongithub-remote`.

**Non-GitHub remote with a PR-only convention** (home-monitor on CodeCommit, whose CLAUDE.md bans pushing to `main`): the `!` rule covers the first feature-branch push of a plan. Once the user explicitly authorizes push + merge + apply for that plan in chat (e.g. 「許可するので push & merge apply までお願い」), it covers every later feature-branch push, PR and merge in the same plan and repo — no `!` per PR cycle. It never covers a `main`-targeting or history-rewriting push, a different repo, or work outside the plan.

## Merge Execution Default — self-execute, plan-scoped authorization

When a PR you created has all required checks green, do NOT present `! gh pr merge …` — `Bash(gh pr …)` is allow-listed, so `!` is not a permission gate. If the approved plan names the merge, self-execute it (`gh pr merge`, sandbox-disabled). If not, take approval once via AskUserQuestion — an explicit chat instruction ("merge 624" / "632 をマージして" / "許可するからマージして進めて") also counts — then self-execute.

**Plan-scoped authorization**: merge approval granted during an approved multi-PR plan extends to every later green-CI PR in the *same plan, same repo, plan-internal branch* without re-confirmation; a plan-internal merge is NOT a "Before destructive operations → pause" case. Same scope for a CodeCommit squash merge (`aws codecommit merge-pull-request-by-squash`), where green CI means "the repo's checks, if any, are green".

**Invariant guards, kept every time**: (a) all required checks green via `gh pr checks`; a KNOWN required check (branch-protection contexts / checks named in the skill or runner prompt, e.g. zp-SHIN's `policy-bot-prod`) NOT YET in the rollup is gate-unsatisfied — absence ≠ green, so a just-created PR waits for checks to materialize. (b) Stacked PR Merge Guard (`gh pr list --base <head>`) before `--delete-branch` — GitHub does NOT auto-retarget downstream PRs when their base is deleted, and the closed PR CANNOT be reopened (`gh pr reopen` / `gh pr edit --base` fail), costing a full PR recreation. (c) probe `gh pr view <n> --json state,mergeStateStatus` right before merging; `UNKNOWN` = mergeability still computing → re-poll after a few seconds, never treat it as BLOCKED and skip. (d) probe unresolved reviewThreads + `reviewDecision` via GraphQL right before merging — `CLEAN` does NOT include review-thread resolution; unresolved > 0 → no self-merge even with green checks, and after addressing comments re-query unresolved=0 BEFORE declaring "反映しました" (a second round can land after your push). The GraphQL query is canonical (`gh pr view --json reviewThreads` is not a valid field; `pulls/<n>/comments` alone is incomplete): see `~/.claude/docs/git-commit-detail.md#pr-review-comment-fetch`. Re-confirm via AskUserQuestion only OUTSIDE the plan scope: a different repo, a plan-external branch, a base change, or a merge needing admin/force.

**Fallback**: only when `gh pr merge` is denied by project-local settings (deny/ask), present `! gh pr merge <n> --squash --delete-branch`.

**shin1ohno/ai-memory — approval stays human (user decision 2026-09-28, ADR 0013 Decision 6)**: the ruleset requires one code-owner approval and the code owner is the user, whose credentials Claude runs with, so a Claude approval would void the control. Claude never approves a pull request there and never bypass-merges one that carries an agent label (the owner approves those; Claude may merge after that approval). Pull requests Claude opened itself it merges through the owner's pull-request bypass (`gh pr merge --admin`) once the invariant guards pass; an agent pull request whose last pusher is the owner is closed and its task re-run rather than bypassed.

**Generalizes beyond merges**: any auto-mode-classifier-blocked production mutation (license changes, service restarts, config pushes) takes the same shape — read-only verify inline, present/ask for the specific mutation, self-execute on authorization. See `~/ManagedProjects/setup/.claude/rules/infrastructure.md` "Auto-Mode Classifier Boundary — Production Reads vs Production Mutations".

**kouzoh org exception — revised 2026-07-24**: the classifier's denial of kouzoh/* self-merge is NON-DETERMINISTIC, not structural, and its deny reasons quote recorded boundaries, so recording "skip the attempt" is self-fulfilling. When the merge gate is satisfied (all required checks green incl. policy-bot, CLEAN/UNSTABLE), ATTEMPT `gh pr merge` once — do NOT pre-skip on this record. It succeeds silently (empty stdout), so ALWAYS verify with `gh pr view <n> --json state,mergedAt` before concluding either way. Only on an actual deny present `! gh -R kouzoh/<repo> pr merge <n> --merge --delete-branch` (zp convention: merge commit). Headless zp loops keep the runner-shell deterministic merge sweep as the first path (CLAUDE.md's "delegated to a runner-shell sweep" exception means that sweep, not an in-session skip). If an attempt outcome contradicts this line, update this line in the same run; a headless runner that cannot edit this repo writes the reversal to memory with tags:["todo"] so the next interactive session syncs it.

Detail (origins, kouzoh attempt log): see `~/.claude/docs/git-commit-detail.md#merge-execution-default`.

### Post-merge cleanup — same turn as the merge

自分の PR の merge 完了（self-execute 後、またはユーザー報告/`!` の merge を `gh pr view <n> --json state` = MERGED で確認後）と同じ turn で、`git fetch --prune` → local main を ff 更新 → 今 merge した PR の head ブランチ（同一 plan 内で merge 済みの兄弟含む）を `-D` で削除します（squash は `--merged` に出ない。MERGED probe が承認根拠）。(a) 対象は今 merge した PR のブランチだけです（全体 sweep は Branch Cleanup Survey、`/clean_gone` は使いません）。(b) 未コミット WIP は削除回避の理由になりません（stash → main checkout → 削除 → stash pop）。loop が working tree を共有するリポでは shared HEAD を checkout せず、別 worktree に checkout 中のブランチとともに削除をスキップしてよいです。(c) 削除しない場合は probe 済みの理由を 1 行で報告します（推測の理由は書きません）。

cwd が worktree 配下のセッションは由来（`EnterWorktree` / `fractal init` / `git worktree add`）を問わず、MERGED 確認後に `ExitWorktree(action: "remove")` → head ブランチ `-D` → 呼び出し元リポの main を `git fetch --prune` + ff 更新まで完了させます。`ExitWorktree` が通らなければ「セッション内からは削除できません」と断定せず、同 turn に `git -C <primary> worktree remove <path>` を 1 回試します。(b) のスキップは自分が作った worktree には適用しません。撤収しない場合は probe 済みの理由を 1 行で報告します。Detail: see `~/.claude/docs/git-commit-detail.md#post-merge-cleanup`.

## Branch Check Before First Commit

Before writing any file or running `git add` in a task repo, run `git branch --show-current` and `git log --oneline -3`. If the branch is not `main` and was not created for this task (a merged PR branch, unrelated in-flight work, a log with unrelated commits), branch from `origin/main` first — the `&&` is load-bearing (a swallowed fetch failure branches from a stale `origin/main`), so never split the lines:

    git fetch origin && \
      git checkout -b fix/<topic> origin/main

Detail: see `~/.claude/docs/git-commit-detail.md#branch-check-before-first-commit`.

### Config-editing tasks — branch check at first Write, not first commit

When the output is edits to `CLAUDE.md`, `~/.claude/rules/*.md`, or other rules/docs files that accumulate Writes before any `git add`, run `git -C /path/to/repo branch --show-current` **before the FIRST Write**, and cut a fresh branch from `origin/main` first if it is wrong. Detail: see `~/.claude/docs/git-commit-detail.md#config-editing-branch-check`.

### Branch check immediately before `gh pr create`

The branch can drift between commit and PR-create; pass `--head <branch>` so gh ignores the CWD: `cat /tmp/pr-body.md | gh pr create --base main --head feat/my-branch --title "..." --body-file -`. Detail: see `~/.claude/docs/git-commit-detail.md#pr-create-branch-check`.

### Multi-repo tasks

For 2+ repositories, run the branch check **per repository** with `git -C /absolute/path` before the first `git add` in each. Detail: see `~/.claude/docs/git-commit-detail.md#multi-repo-branch-check`.

### Cross-repo propagation: enumerate first

When propagating a value (hostname, SSH key, config entry, endpoint, env var) across repos, grep every likely-affected repo **before writing any file** and put all K branch/PR pairs in the plan. Detail: see `~/.claude/docs/git-commit-detail.md#cross-repo-propagation`.

### Re-check after any long-running background operation

Re-run `git branch --show-current` before **every** `git add` / `git commit` after any async gap — background Bash, a repo-writing sub-agent, a user `!` pause, an AskUserQuestion / credential-retry wait, a `Shell cwd was reset to ...` line, or a loop sharing the tree. For a repo KNOWN to host a recurring autonomous git loop, use a worktree unconditionally (prefer `.claude/worktrees/` via EnterWorktree; `/private/tmp/<name>-wt` can be sandbox-denied), never gated on a liveness probe. A shared-tree hook warning naming a different repo than your `git -C` target is a resolution artifact, not a false positive, and loop-repos.json non-registration is not clearance — go to a worktree. The worktree default covers file writes too; contamination diagnosis stays read-only until every dirty file's owner is known. Detail: see `~/.claude/docs/git-commit-detail.md#recheck-after-background-op`.

**Never use `cd` to set git context** — use `git -C /absolute/path` on every git call (`cd` does not survive the CWD reset and its `chpwd` hook masks the reset line; general form: `~/ManagedProjects/setup/.claude/rules/shell.md` "No leading bare `cd` in a command whose exit code or stdout you read"). **Required pattern** for a fix/feat-branch commit — verification and commit in the SAME Bash call, `git checkout -b` never in a separate call:

```bash
test "$(git -C /Users/sh1/ManagedProjects/setup branch --show-current)" = "fix/X" &&
  git -C /Users/sh1/ManagedProjects/setup add <files> &&
  git -C /Users/sh1/ManagedProjects/setup commit -m "..."
```

**EnterWorktree-isolated session: the chained form is refused there — serialize into plain calls.** The harness rejects `git -C` at the shared checkout and any compound git command (this chain, even one git call with a redirect): run `git add <files>`, then `git commit -m …`, from the worktree cwd. The check is textual — a non-git command containing the substring `git` (a `github_pat_` grep pattern, a heredoc mentioning `.git`, a path from a variable) is refused too; pass such text by file (`grep -f patterns.txt`, `python3 script.py`). Elsewhere the chained form stays required. Detail: see `~/.claude/docs/git-commit-detail.md#worktree-isolated-serialization`.

### A commit message containing `?` / `*` / `[` goes through `-F <file>`, not `-m`

zsh globs them and `git commit -m "…"` aborts with `no matches found` (the mangled one-line echo points at quoting, not globbing). Use `git commit -F <path>`; `-m` only for a single line with no glob characters. Detail: see `~/.claude/docs/git-commit-detail.md#commit-message-glob-chars`.

### A worktree in a sibling repo is created with `git worktree add` and driven by absolute paths

`EnterWorktree` works only in the session's current repo (or one nested in it). For a sibling repo: `git worktree add <repo>/.claude/worktrees/<name> -b <branch> origin/main`, edit via absolute paths, commit with `git -C <worktree>`; the textual refusal does not apply. Detail: see `~/.claude/docs/git-commit-detail.md#sibling-repo-worktree`.

### Cherry-pick is a commit operation — branch check applies

Run `git branch --show-current` before `git cherry-pick`; the target must be the intended branch (normally fresh from `origin/main`) — "not main" is not enough. Detail: see `~/.claude/docs/git-commit-detail.md#cherry-pick-branch-check`.

### Branch overlap pre-flight: open PR file scope

Before branching from `origin/main` while a fix-PR is open, cross-check planned file edits against open-PR files. On overlap, ask via AskUserQuestion and **default to branching from the fix-PR's HEAD** (`git checkout -b feat/<topic> origin/<fix-branch>`), rebasing after it merges. Detail: see `~/.claude/docs/git-commit-detail.md#branch-overlap-preflight`.

## `index.lock` — 3-point triage before removal

On `index.lock exists`, neither delete it at once nor call it permanent. Remove and retry ONCE only when (a) it is still there after a few seconds, (b) it is 0 bytes with a minutes-old unchanging mtime, and (c) `pgrep -fl git` shows no writer; otherwise wait or use a worktree. For "multiple repos / frequent / cause unknown", suspect a cwd poller (IDE / prompt / statusline) before an autonomous loop. Detail: see `~/.claude/docs/git-commit-detail.md#index-lock-triage`.

## Branch Cleanup Survey

Detail: see `~/.claude/docs/git-commit-detail.md#branch-cleanup-survey`.

## PR Review Comment Exhaustive Fetch

Detail: see `~/.claude/docs/git-commit-detail.md#pr-review-comment-fetch`.

## Stacked PR Merge Guard — retarget downstream PRs before `--delete-branch`

Detail: see `~/.claude/docs/git-commit-detail.md#stacked-pr-merge-guard`.

## Tag a release immediately when fixing auth/security on a downstream-consumed library

Detail: see `~/.claude/docs/git-commit-detail.md#tag-release-downstream-lib`.

## `gh pr create` body containing code → use `--body-file`

A PR body with backticks, fences, `$()`, `${...}`, nested quotes or multiple paragraphs never goes through inline `--body "$(cat <<'EOF' …)"`. Always:

```
cat > /tmp/pr-body.md <<'EOF'
## Summary
- ...
## Test plan
- `cmd1` … `cmd2` …
EOF
gh pr create --base main --title "..." --body-file /tmp/pr-body.md
```

Detail: see `~/.claude/docs/git-commit-detail.md#pr-body-file`.

### When the harness blocks `--body-file` — pipe via stdin

If `--body-file /tmp/...` is denied as `the body content is unverifiable`, pipe it: `cat /tmp/pr-body.md | (cd /path/to/repo && gh pr create --base main --title "..." --body-file -)`. Detail: see `~/.claude/docs/git-commit-detail.md#body-file-stdin`.

### Cross-sandbox TMPDIR isolation — never reference a `$TMPDIR` file across sandbox modes

A sandbox-disabled call sees a different `$TMPDIR` than the sandbox, so `cat "$TMPDIR/body.md"` returns 0 bytes silently and the PR body ships blank. Build the body inline in the same call:

```
gh pr create --base main --title "..." --body-file - <<'EOF'
## Summary
- ...
## Test plan
- `cmd1` … `cmd2` …
EOF
```

User-run `!` commands cannot see the scratchpad (`/private/tmp/claude-501/...`) or sandbox `$TMPDIR` either: inline via heredoc (`git commit -F - <<'EOF' … EOF`) or write under the repo's `.git/`. Pre-emit check: scan every `!` block for such a path. 相対パスの cwd 依存・`</parameter>` 等のタグ断片の検査（`~/ManagedProjects/setup/.claude/rules/shell.md`「User-run block self-containment」）も同じタイミングで行います。Detail: see `~/.claude/docs/git-commit-detail.md#cross-sandbox-tmpdir`.

## gh CLI network access requires `dangerouslyDisableSandbox`

`gh` calls and HTTPS `git push` fail in the sandbox (`tls: failed to verify certificate`) — run them with `dangerouslyDisableSandbox: true` from the start; SSH `git push` works in-sandbox. A `dial tcp …:443: i/o timeout` gets up to 3 retries (now → 5s → 15s); probe `gh pr view <n> --json state` before re-issuing a timed-out merge. `gh auth refresh` refuses while `GITHUB_TOKEN` is exported (always, here): wrap it and every following `gh` call needing the new credential in `env -u GITHUB_TOKEN`, and prefer the web UI for one-off account-level operations (`-s admin:public_key` widens the token permanently). Detail: see `~/.claude/docs/git-commit-detail.md#gh-network-sandbox` and `#gh-auth-refresh`.

## GPG Signing Failures

On a GPG signing error or timeout, hand the user both halves as one fenced block (reload alone does not prime pinentry; a truncated `--clearsign` fails the same way):

```
! gpg-connect-agent reloadagent /bye && echo "test" | gpg --clearsign > /dev/null
```

Never bypass signing with `-c commit.gpgsign=false` unless the user asks. Detail: see `~/.claude/docs/git-commit-detail.md#gpg-signing-failures`.

## Working directory `.git` check before first file write

Detail: see `~/.claude/docs/git-commit-detail.md#working-dir-git-check`.
