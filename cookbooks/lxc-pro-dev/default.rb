# frozen_string_literal: true
#
# lxc-pro-dev (CT 104): personal SSH workspace continuation of bare-metal `pro`.
#
# Bind-mounts (set up by Terraform):
#   - /mnt/data/workspace (rw, idmap)
#   - /mnt/Media (ro, optional)
#
# Networking: vmbr1, independent tailscaled (Magic DNS = pro-dev,
# tag:dev-host). Separate from pro-router LXC's tailscaled to give barrier
# isolation — pro-router upgrade failure does not kill personal SSH access.
#
# IMPORTANT: this LXC re-applies most of linux.rb's role set. The plan
# (line 202 of the migration doc) flags that bare-metal `pro` sources 30+
# profile.d files (typewritten / fzf-tab / enhancd / zoxide / lazygit /
# tmux resurrect etc) — degrading "ssh pro-dev" to a vanilla shell would
# be a UX regression. Therefore include core/programming/extras/manage/
# network roles inside this LXC.
#
# RAM 12 GiB / CPU 6 / rootfs 200 GiB.

return if node[:platform] == "darwin"

include_recipe "cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

# Full development environment, mirrors linux.rb's modular role set
# (minus server/mcp-server/edge-agent/roon-server/roon-mcp which live in
# their own LXCs). bluez/zeroconf/broadcom-wifi are intentionally absent —
# pro-dev does not own physical hardware.
include_role "core"
include_role "programming"
include_role "llm"
include_role "extras"
include_role "manage"
include_role "network"

# Independent tailscaled for tag:dev-host. ssh-keys cookbook handles the
# private key fetch from /ssh-keys/devices/pro-dev/private.
include_cookbook "tailscale"
include_cookbook "ssh-keys"

local_ruby_block "log lxc-pro-dev tailscale up hint" do
  block do
    state = `tailscale status --json 2>/dev/null`
    if state.empty? || state.include?('"BackendState":"NeedsLogin"')
      MItamae.logger.warn(<<~MSG)
        lxc-pro-dev: tailscaled installed but not authenticated. Run:
          sudo tailscale up \\
            --auth-key=$(aws ssm get-parameter --name /tailscale/pro-dev-auth-key --with-decryption --query Parameter.Value --output text) \\
            --advertise-tags=tag:dev-host \\
            --hostname=pro-dev \\
            --accept-routes \\
            --ssh
      MSG
    end
  end
end
