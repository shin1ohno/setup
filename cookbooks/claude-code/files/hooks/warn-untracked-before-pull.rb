#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse (Bash) hook — soft, non-blocking reminder.
#
# When a `git pull` / `git merge` is about to run against a repository whose
# working tree contains UNTRACKED files, list them as additionalContext. An
# untracked file that collides with an incoming merge fails the operation with
# "untracked working tree files would be overwritten by merge" — typically a
# sub-agent's smoke-test fixture or stub left inside the tracked tree (see
# rules/sub-agents.md "Sub-agent Scratch-File Discipline").
#
# WARN-ONLY: it never blocks and never raises — any failure prints nothing and
# exits 0. It only *reminds*; it does not deny the tool call.

require "json"
require "open3"

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

  # React only to pull / merge (the operations an untracked collision fails).
  exit 0 unless command =~ /\bgit\b[^\n;|&]*\b(?:pull|merge)\b/

  # Resolve the target repo path: an explicit `git -C <path>`, else the cwd.
  target =
    if command =~ /(?:^|\s)-C[=\s]+(?:"([^"]+)"|'([^']+)'|(\S+))/
      Regexp.last_match(1) || Regexp.last_match(2) || Regexp.last_match(3)
    else
      (data["cwd"] || Dir.pwd).to_s
    end
  target = File.expand_path(target.to_s)
  exit 0 unless File.directory?(target)

  out, status = Open3.capture2("git", "-C", target, "status", "--porcelain")
  exit 0 unless status.success?

  untracked = out.lines.select { |l| l.start_with?("?? ") }.map { |l| l[3..].to_s.strip }
  exit 0 if untracked.empty?

  shown = untracked.first(10)
  more  = untracked.size - shown.size
  listing = shown.join(", ") + (more.positive? ? " (+#{more} more)" : "")
  emit(
    "NOTE: #{target} has #{untracked.size} untracked file(s): #{listing}. " \
    "If the incoming merge ships any of these paths, git will abort with " \
    "'untracked working tree files would be overwritten by merge'. Stray " \
    "sub-agent fixtures belong in $TMPDIR/scratchpad (rules/sub-agents.md " \
    "Scratch-File Discipline) — inspect before pulling. Soft reminder; the " \
    "command is NOT blocked.",
  )
rescue StandardError
  # fail-safe: never disturb the tool call
end

exit 0
