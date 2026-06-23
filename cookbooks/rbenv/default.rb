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

# Make rbenv visible to subsequent cookbooks in the same mitamae run.
# Idempotent — no-op if already on PATH.
prepend_path(
  "#{node[:rbenv][:root]}/bin",
  "#{node[:rbenv][:root]}/shims",
)

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

  # ruby-build is cloned once (the top-level git resource is guarded by
  # `not_if test -d`) and never refreshed afterwards, so an existing checkout
  # can lack the definition for a newly-bumped Ruby version (e.g. 4.0.5 needs
  # ruby-build >= 20260616; a fleet host pinned to 20260503 tops out at 4.0.3).
  # Fast-forward master only when the requested version's definition file is
  # absent — a no-op on fresh clones, which already ship it.
  ruby_build_dir = "#{node[:rbenv][:root]}/plugins/ruby-build"
  execute "update ruby-build for #{version} definition" do
    command "git -C #{ruby_build_dir} pull --ff-only origin master"
    user rbenv_user
    not_if "test -f #{ruby_build_dir}/share/ruby-build/#{version}"
  end

  execute "rbenv-install-#{version}" do
    # Log path is per-user: the same Ruby version is installed both by the
    # root auto-mitamae apply (rbenv_user resolves to root) AND by a user's
    # manual apply (rbenv_user = the login user). /tmp has the sticky bit, so a
    # fixed /tmp/rbenv-install-<version>.log created by whoever runs first is
    # owned by them and the other user cannot truncate it → "Permission denied".
    # Suffixing the user name gives each its own file and removes the collision.
    command "sudo -u #{rbenv_user} -E #{env} #{node[:setup][:root]}/rbenv/rbenv install #{version} > /tmp/rbenv-install-#{version}-#{rbenv_user}.log 2>&1"
    not_if "test -d #{node[:rbenv][:root]}/versions/#{version}"
  end

  # XXX: itamae doesn't support `-n` option
  head_path = "#{node[:rbenv][:root]}/versions/#{headof}"
  execute "ln -sfn #{version} #{head_path}" do
    user rbenv_user
    not_if { File.exist?(head_path) && File.readlink(head_path) == version }
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

# Resolve nproc at apply time so the profile entry is a static literal
# (`export BUNDLE_JOBS=10`) and skips a ~5-10ms subprocess on every
# shell start. The value rarely changes (only on hardware swaps); a
# subsequent `mitamae` apply rewrites it.
ncpu_cmd = node[:platform] == "darwin" ? "/usr/sbin/sysctl -n hw.ncpu" : "nproc"
ncpu = run_command(ncpu_cmd).stdout.strip
add_profile "bundler" do
  bash_content "export BUNDLE_JOBS=#{ncpu}\n"
  fish_content "set -gx BUNDLE_JOBS #{ncpu}\n"
end
