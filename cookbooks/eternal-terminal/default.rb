# frozen_string_literal: true

# Eternal Terminal (et) - Remote shell that automatically reconnects
# A resilient SSH alternative that maintains connectivity during network changes
# https://github.com/MisterTea/EternalTerminal

case node[:platform]
when "darwin"
  # Install via Homebrew on macOS
  execute "brew install eternal-terminal" do
    user node[:setup][:user]
    command "brew install MisterTea/et/et"
    not_if "brew list --formula | grep -q '^et$'"
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
  # Install via PPA on Ubuntu
  execute "add eternal-terminal ppa" do
    command "add-apt-repository -y ppa:jgmath2000/et"
    not_if "grep -q 'jgmath2000/et' /etc/apt/sources.list.d/*.list 2>/dev/null"
  end

  execute "apt-get update for eternal-terminal" do
    command "apt-get update"
    not_if "which et"
  end

  package "et" do
    action :install
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    not_if "systemctl is-active et.service"
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
  end

  execute "apt update for eternal-terminal" do
    command "apt-get update"
    not_if "which et"
  end

  package "et" do
    action :install
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    not_if "systemctl is-active et.service"
  end

when "arch"
  # Install via pacman on Arch Linux
  package "eternal-terminal" do
    action :install
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    not_if "systemctl is-active et.service"
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
