# frozen_string_literal: true

if node[:platform] == "darwin"
  package "haskell-stack"
  package "ghcup"
else
  execute 'curl -sSL https://get.haskellstack.org/ | sh' do
    not_if 'which stack > /dev/null'
  end

  execute "curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh" do
    not_if "which ghcup"
  end
end

