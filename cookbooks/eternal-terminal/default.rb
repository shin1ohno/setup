# frozen_string_literal: true

# Eternal Terminal (et) - Remote shell that automatically reconnects
# A resilient SSH alternative that maintains connectivity during network changes
# https://github.com/MisterTea/EternalTerminal

# node[:platform] is normalized to "ubuntu" for any debian-family host
# (see cookbooks/functions/default.rb #90), but eternal-terminal has
# distinct install paths per distro: Ubuntu uses Launchpad PPA, Debian
# uses MisterTea's debian-et repo. Probe /etc/os-release ID directly so
# debian hosts (PVE LXC trixie templates) don't fall into the PPA branch
# which fails with "add-apt-repository: not found".
distro_platform = if node[:platform] == "darwin"
  "darwin"
else
  os_release_id = `. /etc/os-release && echo $ID`.strip
  case os_release_id
  when "ubuntu" then "ubuntu"
  when "debian" then "debian"
  when "arch", "manjaro", "endeavouros" then "arch"
  else node[:platform]
  end
end

case distro_platform
when "darwin"
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

when "arch"
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
# gone. On darwin it is the ONLY recovery path: the central self-heal-resolve
# loop restarts services via `pct exec` (LXC-only) and cannot reach Macs.
if distro_platform == "darwin"
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
else
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
end

# Delete the prior documentation-only profile entry. Pure comments still
# take ~1-3ms to parse on every shell start; `man et` and the cookbook
# itself are the documentation channels.
file "#{node[:setup][:root]}/profile.d/50-eternal-terminal.sh" do
  action :delete
end
