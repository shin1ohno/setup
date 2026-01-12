# frozen_string_literal: true
#
# Cookbook for installing zk - a command-line tool for managing notes with Zettelkasten method
# https://github.com/zk-org/zk

case node[:platform]
when "darwin"
  package "zk"
when "ubuntu", "debian"
  # For Ubuntu/Debian, install from GitHub releases
  # Get the latest version
  latest_version = "v0.15.0" # Fallback version

  # Create directory for binaries if it doesn't exist
  directory "#{node[:setup][:root]}/bin" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  # Download and install zk binary
  execute "download and install zk" do
    command <<-EOM
    curl -L https://github.com/zk-org/zk/releases/download/#{latest_version}/zk-#{latest_version}-linux-amd64.tar.gz -o /tmp/zk.tar.gz
    tar -xzf /tmp/zk.tar.gz -C /tmp
    mv /tmp/zk #{node[:setup][:root]}/bin/zk
    chmod +x #{node[:setup][:root]}/bin/zk
    rm /tmp/zk.tar.gz
    EOM
    not_if "test -x #{node[:setup][:root]}/bin/zk"
  end
when "arch"
  # For Arch Linux, try to install from AUR
  package "zk" do
    user node[:setup][:system_user]
  end
else
  # Generic installation for other platforms
  # Create directory for binaries if it doesn't exist
  directory "#{node[:setup][:root]}/bin" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  # Download and install zk binary
  execute "download and install zk" do
    command <<-EOM
    curl -L https://github.com/zk-org/zk/releases/download/v0.15.0/zk-v0.15.0-linux-amd64.tar.gz -o /tmp/zk.tar.gz
    tar -xzf /tmp/zk.tar.gz -C /tmp
    mv /tmp/zk #{node[:setup][:root]}/bin/zk
    chmod +x #{node[:setup][:root]}/bin/zk
    rm /tmp/zk.tar.gz
    EOM
    not_if "test -x #{node[:setup][:root]}/bin/zk"
  end
# Create initial zk config directory
  directory "#{ENV["HOME"]}/.config/zk" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  # Create a basic config file if it doesn't exist
  file "#{ENV["HOME"]}/.config/zk/config.toml" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    content <<-EOM
  # zk configuration file
  [note]
  # Default location for new notes
  dir = "~/notes"

  # Default filename format for new notes
  # Available variables: {{id}}, {{title}}, {{format}}
  filename = "{{id}}-{{title}}.md"

  # Default format for note IDs
  id-format = "%Y%m%d%H%M"
    
  # Default editor command
  editor = "nvim"

  [format.markdown]
  # Elements used when formatting notes
  link-format = "[[{{id}}]]"
  link-format-with-title = "[[{{id}}|{{title}}]]"
  EOM
    not_if "test -f #{ENV["HOME"]}/.config/zk/config.toml"
  end
end
