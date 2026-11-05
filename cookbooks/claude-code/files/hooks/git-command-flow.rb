# frozen_string_literal: true

module GitCommand
  # Project conditional command lists onto bounded execution paths. The main
  # evaluator still owns quoting, substitutions, variables and shell scopes.
  class FlowPaths
    MAX_PATHS = 32
    SEPARATORS = [";", "\n"].freeze

    def initialize(tokens)
      @tokens = tokens
      @index = 0
    end

    def paths
      tree = sequence([])
      raise ParseError, "unsupported conditional syntax" if peek

      project(tree, nil)
    end

    private

    def peek
      token = @tokens[@index]
      return nil unless token
      return token[1] unless token[0] == :word

      word = token[1]
      word.raw == word.value ? word.value : :quoted
    end

    def take
      token = @tokens[@index]
      @index += 1
      token
    end

    def skip_separators
      take while SEPARATORS.include?(peek)
    end

    def sequence(stops)
      nodes = []
      skip_separators
      until peek.nil? || stops.include?(peek)
        nodes << and_or
        break unless SEPARATORS.include?(peek)

        skip_separators
      end
      [:sequence, nodes]
    end

    def and_or
      node = atom
      while ["&&", "||"].include?(peek)
        operator = take[1]
        take while peek == "\n"
        node = [operator, node, atom]
      end
      node
    end

    def atom
      if peek == "if"
        take
        condition = sequence(["then"])
        expect("then")
        yes = sequence(%w[elif else fi])
        no = if peek == "elif"
               # elif has exactly the grammar of a nested if.
               @tokens[@index] = [:word, Word.new("if", "if", [], [], [])]
               atom
             elsif peek == "else"
               take
               branch = sequence(["fi"])
               expect("fi")
               branch
             else
               expect("fi")
               [:sequence, []]
             end
        [:if, condition, yes, no]
      elsif peek == "{"
        take
        node = sequence(["}"])
        expect("}")
        redirected([:brace, node])
      elsif peek == "("
        take
        node = sequence([")"])
        expect(")")
        redirected([:group, node])
      else
        tokens = []
        until peek.nil? || (["&&", "||", ")"] + SEPARATORS).include?(peek) ||
              (tokens.empty? && %w[then elif else fi }].include?(peek))
          tokens << take
        end
        raise ParseError, "empty conditional command" if tokens.empty?

        [:command, tokens]
      end
    end

    def redirected(node)
      redirections = []
      redirections << take while @tokens[@index] && @tokens[@index][0] == :redir
      redirections.empty? ? node : [:redirected, node, redirections]
    end

    def expect(value)
      raise ParseError, "expected #{value}" unless peek == value

      take
    end

    def bounded(paths)
      raise ParseError, "conditional path budget exceeded" if paths.size > MAX_PATHS

      paths
    end

    def join(left, right)
      bounded(left.product(right).map { |a, b| a + [[:op, ";"]] + b })
    end

    def project(node, status)
      kind, a, b, c = node
      case kind
      when :command
        literal = a.select { |type, _| type == :word }.map { |_, word| word.value }
        known = if literal == ["true"] || literal == [":"] then true
                elsif literal == ["false"] then false
                end
        return [] if !status.nil? && !known.nil? && status != known

        # A failed cd does not change the current directory. Other effects,
        # including substitutions containing git calls, must still be visited.
        [[[:outcome, status]] + a]
      when :sequence
        return [[]] if a.empty?

        prefix = a[0...-1].inject([[]]) { |paths, child| join(paths, project(child, nil)) }
        join(prefix, project(a.last, status))
      when :redirected
        project(a, status).map { |path| path + b }
      when :brace
        project(a, status).map do |path|
          [[:word, Word.new("{", "{", [], [], [])]] + path +
            [[:op, ";"], [:word, Word.new("}", "}", [], [], [])]]
        end
      when :group
        project(a, status).map { |path| [[:op, "("]] + path + [[:op, ")"]] }
      when :if
        paths = join(project(a, true), project(b, status)) +
                join(project(a, false), project(c, status))
        bounded(paths)
      when "&&", "||"
        if status.nil?
          bounded(project(node, true) + project(node, false))
        elsif kind == "&&"
          status ? join(project(a, true), project(b, true)) :
            bounded(project(a, false) + join(project(a, true), project(b, false)))
        else
          status ? bounded(project(a, true) + join(project(a, false), project(b, true))) :
            join(project(a, false), project(b, false))
        end
      end
    end
  end
end
