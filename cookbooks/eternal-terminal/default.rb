# frozen_string_literal: true

# Eternal Terminal (et) - Remote shell that automatically reconnects
# A resilient SSH alternative that maintains connectivity during network changes
# https://github.com/MisterTea/EternalTerminal

# node[:platform] is normalized to "ubuntu" for any debian-family host
# (see cookbooks/functions/default.rb #90), but eternal-terminal has
# distinct install paths per distro: Ubuntu uses Launchpad PPA, Debian
# uses MisterTea's debian-et repo. Probe /etc/os-release ID directly so
# debian hosts (PVE LXC trixie templates) don't fall into the PPA branch
# which fails with "add-apt-repository: not found".
distro_platform = if node[:platform] == "darwin"
  "darwin"
else
  os_release_id = `. /etc/os-release && echo $ID`.strip
  case os_release_id
  when "ubuntu" then "ubuntu"
  when "debian" then "debian"
  when "arch", "manjaro", "endeavouros" then "arch"
  else node[:platform]
  end
end

case distro_platform
when "darwin"
  # MisterTea/EternalTerminal does not publish prebuilt binaries on its
  # GitHub releases (assets is empty on every recent tag). mise's github
  # backend (and the deprecated ubi backend) both fail with
  # "No matching asset found for platform macos-arm64". The brew formula
  # via the official MisterTea/et tap is the only stable darwin install
  # path — keep it.
  execute "brew install eternal-terminal" do
    user node[:setup][:user]
    command "brew install MisterTea/et/et"
    not_if { brew_formula?("et") }
  end

  # Configure and start etserver as a system daemon
  # Apple Silicon Macs use /opt/homebrew, Intel Macs use /usr/local
  etserver_path = node[:homebrew][:machine] == "arm64" ? "/opt/homebrew/bin/etserver" : "/usr/local/bin/etserver"

  directory "#{node[:setup][:root]}/eternal-terminal" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  template "#{node[:setup][:root]}/eternal-terminal/homebrew.mxcl.et.plist" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
    variables(etserver_path: etserver_path)
    source "templates/homebrew.mxcl.et.plist.erb"
  end

  execute "copy etserver launch daemon" do
    user node[:setup][:system_user]
    command "cp #{node[:setup][:root]}/eternal-terminal/homebrew.mxcl.et.plist /Library/LaunchDaemons/homebrew.mxcl.et.plist"
    not_if "test -f /Library/LaunchDaemons/homebrew.mxcl.et.plist"
  end

  execute "set etserver launch daemon ownership" do
    user node[:setup][:system_user]
    command "chown #{node[:setup][:system_user]}:#{node[:setup][:system_group]} /Library/LaunchDaemons/homebrew.mxcl.et.plist"
    only_if "test -f /Library/LaunchDaemons/homebrew.mxcl.et.plist"
  end

  execute "load etserver daemon" do
    user node[:setup][:system_user]
    command "launchctl load -w /Library/LaunchDaemons/homebrew.mxcl.et.plist"
    not_if "launchctl list | grep -q homebrew.mxcl.et"
  end

when "ubuntu"
  # Install via PPA on Ubuntu. add-apt-repository on Ubuntu 24.04+ writes
  # deb822-format `.sources` files instead of legacy `.list`, so the guard
  # must check both extensions — otherwise this re-runs every mitamae apply
  # and trips on transient Launchpad outages even when the PPA is already
  # registered locally.
  execute "add eternal-terminal ppa" do
    command "add-apt-repository -y ppa:jgmath2000/et"
    user node[:setup][:system_user]
    not_if { run_command("grep -rqE 'jgmath2000/(ubuntu/)?et' /etc/apt/sources.list.d/ 2>/dev/null", error: false).exit_status == 0 }
  end

  execute "apt-get update for eternal-terminal" do
    command "apt-get update"
    user node[:setup][:system_user]
    # Skip if `et` is already installed (the PPA was already added in a
    # previous run and the package landed). Ruby File.exist? avoids the
    # PATH-dependent `which et` which fails when wrapped via `sudo -u root`.
    not_if { File.exist?("/usr/bin/et") }
  end

  package "et" do
    user node[:setup][:system_user]
    action :install
    not_if { run_command("dpkg-query -W -f='${Status}' et 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    user node[:setup][:system_user]
    not_if { run_command("systemctl is-active et.service", error: false).exit_status == 0 }
  end

when "debian"
  # Install via custom repository on Debian
  execute "setup eternal-terminal repository" do
    command <<~BASH
      mkdir -m 0755 -p /etc/apt/keyrings
      echo "deb [signed-by=/etc/apt/keyrings/et.gpg] https://mistertea.github.io/debian-et/debian-source/ $(grep VERSION_CODENAME /etc/os-release | cut -d= -f2) main" > /etc/apt/sources.list.d/et.list
      curl -sSL https://github.com/MisterTea/debian-et/raw/master/et.gpg -o /etc/apt/keyrings/et.gpg
    BASH
    not_if "test -f /etc/apt/sources.list.d/et.list"
    user node[:setup][:system_user]
  end

  execute "apt update for eternal-terminal" do
    command "apt-get update"
    not_if "which et"
    user node[:setup][:system_user]
  end

  package "et" do
    user node[:setup][:system_user]
    action :install
    not_if { run_command("dpkg-query -W -f='${Status}' et 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    user node[:setup][:system_user]
    not_if { run_command("systemctl is-active et.service", error: false).exit_status == 0 }
  end

when "arch"
  # Install via pacman on Arch Linux
  package "eternal-terminal" do
    user node[:setup][:system_user]
    action :install
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    user node[:setup][:system_user]
    not_if { run_command("systemctl is-active et.service", error: false).exit_status == 0 }
  end
end

# Add profile entry for documentation
add_profile "eternal-terminal" do
  bash_content <<~BASH
    # Eternal Terminal - Resilient remote shell
    # Usage: et user@hostname
    # Automatically reconnects when network changes
    # Uses SSH for authentication, port 2022 by default
  BASH
  fish_content <<~FISH
    # Eternal Terminal - Resilient remote shell
    # Usage: et user@hostname
    # Automatically reconnects when network changes
    # Uses SSH for authentication, port 2022 by default
  FISH
end
