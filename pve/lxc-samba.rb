# frozen_string_literal: true
#
# Entry recipe for the samba LXC (CT 101): SMB share for [Media] read-only.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-samba.rb

include_recipe "../cookbooks/functions/default"

include_cookbook "samba-server"
lxc_entry(tags: ["lxc", "samba"])
