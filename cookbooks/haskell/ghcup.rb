# frozen_string_literal: true
#
# haskell: the OS-independent ghcup bootstrap. mise has no ghcup plugin, and
# ghcup is itself a toolchain manager, so both platforms run the official
# installer. Included by darwin.rb and linux.rb between their own per-OS
# stack handling, matching the pre-split default.rb's resource order.
remote_file "#{node[:setup][:root]}/ghcup-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/ghcup-install.sh"
end

execute "BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=latest BOOTSTRAP_HASKELL_CABAL_VERSION=latest BOOTSTRAP_HASKELL_INSTALL_STACK=0 BOOTSTRAP_HASKELL_INSTALL_HLS=1 BOOTSTRAP_HASKELL_ADJUST_BASHRC=P #{node[:setup][:root]}/ghcup-install.sh" do
  not_if "which ghcup"
end
