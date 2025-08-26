# frozen_string_literal: true

# tmux installation using mise
# Terminal multiplexer

# Ensure mise is installed
include_cookbook "mise"

# Install tmux using mise
execute "$HOME/.local/bin/mise install tmux@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list tmux | grep -q 'tmux'"
end

# Set tmux as globally available
execute "$HOME/.local/bin/mise use --global tmux@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list tmux | grep -q '\\* '"
end

