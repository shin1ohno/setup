# frozen_string_literal: true

case node[:platform]
when "darwin"
  package "mosh"
else
  package "mosh" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' mosh 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end

  # mosh-server refuses to start unless a UTF-8 native locale is
  # available; LXC images and minimal Debian/Ubuntu installs ship with
  # only C / C.utf8 / POSIX. Enable en_US.UTF-8 + ja_JP.UTF-8 in
  # /etc/locale.gen and run locale-gen. Symptom on a missing locale
  # is Blink/iTerm "NoMoshServerArgs - Did not find mosh server
  # startup message" because mosh-server's locale error is printed
  # before MOSH CONNECT and the client treats the prefix as garbage.
  execute "enable UTF-8 locales for mosh-server" do
    command <<~BASH
      sed -i \
        -e 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
        -e 's/^# ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' \
        /etc/locale.gen
      /usr/sbin/locale-gen
    BASH
    user node[:setup][:system_user]
    not_if { run_command("locale -a 2>/dev/null | grep -qx en_US.utf8", error: false).exit_status == 0 }
  end
end

if node[:platform] == "darwin"
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

  # Enable Remote Login (SSH) - required for mosh connections
  execute "enable remote login for mosh" do
    command "systemsetup -setremotelogin on"
    user node[:setup][:system_user]
    not_if "systemsetup -getremotelogin | grep -q 'On'"
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
end
