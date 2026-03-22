# frozen_string_literal: true

# Ensure mise and Node.js are available
include_cookbook "mise"
include_cookbook "nodejs"

mise_tool "takt" do
  backend "npm"
end

# Deploy custom personas
directory "#{node[:setup][:home]}/.takt/personas" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

Dir.glob("#{File.dirname(__FILE__)}/files/personas/*.md").each do |path|
  file_name = File.basename(path)
  remote_file "#{node[:setup][:home]}/.takt/personas/#{file_name}" do
    source "files/personas/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy custom pieces
directory "#{node[:setup][:home]}/.takt/pieces" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

Dir.glob("#{File.dirname(__FILE__)}/files/pieces/*.yaml").each do |path|
  file_name = File.basename(path)
  remote_file "#{node[:setup][:home]}/.takt/pieces/#{file_name}" do
    source "files/pieces/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end
