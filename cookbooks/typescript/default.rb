# Ensure mise-managed Node.js is available
include_cookbook "nodejs"

execute "export PATH=$HOME/.local/share/mise/shims:$PATH && npm install -g typescript@beta" do
  user node[:setup][:user]
  not_if "which tsc"
end
