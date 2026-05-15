# frozen_string_literal: true

# darwin: SSH agent management is handled by either the launchd-managed
# system ssh-agent (default macOS) or per-user `IdentityAgent` directives
# in ~/.ssh/config (Mercari Macs route to a secured container socket via
# that mechanism). In both cases, sourcing `eval "$(ssh-agent)"` per shell
# creates an orphan agent that nothing uses and costs 100-300ms at every
# shell start.
#
# linux: per-user agent management varies (systemd-user `ssh-agent.socket`
# vs gnome-keyring vs eval-on-shell). Keep the per-shell eval until linux
# setup is audited separately.
if node[:platform] == "darwin"
  # Remove the stale eval line from prior installs.
  file "#{node[:setup][:root]}/profile.d/10-ssh.sh" do
    action :delete
  end
else
  add_profile "ssh" do
    priority 10
    bash_content <<"EOM"
eval "$(ssh-agent)" > /dev/null
EOM
  end
end
