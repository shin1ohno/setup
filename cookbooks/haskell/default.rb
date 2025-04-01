# frozen_string_literal: true

if node[:platform] == "darwin"
  package "haskell-stack"
  package "ghcup"
else
  remote_file "#{node[:setup][:root]}/stack-install.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/stack-install.sh"
  end

  execute "#{node[:setup][:root]}/stack-install.sh" do
    not_if 'which stack > /dev/null'
  end

  remote_file "#{node[:setup][:root]}/ghcup-install.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/ghcup-install.sh"
  end

  execute "BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=latest BOOTSTRAP_HASKELL_CABAL_VERSION=latest BOOTSTRAP_HASKELL_INSTALL_STACK=0 BOOTSTRAP
_HASKELL_INSTALL_HLS=1 BOOTSTRAP_HASKELL_ADJUST_BASHRC=P #{node[:setup][:root]}/ghcup-install.sh" do
    not_if "which ghcup"
  end
  
add_profile "ghcup" do
  bash_content <<'EOM'
    export PATH="$HOME/.ghcup/bin:$PATH"
EOM
end
end

