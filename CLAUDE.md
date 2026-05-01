# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

This is a **mitamae-based infrastructure automation system** for setting up development environments on macOS (Darwin) and Linux. Mitamae is a Ruby-based configuration management tool similar to Chef/Ansible.

## Scope

This repository configures:

- Linux hosts that run `linux.rb` (e.g. `pro`, `neo`, future hosts) — Ubuntu / Debian family
- macOS hosts that run `darwin.rb` (e.g. `air`, `ohnos-macbook`)

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
- The project hook `.claude/hooks/guard-mitamae-dry-run.rb` blocks `mitamae` without `--dry-run` for Claude. Apply runs are user-only — present them as `! ./bin/mitamae local <platform>.rb` for the user to run
- Use `run_command("command", error: false)` for status code checking
- Profile scripts are loaded from `~/.setup_shin1ohno/profile.d/` with priority ordering
- Linux includes Linux-only cookbooks directly in `linux.rb` (bluez, broadcom-wifi, zeroconf for hardware; edge-agent, roon-server, roon-mcp for services)
- macOS includes client-specific setup (mac-settings, mac-apps) directly in `darwin.rb`

