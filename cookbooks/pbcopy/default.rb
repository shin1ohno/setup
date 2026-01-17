# frozen_string_literal: true

# OSC 52 clipboard support for Linux (pbcopy/pbpaste compatible)
# Works over SSH and in headless environments when terminal supports OSC 52

return unless node[:platform] != "darwin"

add_profile "pbcopy" do
  bash_content <<-'BASH'
  # pbcopy using OSC 52 escape sequence
  pbcopy() {
    local input
    if [[ -p /dev/stdin ]]; then
      input=$(cat)
    else
      input="$1"
    fi
    printf "\033]52;c;%s\a" "$(printf "%s" "$input" | base64)"
  }
  BASH
end
