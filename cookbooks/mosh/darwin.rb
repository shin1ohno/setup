# frozen_string_literal: true

package "mosh"

# Enable SSH environment variables for mosh-server PATH
# SSH non-interactive sessions need /usr/local/bin in PATH
mosh_server_path = "#{node[:homebrew][:prefix]}/bin/mosh-server"

# Create symlink in /usr/local/bin (SIP prevents /usr/bin)
execute "create mosh-server symlink" do
  command "ln -sf #{mosh_server_path} /usr/local/bin/mosh-server"
  user node[:setup][:system_user]
  only_if "test -f #{mosh_server_path}"
  not_if "test -L /usr/local/bin/mosh-server"
end

# Enable PermitUserEnvironment in sshd_config
execute "enable sshd PermitUserEnvironment" do
  command "sed -i '' 's/^#PermitUserEnvironment no/PermitUserEnvironment yes/' /etc/ssh/sshd_config"
  user node[:setup][:system_user]
  only_if "grep -q '^#PermitUserEnvironment no' /etc/ssh/sshd_config"
end

# Create ~/.ssh/environment with PATH including /usr/local/bin
directory "#{node[:setup][:home]}/.ssh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "700"
end

file "#{node[:setup][:home]}/.ssh/environment" do
  content "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "600"
  not_if "test -f #{node[:setup][:home]}/.ssh/environment && grep -q '/usr/local/bin' #{node[:setup][:home]}/.ssh/environment"
end

# Enable Remote Login (SSH) - required for mosh connections.
# macOS Ventura+ requires Full Disk Access for `systemsetup -setremotelogin`,
# which mitamae's invoking shell does not have. Skip the toggle and emit a
# one-line guidance message when remote login is currently off — the user
# enables it via System Settings → General → Sharing → Remote Login (one
# click, persists across mitamae runs).
local_ruby_block "check remote login for mosh" do
  block do
    MItamae.logger.warn("=" * 60)
    MItamae.logger.warn("Remote Login is OFF. Enable it manually:")
    MItamae.logger.warn("  System Settings → General → Sharing → Remote Login")
    MItamae.logger.warn("(macOS Ventura+ requires Full Disk Access for CLI toggle)")
    MItamae.logger.warn("=" * 60)
  end
  only_if "systemsetup -getremotelogin 2>/dev/null | grep -q 'Off'"
end

# Add mosh-server to firewall allow list
execute "add mosh-server to firewall" do
  command "/usr/libexec/ApplicationFirewall/socketfilterfw --add #{mosh_server_path}"
  user node[:setup][:system_user]
  only_if "test -f #{mosh_server_path}"
  not_if "/usr/libexec/ApplicationFirewall/socketfilterfw --listapps | grep -q mosh-server"
end

execute "unblock mosh-server in firewall" do
  command "/usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp #{mosh_server_path}"
  user node[:setup][:system_user]
  only_if "test -f #{mosh_server_path}"
end
