# frozen_string_literal: true
#
# lxc-dev-workstation: developer workstation LXC pattern.
#
# A long-lived LXC that re-applies linux.rb's modular role set so SSH
# sessions get the same shell ergonomics (profile.d / fzf-tab / mise /
# lazygit / tmux resurrect etc.) as the bare-metal box. Hardware-coupled
# cookbooks (bluez / zeroconf / broadcom-wifi / edge-agent / roon-server)
# are intentionally absent — a developer LXC does not own physical
# hardware.
#
# Per-host customization is driven by node[:lxc_dev]:
#   hostname           — short hostname (defaults to `hostname -s`)
#   tailscale_tag      — tag:* assertion (defaults to "tag:dev-host")
#   tailscale_ssm_key  — SSM parameter path for the tailscale auth-key
#                        (defaults to "/tailscale/<hostname>-auth-key")
#
# Entry recipes (e.g. lxc-pro-dev.rb) set those attributes before
# include_cookbook "lxc-dev-workstation".

return if node[:platform] == "darwin"

# functions + node[:setup] seeded by the entry recipe.
# Cookbooks must be invoked via that entry, not directly with
# `mitamae local cookbooks/lxc-dev-workstation/default.rb`.

# Defaults — entry recipes can override any of these via reverse_merge!.
detected_hostname = run_command("hostname -s", error: false).stdout.strip
node.reverse_merge!(
  lxc_dev: {
    hostname: detected_hostname,
    tailscale_tag: "tag:dev-host",
    tailscale_ssm_key: nil,
  }
)
lxc_hostname = node[:lxc_dev][:hostname]
tailscale_tag = node[:lxc_dev][:tailscale_tag]
tailscale_ssm_key = node[:lxc_dev][:tailscale_ssm_key] || "/tailscale/#{lxc_hostname}-auth-key"

# Common LXC user provisioning (shin1ohno + sudo + ssh authorized_keys).
include_cookbook "lxc-shared-user"

# Default AWS profile config for ssh-keys cookbook. Per-host role files
# can override via reverse_merge before this include — e.g. to add a
# 2nd profile, point at different SSM paths, or set a bootstrap_profile
# for the initial fetch on a fresh LXC.
#
# This block must come BEFORE `include_role "core"` because the core
# role pulls in ssh-keys, which in turn requires the AWS profile to be
# configured at the require_external_auth gate.
node.reverse_merge!(
  aws_credentials: {
    profiles: {
      "pve-bootstrap-ssm" => {
        access_key_id_ssm:     "/home-monitor/iam/pve-bootstrap-ssm/access-key-id",
        secret_access_key_ssm: "/home-monitor/iam/pve-bootstrap-ssm/secret-access-key",
        region:                "ap-northeast-1",
      },
    },
  }
)
# Bootstrap pve-bootstrap-ssm to ~/.aws/credentials before ssh-keys runs.
# On a fresh LXC the operator passes admin creds via env vars once; this
# cookbook fetches the limited credentials from SSM and persists them.
include_cookbook "aws-credentials"

# Full development environment, mirrors linux.rb's modular role set
# minus server/mcp-server/edge-agent/roon-server/roon-mcp which live
# in their own LXCs. The core role pulls in ssh-keys, which now finds
# the pve-bootstrap-ssm profile already configured by aws-credentials.
include_role "core"
include_role "programming"
include_role "llm"
include_role "extras"
include_role "manage"
include_role "network"

# Independent tailscaled. ssh-keys (already pulled in via core) handles
# the private key fetch from /ssh-keys/devices/<hostname>/private.
include_cookbook "tailscale"
include_cookbook "ssh-keys"

local_ruby_block "log lxc-dev-workstation tailscale up hint" do
  block do
    state = `tailscale status --json 2>/dev/null`
    if state.empty? || state.include?('"BackendState":"NeedsLogin"')
      MItamae.logger.warn(<<~MSG)
        lxc-dev-workstation (#{lxc_hostname}): tailscaled installed but not authenticated. Run:
          sudo tailscale up \\
            --auth-key=$(aws ssm get-parameter --name #{tailscale_ssm_key} --with-decryption --query Parameter.Value --output text) \\
            --advertise-tags=#{tailscale_tag} \\
            --hostname=#{lxc_hostname} \\
            --accept-routes \\
            --ssh
      MSG
    end
  end
end
