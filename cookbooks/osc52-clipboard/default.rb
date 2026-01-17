# frozen_string_literal: true

# OSC 52 clipboard support for transparent copy/paste over SSH/mosh/tmux
# Overrides pbcopy/pbpaste with OSC 52-aware versions

add_profile "osc52-clipboard" do
  priority 50
  bash_content <<~'EOM'
    # OSC 52 clipboard functions
    # Uses OSC 52 when in SSH/mosh session, native pbcopy/pbpaste otherwise

    function pbcopy() {
      if [[ -n "$SSH_CONNECTION" || -n "$SSH_CLIENT" || -n "$SSH_TTY" ]]; then
        local input
        input=$(cat)
        local encoded
        encoded=$(printf '%s' "$input" | base64 | tr -d '\n')

        if [[ -n "$TMUX" ]]; then
          # tmux passthrough sequence
          printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$encoded"
        else
          # Standard OSC 52
          printf '\033]52;c;%s\a' "$encoded"
        fi
      else
        # Local: use native pbcopy
        command pbcopy "$@"
      fi
    }

    function pbpaste() {
      if [[ -n "$SSH_CONNECTION" || -n "$SSH_CLIENT" || -n "$SSH_TTY" ]]; then
        # OSC 52 paste is not widely supported for security reasons
        # Fall back to an error message
        echo "OSC 52 paste not supported over SSH" >&2
        return 1
      else
        # Local: use native pbpaste
        command pbpaste "$@"
      fi
    }
  EOM
end
