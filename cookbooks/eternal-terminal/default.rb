# frozen_string_literal: true

# Eternal Terminal (et) - Remote shell that automatically reconnects
# A resilient SSH alternative that maintains connectivity during network changes
# https://github.com/MisterTea/EternalTerminal

case node[:platform]
when "darwin"
  include_cookbook "mise"
  mise_tool "MisterTea/EternalTerminal" do
    backend "ubi"
  end

  # launchd runs daemons as root, which has its own $HOME — point at the
  # absolute user-home mise shim so it resolves regardless of context.
  etserver_path = "#{node[:setup][:home]}/.local/share/mise/shims/etserver"
  plist_path = "/Library/LaunchDaemons/homebrew.mxcl.et.plist"

  # Unload the old daemon if its plist points at the brew install path —
  # re-templating below will then drop in the mise-shim version.
  execute "unload stale etserver daemon (brew path)" do
    user node[:setup][:system_user]
    command "launchctl unload #{plist_path} || true"
    only_if "test -f #{plist_path} && grep -q '/opt/homebrew/bin/etserver\\|/usr/local/bin/etserver' #{plist_path}"
  end

  execute "remove stale etserver plist (brew path)" do
    user node[:setup][:system_user]
    command "rm -f #{plist_path}"
    only_if "test -f #{plist_path} && grep -q '/opt/homebrew/bin/etserver\\|/usr/local/bin/etserver' #{plist_path}"
  end

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
    command "cp #{node[:setup][:root]}/eternal-terminal/homebrew.mxcl.et.plist #{plist_path}"
    not_if "test -f #{plist_path}"
  end

  execute "set etserver launch daemon ownership" do
    user node[:setup][:system_user]
    command "chown #{node[:setup][:system_user]}:#{node[:setup][:system_group]} #{plist_path}"
    only_if "test -f #{plist_path}"
  end

  execute "load etserver daemon" do
    user node[:setup][:system_user]
    command "launchctl load -w #{plist_path}"
    not_if "launchctl list | grep -q homebrew.mxcl.et"
  end

  # Cleanup: remove the brew formula and its tap.
  execute "brew uninstall eternal-terminal (et)" do
    user node[:setup][:user]
    command "brew uninstall et"
    only_if { brew_formula?("et") }
  end

  execute "brew uninstall eternal-terminal (eternal-terminal)" do
    user node[:setup][:user]
    command "brew uninstall eternal-terminal"
    only_if { brew_formula?("eternal-terminal") }
  end

  execute "brew untap MisterTea/et" do
    only_if { brew_tap?("MisterTea/et") }
  end

when "ubuntu"
  # Install via PPA on Ubuntu
  execute "add eternal-terminal ppa" do
    command "add-apt-repository -y ppa:jgmath2000/et"
    not_if "grep -q 'jgmath2000/et' /etc/apt/sources.list.d/*.list 2>/dev/null"
    user node[:setup][:system_user]
  end

  execute "apt-get update for eternal-terminal" do
    command "apt-get update"
    not_if "which et"
    user node[:setup][:system_user]
  end

  package "et" do
    user node[:setup][:system_user]
    action :install
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    not_if "systemctl is-active et.service"
    user node[:setup][:system_user]
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
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    not_if "systemctl is-active et.service"
    user node[:setup][:system_user]
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
    not_if "systemctl is-active et.service"
    user node[:setup][:system_user]
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
