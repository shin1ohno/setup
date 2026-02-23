# frozen_string_literal: true

# Go installation using mise
# This cookbook replaces gvm-based Go management with mise

# Ensure mise is installed
include_cookbook "mise"

# Install build dependencies for Ubuntu
if node[:platform] == "ubuntu"
  %w(curl git mercurial make binutils bison gcc build-essential).each do |pkg|
    package pkg do
      user node[:setup][:system_user]
    end
  end
end

mise_tool "go" do
  versions node[:go][:versions]
end

# Add Go environment setup
add_profile "golang" do
  bash_content <<~BASH
    # Go managed by mise
    export PATH="$HOME/.local/share/mise/shims:$PATH"
    export GOPATH="$HOME/go"
    export PATH="$GOPATH/bin:$PATH"
  BASH
  priority 70
end
