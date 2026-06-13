# frozen_string_literal: true
#
# Entry recipe for the weave LXC (CT 109): weave 4-component MQTT mesh
# (mosquitto + roon-hub + weave-server + weave-web). Connects to lxc-roon
# at roon-lxc.home.local:9330 via roon-hub.
#
# Bind-mount (set up by Terraform):
#   - /mnt/data/weave (rw, idmap)
#
# RAM 4 GiB / CPU 2.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-weave.rb
#
# Service logic lives in cookbooks/lxc-weave (Phase 4 extraction). This entry
# stays thin: include the cookbook, then the lxc-core + elastic-agent tail.

include_recipe "../cookbooks/functions/default"

include_cookbook "lxc-weave"
lxc_entry(tags: ["lxc", "weave"])
