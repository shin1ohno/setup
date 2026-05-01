execute "update_and_install_deps" do
  command "apt-get update && apt-get install -y ca-certificates curl"
  not_if "dpkg -s ca-certificates curl"
  user node[:setup][:system_user]
end

execute "add_docker_gpg_key" do
  command "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -"
  not_if "apt-key list | grep Docker"
  user node[:setup][:system_user]
end

execute "add_docker_repo" do
  command 'add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable"'
  not_if 'grep -R "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d'
  user node[:setup][:system_user]
end

execute "update_package_index" do
  command "apt-get update"
  user node[:setup][:system_user]
  # Skip if /var/cache/apt/pkgcache.bin was refreshed within the last 24h —
  # apt-get update is a network round-trip that delays every mitamae run
  # even when the index is fresh.
  #
  # Proc form (not string) because mitamae auto-wraps string not_if commands
  # with `sudo -u <user>` when the resource has a `user` attribute, and that
  # wrap silently fails to non-zero on this host — bypassing the guard.
  # Procs evaluate in mitamae's own Ruby context (no user wrap).
  not_if { run_command("find /var/cache/apt/pkgcache.bin -mmin -1440 2>/dev/null | grep -q .", error: false).exit_status == 0 }
end

%w(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin).each do |pkg|
  package pkg do
    action :install
    user node[:setup][:system_user]
  end
end

# Start and enable Docker service
service "docker" do
  action [:start, :enable]
  user node[:setup][:system_user]
end

# Add the setup user to the docker group for rootless access
execute "usermod -aG docker #{node[:setup][:user]}" do
  user node[:setup][:system_user]
  not_if "id -nG #{node[:setup][:user]} | grep -qw docker"
end

