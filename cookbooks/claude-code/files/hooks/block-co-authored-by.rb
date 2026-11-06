#!/usr/bin/env ruby
# frozen_string_literal: true

# PreToolUse (Bash) hook: block a git commit whose message carries a
# Co-Authored-By trailer (matched case-insensitively).
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
# host bash -s <<EOF`). For each one the message sources are checked:
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
#                    write to the same text (`cat > "$F"` + `-F "$F"`)
#   -F <(...)        the substitution's literal output (also --file=<(...),
#                    -F<(...), and -F - < <(...))
#   -F - (and /dev/stdin, /dev/fd/0, /proc/self/fd/0)
#                    stdin, when the command itself shows it: a heredoc or
#                    here-string on the commit (`git commit -F - <<'EOF'`, any
#                    quotes inside the body), `< file`, or the literal output
#                    on the left of a pipe: echo / printf / `cat <<EOF` / `cat
#                    file`, or a { ...; } / ( ... ) group of them
#                    (`{ echo fix; echo; echo "..."; } | git commit -F -`)
# A value may come through a variable the same command sets (MSG=...; export,
# declare, local, `read -d '' MSG <<'EOF'`, `printf -v`, `for M in ...`) and
# through a literal $(...): `-m "$(cat msg)"` and `-m "$(< msg)"` read that
# file (relative to the shell's cwd, as the substitution runs before -C). The
# source text of a $(...) / `...` is not the message: only its literal output
# is checked, so `MSG=$(git log -1 --format=%B | grep -v '^Co-Authored-By:')`
# + `git commit --amend -m "$MSG"` passes. A $NAME the parser cannot resolve
# still blocks when some command names NAME as an unquoted word or an
# assignment head (`mapfile -t NAME`, an assignment form it does not model;
# text inside another quoted string does not count) and the command carries
# the trailer. Input the parser cannot read (an unterminated quote) is checked
# as text: anything after `git ... commit` in that command segment that
# mentions the trailer blocks.
#
# Residual holes — the CLAUDE.md rule ("Co-Authored-By トレーラーは付けない") is
# the enforcement there:
#   - a message built by a program: `-F -` fed by a pipe whose left side is
#     not literal (`gen-msg | git commit -F -`, `cat m | sed ... |`),
#     `-m "$(gen-msg)"` (also `-m "$(gen | sed 's/$/ Co-Authored-By: x/')"`),
#     `-F <(gen-msg)`, a file a program fills (`gen-msg > "$F"`, `git
#     interpret-trailers --in-place`) and a file copied by `cp`.
#   - shell expansion the parser does not do: an unquoted heredoc body is not
#     variable-expanded (`TR='Co-Authored-By: ..'; git commit -F - <<EOF` with
#     $TR in the body), and a here-string's $(...) is not read (`-F - <<<
#     "$(cat f)"`); a variable assigned in an if / else branch or after `||`
#     keeps its last assignment.
#   - only the `commit` subcommand is checked: `git merge -m`, `git tag -m`,
#     `git commit-tree -m`, and commit strings run by `git rebase -x` / `git
#     submodule foreach` pass; so does a reused message (-c / -C /
#     --reuse-message, --fixup=amend:).
#   - a commit not spelled with the literal word: the hook exits before
#     parsing unless the command contains "commit", so `git com\mit`, `git
#     "com"mit`, `git $'\x63ommit'` and git aliases (`git ci`) pass.
#   - a commit inside a quoted command string handed to another program
#     (`ssh host '...'`, `tmux send-keys`, `watch '...'`), and one inside a
#     `function NAME { ...; }` body.
# Conservative: two unresolved paths with the same text (two `$(mktemp)`
# variables) share one key, so the trailer written into either one blocks a
# commit that reads the other; a commit behind ssh / docker ... is checked like
# a local one, and its message file is read from this host.
# History: the -F <path> check came from a 2026-09-16 audit (the -F route,
# which CLAUDE.md recommends for messages with glob characters, passed
# unchecked); SH1-79 replaced the literal "git commit" match with the parser.
#
# Fail-open: any internal error exits 0; only a found trailer exits 2.

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

def block!(where = nil)
  if where
    warn "ERROR: Do not include Co-Authored-By in git commits (found in #{where})."
  else
    warn "ERROR: Do not include Co-Authored-By in git commits."
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

# A message file: what the same command writes into it first, the files it
# copies into it (`cat src > msg`), then the file as it is on disk now unless
# the command truncated it with literal output before this commit (rewritten:
# that invocation's Invocation#rewritten).
def check_path(full, label, result, rewritten, seen = {})
  return if seen[full]

  seen[full] = true
  block!(label) if result.writes.fetch(full, []).any? { |text| trailer?(text) }
  (result.copies || {}).fetch(full, []).each { |src| check_path(src, label, result, rewritten, seen) }
  block!(label) if !rewritten.include?(full) && file_has_trailer?(full)
end

# The parser already expanded the value ($HOME, $TMPDIR, variables the command
# set); path_key resolves it the way the parser keyed the command's writes, so
# `cat > "$F"` and `-F "$F"` meet even when F holds "$(mktemp)".
def check_message_file(path, inv, result)
  full = GitCommand.path_key(inv.dir, path)
  check_path(full, path, result, inv.rewritten || []) if full
end

def check_stdin(inv, result, label)
  block!("stdin of -F #{label}") if trailer?(inv.stdin)
  inv.stdin_files.each { |path| check_path(path, path, result, inv.rewritten || []) }
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
    when :file then check_path(value, value, result, inv.rewritten || []) if kind != :path
    when :var then block!("$#{value}") if unresolved_var_trailer?(value, cmd, result)
    end
  end
end

def check_commit(inv, cmd, result)
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
