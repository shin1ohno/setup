# frozen_string_literal: true
#
# lxc-pro-router (CT 99): Tailscale subnet route advertise + AWS VPC tunnel.
#
# Per migration plan (frolicking-beaming-crescent.md Phase 3a):
#   - tag:home-router (advertises 192.168.1.0/24 to tailnet)
#   - AWS VPC tunnel peer receiving from nrt-subnet-router
#   - Pattern 2 main path (Pattern 1 break-glass lives on PVE host)
#
# RAM 256 MiB / CPU 1 / vmbr1.

return if node[:platform] == "darwin"

# Common LXC user provisioning (shin1ohno + sudo + ssh authorized_keys).
include_cookbook "lxc-shared-user"

# IP forwarding is required for `tailscale up --advertise-routes`. Without
# this sysctl any node accepting the advertised 192.168.1.0/24 route via
# tailnet will black-hole packets through this LXC. Persisted via drop-in
# so it survives reboots and `pct restart`.
file "#{node[:setup][:root]}/lxc-pro-router-ip-forward.conf" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~CFG
    # Managed by setup/cookbooks/lxc-pro-router. Do not edit
    # /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf by hand — the next
    # mitamae run will overwrite it.
    net.ipv4.ip_forward = 1
    net.ipv6.conf.all.forwarding = 1
  CFG
end

execute "install pro-router ip-forward sysctl drop-in" do
  command "sudo install -m 644 -o root -g root #{node[:setup][:root]}/lxc-pro-router-ip-forward.conf /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf"
  not_if "diff -q #{node[:setup][:root]}/lxc-pro-router-ip-forward.conf /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf 2>/dev/null"
  notifies :run, "execute[apply pro-router ip-forward sysctl]"
end

execute "apply pro-router ip-forward sysctl" do
  command "sudo sysctl -p /etc/sysctl.d/99-lxc-pro-router-ip-forward.conf"
  action :nothing
end

# Reuse the canonical Tailscale install path.
include_cookbook "tailscale"

# Helper output: tell the operator the exact `tailscale up` command for
# this LXC. Auth key fetched from SSM at install time.
local_ruby_block "log lxc-pro-router tailscale up hint" do
  block do
    state = `tailscale status --json 2>/dev/null`
    if state.empty? || state.include?('"BackendState":"NeedsLogin"')
      MItamae.logger.warn(<<~MSG)
        lxc-pro-router: tailscaled installed but not authenticated. Run:
          sudo tailscale up \\
            --auth-key=$(aws ssm get-parameter --name /tailscale/pro-router-auth-key --with-decryption --query Parameter.Value --output text) \\
            --advertise-routes=192.168.1.0/24 \\
            --advertise-tags=tag:home-router \\
            --hostname=pro-router \\
            --accept-dns=false \\
            --ssh
      MSG
    end
  end
end
