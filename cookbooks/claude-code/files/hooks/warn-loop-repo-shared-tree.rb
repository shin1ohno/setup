#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse (Bash) hook — soft, non-blocking reminder.
#
# When a git mutation (add / commit / checkout / cherry-pick / stash) runs in a
# repository KNOWN to share its working tree with an autonomous loop (the
# loop-repos registry at ~/.claude/loop-repos.json), and the working path is NOT
# a worktree checkout (under .claude/worktrees/ or a *-wt directory), emit a
# reminder to work in a worktree instead of the shared tree. See
# rules/git-commit.md "Re-check after any long-running background operation".
#
# WARN-ONLY: it never blocks and never raises — any failure prints nothing and
# exits 0. It only *reminds*; it does not deny the tool call.

require "json"

# Emit a non-blocking PreToolUse reminder (additionalContext), then exit 0.
def emit(msg)
  puts JSON.generate(
    "hookSpecificOutput" => {
      "hookEventName"     => "PreToolUse",
      "additionalContext" => msg,
    },
  )
end

begin
  data    = JSON.parse($stdin.read)
  command = data.dig("tool_input", "command").to_s
  exit 0 if command.empty?

  # React only to a git mutation subcommand (add/commit/checkout/cherry-pick/stash).
  exit 0 unless command =~ /\bgit\b/
  exit 0 unless command =~ /\bgit\b[^\n;|&]*\b(?:add|commit|checkout|cherry-pick|stash)\b/

  # Resolve the target repo path: an explicit `git -C <path>`, else the cwd.
  target =
    if command =~ /(?:^|\s)-C[=\s]+(?:"([^"]+)"|'([^']+)'|(\S+))/
      Regexp.last_match(1) || Regexp.last_match(2) || Regexp.last_match(3)
    else
      (data["cwd"] || Dir.pwd).to_s
    end
  target = File.expand_path(target.to_s)

  # Worktree checkouts are the DESIRED state — never warn on them.
  exit 0 if target.include?("/.claude/worktrees/")
  exit 0 if target =~ %r{(^|/)[^/]*-wt(/|$)}

  # Load the loop-repo registry: {"repos": [<path>, ...]} or a bare [<path>, ...].
  # Absent / unparseable -> silent (fail-safe). LOOP_REPOS_FILE is a test seam.
  registry_path = ENV["LOOP_REPOS_FILE"] || File.join(Dir.home, ".claude", "loop-repos.json")
  exit 0 unless File.exist?(registry_path)

  registry = JSON.parse(File.read(registry_path))
  repos = registry.is_a?(Hash) ? registry["repos"] : registry
  exit 0 unless repos.is_a?(Array)

  loop_root = repos
              .map { |p| File.expand_path(p.to_s) }
              .find { |root| target == root || target.start_with?("#{root}/") }
  exit 0 if loop_root.nil?

  emit(
    "WARNING: this git mutation targets #{loop_root}, a repo that shares its " \
    "working tree with an autonomous loop (loop-repos.json). git add/commit/" \
    "checkout/cherry-pick/stash on the shared tree can collide with the loop. " \
    "Per rules/git-commit.md, work in a worktree instead — prefer EnterWorktree " \
    "(repo-internal .claude/worktrees/). Soft reminder; the command is NOT blocked.",
  )
rescue StandardError
  # fail-safe: never disturb the tool call
end

exit 0
