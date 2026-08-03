# frozen_string_literal: true

# Eternal Terminal (et) - Remote shell that automatically reconnects
# A resilient SSH alternative that maintains connectivity during network changes
# https://github.com/MisterTea/EternalTerminal

# MisterTea/EternalTerminal does not publish prebuilt binaries on its
# GitHub releases (assets is empty on every recent tag). mise's github
# backend (and the deprecated ubi backend) both fail with
# "No matching asset found for platform macos-arm64". The brew formula
# via the official MisterTea/et tap is the only stable darwin install
# path — keep it.
execute "brew install eternal-terminal" do
  user node[:setup][:user]
  command "brew install MisterTea/et/et"
  not_if { brew_formula?("et") }
end

# Configure and start etserver as a system daemon
# Apple Silicon Macs use /opt/homebrew, Intel Macs use /usr/local
etserver_path = node[:homebrew][:machine] == "arm64" ? "/opt/homebrew/bin/etserver" : "/usr/local/bin/etserver"
# Log dir MUST track the arch prefix too. The plist previously hardcoded the
# Intel /usr/local/var/log, so on Apple Silicon etserver's stderr went to a
# non-existent dir — the 2026-06 listener-wedge on mini left zero logs, which
# is why root cause was unrecoverable. (issue #567)
log_dir = node[:homebrew][:machine] == "arm64" ? "/opt/homebrew/var/log" : "/usr/local/var/log"

directory "#{node[:setup][:root]}/eternal-terminal" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# launchd creates the StandardOut/ErrorPath FILES but not their parent dir;
# ensure it exists so etserver logs actually land. /opt/homebrew is user-owned
# on Apple Silicon, so no sudo needed.
execute "ensure etserver log dir #{log_dir}" do
  user node[:setup][:user]
  command "mkdir -p #{log_dir}"
  not_if "test -d #{log_dir}"
end

template "#{node[:setup][:root]}/eternal-terminal/homebrew.mxcl.et.plist" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
  variables(etserver_path: etserver_path, log_dir: log_dir)
  source "templates/homebrew.mxcl.et.plist.erb"
end

# Content-diff guard (NOT `test -f`): an already-provisioned Mac has the old
# buggy plist, so a bare existence guard would never propagate the log-path
# fix. Re-copy whenever the staged plist differs, then reload the daemon.
execute "copy etserver launch daemon" do
  user node[:setup][:system_user]
  command "cp #{node[:setup][:root]}/eternal-terminal/homebrew.mxcl.et.plist /Library/LaunchDaemons/homebrew.mxcl.et.plist"
  not_if "diff -q #{node[:setup][:root]}/eternal-terminal/homebrew.mxcl.et.plist /Library/LaunchDaemons/homebrew.mxcl.et.plist >/dev/null 2>&1"
  notifies :run, "execute[reload etserver daemon]", :delayed
end

execute "set etserver launch daemon ownership" do
  user node[:setup][:system_user]
  command "chown #{node[:setup][:system_user]}:#{node[:setup][:system_group]} /Library/LaunchDaemons/homebrew.mxcl.et.plist"
  only_if "test -f /Library/LaunchDaemons/homebrew.mxcl.et.plist"
end

# Initial load on a fresh host (no-op once loaded).
execute "load etserver daemon" do
  user node[:setup][:system_user]
  command "launchctl load -w /Library/LaunchDaemons/homebrew.mxcl.et.plist"
  not_if "launchctl list | grep -q homebrew.mxcl.et"
end

# Notify-driven reload so a changed plist (e.g. the log-path fix) actually
# takes effect on an already-loaded daemon — `load -w` alone is a no-op there.
execute "reload etserver daemon" do
  user node[:setup][:system_user]
  command "launchctl unload /Library/LaunchDaemons/homebrew.mxcl.et.plist 2>/dev/null; launchctl load -w /Library/LaunchDaemons/homebrew.mxcl.et.plist"
  action :nothing
end

