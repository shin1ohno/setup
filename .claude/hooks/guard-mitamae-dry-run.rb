#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: block mitamae commands that lack --dry-run.
# Only checks the executable portion of the command, ignoring git commit messages.

require "json"

data = JSON.parse($stdin.read)
cmd = data.dig("tool_input", "command").to_s

# Skip git commands entirely — mitamae in commit messages is not a real invocation
exit 0 if cmd.strip.start_with?("git ")

# Split on && / ; to handle chained commands
parts = cmd.split(/\s*(?:&&|;)\s*/)

parts.each do |part|
  next unless part.include?("mitamae")

  unless part.include?("--dry-run")
    warn "ERROR: mitamae without --dry-run is blocked. Add --dry-run flag."
    exit 2
  end
end
