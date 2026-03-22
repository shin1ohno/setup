---
globs: ["*.sh", "*.zsh", "*.bash"]
---

# Shell Script Guidelines

- Always quote variables: `"$var"` not `$var`
- Use `set -euo pipefail` at the top of bash scripts
- Consider POSIX compatibility when the script may run on different shells
- Use `$()` for command substitution, not backticks
- Prefer `[[ ]]` over `[ ]` in bash/zsh scripts
