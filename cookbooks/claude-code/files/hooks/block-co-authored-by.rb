#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: block git commit commands that include Co-Authored-By.

require "json"

data = JSON.parse($stdin.read)
cmd = data.dig("tool_input", "command").to_s

exit 0 unless cmd.include?("git commit")

if cmd.downcase.include?("co-authored-by")
  warn "ERROR: Do not include Co-Authored-By in git commits."
  exit 2
end
