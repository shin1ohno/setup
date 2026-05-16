#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: block `sudo mitamae` invocations that lack --dry-run.
require "json"
data = JSON.parse($stdin.read)
cmd = data.dig("tool_input", "command").to_s
exit 0 if cmd.strip.start_with?("git ")
parts = cmd.split(/\s*(?:&&|\|\||;|\|)\s*/)
def sudo_mitamae_invocation?(part)
  tokens = part.split(/\s+/)
  i = 0
  while i < tokens.size && tokens[i].match?(/\A\w+=\S*\z/)
    i += 1
  end
  return false unless i < tokens.size && tokens[i] == "sudo"
  i += 1
  while i < tokens.size && (tokens[i].start_with?("-") || tokens[i].match?(/\A\w+=\S*\z/))
    if %w[-u -g -p -C].include?(tokens[i])
      i += 2
    else
      i += 1
    end
  end
  return false if i >= tokens.size
  argv0 = tokens[i]
  argv0 == "mitamae" || argv0.end_with?("/mitamae")
end
parts.each do |part|
  stripped = part.strip
  next unless sudo_mitamae_invocation?(stripped)
  unless stripped.include?("--dry-run")
    warn "ERROR: `sudo mitamae` without --dry-run is blocked. " \
         "Add --dry-run, or drop `sudo` if the cookbook elevates per-resource."
    exit 2
  end
end
