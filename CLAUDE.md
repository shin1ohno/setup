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
| Service LXC | `lxc-cognee`, `lxc-hydra`, `lxc-memory`, `lxc-monitoring`, `lxc-roon`, `lxc-roon-mcp`, `lxc-weave`, `lxc-samba`, `lxc-housekeeping`, `lxc-consent`, `lxc-pro-router` | matching `pve/lxc-<service>.rb` (apply all in parallel via `bin/apply-pve-lxcs`) |
| macOS | `air`, `ohnos-macbook` | `darwin.rb` |

`linux.rb` is bare-metal-only. MCP servers (cognee, ai-memory, hydra, hydra-consent) and Roon Server / MCP have migrated to dedicated LXCs and are NOT installed on bare-metal pro.

This repository does NOT configure:

- AWS-managed EC2 (Amazon Linux 2023, `nrt-subnet-router`) — see `~/ManagedProjects/home-monitor/scripts/tailscale-setup/`
- Physical network devices (YAMAHA RTX) — see `~/ManagedProjects/home-monitor/`

**Decision rule** for new fixes: when the root cause reproduces across multiple Linux / macOS hosts (even if discovered on one specific host), the fix belongs here. The Cross-OS Scope Gate rule in `~/.claude/rules/infrastructure.md` covers the inverse case (don't drop OS-specific Ubuntu fixes into a cookbook that also runs on AL2023).

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
- `roles/mcp-server/` - Self-hosted MCP servers (Linux only)

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

# Linux
./bin/setup                    # Download mitamae
./bin/mitamae local linux.rb   # Run full Linux setup
```

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

## Development Patterns

**Adding New Tools:**

1. Create cookbook in `cookbooks/[tool-name]/default.rb`
2. Add to appropriate role in `roles/[role-name]/default.rb`
3. Use conditional checks (`not_if`, `only_if`) to prevent redundant execution

**Cookbook Best Practices:**

- Use `not_if "which [command]"` or `test -f [file]` for installation checks
- Use `add_profile` helper for shell environment setup
- Platform-specific logic: `if node[:platform] == "darwin"`
- Always include user/group/mode for file operations
- **External URLs**: Verify external resources (GitHub releases, Homebrew packages, URLs) with `curl -sI` before commit. Dry-run does not fetch external resources — it is not evidence that a URL exists

**Custom Helpers Available** (defined in `cookbooks/functions/default.rb`):

- `include_role(name)` / `include_cookbook(name)` - Include from `roles/` or `cookbooks/`
- `require_external_auth(tool_name:, check_command:, instructions:, skip_if:)` - Gate cookbook on external auth (SSM, gh, etc.); skips in non-TTY contexts
- `prepend_path(*dirs)` - Prepend dirs to PATH for the current recipe run
- `brew_formula?(name)` / `brew_cask?(name)` / `brew_tap?(name)` - Cached lookup against `brew list/tap` (cache populated by `cookbooks/homebrew`)

**Node Configuration Access:**

- `node[:setup][:root]` - Setup directory path (~/.setup_shin1ohno)
- `node[:setup][:user]` - Current user
- `node[:platform]` - Platform (darwin/ubuntu/arch)
- `node[:homebrew][:prefix]` - Homebrew installation path

## Claude Code Hooks

- Hook scripts in `cookbooks/claude-code/files/hooks/` must be written in Ruby

## Important Notes

- Always test cookbook changes with `--dry-run` first
- Project hooks in `.claude/hooks/`: `guard-mitamae-dry-run.rb` blocks `mitamae` without `--dry-run` for Claude (apply runs are user-only — present them as `! ./bin/mitamae local <platform>.rb`); `remind-cookbook-dry-run.rb` reminds Claude to run dry-run after cookbook edits
- **sudo context by host type**: `cookbooks/` resources use `execute "sudo install …"` for system paths and `mitamae runs without sudo` per `~/.claude/rules/ruby.md` — but this rule applies to the OUTER mitamae invocation differently per host:
  - **Bare-metal Linux + macOS** (`pro`, `air`, `ohnos-macbook`): run `./bin/mitamae local <platform>.rb` as the regular user. Do NOT prepend `sudo` — it changes `$HOME` to `/root` and breaks rbenv/mise/pyenv PATH resolution (recipes that compute paths from `ENV["HOME"]` end up with `/root/.rbenv` etc., then later resources try to write there as the regular user and fail)
  - **Service LXCs** (`pve/lxc-*.rb`): the LXC's only user IS root. Run `./bin/mitamae local pve/lxc-<name>.rb` from inside the CT — no sudo prefix needed (already root)
  - When presenting apply commands as `!` to the user, infer host type from the recipe path: `pve/lxc-*.rb` → no sudo, anything else → no sudo. The rare exception is `pve/pve-host.rb` which runs on the bare-metal PVE host as root anyway. The recipe path is the reliable signal — never default to `sudo` "to be safe"
  - This rule exists because the 2026-05-09 retro session's `sudo ./bin/mitamae local pve/lxc-pro-dev.rb` invocation (added "to be safe") confused rbenv path resolution and required diagnosing the recipe failure before realising sudo was the cause
- Use `run_command("command", error: false)` for status code checking
- Profile scripts are loaded from `~/.setup_shin1ohno/profile.d/` with priority ordering
- Linux includes hardware-coupled cookbooks directly in `linux.rb` (bluez, broadcom-wifi, zeroconf, edge-agent). Roon Server / MCP and the rest of the MCP server stack run in dedicated LXCs and are no longer pulled into `linux.rb`
- macOS includes client-specific setup (mac-settings, mac-apps) directly in `darwin.rb`

## Cross-repo Host Registry (Phase A round-table 2026-05-07)

Host registry の canonical source は **AWS SSM Parameter `/host-registry/devices`**。実体は `~/ManagedProjects/home-monitor/contracts/devices.json` (git-managed、19 エントリ: 5 hosts + 12 LXCs + 2 iOS clients)、Terraform で SSM に push。setup cookbook と CI は SSM から fetch:

| Component | Role |
|---|---|
| `cookbooks/ssh-keys/files/aws-config.json` | Bootstrap minimal config (`aws_profile` + `aws_region` のみ、SSM 接続用) |
| `cookbooks/ssh-keys/default.rb` | `aws ssm get-parameter --name /host-registry/devices` で fetch、新ネスト型スキーマ (`d["ssh"]["ssm_prefix"]` 等) で参照 |
| `.github/workflows/test-setup.yml` `ssm-validation` job | GitHub OIDC role (`AWS_OIDC_ROLE_ARN` secret) で SSM fetch + jq sanity check |

4 cookbook (`auto-mitamae-orchestrator` / `auto-mitamae-target` / `cognee` / `lxc-monitoring`) は `aws-config.json` から `aws_profile` / `aws_region` のみ参照 (devices map に touch せず)。

新ホストの追加: `home-monitor/contracts/devices.json` に entry を追加 + `terraform apply` (`kind: lxc` なら `pve/lxc-<name>.rb` も追加)。setup repo の cookbook 修正は不要。

廃案 (Phase A round-table で却下): submodule 経由配送 (cross-VCS auth + protocol.codecommit.allow=always 運用負担)、第 3 リポ抽出 (privilege aggregation anti-pattern)、モノレポ化 (IAM 信頼境界破壊)。詳細: `docs/adr/0001-0004-*.md`。

