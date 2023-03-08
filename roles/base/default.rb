# frozen_string_literal: true
[
  node[:setup][:root],
  "#{node[:setup][:root]}/profile.d",
  "#{node[:setup][:root]}/bin",
].each do |dir|
  directory dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode '755'
    action :create
  end
end

template "#{node[:setup][:root]}/profile" do
  owner node[:setup][:uer]
  group node[:setup][:group]
  mode '644'
  source 'templates/profile'
end

if node[:platform] == 'darwin'
  include_cookbook 'homebrew'
end

include_cookbook 'build-essential'

include_cookbook 'jdk'

include_cookbook 'git'

include_cookbook 'terraform'

# for ruby
include_cookbook 'gdbm'
include_cookbook 'berkeley-db'
include_cookbook 'libffi'
include_cookbook 'libyaml'
include_cookbook 'openssl'
include_cookbook 'readline'
include_cookbook 'ncurses'
include_cookbook 'zlib'
include_cookbook 'autoconf'
include_cookbook 'envchain'
include_cookbook 'awscli'
include_cookbook 'rbenv'

include_cookbook "nodejs"
