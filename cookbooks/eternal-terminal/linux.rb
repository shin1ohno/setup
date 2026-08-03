# frozen_string_literal: true

# Eternal Terminal (et) - Remote shell that automatically reconnects
# A resilient SSH alternative that maintains connectivity during network changes
# https://github.com/MisterTea/EternalTerminal

# DISTRO, not platform: et's install path differs *within* the linux family —
# Ubuntu uses the Launchpad PPA, Debian uses MisterTea's debian-et repo, Arch
# uses pacman. node[:platform] cannot express this (functions normalizes every
# debian-family host to "ubuntu", which is why a debian host would otherwise
# land in the PPA branch and fail with "add-apt-repository: not found"), so read
# /etc/os-release ID directly. The darwin arm of the old derivation is gone —
# that decision now belongs to the include layer.
et_distro = `. /etc/os-release && echo $ID`.strip

case et_distro
when "ubuntu"
  # Install via PPA on Ubuntu. add-apt-repository on Ubuntu 24.04+ writes
  # deb822-format `.sources` files instead of legacy `.list`, so the guard
  # must check both extensions — otherwise this re-runs every mitamae apply
  # and trips on transient Launchpad outages even when the PPA is already
  # registered locally.
  execute "add eternal-terminal ppa" do
    command "add-apt-repository -y ppa:jgmath2000/et"
    user node[:setup][:system_user]
    not_if { run_command("grep -rqE 'jgmath2000/(ubuntu/)?et' /etc/apt/sources.list.d/ 2>/dev/null", error: false).exit_status == 0 }
  end

  execute "apt-get update for eternal-terminal" do
    command "apt-get update"
    user node[:setup][:system_user]
    # Skip if `et` is already installed (the PPA was already added in a
    # previous run and the package landed). Ruby File.exist? avoids the
    # PATH-dependent `which et` which fails when wrapped via `sudo -u root`.
    not_if { File.exist?("/usr/bin/et") }
  end

  package "et" do
    user node[:setup][:system_user]
    action :install
    not_if { run_command("dpkg-query -W -f='${Status}' et 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    user node[:setup][:system_user]
    not_if { run_command("systemctl is-active et.service", error: false).exit_status == 0 }
  end

when "debian"
  # Install via custom repository on Debian
  execute "setup eternal-terminal repository" do
    command <<~BASH
      mkdir -m 0755 -p /etc/apt/keyrings
      echo "deb [signed-by=/etc/apt/keyrings/et.gpg] https://mistertea.github.io/debian-et/debian-source/ $(grep VERSION_CODENAME /etc/os-release | cut -d= -f2) main" > /etc/apt/sources.list.d/et.list
      curl -sSL https://github.com/MisterTea/debian-et/raw/master/et.gpg -o /etc/apt/keyrings/et.gpg
    BASH
    not_if "test -f /etc/apt/sources.list.d/et.list"
    user node[:setup][:system_user]
  end

  execute "apt update for eternal-terminal" do
    command "apt-get update"
    not_if "which et"
    user node[:setup][:system_user]
  end

  package "et" do
    user node[:setup][:system_user]
    action :install
    not_if { run_command("dpkg-query -W -f='${Status}' et 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    user node[:setup][:system_user]
    not_if { run_command("systemctl is-active et.service", error: false).exit_status == 0 }
  end

when "arch", "manjaro", "endeavouros"
  # Install via pacman on Arch Linux
  package "eternal-terminal" do
    user node[:setup][:system_user]
    action :install
  end

  # Enable and start etserver service
  execute "enable etserver service" do
    command "systemctl enable --now et.service"
    user node[:setup][:system_user]
    not_if { run_command("systemctl is-active et.service", error: false).exit_status == 0 }
  end
end

# ---------------------------------------------------------------------------
# et-watchdog — port-listener self-heal (issue #567)
#
# et's supervisor only watches PROCESS liveness, not whether etserver is
# actually accepting on port 2022: launchd KeepAlive(NetworkState) on darwin and
# systemd on linux both miss the "alive-but-not-listening" wedge. That is
# exactly the 2026-06 mini incident — PID up ~4 days, zero listening sockets,
# `et` login refused. This periodic probe restarts etserver when the listener is
# gone.
#
# FAILURE-CLASS DISTINCTION — do not conflate (setup #567 vs #603):
#   - #567 REAL WEDGE: etserver alive but holds zero sockets → loopback connect
#     REFUSED (RST), `lsof -p <pid>` shows 0 sockets; recovery needs an explicit
#     restart. THIS watchdog is the fix.
#   - #603 SLEEP (NOT a wedge): a host that idle-sleeps drops its net stack, so
#     external probes TIMEOUT (SYN drop) and it self-recovers on wake. Fix is
#     power management, NOT this watchdog. Classify by connect behavior:
#     refused = wedge (restart); timeout = sleep/network (fix power/reachability).
#
# systemd watchdog (mirror cookbooks/unbound-watchdog install posture: stage
# in user-space, sudo install into system paths with diff guards, single
# delayed activator running the full daemon-reload/enable/restart/start chain).
wd_files_dir = "#{node[:setup][:root]}/eternal-terminal/files"

directory node[:setup][:root] do
  mode "755"
end

directory wd_files_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# node_exporter textfile dir (also created by node-exporter; declare here so
# include order is irrelevant). Root-owned -> sudo install -d.
execute "create /var/lib/node_exporter/textfile for et-watchdog" do
  command "sudo install -d -m 0755 -o root -g root /var/lib/node_exporter/textfile"
  not_if "test -d /var/lib/node_exporter/textfile"
end

wd_script_staging = "#{wd_files_dir}/et-watchdog.sh"

remote_file wd_script_staging do
  source "files/et-watchdog.linux.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0755"
end

execute "install et-watchdog.sh to /usr/local/bin" do
  command "sudo install -m 0755 -o root -g root #{wd_script_staging} /usr/local/bin/et-watchdog.sh"
  not_if "test -f /usr/local/bin/et-watchdog.sh && diff -q #{wd_script_staging} /usr/local/bin/et-watchdog.sh >/dev/null 2>&1"
  notifies :run, "execute[reload + enable et-watchdog.timer]"
end

%w[et-watchdog.service et-watchdog.timer].each do |unit|
  unit_staging = "#{wd_files_dir}/#{unit}"

  remote_file unit_staging do
    source "files/#{unit}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "0644"
  end

  execute "install #{unit} to /etc/systemd/system" do
    command "sudo install -m 0644 -o root -g root #{unit_staging} /etc/systemd/system/#{unit}"
    not_if "test -f /etc/systemd/system/#{unit} && diff -q #{unit_staging} /etc/systemd/system/#{unit} >/dev/null 2>&1"
    notifies :run, "execute[reload + enable et-watchdog.timer]"
  end
end

# All four steps per the systemd-timer verification rule (see unbound-watchdog).
execute "reload + enable et-watchdog.timer" do
  command "sudo systemctl daemon-reload && " \
          "sudo systemctl enable et-watchdog.timer && " \
          "sudo systemctl restart et-watchdog.timer && " \
          "sudo systemctl start et-watchdog.service"
  action :nothing
end

# Delete the prior documentation-only profile entry. Pure comments still
# take ~1-3ms to parse on every shell start; `man et` and the cookbook
# itself are the documentation channels. (Twin of the same resource at the
# end of darwin.rb — 1 resource, duplicated rather than hoisted to common.rb.)
file "#{node[:setup][:root]}/profile.d/50-eternal-terminal.sh" do
  action :delete
end
