# frozen_string_literal: true

return if node[:platform] != "darwin"

remote_file "#{node[:setup][:root]}/mac-setup.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/macos"
end

# Enforce the always-on power settings from files/macos' Energy block.
#
# `files/macos` is only DEPLOYED (remote_file above) — it is never executed by
# mitamae (it also does disruptive `defaults write` UI changes that must stay a
# manual, one-time run). That left the pmset energy settings enforced by nothing
# on any Mac. mini (a Mac mini, always AC) therefore kept its stock `sleep 1`
# (idle-sleep after 1 min) and slept dozens of times a day; during sleep its
# network stack is down and the CT111 Kibana synthetics TCP probe to
# etserver:2022 SYN-drops → self-heal alert (setup #603). The fleet assumes mini
# is "always-on" (see the synthetics comment + home-monitor devices.tf) but
# nothing made it so. This resource extracts JUST the power settings and enforces
# them idempotently on every darwin apply. `-c sleep 0` (never idle-sleep on AC)
# is the always-on invariant; on laptops `-b sleep 5` (in files/macos, set on the
# one-time manual run) still sleeps on battery. Values mirror files/macos exactly.
execute "enforce always-on power settings" do
  command "sudo pmset -c sleep 0 && sudo pmset -a lidwake 0 && " \
          "sudo pmset -a autorestart 1 && sudo pmset -a hibernatemode 0 && " \
          "sudo pmset -a standbydelay 86400"
  # Skip when AC-power idle sleep is already 0 (a macOS major update can reset
  # pmset, flipping this back to non-zero → this re-runs and re-converges).
  not_if "pmset -g custom | awk '/AC Power/{ac=1} ac && /^ *sleep /{print $2; exit}' | grep -qx 0"
end
