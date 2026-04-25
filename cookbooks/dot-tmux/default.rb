# frozen_string_literal: true

directory "#{node[:setup][:home]}/.config/tmux/plugins" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Block here until SSH-to-GitHub works — the git pull below clones a private
# repo. On a fresh machine the user needs to add their public key (placed by
# the ssh-keys cookbook) to github.com first.
tmux_git_dir = "#{node[:setup][:home]}/.config/tmux/.git"
require_external_auth(
  tool_name: "GitHub SSH access",
  check_command: "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q 'successfully authenticated'",
  instructions: "Add ~/.ssh/<host>_ed25519.pub to https://github.com/settings/keys, then press Enter.",
  skip_if: -> { File.exist?(tmux_git_dir) },
) do
  execute "Initialise tmux config directory" do
    command <<EOF
      GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' && export GIT_SSH_COMMAND &&\n
      git init &&\n
      git remote add origin git@github.com:shin1ohno/tmux.git &&\n
      git pull --rebase origin main &&\n
      git push --set-upstream origin main
EOF
    cwd "#{node[:setup][:home]}/.config/tmux"
  end
end

execute "Initialise TPM" do
  command <<EOF
  git clone https://github.com/tmux-plugins/tpm #{node[:setup][:home]}/.config/tmux/plugins/tpm && #{node[:setup][:home]}/.config/tmux/plugins/tpm/bin/install_plugins
EOF
  not_if { File.exist? "#{node[:setup][:home]}/.config/tmux/plugins/tpm"}
end

execute "update tmux config" do
  command "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' git pull --rebase origin main || true"
  cwd "#{node[:setup][:home]}/.config/tmux"
  only_if "test -d #{node[:setup][:home]}/.config/tmux/.git"
end
