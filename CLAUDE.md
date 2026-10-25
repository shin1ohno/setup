# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

This is a **mitamae-based infrastructure automation system** for setting up development environments on macOS (Darwin) and Linux. Mitamae is a Ruby-based configuration management tool similar to Chef/Ansible.

## Scope

This repository configures:

| Host type | Example | Entry recipe |
|---|---|---|
| Bare-metal Linux workstation | `pro` | `linux.rb` (refuses to apply inside any container — guarded by `systemd-detect-virt -c`; bypass with `MITAMAE_FORCE_BARE_METAL=1`) |
| Proxmox VE host | the host that runs the LXCs | `pve/pve-host.rb` |
| Developer workstation LXC | `pro-dev` (CT 104), future `*-dev` | `pve/lxc-pro-dev.rb` (delegates to the `lxc-dev-workstation` cookbook; future LXCs reuse the cookbook with their own `node[:lxc_dev][:*]` overrides) |
| Service LXC | `lxc-hydra`, `lxc-memory`, `lxc-monitoring`, `lxc-roon`, `lxc-roon-mcp`, `lxc-weave`, `lxc-samba`, `lxc-housekeeping`, `lxc-consent`, `lxc-pro-router`, `lxc-es-0/1/2` (Elasticsearch cluster), `lxc-kibana`, `lxc-apm-server` | matching `pve/lxc-<service>.rb` (apply all in parallel via `bin/apply-pve-lxcs`) |
| macOS | `air`, `ohnos-macbook` | `darwin.rb` |

`linux.rb` is bare-metal-only. MCP servers (ai-memory, hydra, hydra-consent), Roon Server / MCP, and the Elastic stack (Elasticsearch / Kibana / APM Server — see `docs/adr/0005-rtx-logs-loki-to-elasticsearch.md`) have all migrated to dedicated LXCs and are NOT installed on bare-metal pro.

This repository does NOT configure:

- AWS-managed EC2 (Amazon Linux 2023, `nrt-subnet-router`) — see `~/ManagedProjects/home-monitor/scripts/tailscale-setup/`
- Physical network devices (YAMAHA RTX) — see `~/ManagedProjects/home-monitor/`

