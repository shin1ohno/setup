#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse (Bash) hook: block a git commit whose message carries a
# Co-Authored-By trailer (matched case-insensitively).
#
# A safety check, so it fails closed on what the command shows: where the
# parser (git-command.rb) cannot tell where a commit runs or whether a string
# is a script, this hook still checks, against every possibility the command
# names. pre-commit-test.rb, a convenience, skips the same commits instead.
#
# Every git commit in the command is found by git-command.rb, not only a
# command containing the literal "git commit": `git -C <dir> commit`, chains
# such as `test -d X && git -C X add -A && git -C X commit -F msg`, global
# options (`git -c k=v commit`), wrappers (`env VAR=1 git commit`, `command git
# commit`, timeout / nice, sudo with its option clusters (-iu USER, -Hu), and
# any other command followed by `git ... commit`: xargs, mise exec --, flock,
# find -exec ...), `bash -c '...'` / `bash -s` / `bash <<EOF` scripts, also
# behind su / runuser (-c, or the shell reading a heredoc), `sudo -s` / `sudo
# -i` reading a heredoc, `script -qc`, and any other command whose later word
# starts a shell (`flock L bash -c`, `xargs sh -c`, `find -exec sh -c`, `ssh
# host bash -s <<EOF`) or is su / sudo / runuser / script (`flock L su - U
# -c`, `pct exec 104 -- su - U -c`, `setsid -w su U <<EOF`); ssh's remote
# command string, which the remote shell runs reading ssh's stdin (`ssh host
# 'bash -s' <<EOF`, `ssh pve "pct exec 104 -- bash -s" <<EOF`, `ssh host
# 'cd x && git commit ...'`, `ssh host <<EOF`); `NAME() { ...; }` and
# `function NAME { ...; }` bodies; a pipe or && split across lines; a for loop
# over several static items (each item is its own commit); and, uncertain,
# a commit inside any argv word of a non-data command that lexes as a script
# naming git commit (a nested command string): `flock L -c '...'`, `flock
# --command`, `sg G -c`, `watch '...'`, `parallel ::: '...'`, `tmux send-keys
# '...'`, `trap '...' EXIT`, `git rebase -x '...'`, a shell script's own
# arguments (`bash -c 'eval "$1"' _ '...'`), `osascript -e 'do shell script
# "..."'`, `python3 -c 'os.system("...")'` and any wrapper no table lists. Its
# message says when the commit was found in a nested command string. Data
# commands are not scanned (echo / printf / cat / tee, grep / rg, sed / awk,
# jq, gh / glab bodies, curl / wget, logger, git log / show / notes / grep, and
# in a wrapper's argv the words after such a command), so a documented
# example such as `gh pr create --body '... git commit ... Co-Authored-By
# ...'` passes. For each commit the message sources are checked:
#   -m / --message   separate, = and attached forms, and a short-option
#                    cluster such as -am "msg"; unique abbreviations (--mess)
#   --trailer        separate and = forms
#   -F / --file      read relative to the commit's effective directory (cwd,
#   -t / --template  then `cd` (also `cd "$(git rev-parse --show-toplevel)"`),
#                    then -C), MAX_MESSAGE_FILE_BYTES cap; a file that the
#                    same command writes first with literal output (`cat >
#                    msg <<'EOF'`, printf, echo, tee, a { ...; } / ( ... )
#                    group) is checked before it exists, and `cat src > msg`
#                    checks src; once the same command has truncated the file
#                    with literal output before the commit (`printf 'fix\n' >
#                    msg && git commit -F msg`, outside any if / || branch),
#                    the stale copy on disk is not checked. The path is expanded
#                    the way the parser keys those writes (GitCommand.path_key):
#                    $HOME, $PWD, $(pwd), environment variables such as
#                    $TMPDIR / $CLAUDE_PROJECT_DIR and ${NAME:-default}; a path
#                    that stays unresolved, such as F=$(mktemp), matches a
#                    write to the same text (`cat > "$F"` + `-F "$F"`). When
#                    the cwd is unknown, a relative path is checked under
#                    every directory the commit can be in
#                    (Invocation#dir_candidates: each branch of `cd A
#                    2>/dev/null || cd B`, if / else, case arms or a loop, and
#                    the entry directory), and against what the same command
#                    wrote under that same unknown cwd (`cd "$(mktemp -d)"`,
#                    `cd "$UNSET"`, `cd -`, a shell behind ssh / docker / pct:
#                    `ssh host bash -s <<EOF` + `cat > m <<MSG` +
#                    `git commit -F m`); a remote commit's relative file is on
#                    that host, so only those writes are checked, and so is a
#                    cwd with more than MAX_CANDIDATES possible directories
#                    (GitCommand::Evaluator, a parse-time bound reached only
#                    by stacking several `cd a || cd b` with relative targets)
#   -F <(...)        the substitution's literal output (also --file=<(...),
#                    -F<(...), and -F - < <(...))
#   -F - (and /dev/stdin, /dev/fd/0, /proc/self/fd/0)
#                    stdin, when the command itself shows it: a heredoc or
#                    here-string on the commit (`git commit -F - <<'EOF'`, any
#                    quotes inside the body; an unquoted `<<EOF` with the
#                    static variables the command set substituted; `<<<
#                    "$(cat f)"` reads f), `< file`, or the literal output on
#                    the left of a pipe: echo / printf / `cat <<EOF` / `cat
#                    file`, or a { ...; } / ( ... ) group of them (`{ echo fix;
#                    echo; echo "..."; } | git commit -F -`); with none of
#                    these, the stdin of the -c script or nested command
#                    string the commit is in (`bash -c 'git commit -F -'
#                    <<EOF`, `flock L -c 'git commit -F -' <<EOF`, `ssh host
#                    'git commit -F -' <<EOF`)
# A value may come through a variable the same command sets (MSG=...; export,
# declare, local, `read -d '' MSG <<'EOF'`, `printf -v`, `for M in ...`) and
# through a literal $(...): `-m "$(cat msg)"` and `-m "$(< msg)"` read that
# file (relative to the shell's cwd, as the substitution runs before -C). A
# variable reassigned in an if / case / loop / `||` branch is checked with the
# value it had before too, since the branch may not run. The source text of
# a $(...) / `...` is not the message: only its literal output is checked, so
# `MSG=$(git log -1 --format=%B | grep -v '^Co-Authored-By:')` + `git commit
# --amend -m "$MSG"` passes. A $NAME the parser cannot resolve still blocks
# when some command names NAME as an unquoted word or an assignment head
# (`mapfile -t NAME`, an assignment form it does not model; text inside
# another quoted string does not count) and the command carries the trailer.
# Input the parser cannot read (an unterminated quote) is checked as text:
# anything after `git ... commit` in that command segment that mentions the
# trailer blocks.
#
# Residual holes — values this hook cannot see in the command text; the
# CLAUDE.md rule ("Co-Authored-By トレーラーは付けない") is the enforcement there:
#   - run-time values: a message a program prints (`gen-msg | git commit -F
#     -`, `cat m | sed ... |`, `-m "$(gen-msg)"`, also `-m "$(gen | sed
#     's/$/ Co-Authored-By: x/')"`, `-F <(gen-msg)`), a for loop over a glob
#     or $(...), a message reused from an existing commit (-c / -C /
#     --reuse-message, --fixup=amend:), and a remote commit's file on that
#     host.
#   - files created or filled by programs the command does not show: `gen-msg
#     > "$F"`, `git interpret-trailers --in-place`, a copy made by `cp`, a
#     script file run by name (`bash x.sh`, `./x.sh`, `make`, `npm run`), git
#     hooks and templates.
#   - aliases and indirection outside the command: git aliases (`git ci`),
#     shell aliases and functions defined before this command, and a program
#     that assembles its own argv (`subprocess.run(["git", "commit", ...])`).
#   - word-splitting and spelling tricks: the hook exits before parsing
#     unless the command contains "commit", so `git com\mit`, `git "com"mit`
#     and `git $'\x63ommit'` pass; so does an unquoted $VAR that bash splits
#     into several words (`X="commit -m"; git $X "..."`).
#   - a script read from stdin by something that is not a shell taking it as
#     its script: a non-shell program (`python3 - <<EOF`, `newgrp G <<EOF`)
#     and a shell whose name directly follows an option, which is taken as
#     that option's value so `shellcheck -s bash - <<EOF` stays data
#     (`setsid -w bash <<EOF`, `unshare -r bash <<EOF`, `nsenter -t 1 -a sh
#     <<EOF`; their -c form is still parsed).
#   - scope: only the `commit` subcommand is checked; `git merge -m`, `git
#     tag -m` and `git commit-tree -m` pass.
# Conservative (fail closed): two unresolved paths with the same text (two
# `$(mktemp)` variables, two `cd "$X"`) share one key, so the trailer written
# into either one blocks a commit that reads the other; a nested command
# string is checked even when the program treats it as data (`linear ...
# --description "git commit -m '...Co-Authored-By...'"`, `claude -p "..."`,
# `ruby -e '...' "git commit ..."`); a commit behind ssh / docker ... reads an
# absolute message path from this host; ssh's command string the remote shell
# would reject (`ssh host git commit -m "x <a@b>"`, where `<a@b>` turns into a
# redirection) is checked as text; su / sudo after an option (`--become-method
# su <<EOF`) is still taken as su reading the heredoc; a for loop's body runs
# for every item (break / continue are not modeled).
# History: the -F <path> check came from a 2026-09-16 audit (the -F route,
# which CLAUDE.md recommends for messages with glob characters, passed
# unchecked); SH1-79 replaced the literal "git commit" match with the parser;
# SH1-86 made the unknown cwd and nested command strings fail closed.
#
# Fail-open on its own errors: any internal error exits 0; only a found
# trailer exits 2.

