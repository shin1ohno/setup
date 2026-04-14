#!/usr/bin/env ruby
# frozen_string_literal: true

# PostToolUse hook: warn if edited/written file does not end with a newline.

require "json"

data = JSON.parse($stdin.read)
file_path = data.dig("tool_input", "file_path").to_s

exit 0 if file_path.empty?

begin
  content = File.binread(file_path)
  exit 0 if content.empty?

  unless content.end_with?("\n")
    warn "ERROR: #{file_path} does not end with a newline. Add a trailing newline."
    exit 2
  end
rescue SystemCallError
  exit 0
end