# ---------------------------------------------------------------------------
# et-watchdog — port-listener self-heal (issue #567)
#
# et's supervisor only watches PROCESS liveness, not whether etserver is
# actually accepting on port 2022: launchd KeepAlive(NetworkState) on darwin and
# systemd on linux both miss the "alive-but-not-listening" wedge. That is
# exactly the 2026-06 mini incident — PID up ~4 days, zero listening sockets,
# `et` login refused. This periodic probe restarts etserver when the listener is
# gone. On darwin it is the ONLY recovery path: the central self-heal-resolve
# loop restarts services via `pct exec` (LXC-only) and cannot reach Macs.
#
# FAILURE-CLASS DISTINCTION — do not conflate (setup #567 vs #603):
#   - #567 REAL WEDGE: etserver alive but holds zero sockets → loopback connect
#     REFUSED (RST), `lsof -p <pid>` shows 0 sockets; recovery needs an explicit
#     `launchctl kickstart`. THIS watchdog is the fix.
#   - #603 SLEEP (NOT a wedge): the Mac mini idle-slept (mac-settings' always-on
#     `pmset -c sleep 0` was deployed but never executed, so it ran stock
#     `sleep 1`). During sleep the net stack is down: external probes TIMEOUT
#     (SYN drop) while ssh:22 still answers (Bonjour/Wake-on-Demand wakes ssh,
#     not arbitrary ports); it self-recovers on wake. Fix is power management
#     (keep the host awake), NOT this watchdog. The 2026-06-30 self-heal loop
#     misdiagnosed #603 as a #567 wedge because its sandboxed `netstat` showed
#     0 listeners — a tool artifact, not reality. Classify by connect behavior:
#     refused = wedge (kickstart); timeout = sleep/network (fix power/reachability).
#
# launchd watchdog: StartInterval=60 oneshot probing 127.0.0.1:2022.
wd_staging = "#{node[:setup][:root]}/eternal-terminal/et-watchdog.sh"

remote_file wd_staging do
  source "files/et-watchdog.darwin.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0755"
end

execute "install et-watchdog.sh to /usr/local/bin" do
  user node[:setup][:system_user]
  command "mkdir -p /usr/local/bin && " \
          "cp #{wd_staging} /usr/local/bin/et-watchdog.sh && " \
          "chmod 0755 /usr/local/bin/et-watchdog.sh && " \
          "chown #{node[:setup][:system_user]}:#{node[:setup][:system_group]} /usr/local/bin/et-watchdog.sh"
  not_if "test -f /usr/local/bin/et-watchdog.sh && diff -q #{wd_staging} /usr/local/bin/et-watchdog.sh >/dev/null 2>&1"
end

wd_plist_staging = "#{node[:setup][:root]}/eternal-terminal/com.shin1ohno.et-watchdog.plist"

remote_file wd_plist_staging do
  source "files/com.shin1ohno.et-watchdog.plist"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

execute "copy et-watchdog launch daemon" do
  user node[:setup][:system_user]
  command "cp #{wd_plist_staging} /Library/LaunchDaemons/com.shin1ohno.et-watchdog.plist && " \
          "chown #{node[:setup][:system_user]}:#{node[:setup][:system_group]} /Library/LaunchDaemons/com.shin1ohno.et-watchdog.plist"
  not_if "diff -q #{wd_plist_staging} /Library/LaunchDaemons/com.shin1ohno.et-watchdog.plist >/dev/null 2>&1"
  notifies :run, "execute[reload et-watchdog daemon]", :delayed
end

execute "load et-watchdog daemon" do
  user node[:setup][:system_user]
  command "launchctl load -w /Library/LaunchDaemons/com.shin1ohno.et-watchdog.plist"
  not_if "launchctl list | grep -q com.shin1ohno.et-watchdog"
end

execute "reload et-watchdog daemon" do
  user node[:setup][:system_user]
  command "launchctl unload /Library/LaunchDaemons/com.shin1ohno.et-watchdog.plist 2>/dev/null; " \
          "launchctl load -w /Library/LaunchDaemons/com.shin1ohno.et-watchdog.plist"
  action :nothing
end

# Delete the prior documentation-only profile entry. Pure comments still
# take ~1-3ms to parse on every shell start; `man et` and the cookbook
# itself are the documentation channels. (Twin of the same resource at the
# end of linux.rb — 1 resource, duplicated rather than hoisted to common.rb.)
file "#{node[:setup][:root]}/profile.d/50-eternal-terminal.sh" do
  action :delete
end
