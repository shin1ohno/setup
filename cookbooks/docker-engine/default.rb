execute "update_and_install_deps" do
  command "apt-get update && apt-get install -y ca-certificates curl"
  user node[:setup][:system_user]
  not_if {
    %w(ca-certificates curl).all? { |pkg|
      run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0
    }
  }
end

execute "add_docker_gpg_key" do
  command "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -"
  user node[:setup][:system_user]
  not_if { run_command("apt-key list 2>/dev/null | grep -q Docker", error: false).exit_status == 0 }
end

execute "add_docker_repo" do
  command 'add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable"'
  user node[:setup][:system_user]
  not_if { run_command('grep -R "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null', error: false).exit_status == 0 }
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
    not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end

# Start and enable Docker service. The service resource's built-in state
# check is unreliable under the `user "root"` sudo wrap (and even without
# it, mitamae's `enabled` detection mis-fires on this host); use a Proc
# not_if to short-circuit on the systemctl-truth.
service "docker" do
  action [:start, :enable]
  user node[:setup][:system_user]
  not_if {
    run_command("systemctl is-active docker", error: false).exit_status == 0 &&
      run_command("systemctl is-enabled docker", error: false).exit_status == 0
  }
end

# Add the setup user to the docker group for rootless access
execute "usermod -aG docker #{node[:setup][:user]}" do
  user node[:setup][:system_user]
  not_if { run_command("id -nG #{node[:setup][:user]} | grep -qw docker", error: false).exit_status == 0 }
end

