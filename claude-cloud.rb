# frozen_string_literal: true

# Opt-in cloud entry: distribute instructions, skills and agent definitions only.
include_recipe "cookbooks/functions/default.rb"

node.reverse_merge!(setup: {
  home: ENV["HOME"],
  root: "#{ENV['HOME']}/.setup_shin1ohno",
  user: ENV["USER"] || run_command("id -un").stdout.strip,
  group: run_command("id -gn").stdout.strip,
})

directory "#{node[:setup][:home]}/.claude" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

include_recipe "cookbooks/claude-code/instructions.rb"
include_recipe "cookbooks/claude-code/skills.rb"
include_recipe "cookbooks/claude-code/agents.rb"