require "json"

begin
  require_relative "git-command"
rescue LoadError
  exit 0
end

MAX_MESSAGE_FILE_BYTES = 256 * 1024
TRAILER = "co-authored-by"
# -F / -t paths that are the hook's own stdin, not a file on disk.
STDIN_PATHS = %w[- /dev/stdin /dev/fd/0 /proc/self/fd/0].freeze

# git commit options that take a value, mapped to the message source they are
# (nil: takes a value that is not a message, so it must still be skipped).
SHORT_VALUED = { "m" => :message, "F" => :file, "t" => :template, "c" => nil, "C" => nil }.freeze
SHORT_OPTIONAL = %w[S u].freeze # value only when attached (-Skeyid, -uno)
LONG_VALUED = {
  "message" => :message, "file" => :file, "template" => :template, "trailer" => :trailer,
  "author" => nil, "date" => nil, "cleanup" => nil, "reuse-message" => nil,
  "reedit-message" => nil, "fixup" => nil, "squash" => nil, "pathspec-from-file" => nil
}.freeze
# Every git commit long option (git commit --git-completion-helper-all), so an
# abbreviation resolves the way git's parse-options resolves it.
LONG_OPTIONS = (LONG_VALUED.keys + %w[
  ahead-behind all allow-empty allow-empty-message amend branch dry-run edit gpg-sign
  include interactive long no-ahead-behind no-all no-allow-empty no-allow-empty-message
  no-amend no-author no-branch no-cleanup no-date no-dry-run no-edit no-file no-fixup
  no-gpg-sign no-include no-interactive no-long no-message no-null no-only no-patch
  no-pathspec-file-nul no-pathspec-from-file no-porcelain no-post-rewrite no-quiet
  no-reedit-message no-reset-author no-reuse-message no-short no-signoff no-squash
  no-status no-template no-untracked-files no-verbose no-verify null only patch
  pathspec-file-nul porcelain post-rewrite quiet reset-author short signoff status
  untracked-files verbose verify
]).freeze

