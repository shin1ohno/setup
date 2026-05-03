execute "update_and_install_deps" do
  command "apt-get update && apt-get install -y ca-certificates curl"
  user node[:setup][:system_user]
  not_if {
    %w(ca-certificates curl).all? { |pkg|
      run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0
    }
  }
end

# Detect distro family + codename from /etc/os-release; Docker publishes
# separate channels for ubuntu and debian. The previous form hardcoded
# linux/ubuntu and `noble`, breaking on Debian 13 trixie LXC templates.
distro_id = `. /etc/os-release && echo $ID`.strip
distro_codename = `. /etc/os-release && echo $VERSION_CODENAME`.strip

execute "add_docker_gpg_key" do
  # apt-key was removed in Debian 12+ / Ubuntu 22.04+. Use signed-by
  # keyring under /etc/apt/keyrings/. --batch --yes for non-TTY mitamae.
  command "install -d -m 0755 /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/#{distro_id}/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg"
  user node[:setup][:system_user]
  not_if { File.exist?("/etc/apt/keyrings/docker.gpg") }
end

execute "add_docker_repo" do
  command "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/#{distro_id} #{distro_codename} stable' > /etc/apt/sources.list.d/docker.list"
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

