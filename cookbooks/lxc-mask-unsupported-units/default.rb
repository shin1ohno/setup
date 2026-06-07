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
#   - mount units (dev-*.mount, run-lock.mount, tmp.mount): the LXC has its
#     own /run and /tmp tmpfs already populated by the container runtime; the
#     systemd-managed mount units cannot mount over them. NOTE: /run/lock is
#     NOT a host bind-mount — it is created as a 1777 dir on the /run tmpfs by
#     systemd-tmpfiles-setup.service (which therefore must NOT be masked; see
#     the unmask step below).
#   - getty: LXC has no real TTY; `pct enter` and SSH bypass them entirely
#   - journald: host journald captures container output (`journalctl
#     --machine=<vmid>` on the PVE host); in-LXC journald is redundant
#   - networkd: LXC inherits its veth from the host; in-LXC networkd would
#     conflict with the host-side network config
#   - sysctl, udev, systemd-tmpfiles-setup-dev*: host owns /dev + sysctl for
#     LXC guests. Only the -dev tmpfiles variants are masked — the plain
#     systemd-tmpfiles-setup.service must run (it creates /run/lock et al.).
#
# Unused-by-design units also masked:
#   - postfix.service: every LXC in the fleet (Roon, monitoring,
#     application LXCs) has no need for local mail delivery. CT 111
#     (monitoring) had postfix in a failed exit=1 state for 5 days;
#     CT 100 had it hardening-strip-started but unused. Masking on
#     all LXCs is simpler than keeping per-LXC postfix configs.
#
# References: ~/.claude/rules/pve-lxc.md, PR #363 (sibling cookbook).
#
# OS gate (darwin skip) now lives at the include site (roles/lxc-core).
# The container guard below is a SEPARATE concern and stays here.

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
  systemd-udev-load-credentials.service
  systemd-journald-dev-log.socket
  systemd-journald.socket
  systemd-networkd.socket
  postfix.service
).freeze

# Postfix is an installed Debian package, not a built-in systemd unit.
# Debian's postfix package writes its unit file directly to
# /etc/systemd/system/postfix.service (rather than /lib/systemd/system/
# where most packages put theirs). `systemctl mask` then fails with
# "File '/etc/systemd/system/postfix.service' already exists" because
# the target slot for the /dev/null symlink is occupied by the package's
# regular file. Confirmed on CT 100 (roon) 2026-05-17: cycle stuck on
# mitamae_fail until the package was purged AND the unit file removed.
#
# Two-step preparation before the mask loop:
#   1. apt purge if the package is still installed (stops service, removes
#      most config; leaves the systemd unit file because Debian's postfix
#      does NOT list it as a dpkg-managed conffile)
#   2. rm the orphan unit file if it is a regular file (not yet the
#      /dev/null symlink mask --now will create)
#
# Both steps are idempotent — `only_if` gates ensure no-op on hosts that
# have already converged. Re-applies after `daemon-reload` so the mask
# step in the loop below sees a clean slot.
execute "purge postfix package (unused; mask supersedes)" do
  command "DEBIAN_FRONTEND=noninteractive apt-get purge -y postfix"
  user node[:setup][:system_user]
  only_if "dpkg -l postfix 2>/dev/null | grep -q '^ii'"
end

execute "remove orphan postfix.service unit file (left by apt purge)" do
  command "rm -f /etc/systemd/system/postfix.service && systemctl daemon-reload"
  user node[:setup][:system_user]
  only_if "test -f /etc/systemd/system/postfix.service && ! test -L /etc/systemd/system/postfix.service"
end

UNITS_TO_MASK.each do |unit|
  execute "mask #{unit} (structurally non-functional in privileged LXC)" do
    command "systemctl mask --now #{unit}"
    user node[:setup][:system_user]
    not_if "systemctl is-enabled #{unit} 2>/dev/null | grep -qx 'masked'"
  end
end

# systemd-tmpfiles-setup.service was previously (incorrectly) in UNITS_TO_MASK.
# It IS functional inside an LXC and is what CREATES /run/lock (mode 1777)
# plus the other /run, /tmp, /var runtime dirs at boot — /run/lock is NOT
# inherited from the host. With it masked, every LXC restart loses /run/lock,
# silently breaking /var/lock → /run/lock consumers: notably the auto-mitamae
# mitamae-runner's `exec 9>/var/lock/auto-mitamae.lock` flock, which then
# emits no status= line and the orchestrator misclassifies the host as
# ssh_unreachable (so it never converges). Unmask it on hosts a prior apply
# masked, and run `systemd-tmpfiles --create` so /run/lock is restored
# immediately without waiting for a reboot. (2026-05-31: es-0/1/2 hit this
# after a storage-migration restart; the only -setup variant that must run is
# the non-dev one — the -dev / -dev-early variants stay masked because /dev is
# container-runtime-managed.)
execute "unmask systemd-tmpfiles-setup.service + create /run/lock" do
  command "systemctl unmask systemd-tmpfiles-setup.service && systemd-tmpfiles --create"
  user node[:setup][:system_user]
  only_if "systemctl is-enabled systemd-tmpfiles-setup.service 2>/dev/null | grep -qx 'masked'"
end

# After mask --now the unit cannot transition back to active, but its
# historic failed state remains until reset-failed. Clean once when any
# failure is still recorded so `systemctl --failed` returns empty.
#
# Build the unit list from `systemctl --failed` rather than the hardcoded
# UNITS_TO_MASK list — once a unit is masked it becomes `not-loaded` and
# `systemctl reset-failed <not-loaded-unit>` exits 1 with
# "Unit <name> not loaded", failing the whole recipe even though the
# real failed-state cleanup is unnecessary for that unit. Iterating over
# the live failed list is both correct and idempotent.
execute "reset-failed for currently-failed units" do
  command "systemctl --failed --no-legend | awk '{print $2}' | xargs -r systemctl reset-failed"
  user node[:setup][:system_user]
  not_if "test \"$(systemctl --failed --no-legend | wc -l)\" = 0"
end