def trailer?(text)
  !text.nil? && text.to_s.b.downcase.include?(TRAILER)
end

# Set per commit: an uncertain one (found in a nested command string, see
# GitCommand::Invocation#certain) says so in the message.
$nested_commit = false

def block!(where = nil)
  nested = $nested_commit ? "a nested command string" : nil
  found = [where, nested].compact.join(", in ")
  if found.empty?
    warn "ERROR: Do not include Co-Authored-By in git commits."
  else
    warn "ERROR: Do not include Co-Authored-By in git commits (found in #{found})."
  end
  exit 2
end

def resolve_long(name)
  return name if LONG_OPTIONS.include?(name)

  candidates = LONG_OPTIONS.select { |o| o.start_with?(name) }
  candidates.size == 1 ? candidates.first : nil
end

# [[kind, value, index of the arg holding value], ...] for the message
# sources in a git commit argument list.
def message_sources(args)
  sources = []
  i = 0
  while i < args.size
    arg = args[i]
    break if arg == "--"

    if arg.start_with?("--")
      name, eq, value = arg[2..].partition("=")
      full = resolve_long(name)
      if full && LONG_VALUED.key?(full)
        if eq.empty?
          i += 1
          value = args[i]
        end
        sources << [LONG_VALUED[full], value, i] if LONG_VALUED[full] && value
      end
    elsif arg.start_with?("-") && arg.length > 1
      j = 1
      while j < arg.length
        ch = arg[j]
        break if SHORT_OPTIONAL.include?(ch)

        if SHORT_VALUED.key?(ch)
          value = arg[(j + 1)..]
          if value.empty?
            i += 1
            value = args[i]
          end
          sources << [SHORT_VALUED[ch], value, i] if SHORT_VALUED[ch] && value
          break
        end
        j += 1
      end
    end
    i += 1
  end
  sources
end

def file_has_trailer?(path)
  return false unless File.file?(path) && File.readable?(path)
  return false if File.size(path) > MAX_MESSAGE_FILE_BYTES

  trailer?(File.binread(path))
