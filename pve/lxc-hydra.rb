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
# in cookbooks/hydra-server is 127.0.0.1 (loopback-only); that breaks
# `/consent/login` when the consent app's httpx client hits
# hydra.home.local:4445 from a different LXC.
#
# Keeping admin on 0.0.0.0 does NOT expose the unauthenticated admin port
# to the LAN: the hydra-server cookbook installs an nftables source guard
# (cookbooks/hydra-server/files/hydra-admin-guard.nft) that drops tcp/4445
# from every source except the consent LXC (CT110, 192.168.1.75), the
# hydra host itself (CT106, 192.168.1.71), and loopback. The 0.0.0.0 bind
# is the reachability mechanism; the nftables rule is the access control.
# IP source of truth: home-monitor/contracts/devices.tf.
node.reverse_merge!(
  hydra_server: {
    admin_bind_host: "0.0.0.0",
    consent_ip: "192.168.1.75",
    self_ip: "192.168.1.71",
  },
)

include_cookbook "hydra-server"
include_role "lxc-core"

node.reverse_merge!(elastic_agent: { tags: ["lxc", "hydra"] })
include_cookbook "elastic-agent"
