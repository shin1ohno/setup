# frozen_string_literal: true

if node[:platform] == "darwin"
  include_cookbook "mise"
  mise_tool "commercialhaskell/stack" do
    backend "github"
  end
  package "haskell-stack" do
    action :remove
    only_if { brew_formula?("haskell-stack") }
  end
end

# Bootstrap ghcup via the official installer on every platform — mise has no
# ghcup plugin, and ghcup is itself a toolchain manager.
remote_file "#{node[:setup][:root]}/ghcup-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/ghcup-install.sh"
end

execute "BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=latest BOOTSTRAP_HASKELL_CABAL_VERSION=latest BOOTSTRAP_HASKELL_INSTALL_STACK=0 BOOTSTRAP_HASKELL_INSTALL_HLS=1 BOOTSTRAP_HASKELL_ADJUST_BASHRC=P #{node[:setup][:root]}/ghcup-install.sh" do
  not_if "which ghcup"
end

if node[:platform] == "darwin"
  package "ghcup" do
    action :remove
    only_if { brew_formula?("ghcup") }
  end
end

if node[:platform] != "darwin"
  remote_file "#{node[:setup][:root]}/stack-install.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/stack-install.sh"
  end

  execute "#{node[:setup][:root]}/stack-install.sh" do
    not_if "which stack > /dev/null"
  end
end

add_profile "ghcup" do
  bash_content <<'EOM'
[ -f "${HOME}/.ghcup/env" ] && . "${HOME}/.ghcup/env" # ghcup-env
EOM
end

