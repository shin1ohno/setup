# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

This is a **mitamae-based infrastructure automation system** for setting up development environments on macOS (Darwin) and Linux. Mitamae is a Ruby-based configuration management tool similar to Chef/Ansible.

### Core Structure

**Platform Entry Points:**

- `darwin.rb` - macOS setup configuration
- `linux.rb` - Linux setup configuration
- `bin/setup` - Downloads and installs mitamae binary with platform-specific SHA verification

**Modular Role System:**

- `roles/core/` - Essential CLI tools (git, zsh, fzf, ripgrep, etc.)
- `roles/programming/` - Programming languages (Ruby, Python, Node.js, Go, Rust, Haskell)
- `roles/llm/` - LLM tools (Claude Code, Ollama, MCP Hub)
- `roles/network/` - Network tools (mosh, speedtest-cli, rclone, iperf3)
- `roles/extras/` - Specialized development tools (terraform, neovim, docker)
- `roles/manage/` - Managed projects setup from JSON configuration

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

**Custom Helpers Available:**

- `include_role(name)` - Include role from roles/ directory
- `include_cookbook(name)` - Include cookbook from cookbooks/ directory
- `add_profile(name, bash_content:, priority:)` - Add shell profile script
- `install_package(darwin:, ubuntu:, arch:)` - Cross-platform package installation
- `git_clone(uri:, cwd:, user:)` - Git repository cloning

**Node Configuration Access:**

- `node[:setup][:root]` - Setup directory path (~/.setup_shin1ohno)
- `node[:setup][:user]` - Current user
- `node[:platform]` - Platform (darwin/ubuntu/arch)
- `node[:homebrew][:prefix]` - Homebrew installation path

## Important Notes

- Always test cookbook changes with `--dry-run` first
- Use `run_command("command", error: false)` for status code checking
- Profile scripts are loaded from `~/.setup_shin1ohno/profile.d/` with priority ordering
- Linux includes hardware-specific cookbooks directly (bluez, broadcom-wifi, etc.)
- macOS includes client-specific setup (mac-settings, mac-apps) directly in darwin.rb
