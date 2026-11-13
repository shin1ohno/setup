# frozen_string_literal: true
#
# codex-cli::remote_control — keep Codex remote control running on a Linux
# host through systemd user units, so the official ChatGPT app can reach the
# host's ~/.codex sessions after every reboot. Opt-in per host:
#
#   node.reverse_merge!(codex_cli: { remote_control: true })   # pve/lxc-pro-dev.rb
#
# Nothing here runs unless that attribute is true, and it needs systemd, so
# only a Linux entry recipe may set it (a non-systemd host raises instead of
# silently doing nothing). Operating guide (pairing, revocation, updates):
# cookbooks/codex-cli/README.md.
#
# Deployed for the workstation user:
#   ~/.local/share/codex-remote-control/guard.sh              helper the units call
#   ~/.config/systemd/user/codex-remote-control.service       oneshot, `codex remote-control start`
#   ~/.config/systemd/user/codex-remote-control-watch.{service,timer}
#                                                             5-minute watchdog
#   ~/.codex/app-server-daemon/settings.json                  "updater": {"autoUpdateEnabled": false}
#
# The owner's off switch is ~/.config/codex-remote-control.disabled. While it
# exists the units do not start, the watchdog does nothing, and this recipe runs
# `systemctl --user disable --now` on both units instead of enabling them. This
# deviates from cookbooks/session-search/linux.rb, whose only idempotency
# marker is the enable symlink: here that alone would re-enable a unit the owner
# turned off on the next apply, and `codex remote-control start` would switch
# remote control back on. Deleting the file hands control back to the next apply.
#
# Activation otherwise follows session-search: the systemd user bus at
# /run/user/<uid>/bus must exist (pro-dev lingers); without it the step logs a
# WARN and exits 0, and the next apply with the bus present activates the units.

return unless node.dig(:codex_cli, :remote_control)

unless File.directory?("/run/systemd/system")
  raise "codex-cli::remote_control needs systemd user units; set codex_cli.remote_control only from a Linux entry recipe"
end

# Target user: a non-root apply uses node[:setup]. pro-dev's auto-mitamae
# applies as root, where node[:setup] is /root, so the workstation user is
# resolved instead -- the same rule as session-search and memory-mirror.
workstation_user = "shin1ohno"
if run_command("id -u", error: false).stdout.strip == "0"
  rc_user = workstation_user
  rc_home = run_command("sh -c 'printf %s ~#{workstation_user}'", error: false).stdout.strip
  rc_group = run_command("id -gn #{workstation_user}", error: false).stdout.strip
  if rc_home.empty? || rc_home.start_with?("~") || rc_group.empty?
    MItamae.logger.warn(
      "codex-cli::remote_control: running as root but user #{workstation_user} could not be resolved " \
      "(home=#{rc_home.inspect} group=#{rc_group.inspect}) -- skipping the remote-control units.",
    )
    return
  end
else
  rc_user = node[:setup][:user]
  rc_home = node[:setup][:home]
  rc_group = node[:setup][:group]
end

share_dir = "#{rc_home}/.local/share/codex-remote-control"
guard = "#{share_dir}/guard.sh"
unit_dir = "#{rc_home}/.config/systemd/user"
sentinel = "#{rc_home}/.config/codex-remote-control.disabled"
daemon_dir = "#{rc_home}/.codex/app-server-daemon"
settings_json = "#{daemon_dir}/settings.json"
units = %w[codex-remote-control.service codex-remote-control-watch.service codex-remote-control-watch.timer]

# Only the directories this recipe owns, plus the systemd ones session-search
# also declares. ~/.local and ~/.local/share are left alone: they exist (mise
# lives under them) and may be 0700, which a mode here would loosen.
[share_dir, "#{rc_home}/.config/systemd", unit_dir].each do |d|
  directory d do
    owner rc_user
    group rc_group
    mode "755"
  end
end

directory daemon_dir do
  owner rc_user
  group rc_group
  mode "700"
end

