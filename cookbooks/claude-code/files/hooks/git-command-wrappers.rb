# frozen_string_literal: true

module GitCommand
  module Wrappers
    # Consume short clusters according to each program's value-taking options.
    # The remainder after the first valued letter belongs to that value.
    def wrapper_options(words, short_values, long_values, optional_short: "")
      options = {}
      while (word = words.first)
        value = word.value
        break unless value.start_with?("-") && value != "-"

        words.shift
        break if value == "--"

        if value.start_with?("--")
          key, equal, attached = value.partition("=")
          options[key] = if !equal.empty?
                           Word.new(attached, attached, [], [], [])
                         elsif long_values.include?(key)
                           words.shift
                         else
                           true
                         end
        else
          letters = value[1..]
          until letters.empty?
            key = letters.slice!(0)
            if optional_short.include?(key)
              options[key] = letters.empty? ? true : Word.new(letters, letters, [], [], [])
              break
            elsif short_values.include?(key)
              options[key] = letters.empty? ? words.shift : Word.new(letters, letters, [], [], [])
              break
            end
            options[key] = true
          end
        end
      end
      options
    end

    def synthetic_word(text)
      Word.new(text, text, [], [], [])
    end

    def shell_words(words, script = nil)
      words.unshift(synthetic_word("-c"), script) if script
      words.unshift(synthetic_word("sh"))
    end

    def unwrap_su(words, dir, runuser: false)
      values = %w[--command --session-command --group --supp-group --shell --user --whitelist-environment]
      options = wrapper_options(words, "cgGsuw", values)
      login = words.first&.value == "-"
      words.shift if login
      # runuser -u USER -- COMMAND differs from its su-compatible mode.
      if runuser && (options["u"] || options["--user"])
        return options["l"] || options["--login"] ? nil : dir
      end
      words.shift if words.first && !words.first.value.start_with?("-") # account
      options.merge!(wrapper_options(words, "cgGsuw", values))
      script = options["c"] || options["--command"] || options["--session-command"]
      shell_words(words, script)
      login || options["l"] || options["--login"] ? nil : dir
    end

    def unwrap_flock(words)
      options = wrapper_options(words, "Ewc", %w[--conflict-exit-code --wait --timeout --command])
      words.shift # lock file or descriptor
      # flock FILE -c SCRIPT also accepts options after its lock operand.
      options.merge!(wrapper_options(words, "Ewc", %w[--conflict-exit-code --wait --timeout --command]))
      script = options["c"] || options["--command"]
      shell_words(words, script) if script
    end

    def unwrap_xargs(words)
      wrapper_options(words, "aEdInLPsRJS", %w[--arg-file --eof --delimiter --max-lines
                                               --max-args --max-procs --max-chars --process-slot-var],
                      optional_short: "eil")
    end

    def unwrap_script(words)
      options = wrapper_options(words, "cIOotT", %w[--command --log-in --log-out --log-io
                                                    --log-timing --logging-format])
      script = options["c"] || options["--command"]
      if script
        words.clear
        shell_words(words, script)
      else
        # BSD script: options, transcript filename, command and its arguments.
        words.shift
      end
    end

    def skip_sudo(words, dir, env)
      options = wrapper_options(words, "ugChprtTUDR",
                                self.class::SUDO_VALUED.grep(/\A--/) + %w[--chdir --chroot])
      if %w[l v V e --list --validate --version --help --edit].any? { |key| options[key] }
        words.clear
        return dir
      end
      dir = nil if options["i"] || options["--login"] || options["R"] || options["--chroot"]
      target = options["D"] || options["--chdir"]
      dir = resolve_path(dir, target.value, target.raw) if target.is_a?(Word)
      add_env(env, words.shift) while words.first && words.first.raw.match?(self.class::ASSIGNMENT)
      shell_words(words) if words.empty? && (options["s"] || options["i"] || options["--shell"] || options["--login"])
      dir
    end

    def find_commands(cmd, words, dir, depth)
      index = 1
      while index < words.size
        if %w[-exec -execdir -ok -okdir].include?(words[index].value)
          unknown_dir = %w[-execdir -okdir].include?(words[index].value)
          index += 1
          last = index
          last += 1 while last < words.size && !%w[; +].include?(words[last].value)
          child = Command.new(words[index...last], cmd.redirs, cmd.pipe_prev, cmd.piped_out, cmd.async)
          finish(child, unknown_dir ? nil : dir, [], depth + 1) if depth < self.class::MAX_DEPTH
          index = last
        end
        index += 1
      end
    end
  end
end
