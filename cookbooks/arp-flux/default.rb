# Suppress ARP flux on multi-NIC Linux hosts via sysctl.
#
# Why: hosts with 2+ NICs in the same subnet (e.g. pro with
# enp11s0/enp12s0/enp25s0 all in 192.168/16) hit a DHCP ACD false
# positive every renewal cycle because the kernel's default
# arp_ignore=0 lets any NIC reply for any local IP. The non-DHCP NIC
# answers the renewing NIC's own ACD probe, NetworkManager declares
# a conflict, and the lease is released. Setting arp_ignore=1 +
# arp_announce=2 (Linux multi-homing best practice) eliminates the
# cross-NIC reply path. Harmless on single-NIC hosts.
#
# Linux-only: macOS does not use /etc/sysctl.d. The cookbook is
# included from linux.rb so platform gating is implicit, but we add
# a defensive `only_if` in case future composition pulls it in
# elsewhere.

return unless node[:platform] != "darwin"

source = File.expand_path("../files/30-arp-flux.conf", __FILE__)

execute "install arp-flux sysctl drop-in" do
  command <<~BASH
    cp #{source} /etc/sysctl.d/30-arp-flux.conf
    chown root:root /etc/sysctl.d/30-arp-flux.conf
    chmod 644 /etc/sysctl.d/30-arp-flux.conf
  BASH
  user node[:setup][:system_user]
  not_if "test -f /etc/sysctl.d/30-arp-flux.conf && diff -q #{source} /etc/sysctl.d/30-arp-flux.conf"
end

# Apply the new values to the running kernel without a reboot.
# `sysctl --system` reloads every drop-in under /etc/sysctl.d/, so it
# also re-asserts any sibling files (disable-ipv6, etc.). Cheap and
# idempotent. The not_if checks all four target values are already
# in effect.
execute "apply arp-flux sysctl" do
  command "sysctl --system"
  user node[:setup][:system_user]
  not_if <<~BASH
    sysctl -n net.ipv4.conf.all.arp_ignore | grep -q '^1$' && \
    sysctl -n net.ipv4.conf.all.arp_announce | grep -q '^2$' && \
    sysctl -n net.ipv4.conf.default.arp_ignore | grep -q '^1$' && \
    sysctl -n net.ipv4.conf.default.arp_announce | grep -q '^2$'
  BASH
end
