# frozen_string_literal: true

# Ensure rust and cargo are available
# Include rust cookbook in the role that includes this cookbook

directory "#{ENV["HOME"]}/.cargo/bin" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  not_if "test -d #{ENV["HOME"]}/.cargo/bin"
end

# Directory for Claude Desktop MCP configuration
directory "#{ENV["HOME"]}/.config/claude" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Install tfmcp using cargo
execute "Install tfmcp using cargo" do
  command "$HOME/.cargo/bin/cargo install tfmcp --locked"
  user node[:setup][:user]
  not_if "which tfmcp || test -f $HOME/.cargo/bin/tfmcp"
end

