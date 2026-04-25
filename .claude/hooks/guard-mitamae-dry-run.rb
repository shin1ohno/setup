#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: block mitamae binary invocations that lack --dry-run.
#
# Match condition: a part of the command (split on && / ; / | ) actually
# *invokes* the mitamae binary — i.e. starts with `./bin/mitamae`, `bin/mitamae`,
# `mitamae`, or `MISE_*=... ./bin/mitamae`-style env-prefixed forms. References
# to the string "mitamae" in filenames (e.g. /tmp/mitamae-dryrun.log) or in grep
# patterns must NOT trigger the gate, since they are not invocations.

require "json"

data = JSON.parse($stdin.read)
cmd = data.dig("tool_input", "command").to_s

# Skip git commands entirely — mitamae in commit messages is not a real invocation
exit 0 if cmd.strip.start_with?("git ")

# Split on && / ; / | to handle chained / piped commands. Each part is treated
# independently — the dry-run requirement applies to the part that actually
# launches mitamae, not to neighbors that merely reference the name.
parts = cmd.split(/\s*(?:&&|\|\||;|\|)\s*/)

# Recognize an actual mitamae invocation: the binary appears as a tokenized
# argv[0] (optionally preceded by ENV=value pairs and `sudo`/`env` wrappers).
# Path forms accepted: bare `mitamae`, `./bin/mitamae`, `bin/mitamae`, or any
# absolute path ending in `/mitamae`. Excludes mentions where mitamae appears
# only inside a longer token like `/tmp/mitamae-dryrun.log` or as a grep
# argument — those have other characters between `mitamae` and the next
# whitespace.
def mitamae_invocation?(part)
  tokens = part.split(/\s+/)
  i = 0
  # Skip leading env assignments (FOO=bar) and optional sudo/env wrappers.
  while i < tokens.size && tokens[i].match?(/\A\w+=\S*\z/)
    i += 1
  end
  if i < tokens.size && (tokens[i] == "sudo" || tokens[i] == "env")
    i += 1
    while i < tokens.size && tokens[i].match?(/\A\w+=\S*\z/)
      i += 1
    end
  end
  return false if i >= tokens.size
  # The argv[0] after wrappers must be exactly the mitamae binary.
  argv0 = tokens[i]
  argv0 == "mitamae" || argv0.end_with?("/mitamae")
end

parts.each do |part|
  stripped = part.strip
  next unless mitamae_invocation?(stripped)

  unless stripped.include?("--dry-run")
    warn "ERROR: mitamae without --dry-run is blocked. Add --dry-run flag."
    exit 2
  end
end
