# frozen_string_literal: true
#
# Entry recipe for the hydra LXC (CT 106): Ory Hydra OAuth 2.0 / OIDC server
# (native Go binary + systemd unit, Aurora DSN from SSM).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-hydra.rb

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

# Bind hydra admin API on all interfaces so the consent LXC (CT 110)
# can reach it cross-LXC for the OAuth login/consent flow. The default
# in cookbooks/hydra-server is 127.0.0.1 (loopback-only) for safety;
# that breaks `/consent/login` when the consent app's httpx client
# hits hydra.home.local:4445 from a different LXC. The hydra LXC
# itself sits on a private LAN (192.168.1.0/24, no public exposure)
# so the loopback-only invariant isn't load-bearing here.
node.reverse_merge!(
  hydra_server: {
    admin_bind_host: "0.0.0.0",
  },
)

include_cookbook "lxc-hydra"
# Phase 3a: receiver-side of the centralised auto-apply system. node_exporter
# exposes node + textfile metrics scraped by the monitoring LXC; auto-mitamae
# -target installs the forced-command authorized_keys entry that the
# orchestrator on monitoring (192.168.1.76) uses to push mitamae apply runs.
include_cookbook "node-exporter"
include_cookbook "auto-mitamae-target"
