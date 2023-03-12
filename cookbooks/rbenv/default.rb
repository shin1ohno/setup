# frozen_string_literal: true

node.reverse_merge!(
  rbenv: {
    root: "/usr/share/rbenv",
  },
)

if node[:platform] == "darwin"
  node.reverse_merge!(
    rbenv: {
      ruby_configure_opts: %W[
        --with-gcc=clang CXX=clang++
        --with-out-ext=tk,tk/*
        --with-valgrind
        --with-db-dir=#{node[:homebrew][:prefix]}/opt/berkeley-db
        --with-dbm-dir=#{node[:homebrew][:prefix]}/opt/gdbm --with-dbm-type=gdbm
        --with-gdbm-dir=#{node[:homebrew][:prefix]}/opt/gdbm
        --with-libyaml-dir=#{node[:homebrew][:prefix]}/opt/libyaml
        --with-libffi-dir=#{node[:homebrew][:prefix]}/opt/libffi
        --with-openssl-dir=#{node[:homebrew][:prefix]}/opt/openssl
        --with-readline-dir=#{node[:homebrew][:prefix]}/opt/readline --disable-libedit
        --without-gmp
        --enable-shared
        --enable-pthread
      ].join(" "),
    },
  )
else
  node.reverse_merge!(
    rbenv: {
      ruby_configure_opts: %w[
        --with-out-ext=tk,tk/*
        --with-valgrind
        --disable-install-capi
        --disable-install-doc
        --enable-shared
        --enable-pthread
      ].join(" "),
    },
  )
end

backup_path = "#{node[:rbenv][:root]}-setup-backup-#{Time.now.to_i}"
backup_cond = "test -d #{node[:rbenv][:root]} -a ! -d #{node[:rbenv][:root]}/.git"

local_ruby_block "backup alert" do
  block do
    MItamae.logger.warn(%Q["#{node[:rbenv][:root]}" exists but it is not a rbenv git repository.])
    MItamae.logger.warn(%Q["#{node[:rbenv][:root]}" will be renamed to "#{backup_path}".])
  end
  only_if backup_cond
end

# Back up .rbenv by another rbenv installation. `node[:rbenv][:root]` must be a rbenv repository.
execute "mv #{node[:rbenv][:root]} #{backup_path}" do
  only_if backup_cond
end

git node[:rbenv][:root] do
  repository "https://github.com/rbenv/rbenv.git"
  user node[:setup][:user]
  not_if "test -d #{node[:rbenv][:root]}"
end

# Restore versions, shims and sources to avoid rebuild.
Dir.glob("#{node[:rbenv][:root]}/{versions,shims,sources}").each do |dir|
  execute "mv #{backup_path}/#{File.basename(dir)} #{dir}" do
    only_if "test -d #{backup_path}/#{File.basename(dir)}"
  end
end

include_cookbook "rbenv::commands"

rbenv_user = ENV["SUDO_USER"] || ENV.fetch("USER")
rbenv_group = run_command("id -g -n #{rbenv_user}").stdout.strip
%W[
#{node[:rbenv][:root]}/plugins
  #{node[:rbenv][:root]}/shims
  #{node[:rbenv][:root]}/sources
  #{node[:rbenv][:root]}/versions
].each do |path|
  directory path do
    owner rbenv_user
    group rbenv_group
    mode "755"
  end
end

file "#{node[:rbenv][:root]}/version" do
  content "system"
  owner rbenv_user
  group rbenv_group
  not_if "test -f #{node[:rbenv][:root]}/version"
end

git "#{node[:rbenv][:root]}/plugins/ruby-build" do
  repository "https://github.com/rbenv/ruby-build.git"
  user rbenv_user
  not_if "test -d #{node[:rbenv][:root]}/plugins/ruby-build"
end

define :rbenv, version: nil, headof: nil, bundler: nil, env: nil do
  version = params[:version] || params[:name]
  headof = params[:headof] || version[0, 3]
  bundler_version = params[:bundler]
  env =
    if params[:env]
      "env #{params[:env]}"
    else
      ""
    end

  execute "rbenv-install-#{version}" do
    command "sudo -u #{rbenv_user} -E #{env} #{node[:setup][:root]}/rbenv/rbenv install #{version} > /tmp/rbenv-install-#{version}.log 2>&1"
    not_if "test -d #{node[:rbenv][:root]}/versions/#{version}"
  end

  # XXX: itamae doesn't support `-n` option
  head_path = "#{node[:rbenv][:root]}/versions/#{headof}"
  execute "ln -sfn #{version} #{head_path}" do
    user rbenv_user
    not_if { FileTest.exist?(head_path) && File.readlink(head_path) == version }
  end

  execute "#{node[:rbenv][:root]}/bin/rbenv global #{node[:rbenv][:global_version]}" do
    not_if { node[:rbenv][:global_version].nil? }
    only_if "test $(#{node[:rbenv][:root]}/bin/rbenv global) != #{node[:rbenv][:global_version]}"
  end

  gems = node[:rbenv][:global_gems] || ["bundler"]

  gems.each do |g|
    gem_package g do
      user rbenv_user
      gem_binary %W[env PATH=#{node[:setup][:root]}/rbenv:/usr/bin:/bin RBENV_VERSION=#{version} RBENV_ROOT=#{node[:rbenv][:root]} rbenv exec gem]
      if bundler_version
        version bundler_version
      end
    end
  end
end

add_profile "bundler" do
  if node[:platform] == "darwin"
    bash_content "export BUNDLE_JOBS=$(/usr/sbin/sysctl -n hw.ncpu)\n"
    fish_content "set -gx BUNDLE_JOBS (sysctl -n hw.ncpu)\n"
  else
    bash_content "export BUNDLE_JOBS=$(nproc)\n"
    fish_content "set -gx BUNDLE_JOBS (nproc)\n"
  end
end
