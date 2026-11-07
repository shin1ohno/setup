- **Generated instruction files**: `CLAUDE.md`, `AGENTS.md`, `rules/*.md` and `docs/knowledge-persistence.md` in `~/ManagedProjects/setup/cookbooks/claude-code/files/` are generated; the source of truth is the layer files `instructions/{cos,dev,common,writing}.md` there (layer = audience; a section marker's `file=` is the deploy target). After editing, run `bin/build-instructions` and commit layers and outputs together (CI runs `--check`); never hand-edit the generated files in the repo. Deployed copies (`~/.claude/CLAUDE.md`, `~/.agents/AGENTS.md`, `~/.claude/rules/`): **`diff` against the repo copy BEFORE touching them**; prefer edit source, build, apply. Detail: see `~/.claude/docs/claude-md-detail.md#dual-managed-files`.

- **AWS/Terraform 作業は `~/.claude/docs/aws-iam.md` を先に読む**（terraform apply は main からのみ、SSM/KMS ゲートは実ホストで probe）
- **Every meaningful unit of work**: commit immediately

- **Verify functional state, not deployment artifacts**: e.g. a timer's next-elapse (`systemctl status <name>.timer` / `list-timers`), not `systemctl is-active`; `show --property=Trigger` is NOT a valid check. Detail: see `~/.claude/docs/agents-md-detail.md#verify-functional-state`.
- **Hotfix layering**: weigh change frequency vs resource recreation; fix at the right layer, not where it was edited on the server
## Planning and Execution Model

- **After plan approval, execute autonomously** — no per-step permission. PR is the reviewable artifact (branch → implement → test → commit → `gh pr create`)
- **State archaeology before reusing a TF resource type**: `terraform state show`, `aws iam get-user-policy`, `pct config <existing-vmid>`, `cat cookbooks/<existing>/default.rb`. Detail: see `~/.claude/docs/agents-md-detail.md#state-archaeology`.

**Existing-facility probe before asking or building**: before asking where keys/backups/credentials live, or writing a NEW backup/restore/keepalive/wrapper mechanism, run `rg -i '<keyword>' ~/ManagedProjects/setup/cookbooks/ ~/ManagedProjects/setup/bin/ ~/ManagedProjects/setup/docs/` — the owning cookbook names the location and its config knobs. To work around OS behavior, tune the config knob of the cookbook that already owns the feature rather than adding a runtime layer. Detail: see `~/.claude/docs/agents-md-detail.md#existing-facility-probe`.

- **Side effects of a NEW CLI command** — run it once and `find <likely-paths> -newer /tmp/sentinel -type f` (or `strace`) before designing around its output/cache/state.
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
# Code Behavior Debugging Protocol

Always-loaded summary; examples + origins in `~/.claude/docs/debugging-detail.md` (on-demand).

## Silent Failure Detection

Silent failure = success returned (200/Ok) but the intended effect is absent. When the effect is not visible from source: (1) build the observation tool first (status command, env-gated debug log, verify script), (2) capture baseline, (3) fix, (4) re-observe, (5) only then report success.

## Noisy Non-Failure Pattern

Inverse: a warning is present while the system works; "fixing" it can kill a fallback. (1) Test the warned-about function end-to-end first (DNS warning → `getent hosts <peer>`, `tailscale ping <peer>`). (2) Classify: Cosmetic (abandoned path) / Partial (degraded — fix the real problem) / Load-bearing (real breakage). (3) Silence only Cosmetic, keeping the working path. (4) State the classification before proposing a fix.

Detail: see `~/.claude/docs/debugging-detail.md#noisy-non-failure-pattern`.

## Do Not Report Success Without State Evidence

NOT evidence: clean compile/run, `Ok(())`, your own code's "success" line, a previous good run, passing tests, green CI whose exercising step is gated on `workflow_dispatch` inputs (grep its `if:`; if gated, dispatch it and read that step's conclusion and stdout). ARE evidence: receiving-end state (file, DB record, zone status, queue length), tests on the changed path with real inputs, receiving-system logs, a status query showing the expected state.

Detail: see `~/.claude/docs/debugging-detail.md#do-not-report-success-without-state-evidence`.

## Auth Gate Changes — Live Token Step Required

