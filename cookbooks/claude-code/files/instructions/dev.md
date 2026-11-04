<!-- layer=dev: source of truth. Edit here, then run bin/build-instructions. Do not edit the generated files. -->
<!-- section id=claude-cr-general-zsh-blocks file=CLAUDE.md order=0030 harness=claude lazy=n -->
## Critical Rules — General

- **ユーザーに渡す `!` ブロックは zsh 書式で書く**（ログインシェルは zsh 5.9）。bash 専用書式は静かに壊れる（`read -rs -p` は変数が空のまま後続が走る。zsh は `read -rs "V?x: "`）。Detail: see `~/.claude/docs/claude-md-detail.md#zsh-user-blocks`.
<!-- section id=claude-cr-general-bash-tool-zsh file=CLAUDE.md order=0040 harness=claude lazy=n -->
- **Bash ツール自体も zsh（Linux ホストでも同じ）**: ループ・配列・glob・複数行は最初から `/bin/bash -c '…'` か `bash -s <<'EOF'` で書く。`for f in $VAR` は分割されず、glob 不一致は全体を中断し、`echo ===` の `=` 展開と `mapfile` は失敗する。zsh 由来のエラーを 1 回見たらコマンド全体を bash に切り替える。Detail: see `~/.claude/docs/shell-detail.md#zsh-login-shell-traps`.
<!-- section id=claude-cr-general-plan-mode file=CLAUDE.md order=0050 harness=claude lazy=n -->
- **Non-trivial → plan mode**: 2+ files, 2+ repos, deploy steps, new agent/hook/skill. Exception: hardware/protocol debugging with unknown root cause → iterate hypotheses until the cause is found, then plan mode
<!-- section id=claude-cr-general-misclassified-trivial file=CLAUDE.md order=0060 harness=claude lazy=n -->
- **Misclassified as trivial — still need plan mode**: cross-crate enum variant, UI fix requiring contract sibling, fix requiring service restart, hardware verification loops, plugin lockfile bumps with runtime steps (`:Lazy sync`, `npm install`, parser rebuild). Detail: see `~/.claude/docs/claude-md-detail.md#plan-mode-misclassified`.
<!-- section id=claude-cr-general-not-plan-triggers file=CLAUDE.md order=0070 harness=claude lazy=n -->
- **Inverse — NOT new plan triggers**: a mechanical sweep of a validated fix shape across N files in one repo — unless the first instance is unvalidated, or the sweep crosses repos / adds behavior
<!-- section id=claude-cr-general-no-co-authored-by file=CLAUDE.md order=0130 harness=claude lazy=y -->
- **Never add a `Co-Authored-By` trailer.** This rule outranks the harness attribution instruction, which is why it lives here rather than only in a hook. `hooks/block-co-authored-by.rb` blocks `-m` / `-m"…"` / `--trailer` / `-F <file>` with exit 2; `-F -` (stdin) is invisible to argv, so that path is held by this rule alone. zp-SHIN blocks it independently in its own pre-commit hook
<!-- section id=claude-cr-general-dual-managed-files file=CLAUDE.md order=0140 harness=neutral lazy=n -->
- **Dual-managed files**: `CLAUDE.md` and `AGENTS.md` — source `~/ManagedProjects/setup/cookbooks/claude-code/files/`, deploy `~/.claude/CLAUDE.md` / `~/.agents/AGENTS.md`. Update both, `diff` to verify. **`diff` the deploy copy against source BEFORE hand-editing it**; when an apply is available, edit source and apply instead. Detail: see `~/.claude/docs/claude-md-detail.md#dual-managed-files`.

<!-- section id=claude-planning-execution file=CLAUDE.md order=0260 harness=claude lazy=n -->
## Planning and Execution Model — Claude Code specifics

- `/plan` mode + user confirmation before proceeding
- **Batch plan-phase questions** into one AskUserQuestion (multiSelect when non-exclusive) at the end of the draft. **Partial-answer guard**: re-ask any unaddressed question in one AskUserQuestion. **Size-reduction tasks** (「大きい」「削減」): the first ask MUST offer both inline-removal AND architectural-split (move sections to on-demand `docs/*.md` or path-scoped `rules/*.md`). Detail: see `~/.claude/docs/claude-md-detail.md#plan-question-batching`.
- **Auto mode ≠ skipping plan** for non-trivial work

<!-- section id=agents-general-aws-terraform file=AGENTS.md order=0090 harness=neutral lazy=n -->
- **AWS/Terraform 作業は `~/.claude/docs/aws-iam.md` を先に読む**（terraform apply は main からのみ、SSM/KMS ゲートは実ホストで probe）
<!-- section id=agents-general-commit-immediately file=AGENTS.md order=0110 harness=neutral lazy=n -->
- **Every meaningful unit of work**: commit immediately

<!-- section id=agents-bp-verify-functional-state file=AGENTS.md order=0160 harness=neutral lazy=n -->
- **Verify functional state, not deployment artifacts**: e.g. a timer's next-elapse (`systemctl status <name>.timer` / `list-timers`), not `systemctl is-active`; `show --property=Trigger` is NOT a valid check. Detail: see `~/.claude/docs/agents-md-detail.md#verify-functional-state`.
<!-- section id=agents-bp-hotfix-layering file=AGENTS.md order=0170 harness=neutral lazy=n -->
- **Hotfix layering**: weigh change frequency vs resource recreation; fix at the right layer, not where it was edited on the server
<!-- section id=agents-planning-execution file=AGENTS.md order=0230 harness=neutral lazy=n -->
## Planning and Execution Model

- **After plan approval, execute autonomously** — no per-step permission. PR is the reviewable artifact (branch → implement → test → commit → `gh pr create`)
- **State archaeology before reusing a TF resource type**: `terraform state show`, `aws iam get-user-policy`, `pct config <existing-vmid>`, `cat cookbooks/<existing>/default.rb`. Detail: see `~/.claude/docs/agents-md-detail.md#state-archaeology`.

