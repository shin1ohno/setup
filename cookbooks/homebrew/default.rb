# frozen_string_literal: true

if run_command("which brew", error: false).exit_status != 0 &&
  FileTest.directory?(node[:homebrew][:prefix]) &&
  File.exist?("#{node[:setup][:root]}/profile.d/10-homebrew.sh")
  MItamae.logger.error("Homebrew is installed but `brew` can't be searched from PATH.")
  MItamae.logger.error("Add `source #{node[:setup][:root]}/profile` to your shell startup files.")
  exit 1
end

remote_file "#{node[:setup][:root]}/homebrew-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

# Hit ENTER automatically when asked to install CLI tools.
# HAVE_SUDO_ACCESS=0 is required to skip `sudo` capability check.
execute "echo | env HAVE_SUDO_ACCESS=0 #{node[:setup][:root]}/homebrew-install.sh" do
  not_if "test -f #{node[:homebrew][:prefix]}/bin/brew"
end

# Populate cached brew lookup files. Reads by `brew_formula?`, `brew_cask?`,
# `brew_tap?` helpers in cookbooks/functions consume these to avoid running
# `brew list` once per cookbook. Refreshed every run so cache entries
# reflect the state at the start of converge.
brew_cache_dir = "#{node[:setup][:root]}/brew-cache"
brew_bin = "#{node[:homebrew][:prefix]}/bin/brew"

directory brew_cache_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "refresh brew formula list cache" do
  user node[:setup][:user]
  command "#{brew_bin} list --formula > #{brew_cache_dir}/formulae.txt"
  only_if "test -x #{brew_bin}"
end

execute "refresh brew cask list cache" do
  user node[:setup][:user]
  command "#{brew_bin} list --cask > #{brew_cache_dir}/casks.txt"
  only_if "test -x #{brew_bin}"
end

execute "refresh brew tap list cache" do
  user node[:setup][:user]
  command "#{brew_bin} tap > #{brew_cache_dir}/taps.txt"
  only_if "test -x #{brew_bin}"
end

include_recipe "environment"
