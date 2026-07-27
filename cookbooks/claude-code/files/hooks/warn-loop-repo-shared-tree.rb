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

  # Resolve target repo paths. A compound command can address several repos
  # (`git -C /a add … && git -C /b commit …`, or `cd /a && git add …`), and the
  # old first-`-C`-only resolution mislabelled the warning with the cwd repo
  # when the real target was elsewhere — which trained the reader to dismiss it
  # (2026-07-08: 11 dismissals on "name mismatch", then HEAD switched twice).
  # Collect EVERY `git -C <path>` and every `cd <path>`; drop unresolvable
  # shell-variable paths ("$VAR"); fall back to cwd when nothing resolvable
  # remains (covers both plain `git add …` and `git -C "$VAR" …`).
  targets = []
  command.scan(/\bgit\b[^\n;|&]*?\s-C[=\s]+(?:"([^"]+)"|'([^']+)'|(\S+))/) do |dq, sq, bare|
    targets << (dq || sq || bare)
  end
  command.scan(/(?:^|[\s;|&])cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;|&]+))/) do |dq, sq, bare|
    targets << (dq || sq || bare)
  end
  targets = targets.compact.reject { |p| p.include?("$") || p.include?("`") }
  targets << (data["cwd"] || Dir.pwd).to_s if targets.empty?
  targets = targets.map { |p| File.expand_path(p.to_s) }

  # Worktree checkouts are the DESIRED state — never warn on them.
  targets = targets.reject do |t|
    t.include?("/.claude/worktrees/") || t =~ %r{(^|/)[^/]*-wt(/|$)}
  end
  exit 0 if targets.empty?

  # Load the loop-repo registry: {"repos": [<path>, ...]} or a bare [<path>, ...].
  # Absent / unparseable -> silent (fail-safe). LOOP_REPOS_FILE is a test seam.
  registry_path = ENV["LOOP_REPOS_FILE"] || File.join(Dir.home, ".claude", "loop-repos.json")
  exit 0 unless File.exist?(registry_path)

  registry = JSON.parse(File.read(registry_path))
  repos = registry.is_a?(Hash) ? registry["repos"] : registry
  exit 0 unless repos.is_a?(Array)

  roots = repos.map { |p| File.expand_path(p.to_s) }
  loop_root = targets.filter_map { |t| roots.find { |root| t == root || t.start_with?("#{root}/") } }.first
  exit 0 if loop_root.nil?

  emit(
    "WARNING: this git mutation targets #{loop_root}, a repo that shares its " \
    "working tree with an autonomous loop (loop-repos.json). git add/commit/" \
    "checkout/cherry-pick/stash on the shared tree can collide with the loop. " \
    "Per rules/git-commit.md, work in a worktree instead — prefer EnterWorktree " \
    "(repo-internal .claude/worktrees/). If the repo name above differs from " \
    "the repo you think you are operating on, that mismatch is NOT grounds to " \
    "dismiss this warning — check the target repo's own registration in " \
    "~/.claude/loop-repos.json before deciding. Soft reminder; the command is " \
    "NOT blocked.",
  )
rescue StandardError
  # fail-safe: never disturb the tool call
end

exit 0
