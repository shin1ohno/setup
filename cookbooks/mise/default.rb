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

execute "$HOME/.local/bin/mise self-update" do
  only_if { File.exists? "$HOME/.local/bin/mise" }
end

add_profile "mise" do
  bash_content <<~EOS
    # mise-en-place tool version manager
    if [ -f "$HOME/.local/bin/mise" ]; then
      eval "$($HOME/.local/bin/mise activate zsh)"
    fi
  EOS
  fish_content <<~FISH
    # mise-en-place tool version manager
    if test -f "$HOME/.local/bin/mise"
      eval ($HOME/.local/bin/mise activate fish)
    end
  FISH
end
