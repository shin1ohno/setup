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

# awscli before unbound/lxc-core/elastic-agent: their SSM-gated blocks
# (unbound home.local local-data fetch, auto-mitamae-target orchestrator key,
# elastic-agent enrollment secrets) need the `aws` CLI on PATH, else they
# silently skip / fall back under non-TTY apply.
include_cookbook "awscli"
include_cookbook "unbound"
lxc_entry(tags: ["lxc", "dns-resolver"])