For an auth-gate change on a RUNNING system (JWT, `auth_request`, bearer/API key, session cookie, mTLS), a source-level adversarial PASS is necessary but NOT sufficient. MUST also: (1) decode a real token from the live issuer and confirm the check passes its real claims; (2) after deploy, round-trip a real request and observe accept/reject on the receiving system. Design-time counterpart: `adversarial-review.md` "Live Token Round-Trip Gate".

Detail: see `~/.claude/docs/debugging-detail.md#auth-gate-changes-live-token`.

## When to Add Observation Tooling Proactively

Ship a status/observe command *with the feature* when it crosses a network/IPC boundary, is async, controls external hardware/services, or earlier fixes "succeeded" with no visible effect. If none exists, build a minimal one in the same unit of work.

## Adapter layers need tests with host-shaped input

A thin adapter over tested logic (n8n Code node, Lambda handler, webhook controller, CLI parser) needs its own test with the input shape the host actually delivers, asserting what it passes on. When a plan tests only the logic layer, name the adapter tier as a plan gap before implementing. Same class as `docs/ffi-audit.md`.

Detail: see `~/.claude/docs/debugging-detail.md#adapter-layers-host-shaped-input`.

## Auth-boundary error visibility — log Err variant on every reject

Auth gates MUST log the rejection variant at WARN/ERROR **unconditionally**, never behind a default-off flag (`cfg(debug_assertions)`, `RUST_LOG=trace`, `DEBUG=1`). Trigger: `Err(_) => return 401` discarding a rich error enum — log `error_variant = ?e` + expected config, at the call site or the final reject site. Never the full token; do log variant, kid, expected iss/aud/scope, 16-char prefix.

Detail: see `~/.claude/docs/debugging-detail.md#auth-boundary-error-visibility`.

## Do Not Push Error Reproduction to the User

"試してみてください" is a fallback, not a default. Reproduce, confirm the cause, fix and verify by observation yourself, then report with the observed state change.

## Wire-Protocol Reverse Engineering — Capture Reference Bytes First

When an external client's format is undocumented (MCP connector, Slack Socket Mode, vendor webhook), capture raw bytes from a working reference server BEFORE implementing, hex-diff your output against it, and fix all divergences in one batch. Trigger: "client says NG, my server returns 200".

Detail: see `~/.claude/docs/debugging-detail.md#wire-protocol-reverse-engineering`.

## Read the Source Before Researching Patterns

For a third-party SDK error string, **grep the SDK source for it before any web research** (`~/ManagedProjects/<sdk>/`, else `~/.cargo/registry/src/`), read 30-50 lines around the emit site, trace the guard, then hypothesize. Sub-rules (Terraform provider command strings, tool-manager backend claims, CLI JSON schema before jq) in Detail.

Detail: see `~/.claude/docs/debugging-detail.md#read-the-source-before-researching`.

## Confirm the suspected driver is actually deployed before optimizing it

Before caching/throttling a script suspected from source of driving cost or load, probe the target: `find`, `pgrep -a -f`, crontabs, `systemctl list-timers --all`. All absent → find the real driver (CloudTrail, `ps aux`, container logs).

Detail: see `~/.claude/docs/debugging-detail.md#confirm-suspected-driver-deployed`.
# Git Commit Format

Start the summary with a `{component}: ` prefix; explain the "why", not just the "what".

Always-loaded summary. Examples and origins: `~/.claude/docs/git-commit-detail.md` (on demand — Read it when a section pointer matches).

## Deferred Stubs in PR Description

Detail: see `~/.claude/docs/git-commit-detail.md#deferred-stubs`.

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

### A commit message containing `?` / `*` / `[` goes through `-F <file>`, not `-m`

Detail: see `~/.claude/docs/git-commit-detail.md#commit-message-glob-chars`.

### Cherry-pick is a commit operation — branch check applies

Run `git branch --show-current` before `git cherry-pick`; the target must be the intended branch (normally fresh from `origin/main`) — "not main" is not enough. Detail: see `~/.claude/docs/git-commit-detail.md#cherry-pick-branch-check`.

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

Detail: see `~/.claude/docs/git-commit-detail.md#pr-body-file`.

## Working directory `.git` check before first file write

Detail: see `~/.claude/docs/git-commit-detail.md#working-dir-git-check`.
### SDK vs. Consumer Distinction

An SDK must be useful without any specific consumer; consumer-specific logic belongs in the consumer binary. When unsure of the layer, ask before placing it.

