# frozen_string_literal: true
#
# cookbooks/unbound-watchdog: off-box self-heal for the CT 118 unbound LAN
# resolver (192.168.1.61). Runs ON THE PVE HOST (included from pve/pve-host.rb)
# because the failure it guards — unbound "active + bound but zero replies on
# eth0" while localhost still answers (2026-05-31) — is invisible to any
# CT-local probe. The PVE host is on the same LAN, so its probe to .61 traverses
# the CT's eth0 (detects the wedge) and `pct exec` gives it the restart lever.
# The probe target (unbound-watchdog.health) is local-data in cookbooks/unbound;
# a timeout OR a stale-config wrong answer both trigger a restart.
#
# Install posture mirrors cookbooks/node-exporter: in the fleet/auto-mitamae
# context mitamae runs as a non-root user, so system-path writes and systemctl
# go through `sudo`, and root-owned dirs use `sudo install -d` (a `directory`
# resource with owner root triggers a failing sudo chown). User-space staging
# dirs use the `directory` resource.

return if node[:platform] == "darwin"

user      = node[:setup][:user]
group     = node[:setup][:group]
files_dir = "#{node[:setup][:root]}/unbound-watchdog/files"

# Defensive parent dirs (PVE host bootstrap may run this before a sibling
# cookbook created node[:setup][:root]). User-owned, so no sudo.
directory node[:setup][:root] do
  mode "755"
end

directory files_dir do
  owner user
  group group
  mode "755"
end

# The probe uses dig.
execute "install bind9-dnsutils (dig) for unbound-watchdog" do
  command "sudo apt-get install -y bind9-dnsutils"
  not_if "command -v dig >/dev/null 2>&1"
end

# node_exporter textfile dir (also created by node-exporter; declare here so
# include order is irrelevant). Root-owned -> sudo install -d.
execute "create /var/lib/node_exporter/textfile for unbound-watchdog" do
  command "sudo install -d -m 0755 -o root -g root /var/lib/node_exporter/textfile"
  not_if "test -d /var/lib/node_exporter/textfile"
end

script_staging = "#{files_dir}/unbound-watchdog.sh"
script_path    = "/usr/local/bin/unbound-watchdog.sh"

remote_file script_staging do
  source "files/unbound-watchdog.sh"
  owner user
  group group
  mode "0755"
end

execute "install unbound-watchdog.sh to /usr/local/bin" do
  command "sudo install -m 0755 -o root -g root #{script_staging} #{script_path}"
  not_if "test -f #{script_path} && diff -q #{script_staging} #{script_path} 2>/dev/null"
  notifies :run, "execute[reload + enable unbound-watchdog.timer]"
end

%w[unbound-watchdog.service unbound-watchdog.timer].each do |unit|
  unit_staging = "#{files_dir}/#{unit}"

  remote_file unit_staging do
    source "files/#{unit}"
    owner user
    group group
    mode "0644"
  end

  execute "install #{unit} to /etc/systemd/system" do
    command "sudo install -m 0644 -o root -g root #{unit_staging} /etc/systemd/system/#{unit}"
    not_if "test -f /etc/systemd/system/#{unit} && diff -q #{unit_staging} /etc/systemd/system/#{unit} 2>/dev/null"
    # delayed notify (default) so reload/(re)start runs once at end-of-converge,
    # after BOTH unit files are staged.
    notifies :run, "execute[reload + enable unbound-watchdog.timer]"
  end
end

# All four steps per the systemd-timer verification rule: `enable --now` is a
# no-op when the timer is already active, so without `restart timer` a unit-body
# change would not be reloaded; `start service` seeds the OnUnitInactiveSec
# deactivation reference for the recurring fire.
execute "reload + enable unbound-watchdog.timer" do
  command "sudo systemctl daemon-reload && " \
          "sudo systemctl enable unbound-watchdog.timer && " \
          "sudo systemctl restart unbound-watchdog.timer && " \
          "sudo systemctl start unbound-watchdog.service"
  action :nothing
end
