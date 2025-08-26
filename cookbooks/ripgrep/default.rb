include_cookbook "mise"

execute "mise install ripgrep@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list ripgrep | grep -q 'ripgrep'"
end

execute "mise use --global ripgrep@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list ripgrep | grep -q '\\* '"
end
