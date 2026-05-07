# frozen_string_literal: true
#
# lxc-pro-dev (CT 104): drop conflicting LAN supernet from tailscale0
# table 52 so inbound LAN ssh to 192.168.1.64 actually returns over eth0.
#
# Why this cookbook exists:
#   pro-dev runs `tailscale up --accept-routes` (configured by
#   lxc-dev-workstation) so it can reach the AWS VPC at 10.33.128.0/18.
#   `--accept-routes=true` ALSO installs every peer-advertised route into
#   table 52, which `ip rule 5270: from all lookup 52` consults BEFORE
#   the main table. pro-router (CT 99) advertises 192.168.1.0/24 — pro-dev's
#   own LAN — so pro-dev → LAN replies route via tailscale0 instead of eth0,
#   and inbound LAN ssh times out (Air → 192.168.1.64 SYN arrives, SYN-ACK
#   leaves on the wrong interface, observed empirically 2026-05-07).
#
# Same shape as cookbooks/lxc-pro-router/default.rb (which deletes
# 192.168.0.0/16 from hnd-subnet-router) — pro-dev is a pure acceptor and
# does NOT need the ip_forward sysctl, SNAT, or `tailscale set` re-apply
# that pro-router has.
#
# Limitation inherited from pro-router pattern: the systemd unit fires on
# boot only (WantedBy=multi-user.target). After a tailscaled restart that
# re-injects the route, run `sudo systemctl restart
# lxc-pro-dev-tailnet-routes.service` manually.

return if node[:platform] == "darwin"

# Defensive parent-dir guard per ~/.claude/rules/ruby.md "Defensive
# `directory` resource for `node[:setup][:root]` and its subdirs".
directory node[:setup][:root] do
  mode "755"
end

file "#{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  content <<~SH
    #!/bin/bash
    # Managed by setup/cookbooks/lxc-pro-dev. Do not edit by hand.
    #
    # Tailscale's `--accept-routes=true` installs peer-advertised routes
    # into both the main routing table and table 52 (selected by
    # `ip rule 5270: from all lookup 52`). pro-router advertises
    # 192.168.1.0/24 (its own / pro-dev's LAN subnet) — and table 52 is
    # consulted BEFORE main, so any reply from pro-dev to a LAN host (Air,
    # other 192.168.1.x clients) gets routed via tailscale0 instead of
    # eth0, breaking inbound LAN ssh entirely.
    #
    # Fix: drop 192.168.1.0/24 from BOTH tables. Keep 10.33.128.0/18
    # (AWS VPC) and 100.64.0.0/10 (CGNAT) which are legitimate
    # tailscale-only routes.
    set -euo pipefail
    /usr/sbin/ip route del 192.168.1.0/24 dev tailscale0 2>/dev/null || true
    /usr/sbin/ip route del 192.168.1.0/24 dev tailscale0 table 52 2>/dev/null || true
  SH
end

execute "install pro-dev tailnet-routes script" do
  command "sudo install -m 755 -o root -g root #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.sh /usr/local/sbin/lxc-pro-dev-tailnet-routes.sh"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.sh /usr/local/sbin/lxc-pro-dev-tailnet-routes.sh 2>/dev/null"
end

file "#{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.service" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~UNIT
    [Unit]
    Description=Drop conflicting LAN supernet (192.168.1.0/24) from tailscale0 (pro-dev)
    After=tailscaled.service network-online.target
    Wants=tailscaled.service network-online.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/lxc-pro-dev-tailnet-routes.sh
    RemainAfterExit=true

    [Install]
    WantedBy=multi-user.target
  UNIT
end

execute "install pro-dev tailnet-routes systemd unit" do
  command "sudo install -m 644 -o root -g root #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.service /etc/systemd/system/lxc-pro-dev-tailnet-routes.service"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.service /etc/systemd/system/lxc-pro-dev-tailnet-routes.service 2>/dev/null"
  notifies :run, "execute[reload + enable pro-dev tailnet-routes]"
end

execute "reload + enable pro-dev tailnet-routes" do
  command "sudo systemctl daemon-reload && sudo systemctl enable --now lxc-pro-dev-tailnet-routes.service"
  action :nothing
end
