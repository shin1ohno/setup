if run_command('which brew', error: false).exit_status != 0 &&
  FileTest.directory?(node[:homebrew][:prefix]) &&
  FileTest.exist?("#{node[:setup][:root]}/profile.d/10-homebrew.sh")
  MItamae.logger.error("Homebrew is installed but `brew` can't be searched from PATH.")
  MItamae.logger.error("Add `source #{node[:setup][:root]}/profile` to your shell startup files.")
  exit 1
end

remote_file "#{node[:setup][:root]}/homebrew-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  source 'files/install.sh'
end

# Hit ENTER automatically when asked to install CLI tools.
# HAVE_SUDO_ACCESS=0 is required to skip `sudo` capability check.
execute "echo | env HAVE_SUDO_ACCESS=0 #{node[:setup][:root]}/homebrew-install.sh" do
  not_if "test -f #{node[:homebrew][:prefix]}/bin/brew"
end

include_recipe 'environment'
