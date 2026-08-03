# frozen_string_literal: true
#
# zk — command-line note manager for the Zettelkasten method.
# https://github.com/zk-org/zk
#
# linux half: unpack the upstream release tarball into the setup bin dir. mise
# has no core-registry entry for zk and the aqua backend darwin.rb uses is not
# wired up here, so the prebuilt linux-amd64 asset is the install path.
#
# Pinned release — bump to upgrade (the `not_if` below is existence-only, so an
# upgrade needs the old binary removed first).
zk_version = "v0.15.0"

directory "#{node[:setup][:root]}/bin" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "download and install zk" do
  command <<-EOM
  curl -L https://github.com/zk-org/zk/releases/download/#{zk_version}/zk-#{zk_version}-linux-amd64.tar.gz -o /tmp/zk.tar.gz
  tar -xzf /tmp/zk.tar.gz -C /tmp
  mv /tmp/zk #{node[:setup][:root]}/bin/zk
  chmod +x #{node[:setup][:root]}/bin/zk
  rm /tmp/zk.tar.gz
  EOM
  not_if "test -x #{node[:setup][:root]}/bin/zk"
end