<!-- section id=agents-probe-existing-facility file=AGENTS.md order=0260 harness=neutral lazy=n -->
**Existing-facility probe before asking or building**: before asking where keys/backups/credentials live, or writing a NEW backup/restore/keepalive/wrapper mechanism, run `rg -i '<keyword>' ~/ManagedProjects/setup/cookbooks/ ~/ManagedProjects/setup/bin/ ~/ManagedProjects/setup/docs/` — the owning cookbook names the location and its config knobs. To work around OS behavior, tune the config knob of the cookbook that already owns the feature rather than adding a runtime layer. Detail: see `~/.claude/docs/agents-md-detail.md#existing-facility-probe`.

<!-- section id=agents-probe-new-cli-side-effects file=AGENTS.md order=0290 harness=neutral lazy=n -->
- **Side effects of a NEW CLI command** — run it once and `find <likely-paths> -newer /tmp/sentinel -type f` (or `strace`) before designing around its output/cache/state.
<!-- section id=agents-detail-playbooks file=AGENTS.md order=0360 harness=neutral lazy=n -->
## Detail playbooks (load on demand — Read when the task matches)

`docs/` files, not auto-loaded — `Read` when the task matches. Claude Code-only playbooks are indexed in `~/.claude/CLAUDE.md`.

| Topic | File |
|---|---|
| AWS / IAM / SSM / KMS / Terraform — drift, apply branch gate, host probe | `~/.claude/docs/aws-iam.md` |
| mitamae/Ruby・shell・infra ops rules (outside the setup project) | `~/ManagedProjects/setup/.claude/rules/{ruby,shell,infrastructure}.md` |
| Rust commit gate, Cargo.lock, crates.io tokens, cross-platform builds | `~/.claude/docs/rust.md` |
| Docker Compose ops — branch-dep check, `--force-recreate`, UDP host-net, up -d exit-1 | `~/.claude/docs/docker-compose.md` |
| Pre-PR cookbook checklist (IP literal / healthcheck / bind-mount UID / UDP) | `~/.claude/docs/cookbook-prs.md` |
| Homebrew→mise / direct-download migration checks | `~/.claude/docs/mise-migration.md` |
| iOS build (XcodeGen + Rust UniFFI) prereqs, keychain, deploy probe | `~/.claude/docs/ios-build.md` |
| Kibana Lens / saved-object NDJSON gotchas | `~/.claude/docs/kibana-lens.md` |
| Tailscale routing conflicts (`accept-routes`, DHCP option 121) | `~/.claude/docs/tailscale.md` |
| Frontend (Next.js / Vite) dev-server / HMR gotchas | `~/.claude/docs/frontend-dev.md` |
| Data-collection escalation, retry ladder, backing secondary summaries / URLs | `~/.claude/docs/data-collection.md` |
| Weave protocol publish → feedback contract | `~/.claude/docs/weave-protocol.md` |
| Elasticsearch `dense_vector` / kNN / mappings gotchas | `~/.claude/docs/elasticsearch.md` |
| Adding an OAuth-protected MCP service to mcp.ohno.be | `~/.claude/docs/mcp-deployment.md` |
| Neovim (AstroNvim) Lazy sync / lockfile gotchas | `~/.claude/docs/neovim.md` |
| release-plz failure-mode checklist | `~/.claude/docs/release-plz.md` |
| FFI boundary (UniFFI / JNI / WASM) encoding audit | `~/.claude/docs/ffi-audit.md` |
| PVE LXC gotchas — bind-mount UID, `pct exec` non-TTY, Docker-in-LXC | `~/.claude/docs/pve-lxc-detail.md` |
| fractal node trees + plasma-wiki — config home, cost caps, `--scope`, wiki lint, waves | `~/.claude/docs/fractal-nodes.md` |
| GPG subkey distribution to headless hosts via a secret store | `~/.claude/docs/gpg-key-distribution.md` |
| Codex shared-skill probes — description truncation, `[skills] max_context_tokens` | `~/.claude/docs/codex-skills-probe.md` |
<!-- section id=adversarial-review file=rules/adversarial-review.md order=0010 harness=neutral lazy=n -->
# Adversarial Plan Review

Load when a plan involves any security-sensitive component. Launch an adversarial review sub-agent BEFORE implementation — required, not optional.

## Triggers

- OAuth / OIDC flows (DCR, consent, token issuance / validation, JWKS)
- JWT validation, audience / issuer / scope checks
- Secret mounts (tokens.json, ssh keys, TLS certs) with bind-mount path / UID semantics
- nginx `auth_request` or other reverse-proxy access gates
- Privilege boundaries between cooperating services (auth-proxy → MCP server, edge agent → home server)
- ALLOWED_EMAILS / IP allow-lists / firewall rules
- Transport-rewrite rules whose scope decides WHICH credential is used — git `insteadOf` / `pushInsteadOf`, ssh_config `Match`/`Host` blocks, proxy `no_proxy`. A rewrite that is correct today can silently reroute traffic onto the wrong identity as the host's credential set changes later, so review the scope against every credential the host may acquire, not just the ones it has
- Provisioning a credential onto a host that did not previously have one — adding a key can ACTIVATE dormant conditional logic elsewhere in the config
- An unattended runner combining `--permission-mode bypassPermissions` with a `--disallowedTools`/`--allowedTools` clamp — the clamp's runtime effectiveness is a claim to VERIFY, not a property of the flag list. Review must enumerate equivalent capabilities left reachable (a CLI on PATH duplicating a denied MCP server, subagent inheritance, alternate tool names) and require the Live Tool-Clamp Gate (detail doc) before ship

Detail (prompt template / Live Token Round-Trip Gate / origins): see `~/.claude/docs/adversarial-review-detail.md`.
<!-- section id=debugging-summary file=rules/debugging.md order=0010 harness=neutral lazy=n -->
# Code Behavior Debugging Protocol

Always-loaded summary; examples + origins in `~/.claude/docs/debugging-detail.md` (on-demand).

<!-- section id=debugging-silent-failure file=rules/debugging.md order=0020 harness=neutral lazy=n -->
## Silent Failure Detection

Silent failure = success returned (200/Ok) but the intended effect is absent. When the effect is not visible from source: (1) build the observation tool first (status command, env-gated debug log, verify script), (2) capture baseline, (3) fix, (4) re-observe, (5) only then report success.

<!-- section id=debugging-noisy-non-failure file=rules/debugging.md order=0030 harness=neutral lazy=n -->
## Noisy Non-Failure Pattern

