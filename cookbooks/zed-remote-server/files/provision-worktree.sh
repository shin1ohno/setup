#!/usr/bin/env bash
# Zed create_worktree hook (invoked from ~/.config/zed/tasks.json).
#
# Args: $1 = main git worktree root, $2 = newly created worktree root.
# Zed substitutes $ZED_MAIN_GIT_WORKTREE / $ZED_WORKTREE_ROOT into the task
# args; the ${...:-$ZED_*} fallbacks also cover the case where Zed passes them
# as environment variables instead.
#
# Purpose: make a freshly created worktree immediately usable by a Parallel
# Agents thread (or a manual worktree) — carry over gitignored env files from
# the main checkout and trust the worktree's mise dev environment.
#
# Robustness contract: this MUST NOT block worktree creation. Every step is
# guarded and the script ALWAYS exits 0. mise is referenced by absolute path
# because a GUI-launched Zed has a stripped PATH (same reason the LSP binaries
# are pinned in settings.json). macOS-only cookbook, so bash / cp / command -v
# are all available.
set -u
main="${1:-${ZED_MAIN_GIT_WORKTREE:-}}"
new="${2:-${ZED_WORKTREE_ROOT:-}}"
[ -n "$new" ] && [ -d "$new" ] || exit 0

# Carry gitignored env files over from the main checkout. Never clobber a file
# that already exists in the new worktree (e.g. a committed sample).
for f in .env .env.local .envrc; do
  [ -n "$main" ] && [ -f "$main/$f" ] && [ ! -e "$new/$f" ] && cp "$main/$f" "$new/$f"
done

# Trust the worktree's mise config so `mise` does not prompt / skip it. No-op
# (swallowed) when the repo has no mise config.
mise="$HOME/.local/bin/mise"
[ -x "$mise" ] && ( cd "$new" && "$mise" trust >/dev/null 2>&1 || true )

# If an .envrc was carried over and direnv is installed, allow it. direnv is
# currently absent on the fleet; this branch is dormant until it is installed.
if [ -f "$new/.envrc" ] && command -v direnv >/dev/null 2>&1; then
  ( cd "$new" && direnv allow >/dev/null 2>&1 || true )
fi

exit 0
