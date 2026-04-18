# Architecture Details

## Core Architecture Principles

### 1. Modular Design
The system uses a two-tier architecture:
- **Roles**: High-level functional groupings (e.g., core, programming, llm)
- **Cookbooks**: Individual tool/service configurations

This allows for:
- Selective installation of feature sets
- Easy addition/removal of tools
- Clear separation of concerns

### 2. Platform Abstraction
Platform differences are handled through:
- Separate entry points (`darwin.rb`, `linux.rb`)
- Platform detection in cookbooks
- Helper methods that abstract platform-specific commands

### 3. Configuration Management

#### Node Attributes
```ruby
node[:setup][:root]     # Base directory for setup files
node[:setup][:user]     # Current user
node[:setup][:group]    # User's primary group
node[:platform]         # "darwin", "ubuntu", or "arch"
node[:homebrew][:prefix] # Homebrew installation path
```

#### Helper Methods (from cookbooks/functions/default.rb)
- `include_role(name)`: Include a role from the roles directory
- `include_cookbook(name)`: Include a cookbook
- `install_package(darwin: [...], ubuntu: [...], arch: [...])`: Cross-platform package installation
- `add_profile(name, bash_content:, priority:)`: Add shell profile scripts
- `git_clone(name, uri:, cwd:, user:)`: Clone git repositories

### 4. Execution Flow

1. **Setup Phase**:
   - `bin/setup` downloads platform-specific mitamae binary
   - Verifies SHA256 checksum for security

2. **Configuration Phase**:
   - Platform-specific entry point loads `cookbooks/functions/default`
   - Sets up node attributes
   - Creates base directories

3. **Role Inclusion**:
   - Roles are included in order
   - Each role includes multiple cookbooks
   - Cookbooks execute their recipes

4. **Profile Loading**:
   - Shell profiles are created in `~/.setup_shin1ohno/profile.d/`
   - Loaded by priority (00-99)
   - Sourced by user's shell configuration

### 5. Special Considerations

#### Homebrew on Apple Silicon
The system detects ARM64 architecture and adjusts Homebrew prefix:
- Intel Macs: `/opt/brew`
- Apple Silicon: `/opt/homebrew`

#### Privilege Escalation
- macOS: Packages installed as current user
- Linux: Packages require `user "root"` in resource blocks

#### Idempotency
All operations use guards to ensure they can be run multiple times:
- `not_if`: Skip if condition is true
- `only_if`: Run only if condition is true
- File existence checks prevent redundant operations

### 6. Integration Points

#### Shell Integration
Profile scripts are sourced from `~/.setup_shin1ohno/profile.d/` and can:
- Set environment variables
- Define aliases and functions
- Configure tool-specific settings

#### Managed Projects
The `manage` role reads from JSON configuration to:
- Clone project repositories
- Set up project-specific environments
- Configure development tools per project

#### MCP (Model Context Protocol) Integration
Special support for Claude Code and Serena MCP servers:
- Automatic configuration of MCP servers
- Helper scripts for mode switching
- Context-aware tool filtering