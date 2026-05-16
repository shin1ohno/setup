# frozen_string_literal: true
#
# Strip systemd hardening directives from selected upstream unit files so
# they start inside a privileged PVE LXC. Privileged LXCs share the host
# kernel and cannot satisfy mount-namespace setup requested by
# ProtectSystem= / ProtectHome= / PrivateTmp= / NoNewPrivileges= etc. —
# the unit fails with status=226/NAMESPACE every time.
#
# Affected units (observed on CT 100 roon, 2026-05-16):
#   - systemd-logind.service  (restart loop, blocks login session mgmt)
#   - logrotate.service       (daily timer fail, /var/log growth risk)
#   - man-db.service          (12 directives, weekly timer fail, stale man cache)
#   - nftables.service        (2 directives, in-LXC firewall load fails)
#
# postfix is intentionally NOT in this list — it is hardening-strippable
# but the fleet (Roon LXC, monitoring LXC, etc.) does not need local mail
# delivery. lxc-mask-unsupported-units masks it on all LXCs instead.
#
# Approach: copy /usr/lib/systemd/system/<unit>.service into
# /etc/systemd/system/, stripped of every directive that triggers the
# namespace setup. Reload + reset-failed + start only when the stripped
# file content changes.
#
# Why not drop-in `=no` overrides: tested 2026-05-06 and 2026-05-16 —
# systemctl show reports the effective value as no, but the unit still
# fails with status=226. The hardening directives must be ABSENT from
# the evaluated unit, not overridden. See ~/.claude/rules/pve-lxc.md.

return if node[:platform] == "darwin"

hardening_pattern = (
  "ProtectSystem|ProtectHome|PrivateTmp|NoNewPrivileges|ProtectControlGroups|" \
  "RestrictNamespaces|ProtectKernelTunables|ProtectKernelModules|ProtectKernelLogs|" \
  "ProtectClock|ProtectHostname|ProtectProc|PrivateDevices|PrivateUsers|" \
  "PrivateNetwork|PrivateMounts|PrivateIPC|PrivatePIDs|" \
  "MemoryDenyWriteExecute|RestrictRealtime|RestrictSUIDSGID|" \
  "RestrictAddressFamilies|LockPersonality|" \
  "SystemCallFilter|SystemCallArchitectures|CapabilityBoundingSet|" \
  "AmbientCapabilities|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|" \
  "ExecPaths|NoExecPaths|BindPaths|BindReadOnlyPaths|" \
  "TemporaryFileSystem|RootDirectory|RootImage|MountFlags|" \
  "DeviceAllow|DevicePolicy|KeyringMode|ProcSubset|RemoveIPC"
)

%w(logrotate systemd-logind man-db nftables).each do |svc|
  source_unit = "/usr/lib/systemd/system/#{svc}.service"
  override_unit = "/etc/systemd/system/#{svc}.service"

  execute "strip hardening from #{svc}.service for privileged LXC" do
    command "sed -E '/^(#{hardening_pattern})=/d' #{source_unit} > #{override_unit}"
    user node[:setup][:system_user]
    # Idempotency: skip when override exists, has zero hardening lines, and
    # is at least as new as the upstream unit (re-derive on Debian update).
    not_if "test -f #{override_unit} && " \
           "! grep -qE '^(#{hardening_pattern})=' #{override_unit} && " \
           "test #{override_unit} -nt #{source_unit}"
    notifies :run, "execute[reload + reset-failed + start #{svc}]"
  end

  execute "reload + reset-failed + start #{svc}" do
    command "systemctl daemon-reload && " \
            "systemctl reset-failed #{svc}.service && " \
            "systemctl start #{svc}.service"
    user node[:setup][:system_user]
    action :nothing
  end
end