rescue SystemCallError, IOError
  # Unreadable is left to git itself rather than guessed at.
  false
end

# A message file by its path key: what the same command writes into it
# first, the files it copies into it (`cat src > msg`), then the file as it
# is on disk now unless the command truncated it with literal output before
# this commit (rewritten: that invocation's Invocation#rewritten). The key
# of an unknown directory ("<?3>/msg", GitCommand::UnknownDir) names the
# same file under each directory that cwd can be (Result#local_paths); a
# key with an unresolved $ / ` or a remote directory is matched against the
# writes only.
def check_path(key, label, result, rewritten, seen)
  return if key.nil? || seen[key]

  seen[key] = true
  block!(label) if result.writes.fetch(key, []).any? { |text| trailer?(text) }
  (result.copies || {}).fetch(key, []).each { |src| check_path(src, label, result, rewritten, seen) }
  return if rewritten.include?(key)

  if key.start_with?("/")
    block!(label) if file_has_trailer?(key)
  else
    result.local_paths(key).each { |path| check_path(path, label, result, rewritten, seen) }
  end
end

# The parser already expanded the value ($HOME, $TMPDIR, variables the command
# set); path_key resolves it the way the parser keyed the command's writes, so
# `cat > "$F"` and `-F "$F"` meet even when F holds "$(mktemp)", and a file
# written and read under the same unknown cwd meets through its key. Then
# the path under each directory the commit can be in (dir_candidates: the
# branches of `cd A || cd B`, if / case arms ...), unless the command just
# rewrote the file this commit reads.
def check_message_file(path, inv, result)
  rewritten = inv.rewritten || []
  seen = {}
  key = GitCommand.path_key(inv.base, path)
  check_path(key, path, result, rewritten, seen)
  return if key && rewritten.include?(key)

  (inv.dir_candidates || []).each do |dir|
    check_path(GitCommand.path_key(dir, path), path, result, rewritten, seen)
  end
end

def check_stdin(inv, result, label)
  block!("stdin of -F #{label}") if trailer?(inv.stdin)
  inv.stdin_files.each { |path| check_path(path, path, result, inv.rewritten || [], {}) }
end

# A $NAME the parser could not resolve: some command names NAME as an unquoted
# word or assignment head (an assignment form the parser does not model, such
# as `mapfile -t NAME`) and the command carries the trailer.
def unresolved_var_trailer?(name, cmd, result)
  trailer?(cmd) && (result.names || {}).key?(name)
end

# What the parser found behind one arg: $(...) / <(...) output (text or a
# file it reads) and unresolved variables. Files and text count only when they
# are the message (kind :text); a -F / -t path is checked as a path.
def check_extras(inv, extras, kind, cmd, result, label)
  extras.each do |type, value|
    case type
    when :text then block!(label) if kind != :path && trailer?(value)
    when :file then check_path(value, value, result, inv.rewritten || [], {}) if kind != :path
    when :var then block!("$#{value}") if unresolved_var_trailer?(value, cmd, result)
    end
  end
end

def check_commit(inv, cmd, result)
  $nested_commit = inv.certain == false
  block! if inv.fallback && trailer?(inv.raw)

  extras = inv.arg_extras || []
  message_sources(inv.args).each do |kind, value, index|
    content = %i[message trailer].include?(kind)
    label = "$(...)"
    case kind
    when :message, :trailer
      # A $(...) left in the value is source text, not message text; its
      # literal output is in extras.
      block! if trailer?(GitCommand.without_substitutions(value))
    when :file, :template
      if STDIN_PATHS.include?(value)
        check_stdin(inv, result, value)
        content = true
      elsif value.start_with?("<(")
        # -F <(printf ...): the message is what the substitution prints.
        content = true
        label = "-F #{value[0, 2]}...)"
      else
        check_message_file(value, inv, result)
      end
    end
    check_extras(inv, extras[index] || [], content ? :text : :path, cmd, result, label)
  end
end

begin
  data = JSON.parse($stdin.read)
  cmd = data.dig("tool_input", "command").to_s
  # Quick exit before parsing: a commit not spelled with the literal word
  # (`git com\mit`, `git "com"mit`, an alias) is not checked (see above).
  exit 0 unless cmd.include?("commit")

  cwd = data["cwd"].is_a?(String) && File.directory?(data["cwd"]) ? data["cwd"] : Dir.pwd
  result = GitCommand.parse(cmd, cwd: cwd)
  result.commits.each { |inv| check_commit(inv, cmd, result) }
rescue StandardError, SystemStackError
  # A hook must never break the commit path over its own error.
  exit 0
end

exit 0
