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
