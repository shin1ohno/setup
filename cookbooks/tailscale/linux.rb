# frozen_string_literal: true

# Upstream's install.sh picks the right apt/yum repo for the running distro and
# installs tailscaled as a systemd unit. The macOS side tracks the .pkg release
# instead — see darwin.rb.
remote_file "#{node[:setup][:root]}/tailscale.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "#{node[:setup][:root]}/tailscale.sh" do
  not_if "which tailscale"
end

# Ubuntu 24.04 ships a `/usr/sbin/resolvconf` symlink to `resolvectl`
# (compat shim from the systemd-resolved package). tailscaled detects the
# binary and calls `resolvconf -m 0 -x -a tailscale`, but resolvectl
# interprets the `-a` argument as a literal interface name and errors out
# with "Failed to resolve interface 'tailscale': No such device". DNS
# still works because tailscaled falls back to writing /etc/resolv.conf
# directly, but `tailscale status` carries a permanent health-check
# warning. Divert the shim so tailscaled never finds the binary; it then
# skips the resolvconf path and goes straight to DirectManager (already
# the working fallback). Reversible via `dpkg-divert --remove`.
execute "divert systemd-resolved resolvconf shim for tailscale DirectManager" do
  command "sudo dpkg-divert --local --rename --add /usr/sbin/resolvconf"
  only_if "test -L /usr/sbin/resolvconf && dpkg -S /usr/sbin/resolvconf 2>/dev/null | grep -q '^systemd-resolved:'"
  not_if "dpkg-divert --list /usr/sbin/resolvconf 2>/dev/null | grep -q 'local diversion of /usr/sbin/resolvconf'"
  notifies :run, "execute[restart tailscaled after resolvconf divert]"
end

execute "restart tailscaled after resolvconf divert" do
  command "sudo systemctl restart tailscaled"
  only_if "systemctl is-active --quiet tailscaled"
  action :nothing
end
