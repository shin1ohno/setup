# frozen_string_literal: true
#
# Entry recipe for the dns-resolver LXC (CT 118): unbound LAN DNS resolver for
# 192.168.1.0/24. Replaces the RTX1210 forwarder, which does not serve TCP/53 —
# RFC 7766 TCP fallback on truncated responses fails there, breaking Linux name
# resolution.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-dns-resolver.rb

include_recipe "../cookbooks/functions/default"

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

# awscli before unbound/lxc-core/elastic-agent: their SSM-gated blocks
# (unbound home.local local-data fetch, auto-mitamae-target orchestrator key,
# elastic-agent enrollment secrets) need the `aws` CLI on PATH, else they
# silently skip / fall back under non-TTY apply.
include_cookbook "awscli"
include_cookbook "unbound"
include_role "lxc-core"

node.reverse_merge!(elastic_agent: { tags: ["lxc", "dns-resolver"] })
include_cookbook "elastic-agent"
