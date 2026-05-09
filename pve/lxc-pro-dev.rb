# frozen_string_literal: true
#
# Entry recipe for the pro-dev LXC (CT 104): personal SSH workspace
# continuation of bare-metal `pro` — re-applies the linux.rb role set so
# `ssh pro-dev` retains the same ergonomics (profile.d, fzf, mise, etc.)
# that the legacy host had.
#
# Bind-mounts (set up by Terraform):
#   - /mnt/data/workspace (rw, idmap)
#   - /mnt/Media (ro, optional)
#
# Networking: vmbr1, independent tailscaled (Magic DNS = pro-dev,
# tag:dev-host). Separate from pro-router LXC's tailscaled to give barrier
# isolation — pro-router upgrade failure does not kill personal SSH access.
#
# RAM 12 GiB / CPU 6 / rootfs 200 GiB.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-pro-dev.rb
#
# Phase 4 follow-up: ManagedProjects rsync, AWS profile, GPG keys are
# restored from /mnt/data/pve-migration-backup-* via host bind-mount.

include_recipe "../cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

# pro-dev specifics. Skip ollama (CPU-only LXC, install.sh 404s, no local
# LLM runtime in scope). Pin tailscale identity to /tailscale/pro-dev-auth-key.
node.reverse_merge!(
  llm: { skip_ollama: true },
  lxc_dev: {
    hostname: "pro-dev",
    tailscale_tag: "tag:dev-host",
    tailscale_ssm_key: "/tailscale/pro-dev-auth-key",
  },
)

include_cookbook "lxc-dev-workstation"

# Drop conflicting LAN supernet from tailscale0 table 52 so inbound LAN
# ssh to 192.168.1.64 actually returns over eth0.
#
# Why this is needed: pro-dev runs `tailscale up --accept-routes` (configured
# by lxc-dev-workstation) so it can reach the AWS VPC at 10.33.128.0/18.
# `--accept-routes=true` ALSO installs every peer-advertised route into
# table 52, which `ip rule 5270: from all lookup 52` consults BEFORE
# the main table. pro-router (CT 102) advertises 192.168.1.0/24 — pro-dev's
# own LAN — so pro-dev → LAN replies route via tailscale0 instead of eth0,
# and inbound LAN ssh times out (Air → 192.168.1.64 SYN arrives, SYN-ACK
# leaves on the wrong interface, observed empirically 2026-05-07).
#
# Same shape as pro-router's tailnet-routes script (which deletes
# 192.168.0.0/16 from hnd-subnet-router) — pro-dev is a pure acceptor and
# does NOT need the ip_forward sysctl, SNAT, or `tailscale set` re-apply
# that pro-router has.
#
# Self-healing: a sibling `.timer` unit fires every 60s (OnBootSec=30s,
# OnUnitActiveSec=60s) so any future re-injection by tailscaled — peer
# route resync, daemon restart, magic-DNS bounce — is cleared within
# ≤60s without human intervention. The script is idempotent
# (`ip route del 2>/dev/null || true`) so the recurring fire is a no-op
# whenever the route is already absent. The .service is NOT
# `enable --now`'d directly; the timer drives it.

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
    # Managed by setup/pve/lxc-pro-dev.rb. Do not edit by hand.
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

    [Install]
    WantedBy=multi-user.target
  UNIT
end

execute "install pro-dev tailnet-routes systemd unit" do
  command "sudo install -m 644 -o root -g root #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.service /etc/systemd/system/lxc-pro-dev-tailnet-routes.service"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.service /etc/systemd/system/lxc-pro-dev-tailnet-routes.service 2>/dev/null"
  notifies :run, "execute[reload + enable pro-dev tailnet-routes timer]"
end

file "#{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.timer" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~UNIT
    [Unit]
    Description=Periodically drop conflicting LAN supernet from tailscale0 (pro-dev)

    [Timer]
    OnBootSec=30s
    OnUnitActiveSec=60s
    Unit=lxc-pro-dev-tailnet-routes.service

    [Install]
    WantedBy=timers.target
  UNIT
end

execute "install pro-dev tailnet-routes systemd timer" do
  command "sudo install -m 644 -o root -g root #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.timer /etc/systemd/system/lxc-pro-dev-tailnet-routes.timer"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-dev-tailnet-routes.timer /etc/systemd/system/lxc-pro-dev-tailnet-routes.timer 2>/dev/null"
  notifies :run, "execute[reload + enable pro-dev tailnet-routes timer]"
end

execute "reload + enable pro-dev tailnet-routes timer" do
  command "sudo systemctl daemon-reload && sudo systemctl enable --now lxc-pro-dev-tailnet-routes.timer"
  action :nothing
end

include_role "lxc-core"