Inverse: a warning is present while the system works; "fixing" it can kill a fallback. (1) Test the warned-about function end-to-end first (DNS warning → `getent hosts <peer>`, `tailscale ping <peer>`). (2) Classify: Cosmetic (abandoned path) / Partial (degraded — fix the real problem) / Load-bearing (real breakage). (3) Silence only Cosmetic, keeping the working path. (4) State the classification before proposing a fix.

Detail: see `~/.claude/docs/debugging-detail.md#noisy-non-failure-pattern`.

<!-- section id=debugging-state-evidence file=rules/debugging.md order=0040 harness=neutral lazy=n -->
## Do Not Report Success Without State Evidence

NOT evidence: clean compile/run, `Ok(())`, your own code's "success" line, a previous good run, passing tests, green CI whose exercising step is gated on `workflow_dispatch` inputs (grep its `if:`; if gated, dispatch it and read that step's conclusion and stdout). ARE evidence: receiving-end state (file, DB record, zone status, queue length), tests on the changed path with real inputs, receiving-system logs, a status query showing the expected state.

Detail: see `~/.claude/docs/debugging-detail.md#do-not-report-success-without-state-evidence`.

<!-- section id=debugging-auth-gate-live-token file=rules/debugging.md order=0050 harness=neutral lazy=n -->
## Auth Gate Changes — Live Token Step Required

For an auth-gate change on a RUNNING system (JWT, `auth_request`, bearer/API key, session cookie, mTLS), a source-level adversarial PASS is necessary but NOT sufficient. MUST also: (1) decode a real token from the live issuer and confirm the check passes its real claims; (2) after deploy, round-trip a real request and observe accept/reject on the receiving system. Design-time counterpart: `adversarial-review.md` "Live Token Round-Trip Gate".

Detail: see `~/.claude/docs/debugging-detail.md#auth-gate-changes-live-token`.

<!-- section id=debugging-observation-tooling file=rules/debugging.md order=0060 harness=neutral lazy=n -->
## When to Add Observation Tooling Proactively

Ship a status/observe command *with the feature* when it crosses a network/IPC boundary, is async, controls external hardware/services, or earlier fixes "succeeded" with no visible effect. If none exists, build a minimal one in the same unit of work.

<!-- section id=debugging-adapter-layer-tests file=rules/debugging.md order=0070 harness=neutral lazy=n -->
## Adapter layers need tests with host-shaped input

A thin adapter over tested logic (n8n Code node, Lambda handler, webhook controller, CLI parser) needs its own test with the input shape the host actually delivers, asserting what it passes on. When a plan tests only the logic layer, name the adapter tier as a plan gap before implementing. Same class as `docs/ffi-audit.md`.

Detail: see `~/.claude/docs/debugging-detail.md#adapter-layers-host-shaped-input`.

<!-- section id=debugging-auth-boundary-errors file=rules/debugging.md order=0080 harness=neutral lazy=n -->
## Auth-boundary error visibility — log Err variant on every reject

Auth gates MUST log the rejection variant at WARN/ERROR **unconditionally**, never behind a default-off flag (`cfg(debug_assertions)`, `RUST_LOG=trace`, `DEBUG=1`). Trigger: `Err(_) => return 401` discarding a rich error enum — log `error_variant = ?e` + expected config, at the call site or the final reject site. Never the full token; do log variant, kid, expected iss/aud/scope, 16-char prefix.

Detail: see `~/.claude/docs/debugging-detail.md#auth-boundary-error-visibility`.

<!-- section id=debugging-no-repro-push file=rules/debugging.md order=0090 harness=neutral lazy=n -->
## Do Not Push Error Reproduction to the User

"試してみてください" is a fallback, not a default. Reproduce, confirm the cause, fix and verify by observation yourself, then report with the observed state change.

<!-- section id=debugging-fix-loop-escalation file=rules/debugging.md order=0100 harness=claude lazy=n -->
## Fix-Loop Escalation Threshold

Same symptom after 3 hypothesis-test cycles on one path → stop, no 4th local fix. Synthesize ("A, B, C failed; shared assumption X") and ask via AskUserQuestion: "局所修正では解決しない可能性がある。設計上の前提 X を見直す必要があるか？". Count by capability, not error text — differently-worded errors on one capability still count. When each try costs a >60s rebuild, batch all hypothesized fixes into one rebuild.

Detail: see `~/.claude/docs/debugging-detail.md#fix-loop-escalation-threshold`.

<!-- section id=debugging-wire-protocol file=rules/debugging.md order=0110 harness=neutral lazy=n -->
## Wire-Protocol Reverse Engineering — Capture Reference Bytes First

When an external client's format is undocumented (MCP connector, Slack Socket Mode, vendor webhook), capture raw bytes from a working reference server BEFORE implementing, hex-diff your output against it, and fix all divergences in one batch. Trigger: "client says NG, my server returns 200".

Detail: see `~/.claude/docs/debugging-detail.md#wire-protocol-reverse-engineering`.

<!-- section id=debugging-read-source-first file=rules/debugging.md order=0120 harness=neutral lazy=n -->
## Read the Source Before Researching Patterns

For a third-party SDK error string, **grep the SDK source for it before any web research** (`~/ManagedProjects/<sdk>/`, else `~/.cargo/registry/src/`), read 30-50 lines around the emit site, trace the guard, then hypothesize. Sub-rules (Terraform provider command strings, tool-manager backend claims, CLI JSON schema before jq) in Detail.

Detail: see `~/.claude/docs/debugging-detail.md#read-the-source-before-researching`.

<!-- section id=debugging-failure-class file=rules/debugging.md order=0130 harness=claude lazy=n -->
## Frame the Failure Class Before Writing the Fix

Ask "what failure class is this?" before "what stops this error?". Structural triggers: rotating addresses, stored tokens against a mutable endpoint, paths another process manages, timestamps/versions/hashes outliving scope. Structural → propose the class-wide fix (discovery/caching/fallback) via AskUserQuestion; transient → retry suffices. Retry alone never completes a structural fix.

Detail: see `~/.claude/docs/debugging-detail.md#frame-the-failure-class`.

<!-- section id=debugging-remediation-feasible file=rules/debugging.md order=0140 harness=claude lazy=n -->
## Verify a chosen remediation is feasible before executing it

