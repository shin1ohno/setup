#!/usr/bin/env ruby
# frozen_string_literal: true

# PostToolUse hook: warn if edited/written file contains lines with only whitespace.

require "json"

data = JSON.parse($stdin.read)
file_path = data.dig("tool_input", "file_path").to_s

exit 0 if file_path.empty?

SKIP_EXTENSIONS = %w[.png .jpg .jpeg .gif .ico .woff .woff2 .ttf .otf .pdf .zip .gz .tar .bin].freeze
exit 0 if SKIP_EXTENSIONS.include?(File.extname(file_path).downcase)

begin
  bad_lines = []
  File.foreach(file_path).with_index(1) do |line, lineno|
    stripped = line.chomp
    bad_lines << lineno if !stripped.empty? && stripped.strip.empty?
  end

  unless bad_lines.empty?
    shown = bad_lines.first(10).join(", ")
    suffix = bad_lines.size > 10 ? " (and #{bad_lines.size - 10} more)" : ""
    warn "WARNING: #{file_path} has whitespace-only lines at: #{shown}#{suffix}. Remove trailing whitespace."
    exit 2
  end
rescue SystemCallError, ArgumentError
  exit 0
end
