#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: block git commit commands that include Co-Authored-By
# in the -m message, --trailer, or -F/--file message-file arguments only.
#
# Residual hole: `git commit -F -` reads the message from stdin, which is not
# visible in argv, so this hook cannot inspect it. The behavioural rule in
# CLAUDE.md ("Co-Authored-By トレーラーは付けない") is the enforcement there.
# The -F <path> case below was added after a 2026-09-16 audit found that the
# `-F` route — the one CLAUDE.md now recommends for messages containing glob
# characters — passed unchecked.

require "json"
require "shellwords"

MAX_MESSAGE_FILE_BYTES = 256 * 1024

# Read a -F/--file commit-message file and block if it carries the trailer.
# "-" means stdin, which argv cannot show us; anything unreadable or oversized
# is left to git itself rather than guessed at.
def check_message_file(path)
  return if path.nil? || path.empty? || path == "-"
  return unless File.file?(path) && File.readable?(path)
  return if File.size(path) > MAX_MESSAGE_FILE_BYTES

  body = File.read(path)
  return unless body.downcase.include?("co-authored-by")

  warn "ERROR: Do not include Co-Authored-By in git commits (found in #{path})."
  exit 2
rescue SystemCallError, IOError
  # A hook must never break the commit path over its own read error.
  nil
end

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
  elsif (arg == "-F" || arg == "--file") && next_val
    check_message_file(next_val)
  elsif arg.start_with?("-F") && arg.length > 2
    # Handle -F<path> format (no space)
    check_message_file(arg[2..])
  end
end