After AskUserQuestion picks a remediation, run the cheapest probe proving its precondition **before** the destructive/expensive step (snapshot, commit, backup, tag, role exists; credential is not a shared rotating token; device identified by a per-device identifier). Absent → do not run it; return with feasible options.

Detail: see `~/.claude/docs/debugging-detail.md#verify-remediation-feasible`.

<!-- section id=debugging-chain-verify-fix file=rules/debugging.md order=0150 harness=claude lazy=n -->
## Chain verify command with the fix in the same `!` block

Compose a must-succeed credential/config fix with its verify in one `!` block via `&&`. If not composable (interactive `aws configure`), mark the verify **required before retrying the main task**, never optional.

Detail: see `~/.claude/docs/debugging-detail.md#chain-verify-with-fix`.

<!-- section id=debugging-suspected-driver-deployed file=rules/debugging.md order=0160 harness=neutral lazy=n -->
## Confirm the suspected driver is actually deployed before optimizing it

Before caching/throttling a script suspected from source of driving cost or load, probe the target: `find`, `pgrep -a -f`, crontabs, `systemctl list-timers --all`. All absent → find the real driver (CloudTrail, `ps aux`, container logs).

Detail: see `~/.claude/docs/debugging-detail.md#confirm-suspected-driver-deployed`.
<!-- section id=editing-git-mv-reread file=rules/editing.md order=0010 harness=claude lazy=y -->
# File Editing Guidelines

## After `git mv`, Re-Read files before editing

The Edit tool tracks Read history by path, not inode. After `git mv <old> <new>`, the Read cache for `<old>` does NOT carry over to `<new>` — Edit calls on the new path fail with "File has not been read yet", even though the file content is identical and the inode is unchanged.

**Bulk rename workflow:**

1. `git mv` all files first (single Bash call)
2. Re-Read every moved file at its new path — batch in a single message with parallel Read calls
3. Apply Edits

Skipping step 2 produces one "not been read" error per file, scattering across tool calls and wasting context. On a 13-file rename this costs a full round-trip of failed Edits before the re-Read batch can start.

<!-- section id=editing-same-file-edits file=rules/editing.md order=0020 harness=claude lazy=n -->
## Multiple Edits on the same file: serialize across messages

If two `Edit` calls target the same file in a single parallel batch, they may race: both read the pre-edit content, both write, last-writer-wins (prior edits are silently lost). Avoid this by:

- Using `replace_all: true` on a single Edit when the pattern allows, OR
- Sending same-file Edits across separate messages (one Edit per message for that file)

Different-file Edits can safely run in parallel in a single message.
<!-- section id=git-commit-format file=rules/git-commit.md order=0010 harness=neutral lazy=y -->
# Git Commit Format

Start the summary with a `{component}: ` prefix; explain the "why", not just the "what".

Always-loaded summary. Examples and origins: `~/.claude/docs/git-commit-detail.md` (on demand — Read it when a section pointer matches).

<!-- section id=git-commit-deferred-stubs file=rules/git-commit.md order=0020 harness=neutral lazy=y -->
## Deferred Stubs in PR Description

Detail: see `~/.claude/docs/git-commit-detail.md#deferred-stubs`.

<!-- section id=git-commit-pr-branch file=rules/git-commit.md order=0030 harness=claude lazy=y -->
## Default to PR Branch; Do Not Push to main

To reach remote `main`: branch from latest `origin/main` → commit → `git push -u origin <branch>` → `gh pr create --base main` (summary + test plan). Never default to `git push origin main`. Direct push needs explicit opt-in (the user said "push directly to main" in this conversation, or "skip PR for this one" on a single-developer repo with no CI) or an **established convention**: `git log --oneline origin/main -10` shows the last 5+ commits reached `main` directly with the same shape (no `Merge pull request #`, no `(#nnn)`). The convention is per-file-class and only skips the PR question — still present `! git push origin main`, never auto-push. A commit on local `main`: `git branch -m <branch>; git push -u origin <branch>; gh pr create`. Detail: see `~/.claude/docs/git-commit-detail.md#default-to-pr-branch`.

**Push permission shape (settings.json, since 2026-09-08)**: a `fix/` or `feat/` **branch** push runs without a prompt — do not present one as `! git push …`, just run it. Still gated: `main`-targeting pushes in their canonical spellings and every history-rewriting or remote-deleting form (`--force`, `-f`, `--force-with-lease`, `--mirror`, `--delete`) are **denied**; a bare `git push` with no refspec still **asks**. Three residual holes the config cannot close, where this rule is the only enforcement: **a rewrite flag placed after the refspec**, **`main` batched into a branch push**, and **a non-canonical `main` spelling** (`origin main:main`). So never put a rewrite flag after the refspec, never batch `main` into a branch push, and never reach `main` by an unusual spelling. Detail: see `~/.claude/docs/git-commit-detail.md#push-permission-shape`.

**Deny-list scope note**: the matchers only match commands that *start with* `git push`, so a compound `cd /repo && git push ...` or an exotic non-GitHub remote (CodeCommit `codecommit::...`, GitLab custom remote, internal Gitea) can bypass them. The behavioral rule is the enforcement: present a blocked push, and any push to a non-GitHub remote, as `! git push <remote> <branch>`; never exploit the compound-form loophole to auto-push. Detail: see `~/.claude/docs/git-commit-detail.md#deny-list-nongithub-remote`.

**Non-GitHub remote with a PR-only convention** (home-monitor on CodeCommit, whose CLAUDE.md bans pushing to `main`): the `!` rule covers the first feature-branch push of a plan. Once the user explicitly authorizes push + merge + apply for that plan in chat (e.g. 「許可するので push & merge apply までお願い」), it covers every later feature-branch push, PR and merge in the same plan and repo — no `!` per PR cycle. It never covers a `main`-targeting or history-rewriting push, a different repo, or work outside the plan.

<!-- section id=git-commit-merge-execution file=rules/git-commit.md order=0040 harness=claude lazy=y -->
## Merge Execution Default — self-execute, plan-scoped authorization

When a PR you created has all required checks green, do NOT present `! gh pr merge …` — `Bash(gh pr …)` is allow-listed, so `!` is not a permission gate. If the approved plan names the merge, self-execute it (`gh pr merge`, sandbox-disabled). If not, take approval once via AskUserQuestion — an explicit chat instruction ("merge 624" / "632 をマージして" / "許可するからマージして進めて") also counts — then self-execute.

