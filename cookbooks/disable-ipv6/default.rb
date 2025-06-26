# Disable IPv6 via sysctl
remote_file "/etc/sysctl.d/99-disable-ipv6.conf" do
  source "files/99-disable-ipv6.conf"
  owner "root"
  group "root"
  mode "644"
end

# Apply sysctl settings immediately
execute "apply-ipv6-disable" do
  command "sysctl -p /etc/sysctl.d/99-disable-ipv6.conf"
  user "root"
  not_if "sysctl net.ipv6.conf.all.disable_ipv6 | grep -q '= 1'"
end

# Disable IPv6 in GRUB (for persistent disable across reboots)
execute "disable-ipv6-grub" do
  command <<~BASH
    if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
      sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
      update-grub
    fi
  BASH
  user "root"
  only_if "test -f /etc/default/grub"
  not_if "grep -q 'ipv6.disable=1' /etc/default/grub"
end

# For systems using NetworkManager
execute "disable-ipv6-networkmanager" do
  command <<~BASH
    if command -v nmcli &>/dev/null; then
      nmcli connection modify "$(nmcli -t -f NAME connection show --active | head -n1)" ipv6.method "disabled" 2>/dev/null || true
    fi
  BASH
  user "root"
  only_if "command -v nmcli"
end