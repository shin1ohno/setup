# frozen_string_literal: true
#
# lxc-pro-router (CT 99): Tailscale subnet route advertise + AWS VPC tunnel.
#
# Per migration plan (frolicking-beaming-crescent.md Phase 3a):
#   - tag:home-router (advertises 192.168.1.0/24 to tailnet)
#   - AWS VPC tunnel peer receiving from nrt-subnet-router
#   - Pattern 2 main path (Pattern 1 break-glass lives on PVE host)
#
# RAM 256 MiB / CPU 1 / vmbr1.

return if node[:platform] == "darwin"

# Common LXC user provisioning (shin1ohno + sudo + ssh authorized_keys).
include_cookbook "lxc-shared-user"

# IP forwarding is required for `tailscale up --advertise-routes`. Without
# this sysctl any node accepting the advertised 192.168.1.0/24 route via
# tailnet will black-hole packets through this LXC. Persisted via drop-in
# so it survives reboots and `pct restart`.
file "#{node[:setup][:root]}/lxc-pro-router-ip-forward.conf" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~CFG
    # Managed by setup/cookbooks/lxc-pro-router. Do not edit
    # /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf by hand — the next
    # mitamae run will overwrite it.
    net.ipv4.ip_forward = 1
    net.ipv6.conf.all.forwarding = 1
  CFG
end

execute "install pro-router ip-forward sysctl drop-in" do
  command "sudo install -m 644 -o root -g root #{node[:setup][:root]}/lxc-pro-router-ip-forward.conf /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-router-ip-forward.conf /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf 2>/dev/null"
  notifies :run, "execute[apply pro-router ip-forward sysctl]"
end

execute "apply pro-router ip-forward sysctl" do
  command "sudo sysctl -p /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf"
  action :nothing
end

# Reuse the canonical Tailscale install path.
include_cookbook "tailscale"

# Subnet routing: pro-router needs to forward LAN packets (192.168.1.x)
# to AWS VPC (10.33.128.0/18) over tailscale0. This requires:
#   1. accept-routes on tailscale (to register 10.33.128.0/18 as a peer route)
#   2. removing the conflicting 192.168.0.0/16 route from hnd-subnet-router
#      that gets installed on tailscale0 alongside 10.33.128.0/18 — that
#      overlaps with our LAN's 192.168.1.0/24 (eth0) and breaks LAN traffic
#   3. systemd unit that re-applies (1) + (2) on every boot, since
#      `tailscale set` is in-process state and routes are kernel state
#
# The systemd unit also defends against future hnd-subnet-router peers
# advertising any 192.168.x.x supernet — we explicitly del the 192.168.0.0/16
# route. The routes for 100.64.0.0/10 (CGNAT) and 10.33.128.0/18 (VPC) we
# keep.
file "#{node[:setup][:root]}/lxc-pro-router-tailnet-routes.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  content <<~SH
    #!/bin/bash
    # Managed by setup/cookbooks/lxc-pro-router. Do not edit by hand.
    set -euo pipefail
    /usr/bin/tailscale set --accept-routes=true
    sleep 2
    # Drop conflicting LAN supernet route from hnd-subnet-router (if present).
    /usr/sbin/ip route del 192.168.0.0/16 dev tailscale0 2>/dev/null || true
  SH
end

execute "install pro-router tailnet-routes script" do
  command "sudo install -m 755 -o root -g root #{node[:setup][:root]}/lxc-pro-router-tailnet-routes.sh /usr/local/sbin/lxc-pro-router-tailnet-routes.sh"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-router-tailnet-routes.sh /usr/local/sbin/lxc-pro-router-tailnet-routes.sh 2>/dev/null"
end

file "#{node[:setup][:root]}/lxc-pro-router-tailnet-routes.service" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~UNIT
    [Unit]
    Description=Apply pro-router VPC subnet routing through tailscale0
    After=tailscaled.service network-online.target
    Wants=tailscaled.service network-online.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/lxc-pro-router-tailnet-routes.sh
    RemainAfterExit=true

    [Install]
    WantedBy=multi-user.target
  UNIT
end

execute "install pro-router tailnet-routes systemd unit" do
  command "sudo install -m 644 -o root -g root #{node[:setup][:root]}/lxc-pro-router-tailnet-routes.service /etc/systemd/system/lxc-pro-router-tailnet-routes.service"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-router-tailnet-routes.service /etc/systemd/system/lxc-pro-router-tailnet-routes.service 2>/dev/null"
  notifies :run, "execute[reload + enable pro-router tailnet-routes]"
end

execute "reload + enable pro-router tailnet-routes" do
  command "sudo systemctl daemon-reload && sudo systemctl enable --now lxc-pro-router-tailnet-routes.service"
  action :nothing
end

# Helper output: tell the operator the exact `tailscale up` command for
# this LXC. Auth key fetched from SSM at install time.
local_ruby_block "log lxc-pro-router tailscale up hint" do
  block do
    state = `tailscale status --json 2>/dev/null`
    if state.empty? || state.include?('"BackendState":"NeedsLogin"')
      MItamae.logger.warn(<<~MSG)
        lxc-pro-router: tailscaled installed but not authenticated. Run:
          sudo tailscale up \\
            --auth-key=$(aws ssm get-parameter --name /tailscale/pro-router-auth-key --with-decryption --query Parameter.Value --output text) \\
            --advertise-routes=192.168.1.0/24 \\
            --advertise-tags=tag:home-router \\
            --hostname=pro-router \\
            --accept-dns=false \\
            --ssh
      MSG
    end
  end
end