# Every change that alters what the running daemon was started with -- the
# guard (environment scrub list), a unit, the updater setting -- notifies the
# one delayed reload below, which restarts the daemon. mitamae runs each
# delayed notification once per apply (recipe_executor.rb `uniq`), so a first
# apply restarts once. A restart ends turns a phone session has in flight.
remote_file guard do
  source "files/codex-remote-control-guard.sh"
  owner rc_user
  group rc_group
  mode "755"
  notifies :run, "execute[reload codex-remote-control units]"
end

units.each do |unit|
  remote_file "#{unit_dir}/#{unit}" do
    source "files/systemd/#{unit}"
    owner rc_user
    group rc_group
    mode "644"
    notifies :run, "execute[reload codex-remote-control units]"
  end
end

# Owner decision: no daemon auto-updater. It fetches and runs an install
# script every hour; the daemon is updated by hand instead
# (`codex app-server daemon update`). Only the updater key is touched -- the
# daemon's own save() keeps keys it does not know, so remoteControlEnabled and
# featureOverrides stay as Codex wrote them. Applies whether or not the
# sentinel exists; the reload stops an updater the running daemon started.
execute "disable the Codex daemon auto-updater" do
  command "/bin/sh #{guard} updater-off #{settings_json}"
  user rc_user
  not_if "/bin/sh #{guard} updater-off --check #{settings_json}"
  notifies :run, "execute[reload codex-remote-control units]"
end

user_systemctl = "XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user"

bus_check = <<~SH.strip
  XDG_RUNTIME_DIR=/run/user/$(id -u)
  export XDG_RUNTIME_DIR
  if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
    echo "WARN: no systemd user bus for $(id -un); codex-remote-control units not changed (log in or enable linger, then re-apply)" >&2
    exit 0
  fi
SH

# Enable both units and (re)start them unless the owner's sentinel exists;
# with the sentinel, only reload so the changed definitions are known. The
# timer starts first and the service start does not block (the order of the
# systemd Timer Verification Gate): a failing first start then cannot leave the
# watchdog stopped or fail the apply -- Restart=on-failure and the watchdog keep
# retrying.
activate = <<~SH.strip
  sh -c '
    #{bus_check}
    systemctl --user daemon-reload || exit 1
    if [ -e "#{sentinel}" ]; then
      echo "WARN: #{sentinel} exists; codex-remote-control units left disabled" >&2
      exit 0
    fi
    systemctl --user enable codex-remote-control.service codex-remote-control-watch.timer &&
      systemctl --user restart codex-remote-control-watch.timer &&
      systemctl --user restart --no-block codex-remote-control.service
  '
SH

deactivate = <<~SH.strip
  sh -c '
    #{bus_check}
    systemctl --user disable --now codex-remote-control-watch.timer codex-remote-control.service
  '
SH

enabled_marker = "test -L #{unit_dir}/default.target.wants/codex-remote-control.service"
timer_marker = "test -L #{unit_dir}/timers.target.wants/codex-remote-control-watch.timer"

# Activation is needed when an enable symlink is missing or the watchdog timer
# is not running (guards run as rc_user, so `systemctl --user` reaches that
# user's manager from a root apply too). The command itself is a no-op; the
# notification runs the one reload. Skipped while the sentinel exists, so an
# apply never turns the owner's switch back on.
execute "codex-remote-control units need activation" do
  command "true"
  user rc_user
  not_if "test -e #{sentinel} || { #{enabled_marker} && #{timer_marker} && #{user_systemctl} is-active --quiet codex-remote-control-watch.timer; }"
  notifies :run, "execute[reload codex-remote-control units]"
end

# Sentinel present and either unit still enabled or running: turn both off.
execute "disable codex-remote-control units (owner sentinel present)" do
  command deactivate
  user rc_user
  only_if "test -e #{sentinel} && { #{enabled_marker} || #{timer_marker} || #{user_systemctl} is-active --quiet codex-remote-control.service codex-remote-control-watch.timer; }"
end

execute "reload codex-remote-control units" do
  command activate
  user rc_user
  action :nothing
end
