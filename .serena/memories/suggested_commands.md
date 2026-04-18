# Suggested Commands for Development

## Initial Setup Commands

### macOS
```bash
# 1. Install git (if not already installed)
git --version  # This will prompt to install Xcode Command Line Tools

# 2. Install Rosetta 2 (for Apple Silicon Macs)
softwareupdate --install-rosetta

# 3. Download mitamae
./bin/setup

# 4. Run full macOS setup
./bin/mitamae local darwin.rb

# 5. Dry run mode (preview changes without applying)
./bin/mitamae local darwin.rb --dry-run
```

### Linux
```bash
# 1. Download mitamae
./bin/setup

# 2. Run full Linux setup
./bin/mitamae local linux.rb

# 3. Dry run mode
./bin/mitamae local linux.rb --dry-run
```

## Development Commands

### Running Specific Roles
```bash
# Run only a specific role
./bin/mitamae local -e "include_role 'core'" darwin.rb
./bin/mitamae local -e "include_role 'programming'" darwin.rb
```

### Running Specific Cookbooks
```bash
# Run only a specific cookbook
./bin/mitamae local -e "include_cookbook 'git'" darwin.rb
./bin/mitamae local -e "include_cookbook 'ruby'" darwin.rb
```

## Testing and Validation

### Dry Run Mode
Always test changes with dry-run first:
```bash
./bin/mitamae local darwin.rb --dry-run
./bin/mitamae local linux.rb --dry-run
```

### Verbose Output
For debugging:
```bash
./bin/mitamae local darwin.rb --log-level=debug
```

## Git Commands
```bash
# Check current status
git status

# View changes
git diff

# Create commits (English commit messages)
git add .
git commit -m "component: concise description of change"

# View commit history
git log --oneline
```

## System Commands (Darwin)
```bash
# List files/directories
ls -la

# Find files
find . -name "*.rb"

# Search in files (using ripgrep if installed)
rg "pattern" 

# Check if command exists
which command_name

# Check file existence
test -f filepath
test -d directory
```

## Ruby/Mitamae Specific
```bash
# Check Ruby syntax
ruby -c file.rb

# Run RuboCop (if available)
rubocop file.rb

# Check mitamae version
./bin/mitamae --version
```

## Useful Aliases (after setup)
The setup creates various aliases in `~/.setup_shin1ohno/profile.d/`:
- Serena MCP commands: `serena-new`, `serena-continue`, `serena-help`
- Other tool-specific aliases defined in individual cookbooks