include_cookbook "mise"

execute "$HOME/.local/bin/mise install ripgrep@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list ripgrep | grep -q 'ripgrep'"
end

execute "$HOME/.local/bin/mise use --global ripgrep@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list ripgrep | grep -q '\\* '"
end
