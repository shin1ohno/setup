# frozen_string_literal: true

# Deploy agents
directory "#{node[:setup][:home]}/.claude/agents" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(mitamae-validator.md researcher.md session-retrospective.md claude-docs-researcher.md domain-researcher.md service-health-monitor.md infra-investigator.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/agents/#{file_name}" do
    source "files/agents/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end


# Retired agent definitions.
file "#{node[:setup][:home]}/.claude/agents/code-reviewer.md" do
  action :delete
end

file "#{node[:setup][:home]}/.claude/agents/security-reviewer.md" do
  action :delete
end
