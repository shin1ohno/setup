#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse (Bash) hook: run project tests before git commit, and block the
# commit (exit 2, the tail of the test output on stderr) when they fail.
#
# Every git commit in the command is found by git-command.rb, not only a
# command that starts with "git commit": `git -C <dir> commit`, chains such as
# `test -d X && git -C X add -A && git -C X commit -F msg`, `cd X && git
# commit`, wrappers (env / command / timeout, xargs / mise exec -- / flock ...)
# and `bash -c '...'`. Project detection and the test command run in each
# distinct directory a commit targets: its work tree when --work-tree or
# GIT_WORK_TREE names one, otherwise its effective directory (cwd, then `cd`,
# then -C, with variables the command sets substituted: `R=/x; git -C "$R"`,
# plus $HOME / $PWD / environment variables, $(pwd), and `cd "$(git rev-parse
# --show-toplevel)"` / `git -C "$(git rev-parse --show-toplevel)"`, which
# resolve to the nearest ancestor holding .git), so a commit into another
# checkout runs that checkout's tests rather than the session cwd's. Skipped:
# a commit whose directory is not static (`git -C "$REPO" commit` with REPO set
# neither by the command nor in the environment, rev-parse outside any repo),
# a --git-dir / GIT_DIR without a work tree (a bare or dotfiles repo, which the
# cwd's project does not guard), and a commit behind ssh / docker / pct ...
# (not this host's directory).
#
# Fail-open: any internal error exits 0; only a failing test run exits 2.

require "json"
require "open3"

begin
  require_relative "git-command"
rescue LoadError
  exit 0
end

OUTPUT_TAIL_CHARS = 500

def has_npm_test?(dir)
  path = File.join(dir, "package.json")
  return false unless File.exist?(path)

  pkg = JSON.parse(File.read(path))
  script = pkg.dig("scripts", "test").to_s
  !script.empty? && !script.include?("no test specified")
rescue JSON::ParserError, SystemCallError
  false
end

def has_make_target?(dir, target)
  _, _, status = Open3.capture3("make", "-n", target, chdir: dir)
  status.success?
rescue SystemCallError
  false
end

# Project type detection: [marker file, guard, test command]
RUNNERS = [
  ["package.json", ->(dir) { has_npm_test?(dir) }, "npm test"],
  ["Gemfile", ->(dir) { File.exist?(File.join(dir, "Rakefile")) }, "bundle exec rake test"],
  ["Makefile", ->(dir) { has_make_target?(dir, "test") }, "make test"],
  ["Cargo.toml", ->(_dir) { true }, "cargo test"],
  ["pyproject.toml", ->(_dir) { true }, "python -m pytest"],
  ["go.mod", ->(_dir) { true }, "go test ./..."],
].freeze

def tail(text)
  text.length > OUTPUT_TAIL_CHARS ? text[-OUTPUT_TAIL_CHARS..] : text
end

def run_tests(dir)
  RUNNERS.each do |marker, guard, test_cmd|
    next unless File.exist?(File.join(dir, marker)) && guard.call(dir)

    stdout, stderr, status = Open3.capture3(test_cmd, chdir: dir)

    unless status.success?
      warn "pre-commit-test: `#{test_cmd}` failed in #{dir}"
      out = tail(stdout)
      err = tail(stderr)
      warn out unless out.empty?
      warn err unless err.empty?
      exit 2
    end

    break
  end
end

# The directory whose tests guard this commit, or nil to skip it.
def test_dir(inv)
  globals = inv.globals.map(&:first)
  env = inv.env || {}
  return inv.work_tree if globals.include?("--work-tree") || env.key?("GIT_WORK_TREE")
  return nil if globals.include?("--git-dir") || env.key?("GIT_DIR")

  inv.dir
end

dirs =
  begin
    data = JSON.parse($stdin.read)
    command = data.dig("tool_input", "command").to_s
    # Quick exit before parsing: no git commit can hide without the word.
    exit 0 unless command.include?("commit")

    cwd = data["cwd"].is_a?(String) && File.directory?(data["cwd"]) ? data["cwd"] : Dir.pwd
    GitCommand.parse(command, cwd: cwd).commits.map { |inv| test_dir(inv) }.compact.uniq
              .select { |d| File.directory?(d) }
  rescue StandardError, SystemStackError
    exit 0
  end

dirs.each do |dir|
  run_tests(dir)
rescue SystemCallError, IOError
  # The hook must never break the commit path over its own error.
  next
end

exit 0
