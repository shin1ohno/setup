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
directory "#{node[:setup][:home]}/.local/bin" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Download imgcat script from iTerm2
execute "download imgcat script" do
  user node[:setup][:user]
  command "curl -fsSL https://iterm2.com/utilities/imgcat -o #{node[:setup][:home]}/.local/bin/imgcat && chmod +x #{node[:setup][:home]}/.local/bin/imgcat"
  not_if "test -f #{node[:setup][:home]}/.local/bin/imgcat"
end

# Install viu using mise cargo backend
execute "install viu via mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise use --global cargo:viu@latest"
  not_if "$HOME/.local/bin/mise list | grep -q 'cargo:viu'"
end

# Delete the prior documentation-only profile entry. Pure comments still
# take ~1-3ms to parse on every shell start; `man imgcat` / `viu --help`
# and the cookbook source remain the documentation channels.
file "#{node[:setup][:root]}/profile.d/50-imgcat.sh" do
  action :delete
end
