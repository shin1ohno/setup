# frozen_string_literal: true
#
# cookbooks/lan-vpc-route: install a systemd oneshot that holds static routes
# to the AWS VPC (10.33.128.0/18) and tailnet CGNAT (100.64.0.0/10) via the
# pro-router LXC (192.168.1.60), the home tailnet subnet router.
#
# Why: the LAN default gateway (RTX1210, .253) won't hairpin-forward to a
# same-segment next-hop, so LAN hosts can't reach the VPC via the default
# route despite the RTX's static route. Each host must hold the route itself.
# Static-IP PVE LXCs get it here; DHCP clients get it via DHCP option 121
# (home-monitor rtx_dhcp_scope.ebisu_main classless_static_routes).
#
# Skipped on tailnet nodes (pro-router): they reach the VPC via tailscale0
# directly, and routing 10.33/18 via .60 from .60 would loop. The
# `! ip link show tailscale0` guard excludes them at converge time.
# OS gate now lives at the include site (roles/lxc-core, Linux-only).

tailnet_guard = "! ip link show tailscale0 > /dev/null 2>&1"
staging_dir = "#{node[:setup][:root]}/lan-vpc-route"

directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  mode "755"
end

remote_file "#{staging_dir}/vpc-route.service" do
  source "files/vpc-route.service"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

execute "install vpc-route.service" do
  command "sudo install -m 644 -o root -g root " \
          "#{staging_dir}/vpc-route.service " \
          "/etc/systemd/system/vpc-route.service"
  only_if tailnet_guard
  not_if "diff -q #{staging_dir}/vpc-route.service /etc/systemd/system/vpc-route.service 2>/dev/null"
  notifies :run, "execute[reload + enable vpc-route]"
end

execute "reload + enable vpc-route" do
  command "sudo systemctl daemon-reload && sudo systemctl enable --now vpc-route.service"
  action :nothing
end

# Self-heal: ensure the routes are applied even when the unit file was
# unchanged (e.g. routes flushed by a network restart, or first run after the
# unit already existed). `enable --now` is a no-op if already active+enabled.
execute "ensure vpc-route active" do
  command "sudo systemctl enable --now vpc-route.service"
  only_if tailnet_guard
  not_if "systemctl is-active --quiet vpc-route.service"
end
