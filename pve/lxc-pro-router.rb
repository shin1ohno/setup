# frozen_string_literal: true
#
# Entry recipe for the pro-router LXC (CT 102): Tailscale subnet route
# advertise + AWS VPC tunnel (Pattern 2 main path).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-pro-router.rb
#
# `tailscale up` is intentionally not part of the cookbook — auth-key
# fetch + tag flag is an operator step (see cookbook log_warn hint).

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

include_cookbook "lxc-pro-router"
