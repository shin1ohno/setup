# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

## Architecture Overview

A **mitamae-based** (Ruby, Chef/Ansible-like) infrastructure automation system that sets up development environments on macOS (Darwin) and Linux.

## Scope

This repository configures:

| Host type | Example | Entry recipe |
|---|---|---|
| Bare-metal Linux workstation | `pro` | `linux.rb` (refuses to apply inside any container — guarded by `systemd-detect-virt -c`; bypass with `MITAMAE_FORCE_BARE_METAL=1`) |
| Proxmox VE host | the host that runs the LXCs | `pve/pve-host.rb` |
| Developer workstation LXC | `pro-dev` (CT 104), future `*-dev` | `pve/lxc-pro-dev.rb` (delegates to the `lxc-dev-workstation` cookbook; future LXCs reuse it with their own `node[:lxc_dev][:*]` overrides) |
| Service LXC | `lxc-hydra`, `lxc-memory`, `lxc-monitoring`, `lxc-roon`, `lxc-roon-mcp`, `lxc-weave`, `lxc-samba`, `lxc-housekeeping`, `lxc-consent`, `lxc-pro-router`, `lxc-es-0/1/2` (Elasticsearch cluster), `lxc-kibana`, `lxc-apm-server` | matching `pve/lxc-<service>.rb` (apply all in parallel via `bin/apply-pve-lxcs`) |
| macOS | `air`, `ohnos-macbook` | `darwin.rb` |

`linux.rb` is bare-metal-only: MCP servers (ai-memory, hydra, hydra-consent), Roon Server / MCP and the Elastic stack (`docs/adr/0005-rtx-logs-loki-to-elasticsearch.md`) run in dedicated LXCs, NOT on bare-metal pro.

Not configured here: AWS-managed EC2 (Amazon Linux 2023, `nrt-subnet-router`) — `~/ManagedProjects/home-monitor/scripts/tailscale-setup/`; physical network devices (YAMAHA RTX) — `~/ManagedProjects/home-monitor/`.

**Decision rule** for new fixes: a root cause that reproduces across multiple Linux / macOS hosts (even if found on one) is fixed here. The inverse (OS-specific Ubuntu fixes in a cookbook that also runs on AL2023) is the Cross-OS Scope Gate in `~/ManagedProjects/setup/.claude/rules/infrastructure-cookbook.md`.

### Core Structure

Entry points `darwin.rb` / `linux.rb` include roles + platform-specific cookbooks; each role includes cookbooks; `cookbooks/functions/default.rb` provides helpers for all recipes; `bin/setup` downloads mitamae with per-platform SHA verification.

Roles: `core` (CLI tools), `programming` (languages), `llm` (MCP servers, Claude Code, Codex, …), `network`, `extras` (terraform, neovim, docker), `manage` (projects from JSON), `server` (Linux only), `lxc-core` (base of every `pve/lxc-*.rb` + `pve-host.rb`: `node-exporter` :9100 + `auto-mitamae-target` forced-command key).

### Key Commands

```bash
./bin/setup                               # download mitamae (macOS and Linux)
./bin/mitamae local darwin.rb             # full macOS setup (linux.rb on bare-metal Linux)
./bin/mitamae local darwin.rb --dry-run   # dry run
./bin/apply-pve-lxcs                      # apply all pve/lxc-*.rb in parallel
./bin/bootstrap-lxc-creds <CT>            # seed AWS profile into a fresh LXC before its first apply
```

`cookbooks/mac-sudo` ships `Defaults:<user> timestamp_type=global, timestamp_timeout=60`, so a full darwin apply prompts for sudo at most once (Touch ID via pam_tid). Auto-mitamae: `cookbooks/auto-mitamae-target` installs the forced-command `mitamae-runner` on each LXC; `cookbooks/auto-mitamae-orchestrator` drives periodic fleet apply from cron on monitoring (CT 111) — drift-checker every 2 min, orchestrator every 5 min, watchdog every 3 min.

## Claude Code Hooks

- Hook scripts in `cookbooks/claude-code/files/hooks/` must be written in Ruby

## Important Notes

- Test cookbook changes with `--dry-run` first. `.claude/hooks/guard-mitamae-dry-run.rb` blocks **`sudo mitamae`** without `--dry-run`; bare `./bin/mitamae local <recipe>.rb` is allowed (cookbooks elevate per resource via `execute "sudo ..."`, prompting each time) — add `--dry-run` whenever the apply must NOT actually run. `remind-cookbook-dry-run.rb` reminds after cookbook edits.
- **sudo context by host type**: resources use `execute "sudo install …"` and mitamae runs without sudo (`.claude/rules/ruby.md`); for the OUTER invocation, infer from the recipe path and never prepend `sudo` "to be safe":
  - Bare-metal Linux + macOS (`pro`, `air`, `ohnos-macbook`): `./bin/mitamae local <platform>.rb` as the regular user — `sudo` sets `$HOME` to `/root` and breaks rbenv/mise/pyenv path resolution.
  - Service LXCs (`pve/lxc-*.rb`): run inside the CT, already root — no `sudo`. `pve/pve-host.rb` runs as root on the PVE host anyway.
  - Origin 2026-05-09: `sudo ./bin/mitamae local pve/lxc-pro-dev.rb` broke rbenv path resolution.
- `run_command("command", error: false)` for status-code checks; profile scripts load from `~/.setup_shin1ohno/profile.d/` by priority.
- `linux.rb` includes hardware-coupled cookbooks (bluez, broadcom-wifi, zeroconf, edge-agent) directly; `darwin.rb` includes client setup (mac-settings, mac-apps) directly.

## Project rules — what loads when

- Always loaded: `.claude/rules/shell.md` (Bash usage in this repo) and `.claude/rules/infrastructure.md` (ops rules: managed-file ownership, incident first response, blocked commands, the auto-mode classifier boundary, systemd timer verification).
- Loaded when you Read/Edit a file under `cookbooks/`, `roles/`, `pve/`, `bin/`, `config/` or a top-level `*.rb`: `.claude/rules/ruby.md` (mitamae / mruby), `.claude/rules/infrastructure-cookbook.md` (blast radius, merge semantics, cross-OS gate, canary, …) and `.claude/rules/cookbook-conventions.md` (helpers, conventions, guardrails, host registry).
- Planning a cookbook change before opening any file: Read those three first — the plan needs them (IP literals, auth-gate profile, platform purity).
