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

# --- et runtime dependencies (issue #1178) ---------------------------------
#
# etserver/etterminal link against #{prefix}/opt/<dep>/lib/*.dylib for every
# runtime `depends_on` of the MisterTea/et formula. The guard above only checks
# the et formula itself, so a host where a dependency disappeared out from
# under et stays dead: etserver aborts in dyld (`launchctl print` shows
# OS_REASON_DYLD) and et-watchdog's kickstart just repeats the same abort.
# dyld reports only the FIRST missing library, so on mini libsodium surfaced at
# the 2026-11-09 reboot and libcurl only after libsodium came back (11-23).
#
# The removal path is `brew autoremove` while the MisterTea/et tap is
# untrusted: brew refuses to load et's formula (`brew deps MisterTea/et/et`
# fails with "untrusted tap"), cannot see its dependencies, and treats every
# one that is installed only as a dependency as an orphan. So each dependency
# is (1) installed when missing and (2) marked installed-on-request with
# `brew tab`, which takes it out of autoremove's reach. Transitive deps (curl's
# own libraries) stay protected through their homebrew/core parents.
#
# Keep this list in sync with the non-:build `depends_on` lines of
# #{prefix}/Library/Taps/mistertea/homebrew-et/et.rb (et 7.0.0_2 at tap 5401b93;
# the same five are what `otool -L etserver` references in et 6.2.11_2).
#
# Guards read the opt link and its INSTALL_RECEIPT.json rather than the
# brew-cache predicate, which is a snapshot from the start of the run. If an
# installed dependency ever ships a different soname, et itself needs a rebuild
# (`brew reinstall MisterTea/et/et`) — that is a separate failure, not this one.
%w[abseil curl libsodium openssl@3 protobuf].each do |dep|
  dep_opt = "#{node[:homebrew][:prefix]}/opt/#{dep}"

  execute "brew install #{dep} (et runtime dependency)" do
    user node[:setup][:user]
    command "brew install #{dep}"
    not_if "test -d #{dep_opt}/lib"
    # etserver is not running while a library is missing; reload the daemon
    # so recovery does not depend on the watchdog's next 60 s tick.
    notifies :run, "execute[reload etserver daemon]", :delayed
  end

  execute "mark #{dep} installed on request (et runtime dependency)" do
    user node[:setup][:user]
    command "brew tab --installed-on-request #{dep}"
    only_if "test -f #{dep_opt}/INSTALL_RECEIPT.json"
    not_if "grep -q '\"installed_on_request\": *true' #{dep_opt}/INSTALL_RECEIPT.json"
  end
end

# --- etterminal on the non-interactive ssh PATH (issue #741) ---------------
#
# The et CLIENT bootstraps a session by running `ssh <host> etterminal ...`.
# That is a NON-INTERACTIVE, non-login shell, whose PATH on macOS is the stock
# /usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin — `/etc/zprofile`'s path_helper
# never runs, so the Homebrew prefix is absent. On Apple Silicon etterminal
# lives in /opt/homebrew/bin, so `et mini` fails at the ssh sub-step with
#   "Error starting ET process through ssh, please make sure your ssh works first"
# followed by "Error connecting to server: 3: Client is not registered" —
# the second line is the downstream effect, not the cause. Plain `ssh` to the
# same host works, which is what makes this look like a network fault.
# Intel Macs never hit it: their brew prefix was already on the default PATH.
#
# Same failure class, same fix as cookbooks/mosh/darwin.rb ("SSH non-interactive
# sessions need /usr/local/bin in PATH") — mosh-server has been symlinked this
# way for years. SIP prevents writing /usr/bin, so /usr/local/bin it is; this
# cookbook already installs et-watchdog.sh there.
#
# NOTE this is the CLIENT-side entry point and is orthogonal to the etserver
# daemon below: etserver can be listening on 2022 (synthetics green) while
# every `et` login still fails, which is exactly how #741 presented.
etterminal_path = "#{node[:homebrew][:prefix]}/bin/etterminal"

# Guard on the link TARGET, not mere existence — an already-provisioned Mac
# that changed brew prefix (Intel -> Apple Silicon migration) carries a symlink
# pointing at a path that no longer exists, and a `test -L` guard would keep it
# forever. Same reasoning as the plist content-diff guard below.
execute "create etterminal symlink" do
  user node[:setup][:system_user]
  command "mkdir -p /usr/local/bin && ln -sf #{etterminal_path} /usr/local/bin/etterminal"
  only_if "test -f #{etterminal_path}"
  not_if "test \"$(readlink /usr/local/bin/etterminal)\" = \"#{etterminal_path}\""
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
