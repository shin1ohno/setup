# frozen_string_literal: true
#
# cookbooks/unbound: LAN DNS resolver for the home network (CT 118 / 192.168.1.61).
# Replaces the RTX1210 forwarder, which does not serve TCP/53 — RFC 7766 TCP
# fallback on truncated (>512B) responses fails there, breaking Linux name
# resolution. unbound serves UDP+TCP and forwards:
#   home.local + 1.168.192.in-addr.arpa -> VPC Route53 resolver (10.33.128.2)
#   everything else                     -> Cloudflare DoT (1.1.1.1@853 / 1.0.0.1@853)

return if node[:platform] == "darwin"

staging_dir = "#{node[:setup][:root]}/unbound"

# Fresh Debian LXC: refresh apt index + TLS roots before installing unbound.
execute "apt-get update (unbound)" do
  command "sudo apt-get update -qq"
  not_if "dpkg -s unbound >/dev/null 2>&1"
end

execute "install unbound + ca-certificates" do
  command "sudo apt-get install -y unbound ca-certificates && sudo update-ca-certificates"
  not_if "dpkg -s unbound >/dev/null 2>&1"
end

# systemd-resolved (if present) binds :53 and collides with unbound on 0.0.0.0:53.
execute "disable systemd-resolved (collides with unbound on :53)" do
  command "sudo systemctl disable --now systemd-resolved"
  only_if "systemctl is-active systemd-resolved >/dev/null 2>&1 || systemctl is-enabled systemd-resolved >/dev/null 2>&1"
end

# Defensive parent dirs (fresh LXC may not have setup_root yet).
# Per CLAUDE.md "Defensive directory resource" rule — fresh PVE-LXC bootstraps
# call this cookbook before any sibling cookbook has created node[:setup][:root].
directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Stage the drop-in in user space, then install into /etc with sudo.
remote_file "#{staging_dir}/home-monitor.conf" do
  source "files/home-monitor.conf"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

execute "install /etc/unbound/unbound.conf.d/home-monitor.conf" do
  command "sudo install -m 644 -o root -g root " \
          "#{staging_dir}/home-monitor.conf " \
          "/etc/unbound/unbound.conf.d/home-monitor.conf"
  not_if "diff -q #{staging_dir}/home-monitor.conf /etc/unbound/unbound.conf.d/home-monitor.conf 2>/dev/null"
  notifies :run, "execute[validate + restart unbound]"
end

# Validate config BEFORE (re)starting — never restart on a broken config.
execute "validate + restart unbound" do
  command "sudo unbound-checkconf && sudo systemctl restart unbound"
  action :nothing
end

execute "enable unbound" do
  command "sudo systemctl enable unbound"
  not_if "systemctl is-enabled unbound >/dev/null 2>&1"
end

# Self-heal: start unbound if it is installed+enabled but not currently running
# (manual stop, crash, OOM). Mirrors node-exporter's `enable --now` posture so a
# re-run with an unchanged config still asserts the running state.
execute "ensure unbound running" do
  command "sudo systemctl start unbound"
  not_if "systemctl is-active --quiet unbound"
end