**Plan-scoped authorization**: merge approval granted during an approved multi-PR plan extends to every later green-CI PR in the *same plan, same repo, plan-internal branch* without re-confirmation; a plan-internal merge is NOT a "Before destructive operations → pause" case. Same scope for a CodeCommit squash merge (`aws codecommit merge-pull-request-by-squash`), where green CI means "the repo's checks, if any, are green".

**Invariant guards, kept every time**: (a) all required checks green via `gh pr checks`; a KNOWN required check (branch-protection contexts / checks named in the skill or runner prompt, e.g. zp-SHIN's `policy-bot-prod`) NOT YET in the rollup is gate-unsatisfied — absence ≠ green, so a just-created PR waits for checks to materialize. (b) Stacked PR Merge Guard (`gh pr list --base <head>`) before `--delete-branch` — GitHub does NOT auto-retarget downstream PRs when their base is deleted, and the closed PR CANNOT be reopened (`gh pr reopen` / `gh pr edit --base` fail), costing a full PR recreation. (c) probe `gh pr view <n> --json state,mergeStateStatus` right before merging; `UNKNOWN` = mergeability still computing → re-poll after a few seconds, never treat it as BLOCKED and skip. (d) probe unresolved reviewThreads + `reviewDecision` via GraphQL right before merging — `CLEAN` does NOT include review-thread resolution; unresolved > 0 → no self-merge even with green checks, and after addressing comments re-query unresolved=0 BEFORE declaring "反映しました" (a second round can land after your push). The GraphQL query is canonical (`gh pr view --json reviewThreads` is not a valid field; `pulls/<n>/comments` alone is incomplete): see `~/.claude/docs/git-commit-detail.md#pr-review-comment-fetch`. Re-confirm via AskUserQuestion only OUTSIDE the plan scope: a different repo, a plan-external branch, a base change, or a merge needing admin/force.

**Fallback**: only when `gh pr merge` is denied by project-local settings (deny/ask), present `! gh pr merge <n> --squash --delete-branch`.

**shin1ohno/ai-memory — approval stays human (user decision 2026-09-28, ADR 0013 Decision 6)**: the ruleset requires one code-owner approval and the code owner is the user, whose credentials Claude runs with, so a Claude approval would void the control. Claude never approves a pull request there and never bypass-merges one that carries an agent label (the owner approves those; Claude may merge after that approval). Pull requests Claude opened itself it merges through the owner's pull-request bypass (`gh pr merge --admin`) once the invariant guards pass; an agent pull request whose last pusher is the owner is closed and its task re-run rather than bypassed.

**Generalizes beyond merges**: any auto-mode-classifier-blocked production mutation (license changes, service restarts, config pushes) takes the same shape — read-only verify inline, present/ask for the specific mutation, self-execute on authorization. See `~/ManagedProjects/setup/.claude/rules/infrastructure.md` "Auto-Mode Classifier Boundary — Production Reads vs Production Mutations".

**kouzoh org exception — revised 2026-07-24**: the classifier's denial of kouzoh/* self-merge is NON-DETERMINISTIC, not structural, and its deny reasons quote recorded boundaries, so recording "skip the attempt" is self-fulfilling. When the merge gate is satisfied (all required checks green incl. policy-bot, CLEAN/UNSTABLE), ATTEMPT `gh pr merge` once — do NOT pre-skip on this record. It succeeds silently (empty stdout), so ALWAYS verify with `gh pr view <n> --json state,mergedAt` before concluding either way. Only on an actual deny present `! gh -R kouzoh/<repo> pr merge <n> --merge --delete-branch` (zp convention: merge commit). Headless zp loops keep the runner-shell deterministic merge sweep as the first path (CLAUDE.md's "delegated to a runner-shell sweep" exception means that sweep, not an in-session skip). If an attempt outcome contradicts this line, update this line in the same run; a headless runner that cannot edit this repo writes the reversal to memory with tags:["todo"] so the next interactive session syncs it.

Detail (origins, kouzoh attempt log): see `~/.claude/docs/git-commit-detail.md#merge-execution-default`.

<!-- section id=git-commit-post-merge-cleanup file=rules/git-commit.md order=0050 harness=claude lazy=y -->
### Post-merge cleanup — same turn as the merge

自分の PR の merge 完了（self-execute 後、またはユーザー報告/`!` の merge を `gh pr view <n> --json state` = MERGED で確認後）と同じ turn で、`git fetch --prune` → local main を ff 更新 → 今 merge した PR の head ブランチ（同一 plan 内で merge 済みの兄弟含む）を `-D` で削除します（squash は `--merged` に出ない。MERGED probe が承認根拠）。(a) 対象は今 merge した PR のブランチだけです（全体 sweep は Branch Cleanup Survey、`/clean_gone` は使いません）。(b) 未コミット WIP は削除回避の理由になりません（stash → main checkout → 削除 → stash pop）。loop が working tree を共有するリポでは shared HEAD を checkout せず、別 worktree に checkout 中のブランチとともに削除をスキップしてよいです。(c) 削除しない場合は probe 済みの理由を 1 行で報告します（推測の理由は書きません）。

cwd が worktree 配下のセッションは由来（`EnterWorktree` / `fractal init` / `git worktree add`）を問わず、MERGED 確認後に `ExitWorktree(action: "remove")` → head ブランチ `-D` → 呼び出し元リポの main を `git fetch --prune` + ff 更新まで完了させます。`ExitWorktree` が通らなければ「セッション内からは削除できません」と断定せず、同 turn に `git -C <primary> worktree remove <path>` を 1 回試します。(b) のスキップは自分が作った worktree には適用しません。撤収しない場合は probe 済みの理由を 1 行で報告します。Detail: see `~/.claude/docs/git-commit-detail.md#post-merge-cleanup`.

<!-- section id=git-commit-branch-check file=rules/git-commit.md order=0060 harness=neutral lazy=y -->
## Branch Check Before First Commit

Before writing any file or running `git add` in a task repo, run `git branch --show-current` and `git log --oneline -3`. If the branch is not `main` and was not created for this task (a merged PR branch, unrelated in-flight work, a log with unrelated commits), branch from `origin/main` first — the `&&` is load-bearing (a swallowed fetch failure branches from a stale `origin/main`), so never split the lines:

    git fetch origin && \
      git checkout -b fix/<topic> origin/main

