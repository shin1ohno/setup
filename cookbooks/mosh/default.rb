# frozen_string_literal: true

package "mosh" do
  user (node[:platform] == "darwin" ? node[:user] : "root")
end

if node[:platform] == "darwin"
  # Enable SSH environment variables for mosh-server PATH
  # SSH non-interactive sessions need /usr/local/bin in PATH
  mosh_server_path = "#{node[:homebrew][:prefix]}/bin/mosh-server"

  # Create symlink in /usr/local/bin (SIP prevents /usr/bin)
  execute "create mosh-server symlink" do
    command "ln -sf #{mosh_server_path} /usr/local/bin/mosh-server"
    user "root"
    only_if "test -f #{mosh_server_path}"
    not_if "test -L /usr/local/bin/mosh-server"
  end

  # Enable PermitUserEnvironment in sshd_config
  execute "enable sshd PermitUserEnvironment" do
    command "sed -i '' 's/^#PermitUserEnvironment no/PermitUserEnvironment yes/' /etc/ssh/sshd_config"
    user "root"
    only_if "grep -q '^#PermitUserEnvironment no' /etc/ssh/sshd_config"
  end

  # Create ~/.ssh/environment with PATH including /usr/local/bin
  directory "#{ENV['HOME']}/.ssh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "700"
  end

  file "#{ENV['HOME']}/.ssh/environment" do
    content "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "600"
    not_if "test -f #{ENV['HOME']}/.ssh/environment && grep -q '/usr/local/bin' #{ENV['HOME']}/.ssh/environment"
  end

  # Enable Remote Login (SSH) - required for mosh connections
  execute "enable remote login for mosh" do
    command "systemsetup -setremotelogin on"
    user "root"
    not_if "systemsetup -getremotelogin | grep -q 'On'"
  end

  # Add mosh-server to firewall allow list
  execute "add mosh-server to firewall" do
    command "/usr/libexec/ApplicationFirewall/socketfilterfw --add #{mosh_server_path}"
    user "root"
    only_if "test -f #{mosh_server_path}"
    not_if "/usr/libexec/ApplicationFirewall/socketfilterfw --listapps | grep -q mosh-server"
  end

  execute "unblock mosh-server in firewall" do
    command "/usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp #{mosh_server_path}"
    user "root"
    only_if "test -f #{mosh_server_path}"
  end
end
