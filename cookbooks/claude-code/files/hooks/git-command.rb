# frozen_string_literal: true

# Shared parser for the Bash PreToolUse hooks that act on `git commit`
# (block-co-authored-by.rb, pre-commit-test.rb), loaded with require_relative.
# It is a library, not a hook: deployed next to them by the claude-code
# cookbook and NOT wired in settings.json.
#
# GitCommand.parse(command, cwd:) splits a Bash command string into the git
# invocations it runs and returns a Result:
#   invocations   one Invocation per git call, in execution order
#     dir           effective directory: cwd, then `cd` / pushd / popd in the
#                   chain, then each -C (relative to the previous one); nil when
#                   it is not knowable statically ("$VAR", `cd -`)
#     globals       [[option, value], ...] consumed before the subcommand
#                   (-C, -c k=v, --git-dir[=], --work-tree[=], --no-pager, -P,
#                   --bare, --namespace[=], --exec-path[=], --config-env, ...)
#     subcommand    "commit", "log", ...; "help" / "version" for -h / -v
#     args          the subcommand's arguments, quotes removed, with the
#                   variables this command assigned substituted (see below)
#     arg_extras    one list per arg of what its text alone does not show:
#                   [:text, s] / [:file, path] for the literal output of a
#                   $(...) in it (`-m "$(cat msg)"`, `$(< msg)`, also through
#                   a variable), [:var, NAME] for a $NAME that no form below
#                   assigned anywhere in the command (so set some other way)
#     env           {NAME => value} the call runs with: leading NAME=value
#                   words, `env NAME=value`, and variables exported earlier
#     work_tree     --work-tree (or GIT_WORK_TREE) resolved against dir; nil
#                   when absent or not static
#     stdin         fd 0 text when the command itself shows it: a heredoc or
#                   here-string on the git call, `< <(...)`, or the literal
#                   output of what is on the left of a pipe (see "Literal
#                   output" below)
#     stdin_source  :heredoc, :herestring, :file, :process, :pipe,
#                   :pipe_unknown or nil
#     stdin_files   files whose content reaches fd 0 (`< f`, `cat f |`)
#     fallback      true when the regex fallback produced this entry
#     raw           (fallback only) the rest of that command segment after
#                   `commit`, plus the heredoc bodies it introduces
#   writes        {path key => [text, ...]}: literal output redirected into a
#                 file somewhere in the command (`> f`, `>> f`, `tee f`), so
#                 `cat > msg <<'EOF' ... EOF` + `git commit -F msg` is visible
#                 before the file exists. The key is GitCommand.path_key: the
#                 absolute path, or for a path that is not static the expanded
#                 text itself (`F=$(mktemp)` makes both `> "$F"` and
#                 `-F "$F"` the key "$(mktemp)")
#   fallback      true when the command could not be parsed
#
# Understood: && || ; | |& & and newlines outside quotes; ( ) subshells and
# { ...; } groups (a cd or assignment inside a subshell does not leak out; one
# inside a pipeline or `&` does not count); single, double and $'...' quoting,
# backslash escapes, comments; heredocs (<<EOF, <<'EOF', <<"EOF", <<-EOF) and
# here-strings, attached to the command that owns them; $(...), `...` and
# <(...) / >(...), also inside a word (`--file=<(...)`) and as a redirection
# target (`done < <(ls)`), scanned so their quotes and heredocs do not break
# the outer split and searched for git calls themselves; leading VAR=value
# assignments; the wrappers env, command, nohup, time, timeout, nice, exec,
# sudo, su, runuser, flock, xargs, script, find -exec, noglob, nocorrect; bash / sh / zsh / dash / ksh -c strings, `bash -s`
# / `bash` reading a heredoc, and eval. Other commands (mise exec --,
# stdbuf, ...) are searched for a later shell entry point or `git` word that
# starts a commit, unless it is a data command (echo, grep, ...); behind ssh /
# docker / pct ... that commit gets dir nil (not this host's).
#
# Conditional lists retain each reachable cwd (up to 32 paths), rather than
# treating the last cd in an if/else or OR list as the only directory.
#
# Variables: NAME=value commands, export / declare / local / readonly / typeset
# NAME=value, `read [-d ''] NAME` from a heredoc / here-string / `< file`,
# `printf -v NAME` and `for NAME in ...` are tracked like the cwd (a subshell
# does not leak them). In later words, cd / -C targets and redirection
# targets, $NAME, ${NAME} and ${NAME:-default} (also -, := and =) take, in
# order: the value this command assigned; $PWD the shell's cwd at that point
# and $HOME the home directory; any other variable the command never assigns
# from the hook's own environment, which Claude Code's Bash tool shares
# ($TMPDIR, $CLAUDE_PROJECT_DIR); else the default. Two command substitutions
# with a knowable output are replaced too: $(pwd) and $(git [-C dir] rev-parse
# --show-toplevel) (the nearest ancestor holding .git). Anything else stays as
# written, so the same unresolved text on both sides still matches as a path
# key. Globs are not matched and git aliases (`git ci`) are not resolved.
#
# Literal output (pipe input, `> file` content, $(...) / <(...) values): echo,
# printf, `cat <<EOF` / `cat f` / `cat <(...)`, tee passing its stdin on, and
# a { ...; } / ( ... ) group or a $(...) / <(...) list of commands, whose
# output is that of its members that are not piped or redirected elsewhere
# (members whose output is not literal are left out).
#
# Never raises to the caller: input it cannot parse (an unterminated quote,
# nesting deeper than Lexer::MAX_NEST) falls back to a regex scan that still
# finds `commit` after `git` and optional global options, and marks the result
# `fallback`.
#
# CRuby stdlib only (Ruby 2.6 compatible: no filter_map / tally): hooks run
# under CRuby via ruby-shim, not mitamae's mruby.

require_relative "git-command-flow"
require_relative "git-command-wrappers"

