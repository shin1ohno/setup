# frozen_string_literal: true
#
# Entry recipe for the hydra LXC (CT 106): Ory Hydra OAuth 2.0 / OIDC server
# (native Go binary + systemd unit, Aurora DSN from SSM).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local lxc-hydra.rb

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

include_cookbook "lxc-hydra"
