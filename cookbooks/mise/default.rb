# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/mise-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "sh #{node[:setup][:root]}/mise-install.sh" do
  not_if "which mise"
end

add_profile "mise" do
  bash_content <<~EOS
    # mise-en-place tool version manager
    ~/.local/bin/mise activate zsh | source
  EOS
  fish_content <<~FISH
    # mise-en-place tool version manager
    ~/.local/bin/mise activate fish | source
  FISH
end