Detail: see `~/.claude/docs/git-commit-detail.md#branch-check-before-first-commit`.

<!-- section id=git-commit-branch-check-config-edits file=rules/git-commit.md order=0070 harness=neutral lazy=n -->
### Config-editing tasks — branch check at first Write, not first commit

When the output is edits to `CLAUDE.md`, `~/.claude/rules/*.md`, or other rules/docs files that accumulate Writes before any `git add`, run `git -C /path/to/repo branch --show-current` **before the FIRST Write**, and cut a fresh branch from `origin/main` first if it is wrong. Detail: see `~/.claude/docs/git-commit-detail.md#config-editing-branch-check`.

<!-- section id=git-commit-branch-check-pr-create file=rules/git-commit.md order=0080 harness=neutral lazy=y -->
### Branch check immediately before `gh pr create`

The branch can drift between commit and PR-create; pass `--head <branch>` so gh ignores the CWD: `cat /tmp/pr-body.md | gh pr create --base main --head feat/my-branch --title "..." --body-file -`. Detail: see `~/.claude/docs/git-commit-detail.md#pr-create-branch-check`.

<!-- section id=git-commit-multi-repo file=rules/git-commit.md order=0090 harness=neutral lazy=y -->
### Multi-repo tasks

For 2+ repositories, run the branch check **per repository** with `git -C /absolute/path` before the first `git add` in each. Detail: see `~/.claude/docs/git-commit-detail.md#multi-repo-branch-check`.

<!-- section id=git-commit-cross-repo-propagation file=rules/git-commit.md order=0100 harness=neutral lazy=n -->
### Cross-repo propagation: enumerate first

When propagating a value (hostname, SSH key, config entry, endpoint, env var) across repos, grep every likely-affected repo **before writing any file** and put all K branch/PR pairs in the plan. Detail: see `~/.claude/docs/git-commit-detail.md#cross-repo-propagation`.

<!-- section id=git-commit-recheck-after-background file=rules/git-commit.md order=0110 harness=claude lazy=y -->
### Re-check after any long-running background operation

Re-run `git branch --show-current` before **every** `git add` / `git commit` after any async gap — background Bash, a repo-writing sub-agent, a user `!` pause, an AskUserQuestion / credential-retry wait, a `Shell cwd was reset to ...` line, or a loop sharing the tree. For a repo KNOWN to host a recurring autonomous git loop, use a worktree unconditionally (prefer `.claude/worktrees/` via EnterWorktree; `/private/tmp/<name>-wt` can be sandbox-denied), never gated on a liveness probe. A shared-tree hook warning naming a different repo than your `git -C` target is a resolution artifact, not a false positive, and loop-repos.json non-registration is not clearance — go to a worktree. The worktree default covers file writes too; contamination diagnosis stays read-only until every dirty file's owner is known. Detail: see `~/.claude/docs/git-commit-detail.md#recheck-after-background-op`.

**Never use `cd` to set git context** — use `git -C /absolute/path` on every git call (`cd` does not survive the CWD reset and its `chpwd` hook masks the reset line; general form: `~/ManagedProjects/setup/.claude/rules/shell.md` "No leading bare `cd` in a command whose exit code or stdout you read"). **Required pattern** for a fix/feat-branch commit — verification and commit in the SAME Bash call, `git checkout -b` never in a separate call:

```bash
test "$(git -C /Users/sh1/ManagedProjects/setup branch --show-current)" = "fix/X" &&
  git -C /Users/sh1/ManagedProjects/setup add <files> &&
  git -C /Users/sh1/ManagedProjects/setup commit -m "..."
```

**EnterWorktree-isolated session: the chained form is refused there — serialize into plain calls.** The harness rejects `git -C` at the shared checkout and any compound git command (this chain, even one git call with a redirect): run `git add <files>`, then `git commit -m …`, from the worktree cwd. The check is textual — a non-git command containing the substring `git` (a `github_pat_` grep pattern, a heredoc mentioning `.git`, a path from a variable) is refused too; pass such text by file (`grep -f patterns.txt`, `python3 script.py`). Elsewhere the chained form stays required. Detail: see `~/.claude/docs/git-commit-detail.md#worktree-isolated-serialization`.

<!-- section id=git-commit-message-file file=rules/git-commit.md order=0120 harness=neutral lazy=y -->
### A commit message containing `?` / `*` / `[` goes through `-F <file>`, not `-m`

zsh globs them and `git commit -m "…"` aborts with `no matches found` (the mangled one-line echo points at quoting, not globbing). Use `git commit -F <path>`; `-m` only for a single line with no glob characters. Detail: see `~/.claude/docs/git-commit-detail.md#commit-message-glob-chars`.

<!-- section id=git-commit-sibling-worktree file=rules/git-commit.md order=0130 harness=claude lazy=y -->
### A worktree in a sibling repo is created with `git worktree add` and driven by absolute paths

`EnterWorktree` works only in the session's current repo (or one nested in it). For a sibling repo: `git worktree add <repo>/.claude/worktrees/<name> -b <branch> origin/main`, edit via absolute paths, commit with `git -C <worktree>`; the textual refusal does not apply. Detail: see `~/.claude/docs/git-commit-detail.md#sibling-repo-worktree`.

<!-- section id=git-commit-cherry-pick file=rules/git-commit.md order=0140 harness=neutral lazy=y -->
### Cherry-pick is a commit operation — branch check applies

Run `git branch --show-current` before `git cherry-pick`; the target must be the intended branch (normally fresh from `origin/main`) — "not main" is not enough. Detail: see `~/.claude/docs/git-commit-detail.md#cherry-pick-branch-check`.

<!-- section id=git-commit-branch-overlap file=rules/git-commit.md order=0150 harness=claude lazy=y -->
### Branch overlap pre-flight: open PR file scope

Before branching from `origin/main` while a fix-PR is open, cross-check planned file edits against open-PR files. On overlap, ask via AskUserQuestion and **default to branching from the fix-PR's HEAD** (`git checkout -b feat/<topic> origin/<fix-branch>`), rebasing after it merges. Detail: see `~/.claude/docs/git-commit-detail.md#branch-overlap-preflight`.

