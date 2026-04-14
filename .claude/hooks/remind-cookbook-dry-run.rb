#!/usr/bin/env ruby
# frozen_string_literal: true

# PostToolUse hook: remind to test cookbook changes with dry-run after editing.

require "json"

data = JSON.parse($stdin.read)
path = data.dig("tool_input", "file_path").to_s

if path.include?("/cookbooks/") && path.end_with?(".rb")
  warn "Reminder: test cookbook changes with ./bin/mitamae local linux.rb --dry-run"
end
