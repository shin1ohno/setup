# frozen_string_literal: true
#
# Mask systemd units that are structurally non-functional in a privileged
# PVE LXC. These are units whose ExecStart depends on operations the LXC
# cgroup/namespace boundary forbids (mounting filesystems, allocating
# kernel hugepages, loading udev rules, opening real getty TTYs, running
# the journal daemon — host journald already serves the container, etc.).
#
# Unlike hardening-related failures (handled by lxc-systemd-hardening-fix),
# these units cannot be made to start by editing their service file. Masking
# removes them from `systemctl --failed` and lets `is-system-running`
# return `running` instead of `degraded`.
#
# Why masking is safe on a privileged LXC:
#   - mount units: LXC inherits /dev, /run, /tmp, /run/lock from the host
#     via bind-mounts; the systemd-managed mount units cannot mount over them
#   - getty: LXC has no real TTY; `pct enter` and SSH bypass them entirely
#   - journald: host journald captures container output (`journalctl
#     --machine=<vmid>` on the PVE host); in-LXC journald is redundant
#   - networkd: LXC inherits its veth from the host; in-LXC networkd would
#     conflict with the host-side network config
#   - sysctl, tmpfiles, udev: host owns these subsystems for LXC guests
#
# References: ~/.claude/rules/pve-lxc.md, PR #363 (sibling cookbook).

return if node[:platform] == "darwin"

# Only run inside an LXC container. lxc-core role (which includes this
# cookbook) is shared with the bare-metal PVE host (pve/pve-host.rb)
# which needs these units for normal operation — do NOT mask them
# there. `systemd-detect-virt --container` returns "lxc" inside an
# LXC and "none" on bare metal.
return unless `systemd-detect-virt --container 2>/dev/null`.strip == "lxc"

UNITS_TO_MASK = %w(
  dev-hugepages.mount
  dev-mqueue.mount
  run-lock.mount
  tmp.mount
  console-getty.service
  container-getty@1.service
  container-getty@2.service
  systemd-journal-flush.service
  systemd-journald.service
  systemd-network-generator.service
  systemd-networkd.service
  systemd-sysctl.service
  systemd-tmpfiles-clean.service
  systemd-tmpfiles-setup-dev-early.service
  systemd-tmpfiles-setup-dev.service
  systemd-tmpfiles-setup.service
  systemd-udev-load-credentials.service
  systemd-journald-dev-log.socket
  systemd-journald.socket
  systemd-networkd.socket
).freeze

UNITS_TO_MASK.each do |unit|
  execute "mask #{unit} (structurally non-functional in privileged LXC)" do
    command "systemctl mask --now #{unit}"
    user node[:setup][:system_user]
    not_if "systemctl is-enabled #{unit} 2>/dev/null | grep -qx 'masked'"
  end
end

# After mask --now the unit cannot transition back to active, but its
# historic failed state remains until reset-failed. Clean once when any
# failure is still recorded so `systemctl --failed` returns empty.
execute "reset-failed after masking unsupported units" do
  command "systemctl reset-failed #{UNITS_TO_MASK.join(' ')}"
  user node[:setup][:system_user]
  not_if "test \"$(systemctl --failed --no-legend | wc -l)\" = 0"
end