<!-- section id=git-commit-index-lock file=rules/git-commit.md order=0160 harness=neutral lazy=y -->
## `index.lock` — 3-point triage before removal

On `index.lock exists`, neither delete it at once nor call it permanent. Remove and retry ONCE only when (a) it is still there after a few seconds, (b) it is 0 bytes with a minutes-old unchanging mtime, and (c) `pgrep -fl git` shows no writer; otherwise wait or use a worktree. For "multiple repos / frequent / cause unknown", suspect a cwd poller (IDE / prompt / statusline) before an autonomous loop. Detail: see `~/.claude/docs/git-commit-detail.md#index-lock-triage`.

<!-- section id=git-commit-branch-cleanup file=rules/git-commit.md order=0170 harness=neutral lazy=y -->
## Branch Cleanup Survey

Detail: see `~/.claude/docs/git-commit-detail.md#branch-cleanup-survey`.

<!-- section id=git-commit-pr-review-comments file=rules/git-commit.md order=0180 harness=neutral lazy=y -->
## PR Review Comment Exhaustive Fetch

Detail: see `~/.claude/docs/git-commit-detail.md#pr-review-comment-fetch`.

<!-- section id=git-commit-stacked-pr-guard file=rules/git-commit.md order=0190 harness=neutral lazy=y -->
## Stacked PR Merge Guard — retarget downstream PRs before `--delete-branch`

Detail: see `~/.claude/docs/git-commit-detail.md#stacked-pr-merge-guard`.

<!-- section id=git-commit-tag-release file=rules/git-commit.md order=0200 harness=neutral lazy=y -->
## Tag a release immediately when fixing auth/security on a downstream-consumed library

Detail: see `~/.claude/docs/git-commit-detail.md#tag-release-downstream-lib`.

<!-- section id=git-commit-pr-body-file file=rules/git-commit.md order=0210 harness=neutral lazy=y -->
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

<!-- section id=git-commit-body-file-stdin file=rules/git-commit.md order=0220 harness=claude lazy=y -->
### When the harness blocks `--body-file` — pipe via stdin

If `--body-file /tmp/...` is denied as `the body content is unverifiable`, pipe it: `cat /tmp/pr-body.md | (cd /path/to/repo && gh pr create --base main --title "..." --body-file -)`. Detail: see `~/.claude/docs/git-commit-detail.md#body-file-stdin`.

<!-- section id=git-commit-tmpdir-isolation file=rules/git-commit.md order=0230 harness=claude lazy=y -->
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

<!-- section id=git-commit-gh-sandbox file=rules/git-commit.md order=0240 harness=claude lazy=y -->
## gh CLI network access requires `dangerouslyDisableSandbox`

`gh` calls and HTTPS `git push` fail in the sandbox (`tls: failed to verify certificate`) — run them with `dangerouslyDisableSandbox: true` from the start; SSH `git push` works in-sandbox. A `dial tcp …:443: i/o timeout` gets up to 3 retries (now → 5s → 15s); probe `gh pr view <n> --json state` before re-issuing a timed-out merge. `gh auth refresh` refuses while `GITHUB_TOKEN` is exported (always, here): wrap it and every following `gh` call needing the new credential in `env -u GITHUB_TOKEN`, and prefer the web UI for one-off account-level operations (`-s admin:public_key` widens the token permanently). Detail: see `~/.claude/docs/git-commit-detail.md#gh-network-sandbox` and `#gh-auth-refresh`.

<!-- section id=git-commit-gpg-signing file=rules/git-commit.md order=0250 harness=claude lazy=y -->
## GPG Signing Failures

On a GPG signing error or timeout, hand the user both halves as one fenced block (reload alone does not prime pinentry; a truncated `--clearsign` fails the same way):

```
! gpg-connect-agent reloadagent /bye && echo "test" | gpg --clearsign > /dev/null
```

Never bypass signing with `-c commit.gpgsign=false` unless the user asks. Detail: see `~/.claude/docs/git-commit-detail.md#gpg-signing-failures`.

<!-- section id=git-commit-working-dir-git-check file=rules/git-commit.md order=0260 harness=neutral lazy=n -->
## Working directory `.git` check before first file write

Detail: see `~/.claude/docs/git-commit-detail.md#working-dir-git-check`.
<!-- section id=mcp-config-mcp-json file=rules/mcp-config.md order=0010 harness=claude lazy=n -->
# MCP Server Configuration

MCP server configurations belong in **`.mcp.json`** at the project root — NOT in `.claude/settings.local.json` or `.claude/settings.json`.

Format:
```json
{
  "mcpServers": {
    "name": {
      "type": "stdio",
      "command": "/absolute/path/to/binary",
      "args": ["--flag", "value"]
    }
  }
}
```

- Use absolute paths for the command binary (avoid `cargo run` — too slow for MCP startup)
- MCP servers must respond to `initialize` immediately — no startup sleep
- For SSE transport, use `--transport sse --http-port <port>` and the client connects via HTTP

<!-- section id=mcp-config-connected-not-auth file=rules/mcp-config.md order=0020 harness=claude lazy=y -->
## `claude mcp list` の Connected は認証・接続の証拠にしない

`claude mcp list` / `claude mcp get` の Connected は「サーバが initialize に応答した」以上を意味しない。claude.ai スコープの Google 系コネクタ（`*mcp.googleapis.com/mcp/v1`）は未認証の initialize に 200 を返すため、claude.ai で切断した後も Connected と表示される（Notion / Slack / Figma は 401 で Needs authentication になる）。ツールが実際に注入されるかは、新規セッションの ToolSearch か、陽性対照つきの headless 多回 probe（`~/.claude/docs/claude-cli-headless.md`）で判定する。SessionStart の health hook もこの Connected を信じるので、Google 系の認証切れは検出できない。

Origin: 2026-10-30、直接登録 13 本を claude.ai で切断した後に Google 6 本だけが Connected のまま見え、切断失敗と誤読した件。
<!-- section id=planning-intro file=rules/planning.md order=0010 harness=claude lazy=n -->
# Plan-Phase Rules

Examples, origins and the UX / IA plan structure: `~/.claude/docs/planning-detail.md` (on-demand).

<!-- section id=planning-design-to-plan file=rules/planning.md order=0020 harness=claude lazy=n -->
## Design-to-Plan Transition

