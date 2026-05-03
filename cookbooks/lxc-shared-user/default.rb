# frozen_string_literal: true
#
# Provision the `shin1ohno` user inside an LXC so SSH from tailnet
# (where Tailscale SSH ACL grants access by username, not by uid)
# resolves to a real account. Cookbook is included from each lxc-*.rb
# entry recipe.
#
# Scope:
#   - create shin1ohno (uid 1000, primary group shin1ohno, secondary sudo)
#   - passwordless sudo via /etc/sudoers.d/shin1ohno
#   - copy /root/.ssh/authorized_keys (cloud-init seeded) into
#     /home/shin1ohno/.ssh/authorized_keys so the per-LXC key the
#     Terraform layer registered also unlocks the user account
#
# This is bootstrap-only. The full per-user dev environment (zsh,
# profile.d, mise, etc.) still runs as root via the lxc-* cookbook
# stack — moving the role install set to shin1ohno is a Phase 5
# follow-up.

return if node[:platform] == "darwin"

uid = node.dig(:lxc_shared_user, :uid) || 1000
gid = node.dig(:lxc_shared_user, :gid) || 1000
username = node.dig(:lxc_shared_user, :name) || "shin1ohno"

execute "create #{username} group" do
  command "sudo groupadd -g #{gid} #{username}"
  not_if "getent group #{username}"
end

execute "create #{username} user" do
  command "sudo useradd -m -s /bin/bash -u #{uid} -g #{gid} -G sudo #{username}"
  not_if "id -u #{username}"
end

execute "passwordless sudo for #{username}" do
  command "echo '#{username} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/#{username} >/dev/null && sudo chmod 440 /etc/sudoers.d/#{username}"
  not_if "test -f /etc/sudoers.d/#{username}"
end

# Mirror root's authorized_keys (set by Terraform cloud-init from SSM)
# into the user's ~/.ssh/. The LXC has no separate key for the user yet;
# tailnet/SSH ACL will gate access at the tailnet layer.
execute "copy authorized_keys to #{username}" do
  command <<~CMD.strip
    sudo install -d -m 700 -o #{username} -g #{username} /home/#{username}/.ssh && \
    sudo install -m 600 -o #{username} -g #{username} /root/.ssh/authorized_keys /home/#{username}/.ssh/authorized_keys
  CMD
  only_if "test -f /root/.ssh/authorized_keys"
  not_if "test -f /home/#{username}/.ssh/authorized_keys"
end
