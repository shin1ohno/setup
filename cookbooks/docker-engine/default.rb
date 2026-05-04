execute "update_and_install_deps" do
  # gnupg is required by `gpg --dearmor` in add_docker_gpg_key below.
  # Debian 13 LXC trixie templates ship without gnupg, so the bare
  # ca-certificates+curl install is insufficient on a fresh PVE-provisioned
  # LXC.
  command "apt-get update && apt-get install -y ca-certificates curl gnupg"
  user node[:setup][:system_user]
  not_if {
    %w(ca-certificates curl gnupg).all? { |pkg|
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
  # Refresh apt index immediately when this resource added the docker repo,
  # so the package "docker-ce" install below sees the new repo. Without
  # this notify, the 24h freshness guard on update_package_index skips the
  # refresh on freshly-bootstrapped LXCs (where apt-get update ran during
  # bootstrap, before the docker repo was added) — failing with
  # `Package docker-ce has no installation candidate`.
  notifies :run, "execute[update_package_index]", :immediately
end

execute "update_package_index" do
  command "apt-get update"
  user node[:setup][:system_user]
  # Skip if /var/cache/apt/pkgcache.bin was refreshed within the last 24h —
  # apt-get update is a network round-trip that delays every mitamae run
  # even when the index is fresh. add_docker_repo's :immediately notify
  # above forces a refresh when the docker source is newly added, so this
  # 24h skip only applies to subsequent idempotent runs.
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

