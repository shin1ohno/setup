# frozen_string_literal: true

# Terminal image viewers
# imgcat - Official iTerm2 utility for displaying images inline
# viu - Fast terminal image viewer with multiple protocol support
# https://iterm2.com/utilities/imgcat
# https://github.com/atanunq/viu

# Ensure mise is installed for viu
include_cookbook "mise"

# Install Rust via mise for cargo packages
execute "install rust via mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise use --global rust@latest"
  not_if "$HOME/.local/bin/mise list | grep -q 'rust'"
end

# Create bin directory if it doesn't exist
directory "#{ENV['HOME']}/.local/bin" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Download imgcat script from iTerm2
execute "download imgcat script" do
  user node[:setup][:user]
  command "curl -fsSL https://iterm2.com/utilities/imgcat -o #{ENV['HOME']}/.local/bin/imgcat && chmod +x #{ENV['HOME']}/.local/bin/imgcat"
  not_if "test -f #{ENV['HOME']}/.local/bin/imgcat"
end

# Install viu using mise cargo backend
execute "install viu via mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise use --global cargo:viu@latest"
  not_if "$HOME/.local/bin/mise list | grep -q 'cargo:viu'"
end

# Add profile entry for documentation
add_profile "imgcat" do
  bash_content <<~BASH
    # Terminal image viewers

    # imgcat - Display images inline in iTerm2
    # Usage: imgcat image.png
    # Supports: PNG, JPEG, GIF, and more
    # Works with iTerm2 and tmux

    # viu - Fast terminal image viewer
    # Usage: viu image.png
    # Supports: iTerm2, Kitty protocols, and Unicode fallback
    # Features: Animated GIFs, transparency, resizing
  BASH
  fish_content <<~FISH
    # Terminal image viewers

    # imgcat - Display images inline in iTerm2
    # Usage: imgcat image.png
    # Supports: PNG, JPEG, GIF, and more
    # Works with iTerm2 and tmux

    # viu - Fast terminal image viewer
    # Usage: viu image.png
    # Supports: iTerm2, Kitty protocols, and Unicode fallback
    # Features: Animated GIFs, transparency, resizing
  FISH
end
