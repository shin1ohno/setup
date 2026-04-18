# Project Overview: Setup - Mitamae-based Infrastructure Automation System

## Purpose
This is a comprehensive infrastructure automation system designed to set up and configure development environments on macOS (Darwin) and Linux systems. It uses **mitamae**, a Ruby-based configuration management tool similar to Chef/Ansible, to automate the installation and configuration of development tools, programming languages, and system settings.

## Key Features
- **Cross-platform support**: Separate configurations for macOS (`darwin.rb`) and Linux (`linux.rb`)
- **Modular architecture**: Organized into roles and cookbooks for maintainability
- **Idempotent execution**: Uses conditional checks to prevent redundant operations
- **User-specific customization**: Supports user-level configurations and managed projects

## Main Components

### Entry Points
- `darwin.rb` - macOS setup configuration
- `linux.rb` - Linux setup configuration
- `bin/setup` - Downloads and installs mitamae binary with platform-specific SHA verification

### Directory Structure
```
setup/
├── bin/                   # Executable scripts
│   └── setup             # Mitamae installer
├── roles/                # High-level functional groupings
│   ├── core/            # Essential CLI tools
│   ├── programming/     # Programming languages
│   ├── llm/            # LLM tools (Claude Code, Ollama, etc.)
│   ├── network/        # Network tools
│   ├── extras/         # Specialized development tools
│   ├── manage/         # Managed projects setup
│   └── server/         # Server-specific setup (Linux only)
├── cookbooks/           # Individual tool/service configurations
│   ├── functions/      # Helper methods for all recipes
│   └── [tool-name]/    # Specific tool installations
└── templates/          # Configuration file templates
```

## Technical Stack
- **Language**: Ruby (with frozen_string_literal pragma)
- **Configuration Management**: Mitamae v1.14.0
- **Code Quality**: RuboCop with Rails/Performance/Minitest plugins
- **Platform Detection**: Dynamic platform and architecture detection
- **Package Managers**: 
  - macOS: Homebrew (with architecture-aware prefix)
  - Linux: System package managers (apt, yum, pacman)

## User Configuration
- Setup root: `~/.setup_shin1ohno/`
- Profile scripts: `~/.setup_shin1ohno/profile.d/`
- Binary directory: `~/.setup_shin1ohno/bin/`