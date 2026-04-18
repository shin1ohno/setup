# Coding Conventions and Style Guide

## Ruby Style (Based on .rubocop.yml)

### General Principles
- **Ruby Version**: Target Ruby 2.7+
- **String Literals**: Use double quotes (`"string"`) for all strings
- **Frozen String Literal**: Always include `# frozen_string_literal: true` at the top of Ruby files
- **Indentation**: 2 spaces, no tabs
- **Line Length**: Keep lines reasonably short for readability
- **Hash Syntax**: Use Ruby 1.9+ syntax (`{ key: value }` not `{ :key => value }`)

### Code Structure
- No empty lines around class/module/method bodies
- Use `&&`/`||` over `and`/`or`
- Define methods with parentheses when they have parameters
- Use spaces around operators and after commas/colons/semicolons
- End files with a newline character

### Mitamae/Chef-specific Patterns

#### Resource Definitions
```ruby
# Package installation pattern
if node[:platform] == "darwin"
  package "package-name"
else
  package "package-name" do
    user "root"
  end
end

# Or use the helper:
install_package darwin: "brew-package", ubuntu: "apt-package", arch: "pacman-package"
```

#### Conditional Execution
```ruby
execute "command" do
  not_if "test -f /path/to/file"
  only_if "which command_name"
end
```

#### File Operations
```ruby
file "/path/to/file" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"  # Always specify as string
  content "file content"
end
```

### Helper Method Usage

#### Including Roles and Cookbooks
```ruby
include_role "role_name"
include_cookbook "cookbook_name"
```

#### Adding Profile Scripts
```ruby
add_profile "profile_name" do
  bash_content <<~BASH
    export VAR=value
    alias cmd='command'
  BASH
  priority 50  # Lower numbers load first
end
```

#### Git Clone Helper
```ruby
git_clone "repo_name" do
  uri "https://github.com/user/repo.git"
  cwd "/target/directory"
  user node[:setup][:user]
  not_if "test -d /target/directory/repo_name"
end
```

## File Organization

### Cookbook Structure
Each cookbook should follow this pattern:
```
cookbooks/tool-name/
├── default.rb      # Main recipe file
├── files/          # Static files to be copied
└── templates/      # ERB templates
```

### Recipe Best Practices
1. Check for command existence before installation
2. Use platform conditionals when behavior differs
3. Always specify owner/group/mode for files
4. Use `not_if` guards to ensure idempotency
5. Include descriptive comments for complex logic

### Naming Conventions
- Cookbook names: lowercase with hyphens (`mac-settings`)
- Role names: lowercase, single word (`core`, `programming`)
- Variable names: snake_case (`user_home`, `setup_root`)
- Profile script priorities: 00-99 (lower = higher priority)

## Error Handling
- Use `run_command("command", error: false)` for non-critical commands
- Check exit status when needed: `run_command(...).exit_status == 0`
- Log informative messages: `MItamae.logger.info "message"`
- Fail fast with clear error messages using `raise`