**Decision rule** for new fixes: when the root cause reproduces across multiple Linux / macOS hosts (even if discovered on one specific host), the fix belongs here. The Cross-OS Scope Gate rule in `~/ManagedProjects/setup/.claude/rules/infrastructure-cookbook.md` covers the inverse case (don't drop OS-specific Ubuntu fixes into a cookbook that also runs on AL2023).

### Core Structure

**Platform Entry Points:**

- `darwin.rb` - macOS setup configuration
- `linux.rb` - Linux setup configuration
- `bin/setup` - Downloads and installs mitamae binary with platform-specific SHA verification

**Modular Role System:**

- `roles/core/` - Essential CLI tools (git, zsh, fzf, ripgrep, etc.)
- `roles/programming/` - Programming languages (Ruby, Python, Node.js, Go, Rust, Haskell)
- `roles/llm/` - LLM tools (MCP servers, Claude Code, Gemini CLI, Codex CLI, Ollama, Serena, etc.)
- `roles/network/` - Network tools (mosh, speedtest-cli, rclone, iperf3)
- `roles/extras/` - Specialized development tools (terraform, neovim, docker)
- `roles/manage/` - Managed projects setup from JSON configuration
- `roles/server/` - Server-specific setup (Linux only, deploy directory)
- `roles/lxc-core/` - Shared base for every `pve/lxc-*.rb` + `pve-host.rb`: bundles `node-exporter` (Prometheus scrape on :9100) + `auto-mitamae-target` (forced-command authorized_keys for orchestrator-pushed mitamae apply)

**Implementation Pattern:**

- Platform files include modular roles + platform-specific cookbooks
- Each role includes multiple cookbooks
- Cookbooks handle individual tool installation/configuration
- `cookbooks/functions/default.rb` provides helper methods for all recipes

### Key Commands

**Initial Setup:**

```bash
# macOS
./bin/setup                    # Download mitamae
./bin/mitamae local darwin.rb  # Run full macOS setup

# Linux (bare-metal)
./bin/setup                    # Download mitamae
./bin/mitamae local linux.rb   # Run full Linux setup
```

`cookbooks/mac-sudo` ships a `Defaults:<user> timestamp_type=global, timestamp_timeout=60` drop-in (60-min credential cache shared across all of the user's processes), so a full darwin apply prompts for sudo at most once — Touch ID (pam_tid) turns that one prompt into a fingerprint tap.

**Development/Testing:**

```bash
# Dry run mode
./bin/mitamae local darwin.rb --dry-run
```

**Fleet Operations (PVE LXCs):**

```bash
./bin/apply-pve-lxcs              # Apply all pve/lxc-*.rb recipes in parallel
./bin/bootstrap-lxc-creds <CT>    # Seed AWS profile into a fresh LXC before first mitamae apply
```

Auto-mitamae: `cookbooks/auto-mitamae-target` installs a systemd timer on each LXC; `cookbooks/auto-mitamae-orchestrator` drives periodic apply across the fleet.

## Claude Code Hooks

- Hook scripts in `cookbooks/claude-code/files/hooks/` must be written in Ruby

## Important Notes

- Always test cookbook changes with `--dry-run` first
- Project hooks in `.claude/hooks/`: `guard-mitamae-dry-run.rb` blocks **`sudo mitamae`** without `--dry-run` for Claude. Bare `./bin/mitamae local <recipe>.rb` (no outer sudo) is allowed even without `--dry-run` — cookbooks elevate per-resource via `execute "sudo ..."`, which still hits the user's sudo prompt for each privileged step. Add `--dry-run` whenever the apply must NOT be allowed to actually run, even without sudo. `remind-cookbook-dry-run.rb` reminds Claude to run dry-run after cookbook edits
- **sudo context by host type**: `cookbooks/` resources use `execute "sudo install …"` for system paths and `mitamae runs without sudo` per `~/ManagedProjects/setup/.claude/rules/ruby.md` — but this rule applies to the OUTER mitamae invocation differently per host:
  - **Bare-metal Linux + macOS** (`pro`, `air`, `ohnos-macbook`): run `./bin/mitamae local <platform>.rb` as the regular user. Do NOT prepend `sudo` — it changes `$HOME` to `/root` and breaks rbenv/mise/pyenv PATH resolution (recipes that compute paths from `ENV["HOME"]` end up with `/root/.rbenv` etc., then later resources try to write there as the regular user and fail)
  - **Service LXCs** (`pve/lxc-*.rb`): the LXC's only user IS root. Run `./bin/mitamae local pve/lxc-<name>.rb` from inside the CT — no sudo prefix needed (already root)
  - When presenting apply commands as `!` to the user, infer host type from the recipe path: `pve/lxc-*.rb` → no sudo, anything else → no sudo. The rare exception is `pve/pve-host.rb` which runs on the bare-metal PVE host as root anyway. The recipe path is the reliable signal — never default to `sudo` "to be safe"
  - This rule exists because the 2026-05-09 retro session's `sudo ./bin/mitamae local pve/lxc-pro-dev.rb` invocation (added "to be safe") confused rbenv path resolution and required diagnosing the recipe failure before realising sudo was the cause
- Use `run_command("command", error: false)` for status code checking
- Profile scripts are loaded from `~/.setup_shin1ohno/profile.d/` with priority ordering
- Linux includes hardware-coupled cookbooks directly in `linux.rb` (bluez, broadcom-wifi, zeroconf, edge-agent). Roon Server / MCP and the rest of the MCP server stack run in dedicated LXCs and are no longer pulled into `linux.rb`
- macOS includes client-specific setup (mac-settings, mac-apps) directly in `darwin.rb`

## Project rules — what loads when

- Always loaded: `.claude/rules/shell.md` (Bash usage in this repo) and `.claude/rules/infrastructure.md` (ops rules: managed-file ownership, incident first response, blocked commands, the auto-mode classifier boundary, systemd timer verification).
- Loaded when you Read/Edit a file under `cookbooks/`, `roles/`, `pve/`, `bin/`, `config/` or a top-level `*.rb`: `.claude/rules/ruby.md` (mitamae / mruby), `.claude/rules/infrastructure-cookbook.md` (blast radius, merge semantics, cross-OS gate, canary, …) and `.claude/rules/cookbook-conventions.md` (helpers, conventions, guardrails, host registry).
- Planning a cookbook change before opening any file: Read those three first — the plan needs them (IP literals, auth-gate profile, platform purity).
