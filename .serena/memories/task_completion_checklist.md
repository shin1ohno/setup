# Task Completion Checklist

## Before Committing Changes

### 1. Code Quality Checks
- [ ] Verify Ruby syntax: `ruby -c modified_file.rb`
- [ ] Run dry-run to test changes: `./bin/mitamae local darwin.rb --dry-run`
- [ ] Ensure all files end with a newline character
- [ ] Check that frozen_string_literal pragma is present in Ruby files

### 2. Idempotency Verification
- [ ] Confirm all execute blocks have appropriate guards (`not_if`, `only_if`)
- [ ] Verify package installations check for existing installations
- [ ] Ensure file operations won't fail on repeated runs

### 3. Cross-Platform Compatibility
- [ ] Test or review changes for both macOS and Linux compatibility
- [ ] Use platform conditionals where behavior differs
- [ ] Verify paths work on both platforms

### 4. File Permissions and Ownership
- [ ] All created files have explicit owner, group, and mode
- [ ] Executable scripts have mode "755"
- [ ] Configuration files have mode "644"

### 5. Testing Procedure
1. Run dry-run mode first:
   ```bash
   ./bin/mitamae local darwin.rb --dry-run
   ```

2. Review output for unexpected changes

3. Run actual execution:
   ```bash
   ./bin/mitamae local darwin.rb
   ```

4. Verify the installed tool/configuration works as expected

5. Run again to ensure idempotency (should show no changes)

### 6. Documentation Updates
- [ ] Update inline comments if adding complex logic
- [ ] Ensure cookbook has a descriptive header comment
- [ ] Update README.md if adding new major functionality

### 7. Git Commit Guidelines
- Use English for commit messages
- Format: `component: verb description`
- Examples:
  - `git: add configuration for git-lfs`
  - `roles/core: include new terminal enhancement tools`
  - `cookbooks/serena: fix MCP server configuration`

## Common Issues to Check

1. **Homebrew prefix**: Ensure using `node[:homebrew][:prefix]` for paths
2. **User vs root**: Linux packages need `user "root"`, macOS doesn't
3. **Path existence**: Always verify parent directories exist before creating files
4. **Command availability**: Check if commands exist before using them in scripts
5. **Shell compatibility**: Ensure bash scripts work with both bash and zsh

## Post-Implementation Verification
- [ ] Tool is accessible from command line
- [ ] Profile scripts are loaded (may need new shell)
- [ ] No errors in system logs
- [ ] Dependencies are properly installed