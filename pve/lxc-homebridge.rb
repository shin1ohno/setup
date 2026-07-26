# frozen_string_literal: true
#
# Entry recipe for the homebridge LXC (CT 120): Homebridge + the ECHONET Lite
# aircon plugin, exposing the bedroom / JIN's room Panasonic Eolia units to
# HomeKit. See cookbooks/lxc-homebridge.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-homebridge.rb

include_recipe "../cookbooks/functions/default"

# No docker-engine: the official homebridge deb bundles its own Node runtime
# and ships a systemd unit, so the stack is native (features_nesting=false on
# the container spec in home-monitor/contracts/devices.json).
include_cookbook "lxc-homebridge"
lxc_entry(tags: ["lxc", "homebridge"])
