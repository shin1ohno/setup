# frozen_string_literal: true

if node[:platform] == "darwin"
  package "haskell-stack"
  package "ghcup"
else
  execute 'curl -sSL https://get.haskellstack.org/ | sh' do
    not_if 'which stack > /dev/null'
  end

  execute "curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=latest BOOTSTRAP_HASKELL_CABAL_VERSION=latest BOOTSTRAP_HASKELL_INSTALL_STACK=0 BOOTSTRAP_HASKELL_INSTALL_HLS=1 BOOTSTRAP_HASKELL_ADJUST_BASHRC=P sh" do
    not_if "which ghcup"
  end
  
add_profile "ghcup" do
  bash_content <<'EOM'
    export PATH="~/.ghcup/bin:$PATH"
EOM
end
end

