# 2026-08 hurdle-removal campaign (streams A / B′ / C / D)

One-day campaign (2026-08-03, PRs #804-#825 + follow-ups) removing the three
operational hurdles a 2026-08 survey quantified: OS branching inside cookbooks
(84/142 cookbooks, 122 sites), host/IP data duplicated outside the registry,
and silently-skipping external-prerequisite gates (17 SSM-gated cookbooks,
first apply on a fresh machine skipped ALL of them while exiting 0).
Plan of record: approved 4-stream plan (visibility / branch-hoisting /
registry unification / lint), user decisions embedded there.

## Stream A — external prerequisites made visible

- #804 `record_gate_event` in every `require_external_auth` return path +
  `gate-report` cookbook included LAST by every entry recipe: end-of-apply
  stdout summary, RE-RUN REQUIRED banner (fresh-machine two-apply case),
  always-written node-exporter textfile metrics (`mitamae_gate_*`),
  `.gate-rerun-required` sentinel.
- #806 `bin/doctor` — read-only preflight (aws chain / SSM grants per prefix /
  FLEET membership / gh / gpg / tailscale / claude token / network) with a fix
  command per failure. README documents the fresh-machine two-apply rule.
- #810 Prometheus alerts `MitamaeGateNeedsAttention` (`for: 3h` — reconcile
  3600s + jitter 3600s means 90m would false-fire on every fresh host) +
  `MitamaeGateReportStale`.
- #814 + #815 + #816 content-aware skip_if migration (11 sites total:
  `deploy_with_ssm_env` for the standard .env shape, `file_has_all?`
  otherwise) + lint check 13 enforcing at zero.
- Live catch on day one: pro-dev's root apply had been silently skipping the
  mcp/codex-cli SSM gates every cycle (`pve-bootstrap-ssm` has no `/mcp/*`
  grant) — visible for the first time as `mitamae_gate_attention_total 2`.

## Stream B′ — platform branching hoisted out of cookbooks

User directive: "Cookbook で分岐させず、ユースケースごとに darwin.rb /
linux.rb などのレイヤで分岐させる".

- #807 dormant mechanisms: include-layer guards (`::darwin`/`::linux` wrong-OS
  raise + `cookbooks/<name>/platform` marker), `include_platform_cookbook`,
  `platform_value(darwin:, linux:)`, `node[:hw][:machine]/[:ncpu]` facts,
  audit support for default.rb-less split cookbooks (half-split FAIL, per-OS
  orphan FAIL).
- #808 check 12 ratchet seeded with the 82 mechanically-found violating files.
- Migration waves (#811-#813, #815-#817, #819-#820, #822-#825): 82 → 0.
  - markers (dead single-OS guards deleted): 10 darwin + 20 linux + roon,
    fonts, envchain, s3-backup, rclone, obsidian_file_sync, lxc-roon
  - `install_package` data (7): tree, wget, imagemagick, iperf3, tnef,
    smartmontools, ctags
  - `platform_value` / `node[:hw]` / redundant-guard removal (11): rbenv,
    herdr, jq, fd, fastfetch, zsh, lazygit, gcloud-cli, gdbm, yq, dot-config-nvim
    (im-select extraction)
  - per-OS splits (24 cookbooks): elastic-agent (611-line 2-in-1 → the
    flagship), edge-agent, mcp, ollama, pm2, mosh, speedtest-cli, tailscale,
    eternal-terminal, gpg-backup, git, ssh, awscli, build-essential, jdk,
    libffi, golang, haskell, python, gnupg, fzf, starship, terraform, zk,
    neovim
- Deleted as unreachable (git-recoverable, all lead-approved): rclone /
  obsidian_file_sync / lxc-roon darwin arms, python's dead openssl-fix branch,
  `cookbooks/arch-wanko-cc` (its only caller was envchain's dead arch arm).
- Verification doctrine that held it together: before/after real-mruby
  `--dry-run -l debug` resource-sequence diffs (plain --dry-run hides
  converged resources), CI test-macos dry-run step logs pulled as darwin
  compile evidence, full-entry dry-runs as the stale-include net, deletion-only
  PENDING conflict resolution across 10+ concurrent-PR rebases.
- Functional canary: elastic-agent split verified on pro-dev post-merge via
  the orchestrator canary-gate — `elastic-agent/linux.rb` applied, agent
  HEALTHY, 502 ES docs in the trailing 5 minutes, zero apply errors. (The
  plan's manual pause-canary step was replaced by the recorded
  merge-first + canary-gate flow; see the plan file's deviation note.)
- Guardrail self-validation: the check-12 ratchet caught a missed guard
  deletion (remind) inside the very campaign that introduced it.

## Stream C — registry unification (in progress)

- home-monitor CodeCommit PR #120: `ip` added to the devices.json contract
  (19 entries), devices.tf inverted to read from the contract. Plan gate
  passed (diff = the SSM parameter only). Awaiting user merge +
  `terraform apply`; setup-side consumers (S1: `bin/render-host-configs` +
  committed snapshot + hosts.json/prometheus.yml generation) follow.
- Found on the way: SSM Advanced-tier headroom is down to ~560 bytes (the
  "~1.2KB" comment in host-registry-ssm.tf is stale); prometheus.yml scrapes
  a decommissioned CT and misses 4 LXCs; es-memory + apm-server were missing
  from hosts.json (es-memory = genuine drift, apm-server = documented opt-out).

## Stream D — lint/CI

- #805 WARN tier + FLEET↔edge-agent config check (FAIL) + hosts.json↔pve↔FLEET
  check (WARN) + case-without-else check (WARN; all its hits were fixed by the
  B′ migrations). #808/#814 ratchets. #821 audit now FAILs on any include whose
  target recipe file does not exist (the gap the mcp split exposed).

## Numbers

- 22 setup PRs merged in the campaign day (#804-#808, #810-#825 minus #809) +
  1 CodeCommit PR open.
- `node[:platform]` in cookbooks/: 122 sites in 82 files → **0** (allowlist:
  functions + host-profile).
- lint: 8 checks → 13 + WARN tier. audit: 3 new failure classes.
- Known-stale docs (test-cookbook usage, CLAUDE.md helper notes, TODO paths)
  synced in #818 + this PR.

## Still open when this doc landed

- Mac apply round (darwin.rb on air/neo) — CI darwin dry-runs are green for
  every PR, but #455 taught that only a real apply proves the darwin side.
- C stream S1-S6 (blocked on the CodeCommit apply).
- pro-dev `/mcp/*` gap remediation decision (grant vs scope-out vs accept).
- dash-pipefail sites recorded in TODO.md (pre-existing, separate track).
