# frozen_string_literal: true
#
# Entry recipe for the roon LXC (CT 100): Roon Server (RAAT/SOOD multicast).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-roon.rb

include_recipe "../cookbooks/functions/default"

include_cookbook "lxc-roon"
include_cookbook "lxc-systemd-hardening-fix"
lxc_entry(tags: ["lxc", "roon", "privileged"])
