#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse hook: run project tests before git commit.

require "json"
require "open3"

data = JSON.parse($stdin.read)
command = data.dig("tool_input", "command").to_s

# Only intercept git commit commands
exit 0 unless command.strip.start_with?("git commit")

def has_npm_test?
  return false unless File.exist?("package.json")

  pkg = JSON.parse(File.read("package.json"))
  script = pkg.dig("scripts", "test").to_s
  !script.empty? && !script.include?("no test specified")
rescue JSON::ParserError, SystemCallError
  false
end

def has_make_target?(target)
  _, _, status = Open3.capture3("make", "-n", target)
  status.success?
end

# Project type detection: [marker file, guard, test command]
runners = [
  ["package.json", method(:has_npm_test?), "npm test"],
  ["Gemfile", -> { File.exist?("Rakefile") }, "bundle exec rake test"],
  ["Makefile", -> { has_make_target?("test") }, "make test"],
  ["Cargo.toml", -> { true }, "cargo test"],
  ["pyproject.toml", -> { true }, "python -m pytest"],
  ["go.mod", -> { true }, "go test ./..."],
]

runners.each do |marker, guard, test_cmd|
  next unless File.exist?(marker) && guard.call

  stdout, stderr, status = Open3.capture3(test_cmd)

  unless status.success?
    out = stdout.length > 500 ? stdout[-500..] : stdout
    err = stderr.length > 500 ? stderr[-500..] : stderr
    warn out unless out.empty?
    warn err unless err.empty?
    exit 2
  end

  break
end