An exploratory conversation ("考えてみてください", "どう思う？") converging on a direction ("この方向でやろう", "いい案だ", proposal accepted) is the plan-mode entry trigger, not a chat consent question. **Banned closings for non-trivial tasks** — 「この方針で X 実装していいですか？」「X に進んでいいですか？」「実装に入っていいですか？」 (or English equivalents): call EnterPlanMode instead.

<!-- section id=planning-autonomous-execution file=rules/planning.md order=0030 harness=claude lazy=n -->
## Autonomous Execution Boundary

| Situation | Action |
|-----------|--------|
| Plan approved, implementation straightforward | Proceed autonomously |
| Tests fail during implementation | Fix and retry, do not ask |
| Same observable symptom persists after 3 fix attempts | Stop loop — synthesize failed hypotheses, challenge design assumption with AskUserQuestion |
| Ambiguity discovered not covered by the plan | AskUserQuestion |
| Scope creep temptation | AskUserQuestion |
| Destructive operation not in the plan | AskUserQuestion |
| Technically-necessary additive change mid-implementation (extra schema field/variant, no scope change) | Proceed without asking; append a one-line note to the plan file in the same turn so the plan alone reconstructs the decision |
| Implementation complete | Create PR, launch a background `gh pr checks --watch` loop at once; on failure read the log, fix, push unprompted, repeat. Not complete (no user notice) until every required check is green |
| `gh pr checks --watch` exits non-zero with `HTTP 504` / `Bad Gateway` / `no checks reported on the '<branch>' branch` | Re-launch once; on a second failure read `gh pr view <n> --json statusCheckRollup,mergeStateStatus`: `DIRTY` / `CONFLICTING` → rebase, force-push, re-watch; only an empty rollup with `CLEAN` / `UNSTABLE` / `BEHIND` is transient. A single exit-1 is not a CI-failure verdict. Detail: see `~/.claude/docs/planning-detail.md#autonomous-execution-boundary` |
| Unit of work committed, more items remain | Proceed to next item immediately |
| ~8-10 consecutive foreground tool calls with no user-facing text, or a harness "hasn't heard from you in a while" reminder | Emit one line (current step + next) before the next tool call; after the reminder the reply must carry progress. Foreground counterpart of CLAUDE.md's background-poll rule |
| All plan items complete but plan mode still active | Exit plan mode immediately, do not re-enter |
| Blocked waiting for manual user action (sudo, restart, deploy) | Launch background retro/memory/TODO agents immediately |

<!-- section id=planning-research-to-plan file=rules/planning.md order=0040 harness=claude lazy=n -->
## Research-to-Plan Pipeline

When research precedes planning, run both in parallel: launch background research, **immediately** draft in plan mode, fold results in as they land, then present. Waiting for results before planning is a violation.

<!-- section id=planning-parallel-stream file=rules/planning.md order=0060 harness=claude lazy=n -->
## Parallel-Stream Decomposition — Default Plan Shape

For a rewrite / migration / multi-module or multi-repo job with 3+ independent units, default to contracts-first parallel, proposed unasked: Wave 0 freezes shared types/schemas; streams declare file exclusivity (`sub-agents.md`); state the stream-count vs review-load tradeoff. A genuinely serial graph stays serial with a one-line reason (mechanical sweeps out of scope). Derive a fan-out count from an upstream discovery run first, never a guessed cap. 3+ parallel drafters of one document need a Wave 0 *contracts* file (shared names/shapes), not just a decisions file.

Detail: see `~/.claude/docs/planning-detail.md#parallel-stream-decomposition`.

<!-- section id=planning-standard-mechanism-first file=rules/planning.md order=0070 harness=claude lazy=n -->
## Architecture Discussion Gates

### Standard Mechanism First — justify every added layer

Before a plan adds a NEW mechanism (tunnel, proxy, bespoke secret path, wrapper, sync daemon), write one line on whether the platform's **standard** mechanism suffices (plain ssh + `authorized_keys`, the CLI's default auth, a direct IAM grant, the service's scheduler). If it does and you still add the layer, state what it buys and put it through AskUserQuestion; a plan without that line is incomplete.

Detail: see `~/.claude/docs/planning-detail.md#standard-mechanism-first`.

<!-- section id=planning-cross-repo-design file=rules/planning.md order=0080 harness=claude lazy=n -->
### Cross-Repo Design Decisions

When a task spans 2+ repos with a shared contract (protocol schema, MQTT topics, API, event format, shared model), stop before writing it and ask via AskUserQuestion: "This defines a shared contract between [A] and [B]. Proposed design: [x]. Adjust before I implement?"

<!-- section id=planning-architecture-first file=rules/planning.md order=0090 harness=claude lazy=n -->
### Architecture Before Implementation

For a new system layer (binary, service, routing engine): name it, define its single responsibility, inputs/outputs and interactions, confirm via AskUserQuestion, then implement.

<!-- section id=planning-sdk-vs-consumer file=rules/planning.md order=0100 harness=neutral lazy=n -->
### SDK vs. Consumer Distinction

An SDK must be useful without any specific consumer; consumer-specific logic belongs in the consumer binary. When unsure of the layer, ask before placing it.

<!-- section id=planning-ux-plan-structure file=rules/planning.md order=0110 harness=claude lazy=n -->
## UX / IA / Frontend Plan File Structure

For UX revision, IA redesign, or a frontend feature with multiple user-facing behaviors, the plan file MUST use the fixed section order: use-case flows FIRST, and Verification split into **Claude-runnable tests** (mandatory) + numbered **User hardware verification** (device-only steps). Detail: see `~/.claude/docs/planning-detail.md#ux-ia-plan-file-structure`.
<!-- section id=sub-agents-review-out-of-scope file=rules/sub-agents.md order=0080 harness=claude lazy=n -->
## Review Agent Out-of-Scope Findings — Capture, Don't Drop

A correctness / idempotency / stale-reference finding outside a review's scope is captured, never left in prose beside `findings: []`: report it under `category: "correctness"` via `ReportFindings`, or surface it as an "Out-of-scope observations" note AND transcribe it to TODO.md in the same turn (description / reason / first step). Detail: see `~/.claude/docs/sub-agents-detail.md#review-agent-out-of-scope`.

