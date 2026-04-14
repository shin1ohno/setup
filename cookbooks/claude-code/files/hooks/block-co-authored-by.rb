#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: block git commit commands that include Co-Authored-By
# in the -m message or --trailer arguments only.

require "json"
require "shellwords"

data = JSON.parse($stdin.read)
cmd = data.dig("tool_input", "command").to_s

exit 0 unless cmd.include?("git commit")

# Extract -m message values and --trailer values from the command.
# Only check these for Co-Authored-By — ignore heredoc delimiters,
# variable names, and other parts of the command string.
begin
  args = Shellwords.shellwords(cmd)
rescue ArgumentError
  # If shellwords can't parse (e.g., unmatched quotes in heredoc),
  # fall back to simple substring check on the commit message portion.
  # Extract content between heredoc markers if present.
  if cmd =~ /<<[\s-]*'?(\w+)'?\n(.*?)\n\s*\1/m
    message_content = $2
    if message_content.downcase.include?("co-authored-by")
      warn "ERROR: Do not include Co-Authored-By in git commits."
      exit 2
    end
  end
  exit 0
end

args.each_with_index do |arg, i|
  next_val = args[i + 1]
  if (arg == "-m" || arg == "--message") && next_val
    if next_val.downcase.include?("co-authored-by")
      warn "ERROR: Do not include Co-Authored-By in git commits."
      exit 2
    end
  elsif arg == "--trailer" && next_val
    if next_val.downcase.include?("co-authored-by")
      warn "ERROR: Do not include Co-Authored-By in git commits."
      exit 2
    end
  elsif arg.start_with?("-m") && arg.length > 2
    # Handle -m"message" format (no space)
    msg = arg[2..]
    if msg.downcase.include?("co-authored-by")
      warn "ERROR: Do not include Co-Authored-By in git commits."
      exit 2
    end
  end
end
