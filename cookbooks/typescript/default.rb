# Ensure mise-managed Node.js is available
include_cookbook "nodejs"

execute "install typescript via mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise use --global npm:typescript@beta"
  not_if "$HOME/.local/bin/mise list | grep -q 'npm:typescript'"
end
