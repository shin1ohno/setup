# frozen_string_literal: true
#
# session-search (Linux): the shared client install (common.rb) plus C5, the
# sweep timer, as a systemd USER timer (§6.4):
#   ~/.config/systemd/user/ccs-sweep.service   Type=oneshot, `ccs ingest --sweep --quiet`
#   ~/.config/systemd/user/ccs-sweep.timer     OnBootSec=2min, OnActiveSec=2min, OnUnitInactiveSec=15min
#
# Activation follows the systemd Timer Verification Gate: daemon-reload ->
# enable timer -> restart timer -> start service (--no-block, so the apply does
# not wait for a sweep). `systemctl --user` needs the user's manager bus at
# /run/user/<uid>/bus, which exists while the user is logged in or lingering
# (pro-dev and sh1-cloud linger). Without the bus the step logs a WARN and
# exits 0; the next apply with the bus present activates it.
#
# Verify after apply: `systemctl --user list-timers ccs-sweep.timer` must show
# a NEXT time (a `-` there means the timer will never fire).

include_recipe "common"

ss = node[:session_search]
return if ss[:skip]

ss_user = ss[:user]
home = ss[:home]
ss_group = ss[:group]
gate = ss[:redactor_gate]
unit_dir = "#{home}/.config/systemd/user"

["#{home}/.config/systemd", unit_dir].each do |d|
  directory d do
    owner ss_user
    group ss_group
    mode "755"
    only_if gate
  end
end

%w[ccs-sweep.service ccs-sweep.timer].each do |unit|
  remote_file "#{unit_dir}/#{unit}" do
    source "files/systemd/#{unit}"
    owner ss_user
    group ss_group
    mode "644"
    only_if gate
    notifies :run, "execute[reload ccs-sweep timer]"
  end
end

activate = <<~SH.strip
  sh -c '
    XDG_RUNTIME_DIR=/run/user/$(id -u)
    export XDG_RUNTIME_DIR
    if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
      echo "WARN: no systemd user bus for $(id -un); ccs-sweep.timer not activated (log in or enable linger, then re-apply)" >&2
      exit 0
    fi
    systemctl --user daemon-reload &&
      systemctl --user enable ccs-sweep.timer &&
      systemctl --user restart ccs-sweep.timer &&
      systemctl --user start --no-block ccs-sweep.service
  '
SH

# First activation: the enable symlink is the durable marker (readable from a
# root apply too, unlike `systemctl --user is-enabled`).
execute "activate ccs-sweep timer" do
  command activate
  user ss_user
  only_if gate
  not_if "test -L #{unit_dir}/timers.target.wants/ccs-sweep.timer"
end

# Unit content changed: re-run the same four steps so the running timer picks
# up the new definition (enable alone would leave the old one in memory).
execute "reload ccs-sweep timer" do
  command activate
  user ss_user
  action :nothing
  only_if gate
end