module GitCommand
  class ParseError < StandardError; end

  Invocation = Struct.new(:dir, :globals, :subcommand, :args, :arg_extras, :env, :work_tree,
                          :stdin, :stdin_source, :stdin_files, :fallback, :raw,
                          keyword_init: true) do
    def commit?
      subcommand == "commit"
    end
  end

  Result = Struct.new(:invocations, :writes, :fallback, keyword_init: true) do
    def commits
      invocations.select(&:commit?)
    end
  end

  # value: quote-removed text; raw: source text (tells `~` from "~", and an
  # assignment from a quoted word); substs: bodies of $(...) / `...` / <(...);
  # params: a Ref for each expansion in value outside single quotes; extras:
  # see Invocation#arg_extras (set by expansion).
  Word = Struct.new(:value, :raw, :substs, :params, :extras)
  # One expansion inside Word#value, at [pos, pos + len): a parameter (name;
  # op and default for ${NAME:-default} and its -, :=, = forms) or, with name
  # nil, a $(...) / `...` command substitution whose body is body.
  Ref = Struct.new(:pos, :len, :name, :op, :default, :body)
  # fd: nil, a digit string, or "&" (&> / &>>); body: heredoc text.
  Redir = Struct.new(:fd, :op, :target, :body)
  # pipe_prev: the Command piped into this one, :unknown (output that is not
  # knowable), or nil. piped_out / async: a `|` or `&` follows it. group: the
  # Output of the ( ... ) or { ...; } this command closes (`}` and what
  # follows `)`), whose redirections and pipe apply to that group.
  Command = Struct.new(:words, :redirs, :pipe_prev, :piped_out, :async, :group)
  # A tracked shell variable: its text, the arg_extras it carries, exported?
  Var = Struct.new(:text, :extras, :exported)
  # Literal stdout of a command: text (or nil) plus files it copies.
  Output = Struct.new(:text, :files)
  # An open ( ... ) / { ...; } / $(...) list collecting its members' Output.
  Group = Struct.new(:kind, :text, :files, :known)

  def self.parse(command, cwd: Dir.pwd, home: ENV.fetch("HOME", nil))
    Evaluator.new(home).run_top(command.to_s.scrub, cwd)
  rescue StandardError, SystemStackError
    fallback_scan(command, cwd)
  end

  # The absolute path an (expanded) word names, relative to base, or nil when
  # it is not static (an unresolved $ or `, or a relative path with base nil).
  # raw is the word's source text: a leading ~ expands only when unquoted.
  def self.resolve_path(base, value, raw = value, home: ENV.fetch("HOME", nil))
    v = value.to_s.dup
    if v.start_with?("~")
      if !raw.to_s.start_with?("~")
        v = "./#{v}"
      elsif v == "~" || v.start_with?("~/")
        return nil unless home

        v = home + v[1..]
      else
        v = File.expand_path(v) # ~user
      end
    end
    return nil if v.empty? || v.include?("$") || v.include?("`")
    return nil if base.nil? && !v.start_with?("/")

    File.expand_path(v, base)
  rescue ArgumentError
    nil
  end

  # The key a file is known by in Result#writes and arg_extras: the resolved
  # path, or for a path that is not static (`"$(mktemp)"`, `"$(mktemp
  # -d)/msg"`, `"$UNSET/m"`) its expanded text, so the write and the read of
  # the same variable-held path meet. nil for an empty value, or a relative
  # static path whose base is not known.
  def self.path_key(base, value, raw = value, home: ENV.fetch("HOME", nil))
    return nil if value.nil? || value.empty?

    resolve_path(base, value, raw, home: home) ||
      (value.include?("$") || value.include?("`") ? value : nil)
  end

  QUOTED_OR_BARE = %q{(?:"[^"]*"|'[^']*'|[^\s;&|()]+)}
  # `commit` must end the word: `-c commit.gpgsign=false log` is not a commit.
  FALLBACK_RE = Regexp.new(
    "(?:\\A|[\\s;&|(`'\"])(?:[\\w./~-]*/)?git" \
    "((?:\\s+(?:-[Cc]\\s+#{QUOTED_OR_BARE}" \
    "|--(?:git-dir|work-tree|namespace|config-env|super-prefix|attr-source)(?:=|\\s+)#{QUOTED_OR_BARE}" \
    "|--?[\\w-]+(?:=\\S*)?))*)" \
    "\\s+commit(?=[\\s;&|)`'\"]|\\z)",
  )
  FALLBACK_CD_RE = Regexp.new("(?:\\A|[\\s;&|(])cd\\s+(#{QUOTED_OR_BARE})")
  # A heredoc operator (not <<<) and its delimiter, for the fallback scan.
  FALLBACK_HEREDOC_RE = /(?<!<)<<(?!<)(-?)[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|\\?([^\s;&|<>()'"]+))/.freeze

  # Conservative scan for input the lexer rejects: every `git [globals] commit`
  # becomes an Invocation whose args are a naive whitespace split of the rest
  # of its command segment, up to the next unquoted newline, ; & or | or the
  # next match (raw keeps that text, plus the bodies of the heredocs it opens,
  # for a substring check; together the raws still cover every segment).
  # Heredoc bodies are cut out before the search, so a `git commit` mentioned
  # in a document being written is not a commit. Linear in the input: the
  # scan runs on a binary copy, where MatchData offsets are byte offsets (on a
  # UTF-8 string each #begin counts characters from the start), and every cut
  # falls on an ASCII byte, so each piece converts back to valid UTF-8.
  def self.fallback_scan(command, cwd, track_cwd: true)
    code, bodies = fallback_split_heredocs(command.to_s.scrub.b)
    seps = fallback_separators(code)
    body_pos = bodies.map(&:first)
    cds = track_cwd ? code.to_enum(:scan, FALLBACK_CD_RE).map { [Regexp.last_match.begin(0), Regexp.last_match[1]] } : []
    cd_pos = cds.map(&:first)
    matches = code.to_enum(:scan, FALLBACK_RE).map { Regexp.last_match }
    invocations = matches.each_with_index.map do |m, idx|
      dir = cwd
      k = cd_pos.bsearch_index { |pos| pos >= m.begin(0) } || cds.size
      dir = fallback_dir(dir, utf8(cds[k - 1][1])) if k.positive?
      m[1].scan(/-C\s+(#{QUOTED_OR_BARE})/o) { |(path)| dir = fallback_dir(dir, utf8(path)) }
      stop = seps.bsearch { |pos| pos >= m.end(0) } || code.length
      stop = [stop, matches[idx + 1].begin(0)].min if matches[idx + 1]
      from = body_pos.bsearch_index { |pos| pos >= m.begin(0) } || bodies.size
      upto = body_pos.bsearch_index { |pos| pos >= stop } || bodies.size
      raw = utf8(code[m.end(0)...stop].to_s + bodies[from...upto].map(&:last).join)
      Invocation.new(dir: dir, globals: [], subcommand: "commit",
                     args: raw.split(/\s+/).reject(&:empty?).map { |a| a.delete(%q{"'}) },
                     arg_extras: [], env: {}, work_tree: nil,
                     stdin: nil, stdin_source: nil, stdin_files: [], fallback: true, raw: raw)
    end
    Result.new(invocations: invocations, writes: {}, fallback: true)
  rescue StandardError, SystemStackError
    Result.new(invocations: [], writes: {}, fallback: true)
  end

  def self.utf8(bytes)
    bytes.dup.force_encoding(Encoding::UTF_8).scrub
  end

  # [text with heredoc body lines removed, [[operator index in it, body], ...]].
  def self.fallback_split_heredocs(src)
    code = String.new(encoding: src.encoding)
    bodies = []
    pending = []
    src.each_line do |line|
      if pending.empty?
        line.to_enum(:scan, FALLBACK_HEREDOC_RE).each do
          m = Regexp.last_match
          pending << [m[2] || m[3] || m[4], m[1] == "-", code.length + m.begin(0), String.new(encoding: src.encoding)]
        end
        code << line
        next
      end
      doc = pending.first
      check = line.chomp
      check = check.sub(/\A\t+/, "") if doc[1]
      if check == doc[0]
        bodies << [doc[2], doc[3]]
        pending.shift
      else
        doc[3] << line
      end
    end
    pending.each { |doc| bodies << [doc[2], doc[3]] }
    [code, bodies]
  end

  # Indexes of newlines, ; & and | outside quotes (one pass from the start).
  def self.fallback_separators(code)
    seps = []
    single = double = escaped = false
    code.each_char.with_index do |ch, i|
      if escaped
        escaped = false
      elsif single
        single = false if ch == "'"
      elsif ch == "\\"
        escaped = true
      elsif double
        double = false if ch == "\""
      elsif ch == "'"
        single = true
      elsif ch == "\""
        double = true
      elsif ["\n", ";", "&", "|"].include?(ch)
        seps << i
      end
    end
    seps
  end

  def self.fallback_dir(base, path)
    path = path[1..-2] if path.start_with?("\"", "'")
    return nil if path.include?("$") || path.include?("`")
    return nil if base.nil? && !path.start_with?("/", "~")

    File.expand_path(path, base)
  rescue ArgumentError
    nil
  end

  # Turns a command string into [:word, Word] / [:redir, Redir] / [:op, String]
  # tokens. Heredoc bodies are read at the newline that ends their line and
  # stored on the Redir that introduced them.
  class Lexer
    META = [" ", "\t", "\n", ";", "&", "|", "(", ")", "<", ">"].freeze
    ESCAPES = {
      "n" => "\n", "t" => "\t", "r" => "\r", "a" => "\a", "b" => "\b", "e" => "\e",
      "E" => "\e", "f" => "\f", "v" => "\v", "\\" => "\\", "'" => "'", "\"" => "\"", "?" => "?"
    }.freeze
    # Nesting of $( ) / ` ` / ${ } / "..." inside each other. Deeper input is
    # rejected (ParseError, so the caller falls back) before the recursion can
    # exhaust the stack; real commands stay in single digits.
    MAX_NEST = 100
    NAME_START = /[A-Za-z_]/.freeze
    NAME_CHAR = /\w/.freeze
    # ${NAME}, ${NAME:-default} / ${NAME-default} / ${NAME:=default} /
    # ${NAME=default} with a default that needs no further expansion.
    BRACED_PARAM = /\A\$\{([A-Za-z_]\w*)(?:(:?[-=])([^$`'"\\]*))?\}\z/.freeze

    def initialize(src)
      @c = src.chars
      @n = @c.size
      @i = 0
      @tokens = []
      @pending = []
      @nest = 0
    end

    def tokenize
      step while @i < @n
      # A heredoc with no newline after its operator has an empty body.
      @pending.each { |r| r.body = +"" }
      @pending = []
      @tokens
    end

    def self.words(src)
      new(src).tokenize.select { |type, _| type == :word }.map(&:last)
    end

    private

    def step
      ch = @c[@i]
      nx = @c[@i + 1]
      if ch == " " || ch == "\t"
        @i += 1
      elsif ch == "\\" && nx == "\n"
        @i += 2
      elsif ch == "\n"
        @i += 1
        read_heredoc_bodies
        @tokens << [:op, "\n"]
      elsif ch == "#"
        @i += 1 while @i < @n && @c[@i] != "\n"
      elsif ch == "&"
        lex_ampersand(nx)
      elsif ch == "|"
        op(nx == "|" ? "||" : (nx == "&" ? "|&" : "|"))
      elsif ch == ";"
        lex_semicolon(nx)
      elsif ch == "(" || ch == ")"
        op(ch)
      elsif (ch == "<" || ch == ">") && nx == "("
        @tokens << [:word, read_word] # <(...) / >(...), and any text after it
      elsif ch == "<" || ch == ">"
        lex_redirection(nil)
      elsif digit?(ch) && fd_prefix_end
        stop = fd_prefix_end
        fd = @c[@i...stop].join
        @i = stop
        lex_redirection(fd)
      else
        @tokens << [:word, read_word]
      end
    end

    def op(text)
      @tokens << [:op, text]
      @i += text.length
    end

    def lex_ampersand(nx)
      if nx == "&"
        op("&&")
      elsif nx == ">"
        @i += 1
        lex_redirection("&")
      else
        op("&")
      end
    end

    def lex_semicolon(nx)
      if nx == ";"
        op(@c[@i + 2] == "&" ? ";;&" : ";;")
      elsif nx == "&"
        op(";&")
      else
        op(";")
      end
    end

    def digit?(ch)
      !ch.nil? && ch >= "0" && ch <= "9"
    end

    # End index of an fd prefix ("2" in 2>&1) when digits run into < or >.
    def fd_prefix_end
      j = @i
      j += 1 while j < @n && digit?(@c[j])
      ["<", ">"].include?(@c[j]) ? j : nil
    end

    def lex_redirection(fd)
      operator = redirection_operator
      skip_blanks
      heredoc = operator == "<<" || operator == "<<-"
      procsub = !heredoc && (@c[@i] == "<" || @c[@i] == ">") && @c[@i + 1] == "("
      # `done < <(ls)` and `> >(tee log)` read the substitution as the word.
      raise ParseError, "missing redirection target" if !procsub && (@i >= @n || META.include?(@c[@i]))

      redir = Redir.new(fd, operator, read_word, nil)
      @pending << redir if heredoc
      @tokens << [:redir, redir]
    end

    def redirection_operator
      a = @c[@i]
      b = @c[@i + 1]
      text =
        if a == "<"
          if b == "<"
            { "<" => "<<<", "-" => "<<-" }.fetch(@c[@i + 2], "<<")
          else
            { "&" => "<&", ">" => "<>" }.fetch(b, "<")
          end
        else
          { ">" => ">>", "&" => ">&", "|" => ">|" }.fetch(b, ">")
        end
      @i += text.length
      text
    end

    def skip_blanks
      loop do
        if @c[@i] == " " || @c[@i] == "\t"
          @i += 1
        elsif @c[@i] == "\\" && @c[@i + 1] == "\n"
          @i += 2
        else
          break
        end
      end
    end

    def read_heredoc_bodies
      pending = @pending
      @pending = []
      pending.each do |redir|
        delim = redir.target.value
        strip = redir.op == "<<-"
        body = +""
        while @i < @n
          stop = line_end(@i)
          line = @c[@i...stop].join
          @i = [stop + 1, @n].min
          line = line.sub(/\A\t+/, "") if strip
          break if line == delim

          body << line << "\n"
        end
        redir.body = body
      end
    end

    def line_end(from)
      j = from
      j += 1 while j < @n && @c[j] != "\n"
      j
    end

    def index_of(char, from)
      j = from
      j += 1 while j < @n && @c[j] != char
      j < @n ? j : nil
    end

    def read_word
      start = @i
      val = +""
      substs = []
      params = []
      while @i < @n
        ch = @c[@i]
        if (ch == "<" || ch == ">") && @c[@i + 1] == "("
          # Process substitution, also inside a word: bash turns
          # `--file=<(cmd)` into one word, --file=/dev/fd/63. Its path is not
          # knowable, so it gets no Ref; the body is a subst.
          stop, body = scan_parens(@i + 1)
          substs << body
          val << @c[@i...stop].join
          @i = stop
          next
        end
        break if META.include?(ch)

        case ch
        when "\\" then read_backslash(val)
        when "'" then read_single_quote(val)
        when "\"" then read_double_quote(val, substs, params)
        when "$" then read_dollar(val, substs, params)
        when "`"
          stop, body = scan_backtick(@i)
          substs << body
          params << Ref.new(val.length, stop - @i, nil, nil, nil, body)
          val << @c[@i...stop].join
          @i = stop
        else
          val << ch
          @i += 1
        end
      end
      Word.new(val, @c[start...@i].join, substs, params)
    end

    # $NAME at j (the "$"): records it in params and returns the index past it,
    # or nil when no name follows.
    def read_name(val, params, j)
      return nil unless @c[j + 1]&.match?(NAME_START)

      stop = j + 2
      stop += 1 while stop < @n && @c[stop].match?(NAME_CHAR)
      text = @c[j...stop].join
      params << Ref.new(val.length, text.length, text[1..])
      val << text
      stop
    end

    # ${...} at j: appends its source text, records ${NAME} and the
    # ${NAME:-default} forms (others, such as ${NAME#x}, stay as written).
    def read_braced(val, params, j)
      stop = skip_braces(j + 1)
      text = @c[j...stop].join
      m = BRACED_PARAM.match(text)
      params << Ref.new(val.length, text.length, m[1], m[2], m[3]) if m
      val << text
      stop
    end

    # $(...) at j (the "$"), unless it is $(( )) arithmetic: records the body
    # as a subst and as a Ref, appends the source text, returns the end.
    def read_command_subst(val, substs, params, j)
      stop, body = scan_parens(j + 1)
      unless @c[j + 2] == "("
        substs << body
        params << Ref.new(val.length, stop - j, nil, nil, nil, body)
      end
      val << @c[j...stop].join
      stop
    end

    def enter
      @nest += 1
      raise ParseError, "nesting deeper than #{MAX_NEST}" if @nest > MAX_NEST
    end

    def read_backslash(val)
      nx = @c[@i + 1]
      val << nx if nx && nx != "\n"
      @i += 2
    end

    def read_single_quote(val)
      stop = index_of("'", @i + 1) or raise ParseError, "unterminated single quote"
      val << @c[(@i + 1)...stop].join
      @i = stop + 1
    end

    def read_dollar(val, substs, params)
      nx = @c[@i + 1]
      if nx == "'"
        read_ansi_c(val)
      elsif nx == "\""
        @i += 1
        read_double_quote(val, substs, params)
      elsif nx == "("
        @i = read_command_subst(val, substs, params, @i)
      elsif nx == "{"
        @i = read_braced(val, params, @i)
      elsif (stop = read_name(val, params, @i))
        @i = stop
      else
        val << "$"
        @i += 1
      end
    end

    # "..." — keeps $(...), `...` and ${...} as their source text, records the
    # command-substitution bodies and the $NAME / ${NAME} references.
    def read_double_quote(val, substs, params)
      j = @i + 1
      while j < @n
        ch = @c[j]
        nx = @c[j + 1]
        if ch == "\""
          @i = j + 1
          return
        elsif ch == "\\"
          if nx == "\n"
            j += 2
          elsif ["$", "`", "\"", "\\"].include?(nx)
            val << nx
            j += 2
          else
            val << ch
            j += 1
          end
        elsif ch == "$" && nx == "("
          j = read_command_subst(val, substs, params, j)
        elsif ch == "$" && nx == "{"
          j = read_braced(val, params, j)
        elsif ch == "$" && (stop = read_name(val, params, j))
          j = stop
        elsif ch == "`"
          stop, body = scan_backtick(j)
          substs << body
          params << Ref.new(val.length, stop - j, nil, nil, nil, body)
          val << @c[j...stop].join
          j = stop
        else
          val << ch
          j += 1
        end
      end
      raise ParseError, "unterminated double quote"
    end

    def read_ansi_c(val)
      j = @i + 2
      while j < @n
        ch = @c[j]
        if ch == "'"
          @i = j + 1
          return
        elsif ch == "\\" && j + 1 < @n
          j = read_ansi_escape(val, j)
        else
          val << ch
          j += 1
        end
      end
      raise ParseError, "unterminated $'"
    end

    def read_ansi_escape(val, j)
      nx = @c[j + 1]
      if ESCAPES.key?(nx)
        val << ESCAPES[nx]
        return j + 2
      end
      digits =
        case nx
        when "x" then @c[(j + 2)...(j + 4)].join[/\A\h+/]
        when "u", "U" then @c[(j + 2)...(j + (nx == "u" ? 6 : 10))].join[/\A\h+/]
        when "0".."7" then @c[(j + 1)...(j + 4)].join[/\A[0-7]+/]
        end
      if digits.nil?
        val << "\\" << nx
        return j + 2
      end

      code = nx.between?("0", "7") ? digits.to_i(8) : digits.to_i(16)
      val << [code].pack("U") if code.positive? && code < 0x110000 && !code.between?(0xD800, 0xDFFF)
      j + (nx.between?("0", "7") ? 1 : 2) + digits.length
    end

    # From the "(" at `open` to just past its matching ")". Honours quotes,
    # nested substitutions, comments and heredocs, so a body such as
    # `cat <<'EOF'` + "it's (done)" + `EOF` does not unbalance the count.
    def scan_parens(open)
      enter
      depth = 0
      j = open
      pending = []
      word_start = true
      while j < @n
        ch = @c[j]
        case ch
        when "\\"
          j += 2
          word_start = false
          next
        when "'"
          j = (index_of("'", j + 1) or raise ParseError, "unterminated single quote") + 1
          word_start = false
          next
        when "\""
          j = skip_double_quote(j)
          word_start = false
          next
        when "`"
          j = scan_backtick(j)[0]
          word_start = false
          next
        when "("
          depth += 1
        when ")"
          depth -= 1
          return [j + 1, @c[(open + 1)...j].join] if depth.zero?
        when "#"
          if word_start
            j = line_end(j)
            next
          end
        when "<"
          if @c[j + 1] == "<" && @c[j + 2] == "<"
            j += 3
            word_start = false
            next
          elsif @c[j + 1] == "<"
            j = heredoc_operator(j + 2, pending)
            word_start = false
            next
          end
        when "\n"
          j += 1
          pending.each { |delim, strip| j = skip_heredoc_body(j, delim, strip) }
          pending = []
          word_start = true
          next
        end
        word_start = [" ", "\t", ";", "&", "|", "(", ")"].include?(ch)
        j += 1
      end
      raise ParseError, "unterminated command substitution"
    ensure
      @nest -= 1
    end

    def heredoc_operator(j, pending)
      strip = @c[j] == "-"
      j += 1 if strip
      j += 1 while @c[j] == " " || @c[j] == "\t"
      delim, j = scan_delim(j)
      pending << [delim, strip]
      j
    end

    def scan_delim(j)
      delim = +""
      while j < @n
        ch = @c[j]
        break if META.include?(ch)

        if ch == "'" || ch == "\""
          stop = index_of(ch, j + 1) or raise ParseError, "unterminated quote"
          delim << @c[(j + 1)...stop].join
          j = stop + 1
        elsif ch == "\\"
          delim << @c[j + 1].to_s
          j += 2
        else
          delim << ch
          j += 1
        end
      end
      raise ParseError, "missing heredoc delimiter" if delim.empty?

      [delim, j]
    end

    # Skips heredoc lines up to the delimiter. Inside $( ) a delimiter line
    # directly followed by ")" also ends the body (bash accepts `EOF)`).
    def skip_heredoc_body(j, delim, strip)
      while j < @n
        stop = line_end(j)
        line = @c[j...stop].join
        check = strip ? line.sub(/\A\t+/, "") : line
        return [stop + 1, @n].min if check == delim
        return j + (line.length - check.length) + delim.length if check.start_with?("#{delim})")

        j = stop + 1
      end
      @n
    end

    def skip_double_quote(j)
      enter
      j += 1
      while j < @n
        ch = @c[j]
        if ch == "\\"
          j += 2
        elsif ch == "\""
          return j + 1
        elsif ch == "`"
          j = scan_backtick(j)[0]
        elsif ch == "$" && @c[j + 1] == "("
          j = scan_parens(j + 1)[0]
        elsif ch == "$" && @c[j + 1] == "{"
          j = skip_braces(j + 1)
        else
          j += 1
        end
      end
      raise ParseError, "unterminated double quote"
    ensure
      @nest -= 1
    end

    def scan_backtick(j)
      enter
      body = +""
      j += 1
      while j < @n
        ch = @c[j]
        nx = @c[j + 1]
        if ch == "\\" && nx
          body << (["`", "\\", "$"].include?(nx) ? nx : ch + nx)
          j += 2
        elsif ch == "`"
          return [j + 1, body]
        else
          body << ch
          j += 1
        end
      end
      raise ParseError, "unterminated backquote"
    ensure
      @nest -= 1
    end

    def skip_braces(j)
      enter
      depth = 0
      while j < @n
        ch = @c[j]
        if ch == "\\"
          j += 2
          next
        elsif ch == "$" && @c[j + 1] == "("
          j = scan_parens(j + 1)[0]
          next
        elsif ch == "{"
          depth += 1
        elsif ch == "}"
          depth -= 1
          return j + 1 if depth.zero?
        end
        j += 1
      end
      raise ParseError, "unterminated ${"
    ensure
      @nest -= 1
    end
  end

  # Walks the tokens, tracking the working directory (cd / pushd / popd) and
  # shell variables through the chain and its subshells, and records git
  # invocations and literal file writes.
  class Evaluator
    include Wrappers
    MAX_DEPTH = 8
    MAX_RUNS = 256
    SHELLS = %w[bash sh zsh dash ksh].freeze
    RESERVED_SKIP = %w[! { if then elif else do while until].freeze
    RESERVED_STOP = %w[} fi done esac for case select function in].freeze
    ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=/.freeze
    ASSIGNMENT_PARTS = /\A([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?(\+?)=/.freeze
    NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze
    GIT_VALUED = %w[-C -c --git-dir --work-tree --namespace --config-env --super-prefix
                    --attr-source].freeze
    GIT_META = { "-h" => "help", "--help" => "help", "-v" => "version", "--version" => "version" }.freeze
    SUDO_VALUED = %w[-u -g -C -h -p -r -t -T -U --user --group --close-from --host --prompt
                     --role --type --command-timeout --other-user].freeze
    STDIN_OPS = %w[<< <<- <<< <].freeze
    # Operators a $(...) / <(...) body may use and still have a literal output.
    SUBST_OPS = ["\n", ";", "&&", "||", "|"].freeze
    WRITE_OPS = %w[> >> >|].freeze
    DECLARE = %w[export declare typeset local readonly].freeze
    READ_VALUED = "adinNptu"
    # Commands whose later words are data, never a command they run, so a
    # `git` among them is not searched for (`echo git commit`, `which git`).
    DATA_COMMANDS = (%w[echo printf print grep egrep fgrep zgrep rg ag ack sed awk jq man info
                       help whatis apropos tldr which type whereis hash alias unalias test
                       : true false printenv set unset read export declare typeset local
                       readonly] + ["[", "[["]).freeze
    # Wrappers that run their command on another host or in another root: a
    # commit behind them is still found, but its directory is not this one.
    SHELL_READERS = %w[cat less more head tail wc sort uniq cut tr tee diff cmp file ls].freeze
    REMOTE_COMMANDS = %w[ssh mosh docker podman kubectl lxc lxc-attach incus pct qm vagrant
                         multipass distrobox toolbox chroot schroot nsenter machinectl
                         systemd-run].freeze

    def initialize(home)
      @home = home
      @runs = 0
      @invocations = []
      @writes = {}
      @vars = {}
      @assigned = {} # every name any modeled form set, in any scope
    end

    def run_top(src, cwd)
      run(src, cwd, 0)
      Result.new(invocations: @invocations, writes: @writes, fallback: false)
    end

    private

    def run(src, cwd, depth)
      return cwd if depth > MAX_DEPTH

      @runs += 1
      if @runs > MAX_RUNS
        @invocations.concat(GitCommand.fallback_scan(src, nil, track_cwd: false).invocations)
        return nil
      end
      tokens =
        begin
          Lexer.new(src).tokenize
        rescue ParseError
          raise if depth.zero?

          # A nested string (bash -c, $(...), eval) bash itself would reject:
          # scan just that string, keep everything parsed around it.
          @invocations.concat(GitCommand.fallback_scan(src, cwd).invocations)
          return cwd
        end
      if tokens.any? { |type, value| type == :op && value == "||" } ||
         tokens.any? { |type, word| type == :word && word.raw == "if" }
        begin
          paths = FlowPaths.new(tokens.dup).paths
        rescue ParseError
          @invocations.concat(GitCommand.fallback_scan(src, nil, track_cwd: false).invocations)
          return nil
        end
        saved_vars = @vars.dup
        variable_states = []
        directories = paths.flat_map do |path|
          @vars = saved_vars.dup
          after = run_tokens(path, cwd, depth)
          variable_states << @vars.dup
          after.is_a?(Array) ? after : [after]
        end.uniq
        @vars = common_variables(variable_states)
        return bounded_directories(directories)
      end
      run_tokens(tokens, cwd, depth)
    end

    def run_tokens(tokens, cwd, depth)
      scopes = []
      groups = []
      dirstack = []
      cur = new_command(nil)
      tokens.each do |type, val|
        case type
        when :outcome
          @flow_failed = val == false
        when :word
          brace(groups, cur, val)
          cur.words << val
        when :redir then cur.redirs << val
        else
          cur.piped_out = true if val == "|" || val == "|&"
          cur.async = true if val == "&"
          before = cwd
          cwd = finish(cur, cwd, dirstack, depth) unless blank?(cur)
          collect_output(groups.last, cur, before)
          @flow_failed = false
          closed = nil
          case val
          when "("
            scopes.push([cwd, dirstack.dup, @vars.dup])
            groups.push(new_group(:paren))
          when ")"
            cwd, dirstack, @vars = scopes.pop unless scopes.empty?
            closed = close_group(groups, :paren)
          end
          cur = new_command(cur.piped_out ? (blank?(cur) && cur.group.nil? ? :unknown : cur) : nil)
          cur.group = closed
        end
      end
      return cwd if blank?(cur)

      cwd = finish(cur, cwd, dirstack, depth)
      collect_output(groups.last, cur, cwd)
      cwd
    end

    # `{` / `}` as the first word of a command opens / closes a brace group;
    # the `}` command then stands for the group (its output, redirections and
    # pipe).
    def brace(groups, cur, word)
      return unless word.raw == word.value && drop_reserved(cur.words).empty?

      if word.value == "{"
        groups.push(new_group(:brace))
      elsif word.value == "}"
        cur.group = close_group(groups, :brace)
      end
    end

    def new_group(kind)
      Group.new(kind, +"", [], false)
    end

    def close_group(groups, kind)
      return nil unless groups.last&.kind == kind

      group_output(groups.pop)
    end

    def group_output(group)
      group.known ? Output.new(group.text, group.files) : nil
    end

    # Adds cmd's literal stdout to the open group, unless it goes into a pipe
    # or a file instead. A member whose output is not literal adds nothing.
    def collect_output(group, cmd, cwd)
      if cwd.is_a?(Array)
        cwd.each { |directory| collect_output(group, cmd, directory) }
        return
      end
      return if group.nil? || cmd.piped_out || stdout_redirected?(cmd)

      out = literal_output(cmd, cwd)
      return unless out

      group.known = true
      group.text << out.text.to_s
      group.files.concat(out.files)
    end

    def stdout_redirected?(cmd)
      cmd.redirs.any? do |r|
        [nil, "1", "&"].include?(r.fd) &&
          (WRITE_OPS.include?(r.op) || (r.op == ">&" && r.target.value != "1"))
      end
    end

    # A child shell or substitution: it sees the variables, its own do not
    # come back.
    def nested_run(src, cwd, depth, env = {})
      saved = @vars
      saved_failure = @flow_failed
      @flow_failed = false
      @vars = @vars.dup
      env.each { |name, text| set_var(name, text, [], exported: true) }
      run(src, cwd, depth)
    ensure
      @vars = saved
      @flow_failed = saved_failure
    end

    def new_command(pipe_prev)
      Command.new([], [], pipe_prev, false, false)
    end

    def blank?(cmd)
      cmd.words.empty? && cmd.redirs.empty?
    end

    def heredoc?(redir)
      redir.op == "<<" || redir.op == "<<-"
    end

    # Widen excess alternatives to an unknown cwd; an absolute git -C can
    # still identify its checkout without retaining an unbounded cross product.
    def bounded_directories(directories)
      return nil if directories.size > FlowPaths::MAX_PATHS

      directories.size == 1 ? directories.first : directories
    end

    def common_variables(states)
      return {} if states.empty?

      states.first.select { |name, value| states.all? { |state| state[name] == value } }
    end

    # Evaluates one simple command; returns the cwd for the next one. The
    # caller sets the `|` / `&` flags before calling, so isolated? sees them.
    def finish(cmd, cwd, dirstack, depth)
      if cwd.is_a?(Array)
        saved_vars = @vars.dup
        variable_states = []
        directories = cwd.flat_map do |directory|
          @vars = saved_vars.dup
          after = finish(cmd, directory, dirstack.dup, depth)
          variable_states << @vars.dup
          after.is_a?(Array) ? after : [after]
        end.uniq
        @vars = common_variables(variable_states)
        return bounded_directories(directories)
      end
      cmd.words.each { |w| w.substs.each { |body| nested_run(body, cwd, depth + 1) } }
      cmd.redirs.each do |r|
        r.target.substs.each { |body| nested_run(body, cwd, depth + 1) } unless heredoc?(r)
      end
      core = drop_reserved(cmd.words)
      return assign_all(cmd, core, cwd) if !core.empty? && core.all? { |w| w.raw.match?(ASSIGNMENT) }
      return for_loop(core, cwd) if for_loop?(core)

      words, dir, env = strip_prefix(expand_words(cmd.words, cwd), cwd)
      record_writes(cmd, cwd)
      return cwd if words.empty?

      name = command_name(words[0])
      case name
      when "cd" then isolated?(cmd) || @flow_failed ? cwd : cd_target(words, dir)
      when "pushd"
        return cwd if isolated?(cmd) || @flow_failed

        dirstack.push(cwd)
        cd_target(words, dir, pushd: true)
      when "popd" then isolated?(cmd) || @flow_failed || dirstack.empty? ? cwd : dirstack.pop
      when "eval"
        after = run(words[1..].map(&:value).join(" "), dir, depth + 1)
        isolated?(cmd) ? cwd : after
      when *SHELLS
        script = shell_script(cmd, words, cwd)
        nested_run(script, dir, depth + 1, env) if script
        cwd
      when "find"
        find_commands(cmd, words, dir, depth)
        cwd
      when "git"
        @invocations << git_invocation(cmd, words, dir, cwd, exported_env.merge(env))
        cwd
      else
        unless isolated?(cmd)
          declare(words, cwd, name == "export") if DECLARE.include?(name)
          read_into(cmd, words, cwd) if name == "read"
          printf_into(words, cwd) if name == "printf"
        end
        wrapped_git(cmd, words, dir, cwd, exported_env.merge(env), name, depth)
        cwd
      end
    end

    # A cd in a pipeline element or a background job runs in a subshell.
    def isolated?(cmd)
      cmd.pipe_prev || cmd.piped_out || cmd.async ? true : false
    end

    def drop_reserved(words)
      words.drop_while { |w| w.raw == w.value && RESERVED_SKIP.include?(w.value) }
    end

    # "git" for git, /usr/bin/git and \git (File.basename raises on a NUL).
    def command_name(word)
      word.value.sub(%r{\A.*/}m, "")
    end

    # An unlisted wrapper can carry an explicit shell entry point or a git
    # commit. Do not interpret a whole quoted argument as arbitrary shell code.
    def wrapped_git(cmd, words, dir, cwd, env, name, depth)
      return if DATA_COMMANDS.include?(name)

      remote = REMOTE_COMMANDS.include?(name)
      (1...words.size).each do |idx|
        candidate = command_name(words[idx])
        # Inspect an explicit shell entry point, not arbitrary quoted text.
        # File readers do not execute a later shell word or their stdin.
        if !remote && !SHELL_READERS.include?(name) && SHELLS.include?(candidate)
          script = shell_script(cmd, words[idx..], cwd)
          nested_run(script, dir, depth + 1, env) if script
          return if script
        end
        next unless candidate == "git"

        inv = git_invocation(cmd, words[idx..], remote ? nil : dir, cwd, env, remote: remote)
        next unless inv.commit?

        @invocations << inv
        return
      end
    end

    def cd_target(words, base, pushd: false)
      i = 1
      i += 1 while words[i] && words[i].value.match?(/\A-[LPe@]+\z/)
      i += 1 if words[i]&.value == "--"
      word = words[i]
      return nil if word && word.value == "-"
      return (pushd ? nil : @home && File.expand_path(@home)) if word.nil?

      resolve_path(base, word.value, word.raw)
    end

    def resolve_path(base, value, raw = value)
      GitCommand.resolve_path(base, value, raw, home: @home)
    end

    def path_key(base, value, raw = value)
      GitCommand.path_key(base, value, raw, home: @home)
    end

    # ---- variables ------------------------------------------------------

    # Set by the shell itself: never reported as [:var, NAME] when unknown.
    SHELL_VARS = %w[HOME PWD OLDPWD].freeze
    # The commands whose $(...) output expand_word can know.
    STATIC_SUBST_COMMANDS = %w[pwd git].freeze

    # cwd: the shell's directory where the word is expanded ($PWD, $(pwd)).
    def expand_words(words, cwd)
      words.map { |w| expand_word(w, cwd) }
    end

    # The word with each expansion that has a knowable value replaced by it
    # (see the header: assigned variables, $PWD / $HOME, the environment,
    # ${NAME:-default}, $(pwd), $(git rev-parse --show-toplevel)); the rest
    # stay as written. extras gains the variables' extras, and [:var, NAME]
    # for a variable that is set nowhere this parser can see.
    def expand_word(word, cwd)
      return word if word.params.nil? || word.params.empty?

      out = +""
      extras = (word.extras || []).dup
      last = 0
      word.params.each do |ref|
        out << word.value[last...ref.pos]
        text = ref.name ? param_text(ref, cwd, extras) : static_subst(ref.body, cwd)
        out << (text || word.value[ref.pos, ref.len])
        last = ref.pos + ref.len
      end
      out << word.value[last..].to_s
      Word.new(out, word.raw, word.substs, [], extras)
    end

    # The value of a parameter Ref, or nil to leave it as written.
    def param_text(ref, cwd, extras)
      name = ref.name
      var = @vars[name]
      if var
        extras.concat(var.extras)
        text = var.text
      elsif @assigned[name]
        return nil # set in a subshell or pipeline that has ended
      else
        text = env_value(name, cwd)
        extras << [:var, name] if text.nil? && !SHELL_VARS.include?(name)
      end
      return text unless ref.op && (text.nil? || (text.empty? && ref.op.start_with?(":")))

      ref.default
    end

    # A variable the command never assigns: what the shell starts with. The
    # hook inherits Claude Code's environment, as the Bash tool does.
    def env_value(name, cwd)
      case name
      when "HOME" then @home
      when "PWD" then cwd
      when "OLDPWD" then nil
      else
        value = ENV.fetch(name, nil)
        value&.dup&.force_encoding(Encoding::UTF_8)&.scrub
      end
    end

    # The output of a $(...) whose value names a directory knowable here:
    # `pwd` (the cwd) and `git [-C dir] rev-parse --show-toplevel` (the
    # nearest ancestor of that directory holding .git); nil for anything else.
    def static_subst(body, cwd)
      return nil if cwd.nil?

      tokens = Lexer.new(body).tokenize
      return nil if tokens.any? { |type, val| (type == :op && val != "\n") || (type == :redir && val.fd != "2") }

      words = tokens.select { |type, _| type == :word }.map(&:last)
      return nil unless words.any? { |w| STATIC_SUBST_COMMANDS.include?(command_name(w)) }

      words, dir, env = strip_prefix(expand_words(words, cwd), cwd)
      return nil if words.empty? || dir.nil?

      case command_name(words[0])
      when "pwd" then words[1..].all? { |w| w.value.match?(/\A-[LP]+\z/) } ? dir : nil
      when "git" then git_toplevel(words, dir, exported_env.merge(env))
      end
    rescue ParseError
      nil
    end

    def git_toplevel(words, dir, env)
      return nil if env.key?("GIT_DIR") || env.key?("GIT_WORK_TREE")

      i = 1
      while i < words.size && words[i].value != "rev-parse"
        case words[i].value
        when "-C"
          return nil unless words[i + 1]

          dir = resolve_path(dir, words[i + 1].value, words[i + 1].raw) unless words[i + 1].value.empty?
          return nil if dir.nil?

          i += 2
        when "-c" then i += 2
        when "--no-pager", "-P" then i += 1
        else return nil
        end
      end
      return nil unless words[(i + 1)..].to_a.map(&:value) == ["--show-toplevel"]

      find_toplevel(dir)
    end

    def find_toplevel(dir)
      d = dir
      loop do
        return d if File.exist?(File.join(d, ".git"))

        parent = File.dirname(d)
        return nil if parent == d

        d = parent
      end
    rescue SystemCallError, ArgumentError
      nil
    end

    # Extras of an (expanded) word plus the literal output of its $(...) and
    # <(...).
    def word_extras(word, cwd)
      (word.extras || []) + word.substs.flat_map { |body| subst_outputs(body, cwd) }
    end

    # What a $(...) / <(...) body prints when that is literal, as extras:
    # [:text, s] for echo / printf / `cat <<EOF`, [:file, key] for `cat f` and
    # `< f`.
    def subst_outputs(body, cwd)
      out = subst_output(body, cwd)
      return [] unless out

      (out.text ? [[:text, out.text]] : []) + out.files.map { |path| [:file, path] }
    end

    # The Output of a substitution body: `< f` alone, or a list of commands
    # (; && || | and newlines) collected like a group. nil when not literal.
    def subst_output(body, cwd)
      tokens = Lexer.new(body).tokenize
      return nil if tokens.any? { |type, val| type == :op && !SUBST_OPS.include?(val) }

      cmds = [new_command(nil)]
      tokens.each do |type, val|
        cur = cmds.last
        case type
        when :word then cur.words << val
        when :redir then cur.redirs << val
        else
          cur.piped_out = true if val == "|"
          cmds << new_command(cur.piped_out ? cur : nil)
        end
      end
      cmds.reject! { |c| blank?(c) }
      return file_output(cmds[0], cwd) if cmds.size == 1 && cmds[0].words.empty?

      group = new_group(:subst)
      cmds.each { |c| collect_output(group, c, cwd) }
      group_output(group)
    rescue ParseError
      nil
    end

    # `$(< f)`: the file.
    def file_output(cmd, cwd)
      redir = cmd.redirs.find { |r| (r.fd.nil? || r.fd == "0") && r.op == "<" }
      target = redir && expand_word(redir.target, cwd)
      path = target && path_key(cwd, target.value, target.raw)
      path ? Output.new(nil, [path]) : nil
    end

    # A word that is one <(...) and nothing else.
    def process_substitution?(word)
      word.raw.start_with?("<(") && word.raw.end_with?(")") && word.substs.size == 1
    end

    # [NAME, text, append?] of an (expanded) NAME=value word; a leading
    # unquoted ~ in the value is expanded the way bash does in an assignment.
    def assignment(word)
      m = ASSIGNMENT_PARTS.match(word.value)
      return nil unless m

      text = m.post_match
      raw_rest = word.raw.sub(ASSIGNMENT, "")
      if @home && text.start_with?("~") && (raw_rest == "~" || raw_rest.start_with?("~/"))
        text = @home + text[1..]
      end
      [m[1], text, m[2] == "+"]
    end

    def assign(word, cwd, exported = false)
      name, text, append = assignment(word)
      return unless name

      set_var(name, text, word_extras(word, cwd), exported: exported, append: append)
    end

    def set_var(name, text, extras, exported: false, append: false)
      @assigned[name] = true
      old = @vars[name]
      if append && old
        text = old.text + text
        extras = old.extras + extras
      end
      @vars[name] = Var.new(text, extras, exported || (old ? old.exported : false))
    end

    def exported_env
      env = {}
      @vars.each { |name, var| env[name] = var.text if var.exported }
      env
    end

    # NAME=value [NAME=value ...] on its own: left to right, each sees the
    # ones before it.
    def assign_all(cmd, core, cwd)
      core.each { |w| assign(expand_word(w, cwd), cwd) } unless isolated?(cmd)
      cwd
    end

    def for_loop?(core)
      core[0]&.raw == "for" && core[1]&.value&.match?(NAME) && core[2]&.raw == "in"
    end

    # for NAME in WORDS: NAME holds the words joined (one word: that word), so
    # a message or directory given as the only item resolves.
    def for_loop(core, cwd)
      items = expand_words(core[3..], cwd)
      set_var(core[1].value, items.map(&:value).join(" "),
              items.flat_map { |w| word_extras(w, cwd) })
      cwd
    end

    # export / declare / typeset / local / readonly NAME=value ... (-x exports).
    def declare(words, cwd, export)
      words[1..].each do |w|
        v = w.value
        if w.raw.match?(ASSIGNMENT)
          assign(w, cwd, export)
        elsif v.start_with?("-", "+")
          export ||= v.start_with?("-") && v.include?("x")
        elsif export && @vars[v]
          set_var(v, @vars[v].text, @vars[v].extras, exported: true)
        end
      end
    end

    # read [-r] [-d DELIM] NAME... from a heredoc, here-string or `< file`.
    def read_into(cmd, words, cwd)
      delim = "\n"
      i = 1
      while i < words.size
        o = words[i].value
        break unless o.start_with?("-") && o.length > 1

        i += 1
        break if o == "--"

        o[1..].each_char.with_index do |ch, j|
          next unless READ_VALUED.include?(ch)

          value = o[(j + 2)..].to_s
          if value.empty?
            value = words[i]&.value.to_s
            i += 1
          end
          delim = value.empty? ? "\0" : value[0] if ch == "d"
          break
        end
      end
      names = words[i..].to_a.map(&:value).select { |n| n.match?(NAME) }
      names = ["REPLY"] if names.empty?
      text, _source, files = stdin_of(cmd, cwd)
      return if text.nil? && files.empty?

      value = text ? text.split(delim, 2).first.to_s : ""
      extras = files.map { |path| [:file, path] }
      names.each { |n| set_var(n, value, extras) }
    end

    # printf -v NAME FORMAT ARGS: NAME holds the format and args joined.
    def printf_into(words, cwd)
      return unless words[1]&.value == "-v" && words[2]&.value&.match?(NAME)

      args = words[3..]
      args = args.drop(1) if args.first&.value == "--"
      set_var(words[2].value, args.map(&:value).join(" "),
              args.flat_map { |w| word_extras(w, cwd) })
    end

    # ---- prefixes and wrappers -------------------------------------------

    # Drops reserved words, VAR=value assignments and exec wrappers; returns
    # [remaining words, directory the command runs in, {NAME => value} set
    # for it by assignments and `env`].
    def strip_prefix(words, dir)
      ws = words.dup
      env = {}
      until ws.empty?
        w = ws.first
        v = w.value
        if w.raw == v && RESERVED_SKIP.include?(v)
          ws.shift
          next
        end
        if w.raw.match?(ASSIGNMENT)
          add_env(env, ws.shift)
          next
        end
        return [[], dir, env] if w.raw == v && RESERVED_STOP.include?(v)

        case command_name(w)
        when "env"
          ws.shift
          dir = skip_env(ws, dir, env)
        when "command"
          ws.shift
          return [[], dir, env] unless skip_command_options(ws)
        when "nohup", "noglob", "nocorrect", "builtin" then ws.shift
        when "exec"
          ws.shift
          skip_options(ws, %w[-a])
        when "time"
          ws.shift
          skip_options(ws, %w[-f -o --format --output])
        when "nice"
          ws.shift
          skip_options(ws, %w[-n --adjustment])
        when "timeout"
          ws.shift
          skip_options(ws, %w[-s -k --signal --kill-after])
          ws.shift # the duration
        when "su", "runuser"
          name = command_name(ws.shift)
          dir = unwrap_su(ws, dir, runuser: name == "runuser")
        when "flock"
          ws.shift
          unwrap_flock(ws)
        when "xargs"
          ws.shift
          unwrap_xargs(ws)
        when "script"
          ws.shift
          unwrap_script(ws)
        when "sudo"
          ws.shift
          dir = skip_sudo(ws, dir, env)
        else
          return [ws, dir, env]
        end
      end
      [ws, dir, env]
    end

    def add_env(env, word)
      name, text, = assignment(word)
      env[name] = text if name
    end

    def skip_options(ws, valued)
      while (o = ws.first&.value) && o.start_with?("-") && o.length > 1
        ws.shift
        return if o == "--"

        ws.shift if valued.include?(o)
      end
    end

    # `command -v git` / `command -V git` only looks git up.
    def skip_command_options(ws)
      while (o = ws.first&.value) && o.start_with?("-") && o.length > 1
        ws.shift
        return true if o == "--"
        return false if o.match?(/[vV]/)
      end
      true
    end

    def skip_env(ws, dir, env)
      while (w = ws.first)
        o = w.value
        if o == "--"
          ws.shift
          break
        elsif ["-u", "--unset"].include?(o)
          ws.shift(2)
        elsif ["-C", "--chdir"].include?(o)
          ws.shift
          target = ws.shift
          dir = target && resolve_path(dir, target.value, target.raw)
        elsif o.start_with?("--chdir=")
          ws.shift
          dir = resolve_path(dir, o.delete_prefix("--chdir="))
        elsif o.start_with?("-C") && o.length > 2
          ws.shift
          dir = resolve_path(dir, o[2..])
        elsif ["-S", "--split-string"].include?(o) || o.start_with?("--split-string=") || o.start_with?("-S")
          ws.shift
          text = if o.include?("=") then o.split("=", 2)[1]
                 elsif o.length > 2 && o.start_with?("-S") then o[2..]
                 else ws.shift&.value.to_s
                 end
          ws.unshift(*Lexer.words(text))
        elsif w.raw.match?(ASSIGNMENT)
          add_env(env, ws.shift)
        elsif o.start_with?("-")
          ws.shift # other flags and `-` (= -i)
        else
          break
        end
      end
      dir
    end

    # The script a shell runs: the -c string, or its stdin for `bash -s` and a
    # bare `bash` (a heredoc / here-string / literal pipe). nil for a script
    # file, which cannot be inspected.
    def shell_script(cmd, words, cwd)
      i = 1
      cflag = false
      sflag = false
      while i < words.size
        o = words[i].value
        if ["--", "-"].include?(o)
          i += 1
          break
        elsif %w[-o +o -O +O --rcfile --init-file].include?(o)
          i += 2
        elsif o.start_with?("--")
          i += 1
        elsif o.match?(/\A[-+][A-Za-z]+\z/)
          cflag ||= o.start_with?("-") && o.include?("c")
          sflag ||= o.start_with?("-") && o.include?("s")
          i += o.match?(/[oO]/) ? 2 : 1
        else
          break
        end
      end
      return words[i]&.value if cflag
      return nil unless sflag || i >= words.size

      stdin_of(cmd, cwd)[0]
    end

    # ---- git --------------------------------------------------------------

    # remote: the call runs on another host / root (ssh, docker ...), so -C and
    # --work-tree name directories there and dir stays nil.
    def git_invocation(cmd, words, dir, cwd, env, remote: false)
      globals = []
      sub = nil
      work_tree = nil # [value, raw]
      i = 1
      while i < words.size
        o = words[i].value
        if GIT_META.key?(o)
          sub = GIT_META[o]
          i += 1
          break
        elsif GIT_VALUED.include?(o)
          val = words[i + 1]
          globals << [o, val&.value]
          dir = resolve_path(dir, val.value, val.raw) if o == "-C" && val && !val.value.empty? && !remote
          work_tree = [val.value, val.raw] if o == "--work-tree" && val
          i += 2
        elsif o.start_with?("-")
          name, eq, val = o.partition("=")
          globals << [name, eq.empty? ? nil : val]
          work_tree = [val, words[i].raw] if name == "--work-tree" && !eq.empty?
          i += 1
        else
          sub = o
          i += 1
          break
        end
      end
      work_tree ||= [env["GIT_WORK_TREE"], env["GIT_WORK_TREE"]] if env.key?("GIT_WORK_TREE")
      text, source, files = stdin_of(cmd, cwd)
      args = sub ? words[i..] : []
      Invocation.new(dir: dir, globals: globals, subcommand: sub,
                     args: args.map(&:value), arg_extras: args.map { |w| word_extras(w, cwd) },
                     env: env, work_tree: work_tree && !remote ? resolve_path(dir, *work_tree) : nil,
                     stdin: text, stdin_source: source, stdin_files: files,
                     fallback: false, raw: nil)
    end

    # ---- stdin and literal output -----------------------------------------

    # [text, source, files] for what reaches fd 0 of cmd. Redirections are
    # resolved against the shell's cwd (not env -C / git -C).
    def stdin_of(cmd, cwd)
      redir = cmd.redirs.reverse.find { |r| (r.fd.nil? || r.fd == "0") && STDIN_OPS.include?(r.op) }
      if redir
        return [redir.body.to_s, :heredoc, []] if heredoc?(redir)

        if redir.op == "<" && process_substitution?(redir.target)
          out = subst_output(redir.target.substs.first, cwd) # `< <(printf ...)`
          return out ? [out.text, :process, out.files] : [nil, :process, []]
        end

        target = expand_word(redir.target, cwd)
        return ["#{target.value}\n", :herestring, []] if redir.op == "<<<"

        path = path_key(cwd, target.value, target.raw)
        return [nil, :file, path ? [path] : []]
      end
      prev = cmd.pipe_prev
      return [nil, nil, []] if prev.nil?
      return [nil, :pipe_unknown, []] if prev == :unknown

      out = literal_output(prev, cwd)
      out ? [out.text, :pipe, out.files] : [nil, :pipe_unknown, []]
    end

    # The Output a command writes to stdout when that is literal in the
    # command (see the header), or nil when unknown.
    def literal_output(cmd, cwd)
      return cmd.group if cmd.group

      words, dir = strip_prefix(expand_words(cmd.words, cwd), cwd)
      return nil if words.empty?

      args = words[1..].map(&:value)
      case command_name(words[0])
      when "echo"
        args.shift while args.first&.match?(/\A-[neE]+\z/)
        Output.new("#{args.join(' ')}\n", [])
      when "printf"
        return nil if args.first == "-v"

        args.shift if args.first == "--"
        Output.new(args.join(" "), [])
      when "cat" then cat_output(cmd, words[1..].reject { |w| w.value.start_with?("-") }, dir, cwd)
      when "tee" then passthrough(cmd, cwd)
      end
    end

    # cat FILE...: the files it copies, and the literal output of a <(...)
    # among them.
    def cat_output(cmd, files, dir, cwd)
      return passthrough(cmd, cwd) if files.empty?

      text = nil
      paths = []
      files.each do |w|
        if process_substitution?(w)
          out = subst_output(w.substs.first, cwd)
          next unless out

          text = text.to_s + out.text.to_s if out.text
          paths.concat(out.files)
        else
          path = path_key(dir, w.value, w.raw)
          paths << path if path
        end
      end
      Output.new(text, paths)
    end

    # cat with no file / tee: stdout is whatever reaches stdin.
    def passthrough(cmd, cwd)
      text, _source, files = stdin_of(cmd, cwd)
      text.nil? && files.empty? ? nil : Output.new(text, files)
    end

    # Literal output redirected into a file (`> f`, `>> f`, `tee f`), keyed by
    # path_key.
    def record_writes(cmd, cwd)
      targets = cmd.redirs.select { |r| [nil, "1", "&"].include?(r.fd) && WRITE_OPS.include?(r.op) }
                   .map { |r| expand_word(r.target, cwd) }
                   .map { |t| path_key(cwd, t.value, t.raw) }.compact
      words, dir = strip_prefix(expand_words(cmd.words, cwd), cwd)
      if words.first && command_name(words.first) == "tee"
        targets += words[1..].reject { |w| w.value.start_with?("-") }
                             .map { |w| path_key(dir, w.value, w.raw) }.compact
      end
      return if targets.empty?

      text = literal_output(cmd, cwd)&.text
      return unless text

      targets.each { |t| (@writes[t] ||= []) << text }
    end
  end
end
