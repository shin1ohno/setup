#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse (Bash) hook: run project tests before git commit, and block the
# commit (exit 2, the tail of the test output on stderr) when they fail.
#
# Every git commit in the command is found by git-command.rb, not only a
# command that starts with "git commit": `git -C <dir> commit`, chains such as
# `test -d X && git -C X add -A && git -C X commit -F msg`, `cd X && git
# commit`, wrappers (env / command / timeout, sudo -iu USER, xargs / mise exec
# -- / flock ...) and shell scripts: `bash -c '...'`, su / runuser -c or a
# heredoc, `sudo -s <<EOF`, `script -qc`, a shell started by any other
# command (`flock L bash -c`, `xargs sh -c`, `find -exec sh -c`), and su /
# sudo / runuser / script behind such a command (`flock L su root -c`,
# `setsid -w su root <<EOF`, `xargs sudo -iu U git ...`); a pipe, || or &&
# split across lines is read as one command, and a for loop over several
# static directories (`for d in A B; do git -C "$d" commit ...; done`)
# commits in, and tests, each of them. Project
# detection and the test command run in each distinct directory a commit
# targets: its work tree when --work-tree or GIT_WORK_TREE names one,
# otherwise its effective directory (cwd, then `cd`, then -C, with variables
# the command sets substituted: `R=/x; git -C "$R"`, plus $HOME / $PWD /
# environment variables, $(pwd), and `cd "$(git rev-parse --show-toplevel)"` /
# `git -C "$(git rev-parse --show-toplevel)"`, which resolve to the nearest
# ancestor holding .git; `su - USER` / `sudo -i` start in USER's home), so a
# commit into another checkout runs that checkout's tests rather than the
# session cwd's.
#
# A convenience check, so it acts only on what the parser is sure of: a
# certain invocation (GitCommand::Invocation#certain) with a definite
# directory (Invocation#dir). It never tests a directory the commit might not
# be in, so it skips (block-co-authored-by.rb, a safety check, checks these
# same commits instead):
#   - a commit whose directory is not static: `git -C "$REPO" commit` with
#     REPO set neither by the command nor in the environment, `cd
#     "$(mktemp -d)"`, `cd -`, rev-parse outside any repo, and a cd in an if /
#     case branch, a loop body or after `||` (`cd A 2>/dev/null || cd B; git
#     commit`), where the branches end in different directories; it tests
#     neither branch's directory, though Invocation#dir_candidates lists them;
#   - a --git-dir / GIT_DIR without a work tree (a bare or dotfiles repo,
#     which the cwd's project does not guard);
#   - a commit behind ssh / docker / pct ..., also inside a shell started
#     there, in ssh's remote command string (`ssh host 'cd X && git commit'`,
#     `ssh host <<EOF`) or behind a later ssh / docker word (`xargs -I{} ssh
#     {} ...`, `caffeinate -i ssh ...`, `stdbuf -oL docker exec ...`), none of
#     which is this host's directory;
#   - known limitation (TODO.md): an uncertain commit, found only inside a
#     nested command string that no explicit model covers. Commits through
#     unmodelled wrappers are not tested: `flock L -c '...'` / `--command`,
#     `sg G -c`, `watch '...'`, `parallel ::: '...'`, `tmux send-keys`, `trap
#     '...' EXIT`, `git rebase -x '...'` / `--exec='...'`, a shell script's
#     arguments, also when the string starts in a definite directory (`cd X
#     && flock L -c 'git commit ...'`). Whether such a string runs, and
#     where, is not knowable from the command; the modelled forms above
#     (`flock L bash -c`, `su -c`, ...) are tested.
# A commit only inside a snippet handed to a linter or highlighter
# (`shellcheck -s bash - <<EOF`, `bat -l sh`) is not a commit, and neither
# is one run by an interpreter's program (`python3 -c 'os.system(...)'`,
# `ruby -e`, `perl -e`, `node -e`: not shell, not parsed). A `function NAME
# { cd X; }` definition is skipped, so its cd does not move the directory a
# later commit is tested in (`function cleanup { cd X; }; trap cleanup EXIT;
# git commit` tests the cwd).
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

# The directory whose tests guard this commit, or nil to skip it (see the
# header: uncertain, not static, --git-dir without a work tree, remote).
def test_dir(inv)
  return nil unless inv.certain

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
    # Quick exit before parsing: a commit not spelled with the literal word
    # (`git com\mit`, `git "com"mit`, `git $'\x63ommit'`, an alias such as
    # `git ci`) is not checked.
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
